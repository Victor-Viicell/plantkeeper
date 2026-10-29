import { track } from "ripple";
import { signInWithGoogle } from "../utils/auth";

export function Login() @{
  const busy = track(false);
  const error = track<string | null>(null);

  async function handleGoogleSignIn() {
    busy.value = true;
    error.value = null;

    const message = await signInWithGoogle();

    if (message) {
      error.value = message;
      busy.value = false;
    }
  }

  <>
    <style>
      .login {
        min-height: 100vh;
        min-height: 100dvh;
        display: flex;
        align-items: center;
        justify-content: center;
        /* Keeps the card clear of notches and the home indicator. */
        padding: max(2rem, env(safe-area-inset-top)) max(1.25rem, env(safe-area-inset-right))
          max(2rem, env(safe-area-inset-bottom)) max(1.25rem, env(safe-area-inset-left));
        background: radial-gradient(
          120% 120% at 50% 0%,
          var(--app-backdrop-accent) 0%,
          var(--app-backdrop) 55%
        );
      }

      .login-card {
        width: 100%;
        max-width: var(--app-max-width);
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.75rem;
        padding: 2.25rem 1.5rem;
        border: 1px solid var(--app-border);
        border-radius: 1.5rem;
        background: var(--app-card);
        box-shadow: var(--app-shadow);
        text-align: center;
      }

      .login-badge {
        font-size: 2.75rem;
        line-height: 1;
      }

      .login-title {
        margin: 0;
        font-size: 1.75rem;
        letter-spacing: -0.02em;
      }

      .login-subtitle {
        margin: 0 0 0.75rem;
        font-size: 1rem;
        line-height: 1.45;
        color: var(--app-text-muted);
        text-wrap: balance;
      }

      /* Full-width, 48px tall: the comfortable minimum for a thumb. */
      .login-button {
        width: 100%;
        min-height: 3rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 0.625rem;
        padding: 0.75rem 1.25rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: var(--app-card);
        color: inherit;
        font-family: inherit;
        font-size: 1rem;
        font-weight: 600;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.08);
        cursor: pointer;
        /* Drops the 300ms tap delay and the double-tap zoom on touch. */
        touch-action: manipulation;
        transition: border-color 0.2s ease, box-shadow 0.2s ease, opacity 0.2s ease;
      }

      .login-button:active:not(:disabled) {
        opacity: 0.75;
      }

      .login-button:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      .login-button:disabled {
        cursor: progress;
        opacity: 0.7;
      }

      /* Sticky hover is a touch bug, so only apply it to real pointers. */
      @media (hover: hover) {
        .login-button:hover:not(:disabled) {
          border-color: var(--app-accent);
          box-shadow: 0 6px 18px rgba(52, 168, 83, 0.22);
        }
      }

      .google-mark {
        width: 1.25rem;
        height: 1.25rem;
        flex: none;
      }

      .login-error {
        margin: 0;
        font-size: 0.9375rem;
        line-height: 1.4;
        color: var(--app-callout);
      }

      /* Phones held sideways have very little height to spare. */
      @media (orientation: landscape) and (max-height: 32rem) {
        .login {
          padding-block: max(0.75rem, env(safe-area-inset-top))
            max(0.75rem, env(safe-area-inset-bottom));
        }

        .login-card {
          gap: 0.5rem;
          padding-block: 1.25rem;
        }

        .login-badge {
          display: none;
        }
      }

      /* Keeps the label on one line on the narrowest phones. */
      @media (max-width: 22.5rem) {
        .login-card {
          padding-inline: 1.25rem;
        }

        .login-button {
          gap: 0.5rem;
          padding-inline: 1rem;
          font-size: 0.9375rem;
        }
      }
    </style>

    <main class="login">
      <section class="login-card">
        <span class="login-badge" aria-hidden="true">🌱</span>
        <h1 class="login-title">Plantkeeper</h1>
        <p class="login-subtitle">Acompanhe suas plantas.</p>

        <button
          class="login-button"
          type="button"
          disabled={busy.value}
          onClick={handleGoogleSignIn}
        >
          <svg class="google-mark" viewBox="0 0 48 48" aria-hidden="true">
            <path
              fill="#EA4335"
              d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"
            />
            <path
              fill="#4285F4"
              d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"
            />
            <path
              fill="#FBBC05"
              d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"
            />
            <path
              fill="#34A853"
              d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"
            />
          </svg>
          <span>{busy.value ? "Conectando…" : "Continuar com o Google"}</span>
        </button>

        @if (error.value) {
          <p class="login-error" role="alert">{error.value}</p>
        }
      </section>
    </main>
  </>
}
