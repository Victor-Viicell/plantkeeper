import { effect, track, type Tracked } from "ripple";
import { DeviceNotifications } from "./DeviceNotifications.tsrx";
import { MetricIcon } from "./MetricIcon.tsrx";
import { forgetDeviceNotifications, type NotificationState } from "../utils/notifications";
import {
  DEVICE_REFRESH_MS,
  formatLastSeen,
  loadDeviceHistory,
  READING_METRICS,
  readingMetric,
  releaseDevice,
  renameDevice,
  STATUS_LABELS,
  type Device,
  type DeviceReadings,
  type ReadingMetricKey,
} from "../utils/devices";
import { describeError } from "../utils/errors";

/** The chart's own coordinate space; CSS stretches it to the column. */
const CHART_WIDTH = 300;
const CHART_HEIGHT = 96;
/** Keeps the line clear of the frame, so a peak is never clipped. */
const CHART_PAD = 12;

type Chart = {
  /** Ready-made `points` for the polyline. */
  line: string;
  lo: number;
  hi: number;
  /** The final sample, always present: with a single sample it is the dot. */
  lastX: number;
  lastY: number;
  /** True when a lone sample means the polyline draws nothing visible. */
  single: boolean;
};

/**
 * Maps samples onto SVG coordinates, or `null` when there is nothing to draw.
 * `fixedMax` pins percent metrics to 0-100 so two visits are comparable;
 * `null` scales a temperature series to its own range.
 */
function toChart(values: number[], fixedMax: number | null): Chart | null {
  if (values.length === 0) return null;

  const lo = fixedMax === null ? Math.min(...values) : 0;
  const hi = fixedMax === null ? Math.max(...values) : fixedMax;
  // A flat series would otherwise divide by zero and fly off the frame.
  const span = hi - lo || 1;
  const step = values.length > 1 ? CHART_WIDTH / (values.length - 1) : 0;

  const coords = values.map((value, index) => ({
    x: values.length > 1 ? index * step : CHART_WIDTH / 2,
    y: CHART_HEIGHT - CHART_PAD - ((value - lo) / span) * (CHART_HEIGHT - CHART_PAD * 2),
  }));

  const last = coords[coords.length - 1];
  return {
    line: coords.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" "),
    lo,
    hi,
    lastX: last.x,
    lastY: last.y,
    single: coords.length === 1,
  };
}

/** The numeric samples for one metric, skipping the gaps in the series. */
function series(points: DeviceReadings[], key: ReadingMetricKey): number[] {
  return points
    .map((point) => point[key])
    .filter((value): value is number => typeof value === "number");
}

