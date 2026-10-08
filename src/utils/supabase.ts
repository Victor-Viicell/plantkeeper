import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL?.trim();
const supabaseKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();

let client: SupabaseClient | null = null;

/**
 * The client is built on first use, not on import.
 *
 * `createClient()` throws when the URL is missing, and `.env` is gitignored —
 * so building it eagerly turned a fresh clone (which runs on the mocked
 * sign-in and never talks to Supabase) into a blank page. Nothing here runs
 * until a real request needs it, and the mock paths never get that far.
 */
export function getSupabase(): SupabaseClient {
  if (client) return client;

  if (!supabaseUrl || !supabaseKey) {
    throw new Error(
      "Supabase não está configurado: copie .env.example para .env e preencha " +
        "VITE_SUPABASE_URL e VITE_SUPABASE_PUBLISHABLE_KEY. Para trabalhar sem " +
        "backend, use o login simulado em src/utils/auth.ts.",
    );
  }

  client = createClient(supabaseUrl, supabaseKey, {
    auth: {
      // PKCE is what lets the desktop app finish sign-in away from the webview:
      // the redirect carries a one-time `code` and the verifier never leaves the
      // device. A browser tab walks the same path, so there is one flow to trust.
      flowType: "pkce",
    },
  });

  return client;
}
