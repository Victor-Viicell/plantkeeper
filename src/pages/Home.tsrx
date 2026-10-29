import { effect, track, untrack } from "ripple";
import { AddDeviceFab } from "../components/AddDeviceFab.tsrx";
import { DeviceDetail } from "../components/DeviceDetail.tsrx";
import { MetricIcon } from "../components/MetricIcon.tsrx";
import { NotificationBell, NotificationsPanel } from "../components/Notifications.tsrx";
import { signOut } from "../utils/auth";
import {
  connectDevice,
  describeDevice,
  DEVICE_REFRESH_MS,
  formatLastSeen,
  loadDevices,
  READING_METRICS,
  STATUS_LABELS,
  type Device,
  type DeviceReadings,
  type ReadingMetricKey,
} from "../utils/devices";
import { describeError } from "../utils/errors";
import { dismissNativeAlert, sendNativeAlerts, syncRoutineSchedules } from "../utils/nativeNotifications";
import {
  createNotificationState,
  deviceSettings,
  dismissNotification,
  evaluateNotifications,
  type AppNotification,
} from "../utils/notifications";

type DeviceMetric = { key: ReadingMetricKey; label: string; value: string };

/** How often the notification centre re-reads the clock, in milliseconds. */
const NOTIFICATION_TICK_MS = 30_000;

/** Flattens the nullable reading row into labels the card can loop over. */
function metrics(readings: DeviceReadings): DeviceMetric[] {
  return READING_METRICS.map((metric) => ({
    key: metric.key,
    label: metric.label,
    value: metric.format(readings[metric.key]),
  }));
}