export function DeviceDetail({
  device,
  notificationState,
  onClose,
  onChanged,
  onRemoved,
}: {
  device: Device;
  /** The rules this vase's warnings and routine live in, owned by `Home`. */
  notificationState: Tracked<NotificationState>;
  onClose: () => void;
  onChanged: () => void;
  onRemoved: () => void;
}) @{
  const history = track<DeviceReadings[]>([]);
  const loading = track(true);
  const historyError = track<string | null>(null);
  const metric = track<ReadingMetricKey>("soil");

  // The name is kept locally: a rename should land immediately rather than
  // after the list behind this view has been re-read.
  const name = track(device.name);
  const draftName = track(device.name);
  const renaming = track(false);
  const renameError = track<string | null>(null);

  const confirmingRelease = track(false);
  const releasing = track(false);
  const releaseError = track<string | null>(null);

  let backButton: HTMLButtonElement | undefined;

  function refreshHistory(): Promise<void> {
    return loadDeviceHistory(device.id)
      .then((points) => {
        history.value = points;
        historyError.value = null;
      })
      .catch((cause) => {
        historyError.value = describeError(cause, "Não foi possível carregar o histórico.");
      });
  }

  refreshHistory().finally(() => {
    loading.value = false;
  });

  // The vase keeps publishing, so the chart follows it while the view is open.
  effect(() => {
    const timer = setInterval(() => {
      void refreshHistory();
    }, DEVICE_REFRESH_MS);

    return () => clearInterval(timer);
  });

  // Opening with focus inside is what makes the view navigable by keyboard.
  effect(() => {
    backButton?.focus();
  });

  effect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  });

  const hasSamples = track(() => history.value.length > 0);
  const values = track(() => series(history.value, metric.value));
  const geometry = track(() => toChart(values.value, readingMetric(metric.value).max));
  const hasChart = track(() => geometry.value !== null);
  // Always something to read from; `hasChart` decides whether it is drawn, so
  // the template never has to narrow a possibly-null value mid-expression.
  const chart = track(
    () =>
      geometry.value ?? { line: "", lo: 0, hi: 0, lastX: 0, lastY: 0, single: false },
  );

  /** The newest sample, formatted — or why there is nothing to show. */
  const lastSampleText = track(() => {
    const sample = history.value[history.value.length - 1];
    return sample
      ? `Leitura ${formatLastSeen(sample.capturedAt)}.`
      : "Sem leituras ainda.";
  });

  /** The tiles read the newest sample, so they follow the same refresh. */
  const tiles = track(() => {
    const sample = history.value[history.value.length - 1];
    return READING_METRICS.map((entry) => ({
      key: entry.key,
      label: entry.label,
      value: entry.format(sample?.[entry.key] ?? null),
    }));
  });

  const chartSummary = track(() => {
    const sample = geometry.value;
    if (!sample) return "";
    const entry = readingMetric(metric.value);
    return (
      `${entry.label} nas últimas ${values.value.length} leituras, ` +
      `de ${entry.axisFormat(sample.lo)} a ${entry.axisFormat(sample.hi)} ${entry.unit}.`
    );
  });

  function submitRename(event: SubmitEvent) {
    event.preventDefault();

    const next = draftName.value.trim();
    if (!next || renaming.value || next === name.value) return;

    renaming.value = true;
    renameError.value = null;

    renameDevice(device.id, next)
      .then(() => {
        name.value = next;
        onChanged();
      })
      .catch((cause) => {
        renameError.value = describeError(cause, "Não foi possível renomear o dispositivo.");
      })
      .finally(() => {
        renaming.value = false;
      });
  }

  function remove() {
    if (releasing.value) return;

    releasing.value = true;
    releaseError.value = null;

    // On success the parent unmounts this view, so the busy flag is left set
    // deliberately rather than updated after the component is gone.
    releaseDevice(device.id)
      .then(() => {
        // The vase is free for anyone to claim, so its warnings and routine go
        // with it — the id never comes back.
        forgetDeviceNotifications(notificationState, device.id);
        onRemoved();
      })
      .catch((cause) => {
        releaseError.value = describeError(cause, "Não foi possível remover o dispositivo.");
        releasing.value = false;
      });
  }

  <>
    <style>
      .detail {
        width: 100%;
        max-width: var(--app-max-width);
        min-height: 100vh;
        min-height: 100dvh;
        margin-inline: auto;
        display: flex;
        flex-direction: column;
        background: var(--app-surface);
      }

      .detail-header {
        position: sticky;
        top: 0;
        z-index: 1;
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: max(0.75rem, env(safe-area-inset-top)) max(1rem, env(safe-area-inset-right)) 0.75rem
          max(1rem, env(safe-area-inset-left));
        border-bottom: 1px solid var(--app-border);
        background: var(--app-card);
      }

      .detail-back {
        flex: none;
        width: 2.75rem;
        height: 2.75rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        margin-inline-start: -0.5rem;
        padding: 0;
        border: none;
        border-radius: 50%;
        background: transparent;
        color: inherit;
        cursor: pointer;
        touch-action: manipulation;
        transition: background-color 0.2s ease;
      }

      .detail-back:active {
        background: var(--app-surface);
      }

      .detail-back:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .detail-back:hover {
          background: var(--app-surface);
        }
      }

      .detail-icon {
        width: 1.5rem;
        height: 1.5rem;
      }

      .detail-title {
        min-width: 0;
        overflow: hidden;
        font-size: 1.0625rem;
        font-weight: 600;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .detail-body {
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
        /* The last card holds text fields, so the scroll has to run past the
           keyboard: without the inset the form cannot be scrolled into view. */
        padding: 1rem max(1rem, env(safe-area-inset-right))
          calc(1.5rem + env(safe-area-inset-bottom) + var(--keyboard-inset, 0px))
          max(1rem, env(safe-area-inset-left));
      }

      .detail-card {
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
        padding: 1rem;
        border: 1px solid var(--app-border);
        border-radius: 1rem;
        background: var(--app-card);
      }

      .detail-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 0.5rem 0.75rem;
      }

      .detail-meta {
        min-width: 0;
        overflow: hidden;
        font-size: 0.8125rem;
        line-height: 1.35;
        color: var(--app-text-muted);
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .detail-status {
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

      .detail-dot {
        width: 0.5rem;
        height: 0.5rem;
        border-radius: 50%;
        background: currentColor;
      }

      .detail-status-online {
        border-color: #bfe3c9;
        background: #eef8f0;
        color: #1f6f3f;
      }

      .detail-section {
        display: flex;
        align-items: baseline;
        gap: 0.375rem;
        margin: 0;
        font-size: 0.9375rem;
      }

      .detail-unit {
        font-size: 0.75rem;
        font-weight: 600;
        color: var(--app-text-muted);
      }

      .detail-tiles {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.5rem;
        margin: 0;
      }

      .detail-tile {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        padding: 0.625rem 0.75rem;
        border-radius: 0.875rem;
        background: var(--app-surface);
      }

      .detail-tile dt {
        display: flex;
        align-items: center;
        gap: 0.375rem;
        font-size: 0.75rem;
        font-weight: 600;
        color: var(--app-text-muted);
      }

      .detail-tile dd {
        margin: 0;
        font-size: 1.125rem;
        font-weight: 650;
        font-variant-numeric: tabular-nums;
        letter-spacing: -0.01em;
      }

      /* Metric picker: a row of pills that can wrap on a narrow phone. */
      .detail-metrics {
        display: flex;
        flex-wrap: wrap;
        gap: 0.375rem;
      }

      .detail-metric {
        min-height: 2.25rem;
        display: inline-flex;
        align-items: center;
        gap: 0.375rem;
        padding: 0.375rem 0.75rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: var(--app-surface);
        color: inherit;
        font-family: inherit;
        font-size: 0.8125rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease, background-color 0.2s ease, color 0.2s ease;
      }

      .detail-metric:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .detail-metric:hover {
          border-color: var(--app-accent);
        }
      }

      .detail-metric-active {
        border-color: var(--app-accent);
        background: var(--app-accent);
        color: #ffffff;
      }

      .detail-metric-active .metric-icon {
        color: #ffffff;
      }

      .detail-chart {
        display: flex;
        align-items: stretch;
        gap: 0.5rem;
        margin: 0;
        padding: 0.75rem;
        border-radius: 0.75rem;
        background: var(--app-surface);
      }

      .detail-scale {
        flex: none;
        display: flex;
        flex-direction: column;
        justify-content: space-between;
        font-size: 0.6875rem;
        font-weight: 600;
        color: var(--app-text-muted);
      }

      /* The svg stretches to whatever width is left; the stroke stays 2px
         because the line opts out of the scale with `vector-effect`. */
      .detail-plot {
        flex: 1;
        min-width: 0;
        height: 6rem;
      }

      .detail-line {
        stroke: var(--app-accent);
        stroke-width: 2;
        stroke-linecap: round;
        stroke-linejoin: round;
      }

      .detail-point {
        fill: var(--app-accent);
      }

      .detail-note {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.45;
        color: var(--app-text-muted);
      }

      .detail-error {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.4;
        color: var(--app-callout);
      }

      .detail-form {
        display: flex;
        flex-direction: column;
        gap: 0.5rem;
      }

      .detail-label {
        font-size: 0.8125rem;
        font-weight: 600;
        letter-spacing: 0.01em;
      }

      /* 1rem text keeps mobile browsers from zooming in on focus. */
      .detail-input {
        width: 100%;
        min-height: 3rem;
        padding: 0.75rem 1rem;
        border: 1px solid var(--app-control-border);
        border-radius: 0.875rem;
        background: var(--app-surface);
        color: inherit;
        font-family: inherit;
        font-size: 1rem;
        transition: border-color 0.2s ease, box-shadow 0.2s ease;
      }

      .detail-input:focus {
        outline: none;
        border-color: var(--app-accent);
        box-shadow: 0 0 0 3px rgba(52, 168, 83, 0.18);
      }

      .detail-primary {
        min-height: 3rem;
        padding: 0.75rem 1.25rem;
        border: none;
        border-radius: 999px;
        background: var(--app-accent);
        color: #ffffff;
        font-family: inherit;
        font-size: 1rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: opacity 0.2s ease;
      }

      .detail-primary:disabled {
        cursor: not-allowed;
        opacity: 0.45;
      }

      .detail-primary:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 3px;
      }

      @media (hover: hover) {
        .detail-primary:hover:not(:disabled) {
          opacity: 0.9;
        }
      }

      .detail-outline {
        min-height: 3rem;
        padding: 0.75rem 1.25rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: transparent;
        color: inherit;
        font-family: inherit;
        font-size: 1rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease, color 0.2s ease;
      }

      .detail-outline:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 3px;
      }

      @media (hover: hover) {
        .detail-outline:hover {
          border-color: var(--app-callout);
          color: var(--app-callout);
        }
      }

      .detail-actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.5rem;
      }

      /* Destructive and irreversible from the app's side, so it reads as such. */
      .detail-danger {
        flex: 1 1 10rem;
        min-height: 3rem;
        padding: 0.75rem 1.25rem;
        border: none;
        border-radius: 999px;
        background: var(--app-callout);
        color: #ffffff;
        font-family: inherit;
        font-size: 1rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: opacity 0.2s ease;
      }

      .detail-danger:disabled {
        cursor: not-allowed;
        opacity: 0.55;
      }

      .detail-danger:focus-visible {
        outline: 2px solid var(--app-callout);
        outline-offset: 3px;
      }

      .detail-link {
        flex: none;
        min-height: 3rem;
        padding: 0.75rem 0.75rem;
        border: none;
        background: transparent;
        color: var(--app-text-muted);
        font-family: inherit;
        font-size: 0.9375rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
      }

      .detail-link:disabled {
        cursor: not-allowed;
        opacity: 0.5;
      }

      .detail-link:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (prefers-color-scheme: dark) {
        .detail-status-online {
          border-color: #2c4d37;
          background: #16281a;
          color: #7fd39a;
        }
      }

      /* Phones held sideways have very little height to spare. */
      @media (orientation: landscape) and (max-height: 32rem) {
        .detail-body {
          /* Tighter, but still clears the keyboard: sideways with the keys up
             there is almost no room left for the form. */
          padding-block: 0.75rem calc(0.75rem + var(--keyboard-inset, 0px));
        }

        .detail-plot {
          height: 4rem;
        }
      }
    </style>

    <main class="detail">
      <header class="detail-header">
        <button
          class="detail-back"
          type="button"
          aria-label="Voltar para a lista"
          ref={backButton}
          onClick={onClose}
        >
          <svg class="detail-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M15 5l-7 7 7 7"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </button>
        <h1 class="detail-title">{name.value}</h1>
      </header>

      <div class="detail-body">
        <section class="detail-card">
          <div class="detail-head">
            <span class="detail-meta">{device.hardwareId}</span>
            <span class={`detail-status detail-status-${device.status}`}>
              <span class="detail-dot" aria-hidden="true"></span>
              {STATUS_LABELS[device.status]}
            </span>
          </div>

          @if (loading.value) {
            <p class="detail-note">Carregando…</p>
          } @else if (!hasSamples.value) {
            <p class="detail-note">{lastSampleText.value}</p>
          } @else {
            <>
              <dl class="detail-tiles">
                @for (const tile of tiles.value; key tile.key) {
                  <div class="detail-tile">
                    <dt>
                      <MetricIcon metric={tile.key} />
                      {tile.label}
                    </dt>
                    <dd>{tile.value}</dd>
                  </div>
                }
              </dl>
              <p class="detail-note">{lastSampleText.value}</p>
            </>
          }

          @if (historyError.value) {
            <>
              <p class="detail-error" role="alert">{historyError.value}</p>
              <button
                class="detail-outline"
                type="button"
                onClick={() => {
                  void refreshHistory();
                }}
              >
                Tentar de novo
              </button>
            </>
          }
        </section>

        <section class="detail-card">
          <h2 class="detail-section">
            Histórico
            <span class="detail-unit">{readingMetric(metric.value).unit}</span>
          </h2>

          <div class="detail-metrics" role="group" aria-label="Escolha o que acompanhar">
            @for (const entry of READING_METRICS; key entry.key) {
              <button
                class={`detail-metric ${entry.key === metric.value ? "detail-metric-active" : ""}`}
                type="button"
                aria-pressed={entry.key === metric.value}
                onClick={() => {
                  metric.value = entry.key;
                }}
              >
                <MetricIcon metric={entry.key} />
                {entry.label}
              </button>
            }
          </div>

          @if (hasChart.value) {
            <figure class="detail-chart">
              <div class="detail-scale" aria-hidden="true">
                <span>{readingMetric(metric.value).axisFormat(chart.value.hi)}</span>
                <span>{readingMetric(metric.value).axisFormat(chart.value.lo)}</span>
              </div>

              <svg
                class="detail-plot"
                viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}
                preserveAspectRatio="none"
                role="img"
                aria-label={chartSummary.value}
              >
                <polyline
                  class="detail-line"
                  points={chart.value.line}
                  fill="none"
                  vectorEffect="non-scaling-stroke"
                />
                @if (chart.value.single) {
                  <circle
                    class="detail-point"
                    cx={chart.value.lastX}
                    cy={chart.value.lastY}
                    r="3"
                  />
                }
              </svg>
            </figure>
          } @else {
            <p class="detail-note">Sem amostras ainda.</p>
          }
        </section>

        <section class="detail-card">
          <h2 class="detail-section">Nome</h2>

          <form class="detail-form" onSubmit={submitRename}>
            <label class="detail-label" for="detail-name">Nome do vaso</label>
            <input
              class="detail-input"
              id="detail-name"
              type="text"
              maxLength={60}
              autoComplete="off"
              value={draftName.value}
              onInput={(event) => {
                draftName.value = event.currentTarget.value;
              }}
            />

            @if (renameError.value) {
              <p class="detail-error" role="alert">{renameError.value}</p>
            }

            <button
              class="detail-primary"
              type="submit"
              disabled={renaming.value ||
                !draftName.value.trim() ||
                draftName.value.trim() === name.value}
            >
              {renaming.value ? "Salvando…" : "Salvar"}
            </button>
          </form>
        </section>

        <DeviceNotifications deviceId={device.id} state={notificationState} />

        <section class="detail-card">
          <h2 class="detail-section">Remover</h2>
          <p class="detail-note">
            O vaso fica livre para ser conectado de novo. As leituras continuam salvas.
          </p>

          @if (confirmingRelease.value) {
            <div class="detail-actions">
              <button
                class="detail-danger"
                type="button"
                disabled={releasing.value}
                onClick={remove}
              >
                {releasing.value ? "Removendo…" : "Remover"}
              </button>
              <button
                class="detail-link"
                type="button"
                disabled={releasing.value}
                onClick={() => {
                  confirmingRelease.value = false;
                }}
              >
                Cancelar
              </button>
            </div>
          } @else {
            <button
              class="detail-outline"
              type="button"
              onClick={() => {
                confirmingRelease.value = true;
                releaseError.value = null;
              }}
            >
              Remover vaso
            </button>
          }

          @if (releaseError.value) {
            <p class="detail-error" role="alert">{releaseError.value}</p>
          }
        </section>
      </div>
    </main>
  </>
}
