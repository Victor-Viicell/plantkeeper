import type { Session } from "@supabase/supabase-js";
import { isTauri } from "@tauri-apps/api/core";
import type { UnlistenFn } from "@tauri-apps/api/event";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getSupabase } from "./supabase";

/**
 * Local-only escape hatch: while `true` the app signs in with a fake session
 * and serves a local device stand-in, with no backend involved. It is `false`
 * in the shipped app, so sign-in goes through Google and reads/writes go to
 * Supabase. Flip it to `true` only for offline UI work.
 */
const USE_MOCK_AUTH: boolean = false;

/**
 * Tells the rest of the app which mode it is running in, so adapters that talk
 * to Supabase can offer a matching stand-in. Sign-in is the only thing that
 * flips: everything else keeps the same contract either way.
 */
export function isMockAuthEnabled(): boolean {
  return USE_MOCK_AUTH;
}

export type AppUser = {
  email: string;
  name: string;
  avatarUrl: string | null;
};

export type AppSession = {
  user: AppUser;
};

/**
 * The scheme the mobile app registers for (tauri.conf.json → plugins.deep-link).
 * The matching redirect URL in Supabase → Authentication → URL Configuration is
 * `com.viicell.plantkeeper://login-callback`.
 */
const DEEP_LINK_SCHEME = "com.viicell.plantkeeper";
const REDIRECT_TO = `${DEEP_LINK_SCHEME}://login-callback`;

/** How long the browser gets to finish signing in before we give up. */
const SIGN_IN_TIMEOUT_MS = 300_000;

type AuthListener = (session: AppSession | null) => void;

const MOCK_STORAGE_KEY = "plantkeeper.mock-session";
const MOCK_USER: AppUser = {
  email: "gardener@plantkeeper.local",
  name: "Amante de Plantas",
  avatarUrl: null,
};

const mockListeners = new Set<AuthListener>();

/**
 * Restores the persisted session, if any. The app awaits this before choosing
 * between the login page and the main app.
 */
export function getSession(): Promise<AppSession | null> {
  return USE_MOCK_AUTH ? Promise.resolve(readMockSession()) : readSupabaseSession();
}

/**
 * Subscribes to sign-in and sign-out, and returns the unsubscribe function. The
 * restored session is not replayed here; `getSession()` already delivered it.
 */
export function onAuthStateChange(listener: AuthListener): () => void {
  if (USE_MOCK_AUTH) {
    mockListeners.add(listener);
    return () => mockListeners.delete(listener);
  }

  // A project with no credentials must not take the app down: there is no
  // session to follow, so there is simply nothing to subscribe to. The message
  // still reaches the user the moment they try to sign in.
  let subscription: { unsubscribe: () => void } | undefined;

  try {
    const { data } = getSupabase().auth.onAuthStateChange((event, session) => {
      if (event === "INITIAL_SESSION") return;
      listener(toAppSession(session));
    });

    subscription = data.subscription;
  } catch (cause) {
    console.error("Não foi possível acompanhar a sessão.", cause);
  }

  return () => subscription?.unsubscribe();
}

/**
 * Starts the Google sign-in flow. Resolves to `null` once the user is signed in
 * (or the redirect has been handed off), or to a message describing what broke.
 *
 * Which half of the journey runs depends on where the app is: a browser tab is
 * an ordinary origin that can receive the redirect itself, while the mobile app
 * is a webview — it cannot host Google's consent screen, so the browser does
 * that part and hands the result back as a deep link.
 */
export async function signInWithGoogle(): Promise<string | null> {
  if (USE_MOCK_AUTH) {
    // Stands in for the round trip through Google so the busy state is visible.
    await new Promise((resolve) => setTimeout(resolve, 600));
    setMockSession({ user: MOCK_USER });
    return null;
  }

  return isTauri() ? signInWithGoogleMobile() : signInWithGoogleWeb();
}

/**
 * Finishes a sign-in whose deep link arrived while the app was not listening —
 * Android may restart the app while the browser holds the consent screen. Called
 * once on boot; resolves to the session it recovered, or `null` if there was no
 * sign-in waiting.
 */
export async function resumePendingSignIn(): Promise<AppSession | null> {
  if (USE_MOCK_AUTH || !isTauri()) return null;

  const pending = (await getCurrent().catch(() => null))?.find(isSignInCallback);
  if (!pending) return null;

  const message = await completeSignIn(pending);
  if (message) {
    console.error("Não foi possível concluir a entrada pendente.", message);
    return null;
  }

  return readSupabaseSession();
}