export function Home() @{
  const devices = track<Device[]>([]);
  const loading = track(true);
  const refreshing = track(false);
  /** Fatal: there is nothing to show, so the screen becomes the error. */
  const loadError = track<string | null>(null);
  /** Soft: the list on screen is kept, but it may be out of date. */
  const staleNotice = track<string | null>(null);
  /** The device whose detail view is open, if any. */
  const opened = track<Device | null>(null);

  // Promise chains rather than try/catch: `try` is reserved for rendered
  // control flow in `.tsrx`, so a statement-level one cannot live here.
  function refresh(manual = false): Promise<void> {
    // Whether a list is already on screen decides how a failure is reported,
    // and that is the state *before* this request, not after it.
    const hasList = devices.value.length > 0;
    if (manual) refreshing.value = true;

    return loadDevices()
      .then((next) => {
        devices.value = next;
        loadError.value = null;
        staleNotice.value = null;
      })
      .catch((cause) => {
        const message = describeError(cause, "Não foi possível carregar seus dispositivos.");

        // One dropped poll should not throw away a working list: keep it and
        // say it may be behind, instead of replacing it with an error page.
        if (hasList) staleNotice.value = message;
        else loadError.value = message;
      })
      .finally(() => {
        refreshing.value = false;
        loading.value = false;
      });
  }

  refresh();

  // The vase keeps publishing while the app is open, so keep the list warm.
  effect(() => {
    const timer = setInterval(() => {
      void refresh();
    }, DEVICE_REFRESH_MS);

    return () => clearInterval(timer);
  });

  /**
   * The bell and the notification centre. Warnings follow the device list the
   * polling already refreshes; routines also need the clock, because one can
   * fall due while the screen is open with nothing else changing.
   *
   * The rules and dismissals live in one tracked value created here, so the
   * panel, the badge and the settings card inside a vase all read and write the
   * same state.
   *
   * The panel is rendered inside `<main>` rather than in the header it is opened
   * from: `position: sticky` gives the header a stacking context of its own, and
   * the overlay would be trapped under the connect button instead of over it.
   */
  const notificationState = createNotificationState();
  const clock = track(Date.now());
  const notificationsOpen = track(false);
  const notifications = track(() =>
    evaluateNotifications(notificationState.value, devices.value, clock.value),
  );

  effect(() => {
    const timer = setInterval(() => {
      clock.value = Date.now();
    }, NOTIFICATION_TICK_MS);

    return () => clearInterval(timer);
  });

  /**
   * The phone is the place these alerts are meant to arrive. The in-app list is
   * mirrored to the OS notification centre as new items appear, and the enabled
   * routines are written to the mobile scheduler so they fire even when the app
   * is closed. Both effects run through `untrack` so a poll that only refreshes
   * readings does not reschedule everything.
   */
  const alertsSignature = track(() =>
    notifications.value
      .map((notification) => notification.id)
      .sort()
      .join("|"),
  );

  const routinesSignature = track(() =>
    devices.value
      .map((device) => {
        const routine = deviceSettings(notificationState.value, device.id).routine;
        const done = notificationState.value.dismissals[`routine:${device.id}`] ?? "";
        return `${device.id}:${device.name}:${routine.enabled}:${routine.everyDays}:${routine.time}:${routine.label}:${done}`;
      })
      .join("|"),
  );

  effect(() => {
    alertsSignature.value;
    untrack(() => {
      void sendNativeAlerts(notifications.value);
    });
  });

  effect(() => {
    routinesSignature.value;
    untrack(() => {
      void syncRoutineSchedules(devices.value, notificationState.value);
    });
  });

  // A backgrounded phone webview pauses timers; catch up as soon as it returns.
  effect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible") void refresh();
    }

    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  });

  /** Opens the vase a notification is about, if it is still on screen. */
  function openFromNotification(deviceId: string) {
    const device = devices.value.find((entry) => entry.id === deviceId);
    if (!device) return;

    notificationsOpen.value = false;
    opened.value = device;
  }

  function dismiss(notification: AppNotification) {
    dismissNativeAlert(notification);
    dismissNotification(notificationState, notification);
  }

  /** Runs the claim handshake; returns an error message, or null on success. */
  function connect(claimCode: string): Promise<string | null> {
    return connectDevice(claimCode)
      .then(() => refresh())
      .then(() => null)
      .catch((cause) => describeError(cause, "Não foi possível conectar o dispositivo."));
  }

  <>
    <style>
      /* The whole page is the mobile column: capped and centered, with the
         backdrop showing either side in a wider window. */
      .home {
        width: 100%;
        max-width: var(--app-max-width);
        min-height: 100vh;
        min-height: 100dvh;
        margin-inline: auto;
        display: flex;
        flex-direction: column;
        background: var(--app-surface);
      }

      .home-header {
        position: sticky;
        top: 0;
        z-index: 1;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        padding: max(0.75rem, env(safe-area-inset-top)) max(1rem, env(safe-area-inset-right)) 0.75rem
          max(1rem, env(safe-area-inset-left));
        border-bottom: 1px solid var(--app-border);
        background: var(--app-card);
      }

      .home-brand {
        min-width: 0;
        overflow: hidden;
        font-size: 1rem;
        font-weight: 600;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .home-actions {
        flex: none;
        display: inline-flex;
        align-items: center;
        gap: 0.5rem;
      }

      .home-signout {
        flex: none;
        min-height: 2.75rem;
        padding: 0.5rem 1.125rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: transparent;
        color: inherit;
        font-family: inherit;
        font-size: 0.9375rem;
        font-weight: 500;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease, color 0.2s ease, opacity 0.2s ease;
      }

      .home-signout:active {
        opacity: 0.75;
      }

      .home-signout:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .home-signout:hover {
          border-color: var(--app-accent);
          color: var(--app-accent);
        }
      }

      .home-empty {
        flex: 1;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 0.5rem;
        padding: 2rem max(1.25rem, env(safe-area-inset-right)) max(2rem, env(safe-area-inset-bottom))
          max(1.25rem, env(safe-area-inset-left));
        text-align: center;
      }

      .home-empty h1 {
        margin: 0;
        font-size: 1.375rem;
      }

      .home-empty p {
        max-width: 20rem;
        margin: 0;
        font-size: 1rem;
        line-height: 1.45;
        color: var(--app-text-muted);
        text-wrap: balance;
      }

      .home-retry {
        min-height: 2.75rem;
        margin-top: 0.5rem;
        padding: 0.5rem 1.25rem;
        border: none;
        border-radius: 999px;
        background: var(--app-accent);
        color: #ffffff;
        font-family: inherit;
        font-size: 0.9375rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: opacity 0.2s ease;
      }

      .home-retry:active {
        opacity: 0.8;
      }

      .home-retry:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 3px;
      }

      .home-refresh {
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

      .home-refresh:active {
        opacity: 0.75;
      }

      .home-refresh:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      /* Travels the same path the polling does, so a slow read looks busy
         rather than broken. */
      .home-refresh:disabled .home-refresh-icon {
        animation: plantkeeper-spin 0.9s linear infinite;
      }

      @media (hover: hover) {
        .home-refresh:hover:not(:disabled) {
          border-color: var(--app-accent);
          color: var(--app-accent);
        }
      }

      .home-refresh-icon {
        width: 1.25rem;
        height: 1.25rem;
      }

      @keyframes plantkeeper-spin {
        to {
          transform: rotate(360deg);
        }
      }

      /* A failed poll with a list already on screen: say so, keep the list. */
      .home-notice {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 0.25rem 0.75rem;
        margin: 0;
        padding: 0.625rem max(1rem, env(safe-area-inset-right)) 0.625rem
          max(1rem, env(safe-area-inset-left));
        border-bottom: 1px solid var(--app-border);
        background: var(--app-backdrop-accent);
        font-size: 0.8125rem;
        line-height: 1.4;
        color: var(--app-text-muted);
      }

      .home-notice-retry {
        flex: none;
        min-height: 2rem;
        padding: 0.25rem 0.5rem;
        border: none;
        background: transparent;
        color: var(--app-accent);
        font-family: inherit;
        font-size: 0.8125rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
      }

      .home-notice-retry:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (prefers-reduced-motion: reduce) {
        .home-refresh:disabled .home-refresh-icon {
          animation: none;
        }
      }

      /* Bottom padding clears the floating button. */
      .device-list {
        list-style: none;
        display: flex;
        flex-direction: column;
        gap: 0.625rem;
        margin: 0;
        padding: 1rem max(1rem, env(safe-area-inset-right)) calc(6rem + env(safe-area-inset-bottom))
          max(1rem, env(safe-area-inset-left));
      }

      .device {
        position: relative;
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
        padding: 0.875rem 1rem;
        border: 1px solid var(--app-border);
        border-radius: 1rem;
        background: var(--app-card);
      }

      /* The whole card is the target, so a tap anywhere opens the detail. The
         button is stretched over the card instead of wrapping it, because a
         button element may only contain phrasing content and the readings are
         a description list. */
      .device-open {
        position: absolute;
        inset: 0;
        padding: 0;
        border: none;
        border-radius: inherit;
        background: transparent;
        cursor: pointer;
        touch-action: manipulation;
      }

      .device-open:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      .device-chevron {
        flex: none;
        width: 1.125rem;
        height: 1.125rem;
        color: var(--app-text-muted);
      }

      .device-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 0.5rem 0.75rem;
      }

      .device-body {
        /* Keeps a readable width: when the status pill no longer fits beside
           it, the pill wraps to a second line instead of crushing the name
           and its meta line to a sliver. */
        flex: 1 1 10rem;
        min-width: 0;
        display: flex;
        flex-direction: column;
        gap: 0.125rem;
      }

      .device-name {
        overflow: hidden;
        font-size: 1rem;
        font-weight: 600;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .device-meta {
        font-size: 0.8125rem;
        line-height: 1.35;
        color: var(--app-text-muted);
      }

      .device-status {
        flex: none;
        display: inline-flex;
        align-items: center;
        gap: 0.375rem;
        padding: 0.3125rem 0.625rem;
        border: 1px solid var(--app-border);
        border-radius: 999px;
        background: var(--app-surface);
        font-size: 0.75rem;
        font-weight: 600;
        color: var(--app-text-muted);
      }

      .device-dot {
        width: 0.5rem;
        height: 0.5rem;
        border-radius: 50%;
        background: currentColor;
      }

      .device-status-online {
        border-color: #bfe3c9;
        background: #eef8f0;
        color: #1f6f3f;
      }

      .device-readings {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.5rem;
        margin: 0;
      }

      .reading {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        padding: 0.625rem 0.75rem;
        border-radius: 0.875rem;
        background: var(--app-surface);
      }

      .reading dt {
        display: flex;
        align-items: center;
        gap: 0.375rem;
        font-size: 0.75rem;
        font-weight: 600;
        color: var(--app-text-muted);
      }

      .reading dd {
        margin: 0;
        font-size: 1.0625rem;
        font-weight: 650;
        font-variant-numeric: tabular-nums;
        letter-spacing: -0.01em;
      }

      .device-note {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.4;
        color: var(--app-text-muted);
      }

      @media (prefers-color-scheme: dark) {
        .device-status-online {
          border-color: #2c4d37;
          background: #16281a;
          color: #7fd39a;
        }
      }

      /* Phones held sideways have very little height to spare. */
      @media (orientation: landscape) and (max-height: 32rem) {
        .home-empty {
          padding-block: 1.25rem;
        }

        .device-list {
          padding-top: 0.75rem;
        }
      }
    </style>

    @if (opened.value) {
      <DeviceDetail
        device={opened.value}
        notificationState={notificationState}
        onClose={() => {
          opened.value = null;
        }}
        onChanged={() => {
          void refresh();
        }}
        onRemoved={() => {
          opened.value = null;
          void refresh();
        }}
      />
    } @else {
      <main class="home">
        <header class="home-header">
          <span class="home-brand">🌱 Plantkeeper</span>
          <span class="home-actions">
            <NotificationBell
              notifications={notifications}
              open={notificationsOpen}
              onToggle={() => {
                notificationsOpen.value = !notificationsOpen.value;
              }}
            />

            <button
              class="home-refresh"
              type="button"
              aria-label="Atualizar leituras"
              disabled={refreshing.value || loading.value}
              onClick={() => {
                void refresh(true);
              }}
            >
              <svg class="home-refresh-icon" viewBox="0 0 24 24" aria-hidden="true">
                <path
                  d="M20 12a8 8 0 1 1-2.34-5.66M20 4v5h-5"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </button>
            <button
              class="home-signout"
              type="button"
              onClick={() => {
                void signOut();
              }}
            >
              Sair
            </button>
          </span>
        </header>

        @if (staleNotice.value) {
          <p class="home-notice" role="status">
            <span>{staleNotice.value}</span>
            <button
              class="home-notice-retry"
              type="button"
              onClick={() => {
                void refresh(true);
              }}
            >
              Tentar de novo
            </button>
          </p>
        }

        @if (loading.value) {
          <section class="home-empty">
            <p>Carregando…</p>
          </section>
        } @else if (loadError.value) {
          <section class="home-empty">
            <h1>Não foi possível carregar</h1>
            <p>{loadError.value}</p>
            <button
              class="home-retry"
              type="button"
              onClick={() => {
                void refresh();
              }}
            >
              Tentar de novo
            </button>
          </section>
        } @else if (devices.value.length === 0) {
          <section class="home-empty">
            <h1>Nenhum vaso ainda</h1>
            <p>Toque em + e informe o código que o vaso mostra.</p>
          </section>
        } @else {
          <ul class="device-list">
            @for (const device of devices.value; key device.id) {
              <li class="device">
                <button
                  class="device-open"
                  type="button"
                  aria-label={`Ver o histórico de ${device.name}`}
                  onClick={() => {
                    opened.value = device;
                  }}
                ></button>

                <div class="device-head">
                  <span class="device-body">
                    <span class="device-name">{device.name}</span>
                    <span class="device-meta">{describeDevice(device)}</span>
                  </span>

                  <span class={`device-status device-status-${device.status}`}>
                    <span class="device-dot" aria-hidden="true"></span>
                    {STATUS_LABELS[device.status]}
                  </span>

                  <svg class="device-chevron" viewBox="0 0 24 24" aria-hidden="true">
                    <path
                      d="M9 5l7 7-7 7"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </div>

                @if (device.readings) {
                  <>
                    <dl class="device-readings">
                      @for (const metric of metrics(device.readings); key metric.key) {
                        <div class="reading">
                          <dt>
                            <MetricIcon metric={metric.key} />
                            {metric.label}
                          </dt>
                          <dd>{metric.value}</dd>
                        </div>
                      }
                    </dl>
                    <p class="device-note">
                      {`Leitura ${formatLastSeen(device.readings.capturedAt)}.`}
                    </p>
                  </>
                } @else {
                  <p class="device-note">Sem leituras ainda.</p>
                }
              </li>
            }
          </ul>
        }

        <NotificationsPanel
          notifications={notifications}
          open={notificationsOpen}
          onClose={() => {
            notificationsOpen.value = false;
          }}
          onDismiss={dismiss}
          onOpenDevice={openFromNotification}
        />

        <AddDeviceFab onConnect={connect} />
      </main>
    }
  </>
}
