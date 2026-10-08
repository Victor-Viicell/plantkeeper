import { effect, track, type Derived, type Tracked } from "ripple";
import { formatLastSeen } from "../utils/devices";
import { WARNING_SNOOZE_MS, type AppNotification } from "../utils/notifications";

/** Rounded hours, so the button says what the snooze actually buys. */
const SNOOZE_HOURS = Math.round(WARNING_SNOOZE_MS / (60 * 60 * 1000));

/** The icon-only button in the home header, carrying the unread count. */
export function NotificationBell({
  notifications,
  open,
  onToggle,
}: {
  notifications: Derived<AppNotification[]>;
  open: Tracked<boolean>;
  onToggle: () => void;
}) @{
  /** More than nine is "9+": the badge is a hint, not a counter. */
  const badge = track(() => (notifications.value.length > 9 ? "9+" : String(notifications.value.length)));
  const label = track(() =>
    notifications.value.length > 0
      ? `Notificações (${notifications.value.length})`
      : "Notificações",
  );

  <>
    <style>
      .bell {
        position: relative;
        flex: none;
        width: 2.75rem;
        height: 2.75rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 0;
        border: 1px solid var(--app-control-border);
        border-radius: 50%;
        background: transparent;
        color: inherit;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease, color 0.2s ease, opacity 0.2s ease;
      }

      .bell:active {
        opacity: 0.75;
      }

      .bell:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .bell:hover {
          border-color: var(--app-accent);
          color: var(--app-accent);
        }
      }

      .bell-icon {
        width: 1.25rem;
        height: 1.25rem;
      }

      /* Warning red, so an alert reads as one even before the panel is open. */
      .bell-badge {
        position: absolute;
        top: -0.125rem;
        right: -0.125rem;
        min-width: 1.125rem;
        height: 1.125rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 0 0.25rem;
        border-radius: 999px;
        background: var(--app-callout);
        color: #ffffff;
        font-size: 0.6875rem;
        font-weight: 700;
        line-height: 1;
      }

      /* In dark mode the callout is a pale red, so the text flips with it. */
      @media (prefers-color-scheme: dark) {
        .bell-badge {
          color: #1b1f1b;
        }
      }
    </style>

    <button
      class="bell"
      type="button"
      aria-label={label.value}
      aria-haspopup="dialog"
      aria-expanded={open.value}
      onClick={onToggle}
    >
      <svg class="bell-icon" viewBox="0 0 24 24" aria-hidden="true">
        <path
          d="M18 15.5V10a6 6 0 1 0-12 0v5.5L4.5 19h15L18 15.5z"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M10 21.5h4"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
        />
      </svg>

      @if (notifications.value.length > 0) {
        <span class="bell-badge" aria-hidden="true">{badge.value}</span>
      }
    </button>
  </>
}

/**
 * The centre itself: every warning and pending routine, with the two ways out of
 * each one — open the vase it belongs to, or put it away for a while.
 *
 * It is rendered beside `<main>` rather than inside the header, so the overlay
 * is not trapped in the header's stacking context and can cover the whole app.
 */
