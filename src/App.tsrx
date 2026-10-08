import { effect, track } from "ripple";
import { getSession, onAuthStateChange, resumePendingSignIn, type AppSession } from "./utils/auth";
import { Login } from "./pages/Login.tsrx";
import { Home } from "./pages/Home.tsrx";

// The splash stays on screen this long even when the session is restored faster.
const SPLASH_MIN_MS = 1200;

export function App() @{
  const ready = track(false);
  const session = track<AppSession | null>(null);

  const minimumSplash = new Promise<void>((resolve) => setTimeout(resolve, SPLASH_MIN_MS));

  Promise.all([getSession(), resumePendingSignIn(), minimumSplash])
    .then(([restored, resumed]) => {
      session.value = restored ?? resumed;
    })
    .catch((cause) => {
      console.error("Não foi possível restaurar a sessão.", cause);
    })
    .finally(() => {
      ready.value = true;
    });

  effect(() =>
    onAuthStateChange((nextSession) => {
      session.value = nextSession;
    }),
  );

  @if (!ready.value) {
    <>
      <style>
        .splash {
          min-height: 100vh;
          min-height: 100dvh;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          gap: 0.75rem;
          padding: max(1.5rem, env(safe-area-inset-top)) 1.5rem max(1.5rem, env(safe-area-inset-bottom));
          background: linear-gradient(160deg, #1f6f3f 0%, #2f9e57 100%);
          color: #ffffff;
        }

        .splash-logo {
          font-size: 4rem;
          line-height: 1;
          animation: plantkeeper-splash-pulse 1.6s ease-in-out infinite;
        }

        .splash-name {
          margin: 0;
          font-size: 1.5rem;
          font-weight: 600;
          letter-spacing: 0.02em;
        }

        @keyframes plantkeeper-splash-pulse {
          0%,
          100% {
            transform: scale(1);
            opacity: 1;
          }
          50% {
            transform: scale(1.12);
            opacity: 0.75;
          }
        }

        @media (prefers-reduced-motion: reduce) {
          .splash-logo {
            animation: none;
          }
        }
      </style>

      <main class="splash">
        <span class="splash-logo" aria-hidden="true">🌱</span>
        <p class="splash-name">Plantkeeper</p>
      </main>
    </>
  } @else if (session.value) {
    <Home />
  } @else {
    <Login />
  }
}