/** A normal origin: the full-page redirect, and the callback it lands on, work. */
async function signInWithGoogleWeb(): Promise<string | null> {
  try {
    const { error } = await getSupabase().auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: window.location.origin,
      },
    });

    return error ? error.message : null;
  } catch (cause) {
    return describeAuthError(cause);
  }
}

/**
 * Mobile: ask Supabase for the authorization URL, open it in the system browser
 * (Google refuses its consent screen inside a webview), and wait for the deep
 * link that brings the one-time code back.
 */
async function signInWithGoogleMobile(): Promise<string | null> {
  try {
    const { data, error } = await getSupabase().auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: REDIRECT_TO, skipBrowserRedirect: true },
    });
    if (error) return error.message;
    if (!data.url) return "Não foi possível iniciar a entrada com o Google.";
    const authorizeUrl = data.url;

    const callback = await waitForCallback(() => openUrl(authorizeUrl));
    if (!callback) return "Tempo esgotado ao aguardar o retorno do Google.";

    return completeSignIn(callback);
  } catch (cause) {
    return describeAuthError(cause);
  }
}

/** True for the URLs our own scheme delivers, ignoring anything else. */
function isSignInCallback(url: string): boolean {
  return url.startsWith(`${DEEP_LINK_SCHEME}://`);
}

/**
 * Subscribes, then opens the browser — in that order, so a fast redirect cannot
 * arrive before there is anything listening for it.
 */
async function waitForCallback(open: () => Promise<void>): Promise<string | null> {
  let settle: (url: string | null) => void = () => undefined;
  const arrived = new Promise<string | null>((resolve) => {
    settle = resolve;
  });

  let timer: ReturnType<typeof setTimeout> | undefined;
  let unlisten: UnlistenFn | undefined;
  const finish = (url: string | null) => {
    if (timer) clearTimeout(timer);
    unlisten?.();
    settle(url);
  };

  unlisten = await onOpenUrl((urls) => {
    const callback = urls.find(isSignInCallback);
    if (callback) finish(callback);
  });
  timer = setTimeout(() => finish(null), SIGN_IN_TIMEOUT_MS);

  await open();
  return arrived;
}

/**
 * Exchanges the redirect's one-time code for a session. Resolves to an error
 * message, or to `null` once the session is stored.
 */
async function completeSignIn(callback: string): Promise<string | null> {
  // Supabase reports a denied consent on the same redirect, with `error=`.
  const params = readCallbackParams(callback);
  const denied = params.get("error_description") ?? params.get("error");
  if (denied) return denied;

  const code = params.get("code");
  if (!code) return "O Google não devolveu um código de acesso.";

  const { error } = await getSupabase().auth.exchangeCodeForSession(code);
  return error ? error.message : null;
}

/** PKCE answers on the query string; the hash is read for older flows. */
function readCallbackParams(callback: string): URLSearchParams {
  const parsed = new URL(callback);
  const params = new URLSearchParams(parsed.search);

  for (const [key, value] of new URLSearchParams(parsed.hash.replace(/^#/, ""))) {
    params.set(key, value);
  }

  return params;
}

function describeAuthError(cause: unknown): string {
  return cause instanceof Error && cause.message
    ? cause.message
    : "Não foi possível iniciar a entrada com o Google.";
}

export async function signOut(): Promise<void> {
  if (USE_MOCK_AUTH) {
    setMockSession(null);
    return;
  }

  await getSupabase().auth.signOut();
}

function readMockSession(): AppSession | null {
  try {
    const raw = window.localStorage.getItem(MOCK_STORAGE_KEY);
    return raw ? (JSON.parse(raw) as AppSession) : null;
  } catch {
    return null;
  }
}

function setMockSession(session: AppSession | null) {
  try {
    if (session) {
      window.localStorage.setItem(MOCK_STORAGE_KEY, JSON.stringify(session));
    } else {
      window.localStorage.removeItem(MOCK_STORAGE_KEY);
    }
  } catch {
    // Storage can be unavailable; the in-memory session still drives the UI.
  }

  for (const listener of mockListeners) {
    listener(session);
  }
}

async function readSupabaseSession(): Promise<AppSession | null> {
  const { data } = await getSupabase().auth.getSession();
  return toAppSession(data.session);
}

function toAppSession(session: Session | null): AppSession | null {
  if (!session) return null;

  const { email, user_metadata: metadata } = session.user;
  const name = typeof metadata?.full_name === "string" ? metadata.full_name : "";
  const avatarUrl = typeof metadata?.avatar_url === "string" ? metadata.avatar_url : null;

  return {
    user: {
      email: email ?? name,
      name: name || email || "Sessão iniciada",
      avatarUrl,
    },
  };
}