export function NotificationsPanel({
  notifications,
  open,
  onClose,
  onDismiss,
  onOpenDevice,
}: {
  notifications: Derived<AppNotification[]>;
  open: Tracked<boolean>;
  onClose: () => void;
  onDismiss: (notification: AppNotification) => void;
  onOpenDevice: (deviceId: string) => void;
}) @{
  let closeButton: HTMLButtonElement | undefined;

  // Opening with focus inside is what makes the panel navigable by keyboard.
  effect(() => {
    if (open.value) closeButton?.focus();
  });

  effect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && open.value) onClose();
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  });

  <>
    <style>
      .notice-layer {
        position: fixed;
        inset: 0;
        z-index: 30;
        display: flex;
        justify-content: center;
        background: rgba(12, 20, 14, 0.45);
        animation: plantkeeper-notice-fade 0.18s ease-out;
      }

      /* The panel is the page column, so a wide window shows the backdrop on
         either side instead of a full-bleed sheet. */
      .notice {
        width: 100%;
        max-width: var(--app-max-width);
        height: 100%;
        overflow-y: auto;
        overscroll-behavior: contain;
        display: flex;
        flex-direction: column;
        gap: 1rem;
        padding: max(1rem, env(safe-area-inset-top)) max(1.25rem, env(safe-area-inset-right))
          calc(1.5rem + env(safe-area-inset-bottom)) max(1.25rem, env(safe-area-inset-left));
        background: var(--app-surface);
        animation: plantkeeper-notice-up 0.22s ease-out;
      }

      .notice-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
      }

      .notice-heading {
        margin: 0;
        font-size: 1.25rem;
      }

      .notice-close {
        flex: none;
        width: 2.75rem;
        height: 2.75rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 0;
        border: none;
        border-radius: 50%;
        background: transparent;
        color: inherit;
        cursor: pointer;
        touch-action: manipulation;
        transition: background-color 0.2s ease;
      }

      .notice-close:active {
        background: var(--app-card);
      }

      .notice-close:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .notice-close:hover {
          background: var(--app-card);
        }
      }

      .notice-icon {
        width: 1.25rem;
        height: 1.25rem;
      }

      .notice-list {
        list-style: none;
        display: flex;
        flex-direction: column;
        gap: 0.625rem;
        margin: 0;
        padding: 0;
      }

      /* The left edge carries the kind: red for something wrong, green for the
         day's routine. */
      .notice-item {
        display: flex;
        flex-direction: column;
        gap: 0.375rem;
        padding: 0.875rem 1rem;
        border: 1px solid var(--app-border);
        border-left: 3px solid var(--app-accent);
        border-radius: 1rem;
        background: var(--app-card);
      }

      .notice-item-warning {
        border-left-color: var(--app-callout);
      }

      .notice-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
      }

      .notice-kind {
        font-size: 0.6875rem;
        font-weight: 700;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--app-accent);
      }

      .notice-item-warning .notice-kind {
        color: var(--app-callout);
      }

      .notice-time {
        flex: none;
        font-size: 0.75rem;
        color: var(--app-text-muted);
      }

      .notice-device {
        margin: 0;
        font-size: 0.8125rem;
        color: var(--app-text-muted);
      }

      .notice-title {
        margin: 0;
        font-size: 1rem;
        font-weight: 600;
      }

      .notice-detail {
        margin: 0;
        font-size: 0.875rem;
        line-height: 1.45;
        color: var(--app-text-muted);
      }

      .notice-actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 0.5rem;
        margin-top: 0.25rem;
      }

      .notice-outline {
        min-height: 2.5rem;
        padding: 0.5rem 1rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: transparent;
        color: inherit;
        font-family: inherit;
        font-size: 0.9375rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease, color 0.2s ease;
      }

      .notice-outline:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .notice-outline:hover {
          border-color: var(--app-accent);
          color: var(--app-accent);
        }
      }

      .notice-link {
        min-height: 2.5rem;
        padding: 0.5rem 0.25rem;
        border: none;
        background: transparent;
        color: var(--app-text-muted);
        font-family: inherit;
        font-size: 0.875rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
      }

      .notice-link:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      .notice-empty {
        flex: 1;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 0.375rem;
        text-align: center;
      }

      .notice-empty-mark {
        font-size: 3rem;
        line-height: 1;
      }

      .notice-empty-title {
        margin: 0;
        font-size: 1.125rem;
        font-weight: 600;
      }

      .notice-empty-note {
        max-width: 20rem;
        margin: 0;
        font-size: 0.9375rem;
        line-height: 1.45;
        color: var(--app-text-muted);
        text-wrap: balance;
      }

      .notice-footnote {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.45;
        color: var(--app-text-muted);
      }

      @keyframes plantkeeper-notice-fade {
        from {
          opacity: 0;
        }
        to {
          opacity: 1;
        }
      }

      @keyframes plantkeeper-notice-up {
        from {
          transform: translateY(2rem);
          opacity: 0;
        }
        to {
          transform: translateY(0);
          opacity: 1;
        }
      }

      @media (prefers-reduced-motion: reduce) {
        .notice-layer,
        .notice {
          animation: none;
        }
      }

      /* Phones held sideways have very little height to spare. */
      @media (orientation: landscape) and (max-height: 32rem) {
        .notice {
          gap: 0.75rem;
          padding-block: 0.75rem;
        }
      }
    </style>

    @if (open.value) {
      <div class="notice-layer" onClick={onClose}>
        <section
          class="notice"
          role="dialog"
          aria-modal="true"
          aria-labelledby="notifications-title"
          onClick={(event) => event.stopPropagation()}
        >
          <header class="notice-header">
            <h2 class="notice-heading" id="notifications-title">Notificações</h2>
            <button
              class="notice-close"
              type="button"
              aria-label="Fechar notificações"
              ref={closeButton}
              onClick={onClose}
            >
              <svg class="notice-icon" viewBox="0 0 24 24" aria-hidden="true">
                <path
                  d="M6 6l12 12M18 6L6 18"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                />
              </svg>
            </button>
          </header>

          @if (notifications.value.length === 0) {
            <div class="notice-empty">
              <span class="notice-empty-mark" aria-hidden="true">🌿</span>
              <p class="notice-empty-title">Tudo em ordem</p>
              <p class="notice-empty-note">
                Nenhum aviso e nenhuma rotina pendente. Abra um vaso da lista para
                escolher os limites e o horário da rotina.
              </p>
            </div>
          } @else {
            <>
              <ul class="notice-list">
                @for (const item of notifications.value; key item.id) {
                  <li class={`notice-item notice-item-${item.kind}`}>
                    <div class="notice-head">
                      <span class="notice-kind">
                        {item.kind === "warning" ? "Aviso" : "Rotina"}
                      </span>
                      <span class="notice-time">{formatLastSeen(item.at)}</span>
                    </div>

                    <p class="notice-device">{item.deviceName}</p>
                    <p class="notice-title">{item.title}</p>
                    <p class="notice-detail">{item.detail}</p>

                    <div class="notice-actions">
                      <button
                        class="notice-link"
                        type="button"
                        onClick={() => {
                          onOpenDevice(item.deviceId);
                        }}
                      >
                        Abrir o vaso
                      </button>

                      <button
                        class="notice-outline"
                        type="button"
                        onClick={() => {
                          onDismiss(item);
                        }}
                      >
                        {item.kind === "routine" ? "Feito hoje" : `Dispensar ${SNOOZE_HOURS} h`}
                      </button>
                    </div>
                  </li>
                }
              </ul>

              <p class="notice-footnote">
                {`Um aviso volta a aparecer depois de ${SNOOZE_HOURS} h; uma rotina marcada como feita só volta no dia seguinte.`}
              </p>
            </>
          }
        </section>
      </div>
    }
  </>
}
