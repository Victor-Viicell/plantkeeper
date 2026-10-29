import { track, type Tracked } from "ripple";
import { MetricIcon } from "./MetricIcon.tsrx";
import { READING_METRICS, type ReadingMetricKey } from "../utils/devices";
import {
  defaultSettings,
  deviceSettings,
  fromDraft,
  metricLimitRange,
  metricStep,
  metricUnit,
  PLANT_PRESETS,
  presetSettings,
  ROUTINE_DAYS_MAX,
  ROUTINE_LABEL_MAX,
  saveSettings,
  toDraft,
  type NotificationDraft,
  type NotificationState,
  type PlantPreset,
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
  const activePreset = track(
    () => PLANT_PRESETS.find((preset) => preset.id === draft.value.presetId) ?? null,
  );
  const error = track<string | null>(null);
  const notice = track<string | null>(null);

  // Both sides are built by `toDraft`, so the same key order makes this
  // comparison a plain string compare.
  const dirty = track(() => JSON.stringify(draft.value) !== JSON.stringify(toDraft(saved.value)));

  function edit(change: (next: NotificationDraft) => void) {
    const next = copyDraft(draft.value);
    change(next);

    // Any manual change leaves the preset behind: the stored id should describe
    // the current rules, not the ones the user started from.
    next.presetId = null;
    draft.value = next;
    error.value = null;
    notice.value = null;
  }

  function applyPreset(preset: PlantPreset) {
    draft.value = toDraft(presetSettings(preset));
    error.value = null;
    notice.value = "Preset preenchido. Salve para aplicar.";
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
    draft.value = toDraft(defaultSettings());
    error.value = null;
    notice.value = "Padrões preenchidos. Salve para aplicar.";
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

      .rules-label {
        font-size: 0.8125rem;
        font-weight: 600;
        letter-spacing: 0.01em;
      }

      .preset-block {
        display: flex;
        flex-direction: column;
        gap: 0.5rem;
      }

      .presets {
        display: flex;
        flex-wrap: wrap;
        gap: 0.375rem;
      }

      .preset {
        min-height: 2.25rem;
        display: inline-flex;
        align-items: center;
        gap: 0.375rem;
        padding: 0.375rem 0.75rem;
        border: 1px solid var(--app-control-border);
        border-radius: 999px;
        background: var(--app-card);
        color: inherit;
        font-family: inherit;
        font-size: 0.8125rem;
        font-weight: 600;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease, background-color 0.2s ease, color 0.2s ease;
      }

      .preset:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .preset:hover {
          border-color: var(--app-accent);
        }
      }

      .preset-active {
        border-color: var(--app-accent);
        background: var(--app-accent);
        color: #ffffff;
      }

      .preset-summary {
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
        display: inline-flex;
        align-items: center;
        gap: 0.375rem;
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
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
        gap: 0.5rem;
      }

      /* The routine fields carry longer text, so they stack instead of sharing
         a row where the label and the input compete for width. */
      .rule-limits-single {
        grid-template-columns: minmax(0, 1fr);
      }

      .rule-field {
        display: flex;
        align-items: center;
        gap: 0.375rem;
        min-width: 0;
      }

      /* A long text value gets the whole row; its label sits above it. */
      .rule-field-stacked {
        flex-direction: column;
        align-items: stretch;
        gap: 0.25rem;
      }

      .rule-field-label {
        flex: none;
        font-size: 0.75rem;
        color: var(--app-text-muted);
      }

      /* 1rem text keeps mobile browsers from zooming in on focus. */
      .rule-input {
        flex: 1 1 auto;
        width: auto;
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

      /* Short fields do not need to stretch across the whole row. */
      .rule-input-days {
        flex: 0 1 5.5rem;
        max-width: 5.5rem;
      }

      .rule-input-time {
        flex: 0 1 10rem;
        max-width: 10rem;
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
        Escolha o tipo de planta para preencher limites e rotina. Depois ajuste o
        que quiser; limite em branco: sem aviso daquele lado.
      </p>

      <form class="rules-form" onSubmit={submit}>
        <div class="preset-block">
          <span class="rules-label">Tipo de planta</span>
          <div class="presets" role="group" aria-label="Preset de planta">
            @for (const preset of PLANT_PRESETS; key preset.id) {
              <button
                class={`preset ${preset.id === draft.value.presetId ? "preset-active" : ""}`}
                type="button"
                aria-pressed={preset.id === draft.value.presetId}
                onClick={() => {
                  applyPreset(preset);
                }}
              >
                <span aria-hidden="true">{preset.emoji}</span>
                {preset.name}
              </button>
            }
          </div>
          <p class="preset-summary">
            {activePreset.value
              ? activePreset.value.summary
              : "Personalizado: ajuste os limites e a rotina abaixo."}
          </p>
        </div>

        @for (const metric of READING_METRICS; key metric.key) {
          <div class="rule">
            <div class="rule-head">
              <span class="rule-name">
                <MetricIcon metric={metric.key} />
                {metric.label}
              </span>
              <button
                class={`rule-switch ${draft.value.warnings[metric.key].enabled ? "rule-switch-on" : ""}`}
                type="button"
                role="switch"
                aria-checked={draft.value.warnings[metric.key].enabled}
                aria-label={`Avisar sobre ${metric.name}`}
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
                    aria-label={`Avisar quando ${metric.name} ficar abaixo de`}
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
                    aria-label={`Avisar quando ${metric.name} passar de`}
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
            <span class="rule-name">Rotina</span>
            <button
              class={`rule-switch ${draft.value.routineEnabled ? "rule-switch-on" : ""}`}
              type="button"
              role="switch"
              aria-checked={draft.value.routineEnabled}
              aria-label="Lembrar a rotina"
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
            <div class="rule-limits rule-limits-single">
              <div class="rule-field">
                <label class="rule-field-label" for="rule-routine-days">A cada</label>
                <input
                  class="rule-input rule-input-days"
                  id="rule-routine-days"
                  type="number"
                  inputMode="numeric"
                  min={1}
                  max={ROUTINE_DAYS_MAX}
                  step={1}
                  aria-label="Repetir a rotina a cada quantos dias"
                  value={draft.value.routineEveryDays}
                  onInput={(event) => {
                    edit((next) => {
                      next.routineEveryDays = event.currentTarget.value;
                    });
                  }}
                />
                <span class="rule-unit" aria-hidden="true">dias</span>
              </div>

              <div class="rule-field">
                <label class="rule-field-label" for="rule-routine-time">Às</label>
                <input
                  class="rule-input rule-input-time"
                  id="rule-routine-time"
                  type="time"
                  lang="pt-BR"
                  value={draft.value.routineTime}
                  onInput={(event) => {
                    edit((next) => {
                      next.routineTime = event.currentTarget.value;
                    });
                  }}
                />
              </div>

              <div class="rule-field rule-field-stacked">
                <label class="rule-field-label" for="rule-routine-label">Lembrete</label>
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
            Salvar
          </button>
          <button class="rules-link" type="button" onClick={restoreDefaults}>
            Padrões
          </button>
        </div>
      </form>
    </section>
  </>
}
