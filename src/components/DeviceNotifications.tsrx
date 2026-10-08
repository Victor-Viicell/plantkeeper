import { track, type Tracked } from "ripple";
import { READING_METRICS, type ReadingMetricKey } from "../utils/devices";
import {
  defaultSettings,
  deviceSettings,
  fromDraft,
  metricLimitRange,
  metricStep,
  metricUnit,
  ROUTINE_LABEL_MAX,
  saveSettings,
  toDraft,
  type NotificationDraft,
  type NotificationState,
} from "../utils/notifications";

/** A fresh copy, so an edit never writes into the draft the form is showing. */
function copyDraft(source: NotificationDraft): NotificationDraft {
  const warnings = {} as NotificationDraft["warnings"];

  for (const metric of READING_METRICS) {
    warnings[metric.key] = { ...source.warnings[metric.key] };
  }

  return { ...source, warnings };
}

/**
 * The per-device rules: which readings are worth a warning, and when the daily
 * routine should be remembered.
 *
 * The form keeps a draft of raw input text and only turns it into settings on
 * submit, so a half-typed threshold never arms a warning — and an empty field
 * means "no limit on that side", not zero.
 */
export function DeviceNotifications({
  deviceId,
  state,
}: {
  deviceId: string;
  /** The shared rules, created by `Home` and handed down through the detail view. */
  state: Tracked<NotificationState>;
}) @{
  const saved = track(() => deviceSettings(state.value, deviceId));
  const draft = track(toDraft(saved.value));
  const error = track<string | null>(null);
  const notice = track<string | null>(null);

  // Both sides are built by `toDraft`, so the same key order makes this
  // comparison a plain string compare.
  const dirty = track(() => JSON.stringify(draft.value) !== JSON.stringify(toDraft(saved.value)));

  function edit(change: (next: NotificationDraft) => void) {
    const next = copyDraft(draft.value);
    change(next);

    draft.value = next;
    error.value = null;
    notice.value = null;
  }

  function toggleWarning(key: ReadingMetricKey) {
    edit((next) => {
      next.warnings[key].enabled = !next.warnings[key].enabled;
    });
  }

  function setLimit(key: ReadingMetricKey, side: "low" | "high", value: string) {
    edit((next) => {
      next.warnings[key][side] = value;
    });
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();

    const parsed = fromDraft(draft.value);
    if ("error" in parsed) {
      error.value = parsed.error;
      notice.value = null;
      return;
    }

    saveSettings(state, deviceId, parsed.settings);
    draft.value = toDraft(parsed.settings);
    error.value = null;
    notice.value = "Avisos salvos.";
  }

  function restoreDefaults() {
    const defaults = defaultSettings();

    saveSettings(state, deviceId, defaults);
    draft.value = toDraft(defaults);
    error.value = null;
    notice.value = "Voltamos aos limites sugeridos.";
  }

  <>
    <style>
      .rules {
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
        padding: 1rem;
        border: 1px solid var(--app-border);
        border-radius: 1rem;
        background: var(--app-card);
      }

      .rules-heading {
        margin: 0;
        font-size: 0.9375rem;
      }

      .rules-note {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.45;
        color: var(--app-text-muted);
      }

      .rules-form {
        display: flex;
        flex-direction: column;
        gap: 0.75rem;
      }

      .rule {
        display: flex;
        flex-direction: column;
        gap: 0.5rem;
        padding: 0.75rem;
        border-radius: 0.75rem;
        background: var(--app-surface);
      }

      .rule-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
      }

      .rule-name {
        font-size: 0.9375rem;
        font-weight: 600;
      }

      /* A switch, not a checkbox: the whole row is a setting, and the state has
         to read at a glance on a phone. */
      .rule-switch {
        flex: none;
        width: 3rem;
        height: 1.75rem;
        display: inline-flex;
        align-items: center;
        padding: 0.1875rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: var(--app-card);
        cursor: pointer;
        touch-action: manipulation;
        transition: background-color 0.2s ease, border-color 0.2s ease;
      }

      .rule-switch-on {
        justify-content: flex-end;
        border-color: var(--app-accent);
        background: var(--app-accent);
      }

      .rule-switch:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      .rule-knob {
        width: 1.25rem;
        height: 1.25rem;
        border-radius: 50%;
        background: var(--app-control-border);
        transition: background-color 0.2s ease;
      }

      .rule-switch-on .rule-knob {
        background: #ffffff;
      }

      .rule-limits {
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem;
      }

      .rule-field {
        flex: 1 1 8rem;
        display: flex;
        align-items: center;
        gap: 0.375rem;
      }

      .rule-field-label {
        flex: none;
        font-size: 0.75rem;
        color: var(--app-text-muted);
      }

      /* 1rem text keeps mobile browsers from zooming in on focus. */
      .rule-input {
        flex: 1;
        min-width: 0;
        min-height: 2.75rem;
        padding: 0.5rem 0.75rem;
        border: 1px solid var(--app-control-border);
        border-radius: 0.75rem;
        background: var(--app-card);
        color: inherit;
        font-family: inherit;
        font-size: 1rem;
        transition: border-color 0.2s ease, box-shadow 0.2s ease;
      }

      .rule-input:focus {
        outline: none;
        border-color: var(--app-accent);
        box-shadow: 0 0 0 3px rgba(52, 168, 83, 0.18);
      }

      .rule-unit {
        flex: none;
        font-size: 0.75rem;
        color: var(--app-text-muted);
      }

      .rules-error {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.4;
        color: var(--app-callout);
      }

      .rules-notice {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.4;
        color: var(--app-accent);
      }

      .rules-actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.5rem;
      }

      .rules-primary {
        flex: 1 1 9rem;
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

      .rules-primary:disabled {
        cursor: not-allowed;
        opacity: 0.45;
      }

      .rules-primary:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 3px;
      }

      @media (hover: hover) {
        .rules-primary:hover:not(:disabled) {
          opacity: 0.9;
        }
      }

      .rules-link {
        flex: none;
        min-height: 3rem;
        padding: 0.75rem 0.5rem;
        border: none;
        background: transparent;
        color: var(--app-text-muted);
        font-family: inherit;
        font-size: 0.875rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
      }

      .rules-link:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }
    </style>

    <section class="rules">
      <h2 class="rules-heading">Avisos e rotina</h2>
      <p class="rules-note">
        O Plantkeeper avisa quando uma leitura passa dos limites que você escolher, e
        lembra a rotina no horário marcado. Deixe um limite em branco para não ser
        avisado daquele lado.
      </p>

      <form class="rules-form" onSubmit={submit}>
        @for (const metric of READING_METRICS; key metric.key) {
          <div class="rule">
            <div class="rule-head">
              <span class="rule-name">{metric.label}</span>
              <button
                class={`rule-switch ${draft.value.warnings[metric.key].enabled ? "rule-switch-on" : ""}`}
                type="button"
                role="switch"
                aria-checked={draft.value.warnings[metric.key].enabled}
                aria-label={`Avisar sobre ${metric.label.toLowerCase()}`}
                onClick={() => {
                  toggleWarning(metric.key);
                }}
              >
                <span class="rule-knob" aria-hidden="true"></span>
              </button>
            </div>

            @if (draft.value.warnings[metric.key].enabled) {
              <div class="rule-limits">
                <div class="rule-field">
                  <label class="rule-field-label" for={`rule-${metric.key}-low`}>Abaixo de</label>
                  <input
                    class="rule-input"
                    id={`rule-${metric.key}-low`}
                    type="number"
                    inputMode="decimal"
                    min={metricLimitRange(metric.key).min}
                    max={metricLimitRange(metric.key).max}
                    step={metricStep(metric.key)}
                    placeholder="—"
                    aria-label={`Avisar quando ${metric.label.toLowerCase()} ficar abaixo de`}
                    value={draft.value.warnings[metric.key].low}
                    onInput={(event) => {
                      setLimit(metric.key, "low", event.currentTarget.value);
                    }}
                  />
                  <span class="rule-unit" aria-hidden="true">{metricUnit(metric.key)}</span>
                </div>

                <div class="rule-field">
                  <label class="rule-field-label" for={`rule-${metric.key}-high`}>Acima de</label>
                  <input
                    class="rule-input"
                    id={`rule-${metric.key}-high`}
                    type="number"
                    inputMode="decimal"
                    min={metricLimitRange(metric.key).min}
                    max={metricLimitRange(metric.key).max}
                    step={metricStep(metric.key)}
                    placeholder="—"
                    aria-label={`Avisar quando ${metric.label.toLowerCase()} passar de`}
                    value={draft.value.warnings[metric.key].high}
                    onInput={(event) => {
                      setLimit(metric.key, "high", event.currentTarget.value);
                    }}
                  />
                  <span class="rule-unit" aria-hidden="true">{metricUnit(metric.key)}</span>
                </div>
              </div>
            }
          </div>
        }

        <div class="rule">
          <div class="rule-head">
            <span class="rule-name">Rotina diária</span>
            <button
              class={`rule-switch ${draft.value.routineEnabled ? "rule-switch-on" : ""}`}
              type="button"
              role="switch"
              aria-checked={draft.value.routineEnabled}
              aria-label="Lembrar a rotina todos os dias"
              onClick={() => {
                edit((next) => {
                  next.routineEnabled = !next.routineEnabled;
                });
              }}
            >
              <span class="rule-knob" aria-hidden="true"></span>
            </button>
          </div>

          @if (draft.value.routineEnabled) {
            <div class="rule-limits">
              <div class="rule-field">
                <label class="rule-field-label" for="rule-routine-time">Às</label>
                <input
                  class="rule-input"
                  id="rule-routine-time"
                  type="time"
                  value={draft.value.routineTime}
                  onInput={(event) => {
                    edit((next) => {
                      next.routineTime = event.currentTarget.value;
                    });
                  }}
                />
              </div>

              <div class="rule-field">
                <label class="rule-field-label" for="rule-routine-label">O que fazer</label>
                <input
                  class="rule-input"
                  id="rule-routine-label"
                  type="text"
                  maxLength={ROUTINE_LABEL_MAX}
                  autoComplete="off"
                  value={draft.value.routineLabel}
                  onInput={(event) => {
                    edit((next) => {
                      next.routineLabel = event.currentTarget.value;
                    });
                  }}
                />
              </div>
            </div>
          }
        </div>

        @if (error.value) {
          <p class="rules-error" role="alert">{error.value}</p>
        } @else if (notice.value) {
          <p class="rules-notice" role="status">{notice.value}</p>
        }

        <div class="rules-actions">
          <button class="rules-primary" type="submit" disabled={!dirty.value}>
            Salvar avisos
          </button>
          <button class="rules-link" type="button" onClick={restoreDefaults}>
            Restaurar padrões
          </button>
        </div>
      </form>
    </section>
  </>
}
