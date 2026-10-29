/**
 * Warnings and routines.
 *
 * Two kinds of thing reach the notification centre:
 *
 *   - a **warning** comes from the newest reading of a vase: a value that
 *     crossed a limit the user set for that device;
 *   - a **routine** is a reminder every N days at a fixed time ("regar a
 *     planta a cada 7 dias, às 9h"), which falls due even when the vase is not
 *     reporting.
 *
 * Warnings and routines can be filled from a plant preset, so someone who does
 * not know a species' limits still starts from sensible values.
 *
 * Both are worked out on the client from readings the app already has, so
 * nothing here talks to Supabase. Settings and dismissals are per device and
 * kept in `localStorage`, next to the device stand-in, so the centre behaves the
 * same with the mocked sign-in and with the real backend.
 *
 * The state itself is a tracked value owned by `Home` (see
 * `createNotificationState`) and handed down, so saving a rule or dismissing an
 * alert redraws the panel immediately — no poll and no refresh button between.
 */
import { track, type Tracked } from "ripple";
import { READING_METRICS, type Device, type ReadingMetricKey } from "./devices";

/** Which readings count as a problem for one metric. `null` means "no limit". */
export type MetricWarning = {
  enabled: boolean;
  /** Warn while the reading stays below this. */
  low: number | null;
  /** Warn while the reading stays above this. */
  high: number | null;
};

/** A reminder every `everyDays` days at a fixed local time. */
export type CareRoutine = {
  enabled: boolean;
  /** Days between reminders; 1 means every day. */
  everyDays: number;
  /** Local time of day, `HH:MM`. */
  time: string;
  label: string;
};

export type DeviceNotificationSettings = {
  /** The plant preset this came from, or `null` after a manual edit. */
  presetId: string | null;
  warnings: Record<ReadingMetricKey, MetricWarning>;
  routine: CareRoutine;
};

export type AppNotification = {
  /** Stable per (device, rule), which is what lets a dismissal be remembered. */
  id: string;
  kind: "warning" | "routine";
  deviceId: string;
  deviceName: string;
  title: string;
  detail: string;
  /** ISO stamp: when the reading was sampled, or when the routine fell due. */
  at: string;
  /** Routines only: how many days separate two reminders. */
  everyDays?: number;
};

/** How long "Dispensar" keeps a warning quiet before it comes back. */
export const WARNING_SNOOZE_MS = 60 * 60 * 1000;

/** The label field is a nudge, not a sentence. */
export const ROUTINE_LABEL_MAX = 60;

/**
 * The thresholds a new device starts with. Only the readings that call for
 * action are armed — air humidity is recorded but says nothing on its own — and
 * the values are the usual ones for a potted plant.
 */
export function defaultSettings(): DeviceNotificationSettings {
  return {
    presetId: null,
    warnings: {
      soil: { enabled: true, low: 35, high: null },
      // 200 lx is shade under a shelf: dark enough to matter for most plants.
      light: { enabled: true, low: 200, high: null },
      temperature: { enabled: true, low: null, high: 32 },
      humidity: { enabled: false, low: null, high: null },
    },
    routine: { enabled: false, everyDays: 1, time: "09:00", label: "Verificar a planta" },
  };
}

/** Upper bound for a routine interval, in days. */
export const ROUTINE_DAYS_MAX = 60;

export type PlantPreset = {
  id: string;
  name: string;
  emoji: string;
  /** One line under the picker, naming the plants it covers. */
  summary: string;
  warnings: Record<ReadingMetricKey, MetricWarning>;
  routine: CareRoutine;
};

/**
 * Starting points for the plants people usually keep. The thresholds assume the
 * app's approximate soil and light scales and are deliberately generous — they
 * are a substitute for knowing the species, not a substitute for watching the
 * plant. Every field stays editable after a preset is picked.
 */
export const PLANT_PRESETS: ReadonlyArray<PlantPreset> = [
  {
    id: "succulent",
    name: "Suculenta",
    emoji: "🌵",
    summary: "Cactos e suculentas: sol, solo seco e rega a cada 14 dias.",
    warnings: {
      soil: { enabled: true, low: 15, high: 85 },
      light: { enabled: true, low: 800, high: null },
      temperature: { enabled: true, low: 5, high: 35 },
      humidity: { enabled: false, low: null, high: null },
    },
    routine: { enabled: true, everyDays: 14, time: "09:00", label: "Regar a suculenta" },
  },
  {
    id: "fern",
    name: "Samambaia",
    emoji: "🌿",
    summary: "Samambaias e avencas: sombra, ar úmido e rega a cada 3 dias.",
    warnings: {
      soil: { enabled: true, low: 50, high: 90 },
      light: { enabled: true, low: 150, high: 2500 },
      temperature: { enabled: true, low: 15, high: 28 },
      humidity: { enabled: true, low: 50, high: null },
    },
    routine: { enabled: true, everyDays: 3, time: "08:00", label: "Borrifar e regar a samambaia" },
  },
  {
    id: "tropical",
    name: "Tropical",
    emoji: "🌴",
    summary: "Monstera e filodendro: luz indireta e rega a cada 7 dias.",
    warnings: {
      soil: { enabled: true, low: 35, high: 85 },
      light: { enabled: true, low: 400, high: 4000 },
      temperature: { enabled: true, low: 15, high: 30 },
      humidity: { enabled: true, low: 40, high: null },
    },
    routine: { enabled: true, everyDays: 7, time: "09:00", label: "Regar a folhagem" },
  },
  {
    id: "shade",
    name: "Sombra",
    emoji: "🪴",
    summary: "Jiboia e zamioculca: pouca luz e rega a cada 10 dias.",
    warnings: {
      soil: { enabled: true, low: 25, high: 80 },
      light: { enabled: true, low: 100, high: 2000 },
      temperature: { enabled: true, low: 12, high: 30 },
      humidity: { enabled: false, low: null, high: null },
    },
    routine: { enabled: true, everyDays: 10, time: "09:00", label: "Regar a planta de sombra" },
  },
  {
    id: "orchid",
    name: "Orquídea",
    emoji: "🌸",
    summary: "Orquídeas: luz indireta e rega a cada 7 dias, sem encharcar.",
    warnings: {
      soil: { enabled: true, low: 25, high: 70 },
      light: { enabled: true, low: 300, high: 3000 },
      temperature: { enabled: true, low: 15, high: 30 },
      humidity: { enabled: true, low: 45, high: null },
    },
    routine: { enabled: true, everyDays: 7, time: "09:00", label: "Regar a orquídea" },
  },
  {
    id: "herbs",
    name: "Horta",
    emoji: "🌱",
    summary: "Manjericão e salsinha: muita luz e rega a cada 2 dias.",
    warnings: {
      soil: { enabled: true, low: 45, high: 85 },
      light: { enabled: true, low: 1000, high: null },
      temperature: { enabled: true, low: 15, high: 32 },
      humidity: { enabled: true, low: 40, high: null },
    },
    routine: { enabled: true, everyDays: 2, time: "08:00", label: "Regar a horta" },
  },
];

/** A mutable copy of a preset, stamped with the preset it came from. */
export function presetSettings(preset: PlantPreset): DeviceNotificationSettings {
  const warnings = {} as Record<ReadingMetricKey, MetricWarning>;

  for (const metric of READING_METRICS) {
    warnings[metric.key] = { ...preset.warnings[metric.key] };
  }

  return {
    presetId: preset.id,
    warnings,
    routine: { ...preset.routine },
  };
}

/** Headline for a breached limit, e.g. "Solo seco". */
const WARNING_TITLES: Record<ReadingMetricKey, { low: string; high: string }> = {
  soil: { low: "Solo seco", high: "Solo encharcado" },
  light: { low: "Pouca luz", high: "Luz demais" },
  temperature: { low: "Frio demais", high: "Calor demais" },
  humidity: { low: "Ar seco", high: "Ar úmido demais" },
};

/** The plausible span of each reading, used to reject typos in the form. */
const LIMIT_RANGE: Record<ReadingMetricKey, { min: number; max: number }> = {
  soil: { min: 0, max: 100 },
  light: { min: 0, max: 10_000 },
  temperature: { min: -10, max: 60 },
  humidity: { min: 0, max: 100 },
};

const METRIC_UNITS: Record<ReadingMetricKey, string> = {
  soil: "%",
  light: "lx",
  temperature: "°C",
  humidity: "%",
};

/** The smallest step the form accepts for a metric, e.g. 0.5 °C. */
const METRIC_STEPS: Record<ReadingMetricKey, number> = {
  soil: 1,
  light: 10,
  temperature: 0.5,
  humidity: 1,
};

const TIME_PATTERN = /^([01]\d|2[0-3]):([0-5]\d)$/;

// Versioned because the light limits changed from the sensor's 0-100 index to
// lux: reading the old key would silently reinterpret 25 as 25 lx.
const SETTINGS_KEY = "plantkeeper.notification-settings.v2";
const LEGACY_SETTINGS_KEY = "plantkeeper.notification-settings";
const DISMISSALS_KEY = "plantkeeper.notification-dismissals";

/** Dismissals older than this are dropped on the next write. */
const DAY_MS = 24 * 60 * 60 * 1000;
const DISMISSAL_KEEP_MS = (ROUTINE_DAYS_MAX + 2) * DAY_MS;

type SettingsMap = Record<string, DeviceNotificationSettings>;
type DismissalMap = Record<string, string>;

/**
 * Everything the centre is drawn from: the rules per device, and what the user
 * has put away. Kept together so one value carries the whole panel.
 */
export type NotificationState = {
  settings: SettingsMap;
  dismissals: DismissalMap;
};

/**
 * Builds the state from what storage holds.
 *
 * Called from a component body, not at module scope: a tracked value belongs to
 * the component that created it, and one made without that context refuses its
 * first write — which is exactly when a rule is saved, long after mount.
 */
export function createNotificationState(): Tracked<NotificationState> {
  return track<NotificationState>({
    settings: readStoredSettings(),
    dismissals: readStoredDismissals(),
  });
}

/** The unit a threshold field is labelled with. */
export function metricUnit(key: ReadingMetricKey): string {
  return METRIC_UNITS[key];
}

/** The step a threshold field moves by. */
export function metricStep(key: ReadingMetricKey): number {
  return METRIC_STEPS[key];
}

/** The span a threshold field accepts, for `min`/`max` on the input. */
export function metricLimitRange(key: ReadingMetricKey): { min: number; max: number } {
  return LIMIT_RANGE[key];
}

/**
 * The rules for one device, or the defaults for a vase nobody has configured.
 * Reading this inside a derived value subscribes it to later saves.
 */
export function deviceSettings(
  state: NotificationState,
  deviceId: string,
): DeviceNotificationSettings {
  return state.settings[deviceId] ?? defaultSettings();
}

/** Stores the rules for one device; the panel and the badge follow. */
export function saveSettings(
  state: Tracked<NotificationState>,
  deviceId: string,
  settings: DeviceNotificationSettings,
): void {
  const rules = { ...state.value.settings, [deviceId]: settings };
  state.value = { settings: rules, dismissals: state.value.dismissals };
  writeStored(SETTINGS_KEY, rules);
}

/**
 * Forgets a device's rules and dismissals, for a vase that was released. Its id
 * never comes back, so keeping them would only leave dead rows behind.
 */
export function forgetDeviceNotifications(
  state: Tracked<NotificationState>,
  deviceId: string,
): void {
  const rules = { ...state.value.settings };
  const dismissals = { ...state.value.dismissals };
  // Dismissal keys are `kind:deviceId:…`, so the id sits in the same field for
  // both kinds and can be matched directly.
  const ownDismissals = Object.keys(dismissals).filter((id) => id.split(":")[1] === deviceId);

  if (!(deviceId in rules) && ownDismissals.length === 0) return;

  delete rules[deviceId];
  for (const id of ownDismissals) delete dismissals[id];

  state.value = { settings: rules, dismissals };
  writeStored(SETTINGS_KEY, rules);
  writeStored(DISMISSALS_KEY, dismissals);
}

/**
 * Everything the centre should list right now, warnings first and newest first
 * inside each group. Devices that stopped reporting are skipped: their newest
 * reading is stale, and an alert about it would be about a pot nobody has
 * touched since the vase went quiet.
 */
export function evaluateNotifications(
  state: NotificationState,
  devices: Device[],
  now: number = Date.now(),
): AppNotification[] {
  const found: AppNotification[] = [];

  for (const device of devices) {
    const settings = deviceSettings(state, device.id);
    found.push(...warningsFor(device, settings));
    const routine = routineFor(device, settings, now);
    if (routine) found.push(routine);
  }

  return found
    .filter((notification) => !stillDismissed(notification, state.dismissals[notification.id], now))
    .sort((a, b) => rank(a) - rank(b) || Date.parse(b.at) - Date.parse(a.at));
}

/**
 * Hides a notification: a warning stays quiet for an hour, a routine is done for
 * the rest of the day. Either way it comes back by itself, so "dispensar" can
 * never hide a problem for good.
 */
export function dismissNotification(
  state: Tracked<NotificationState>,
  notification: AppNotification,
  now: number = Date.now(),
): void {
  const stamp = new Date(now).toISOString();
  const dismissals = pruneDismissals(
    { ...state.value.dismissals, [notification.id]: stamp },
    now,
  );

  state.value = { settings: state.value.settings, dismissals };
  writeStored(DISMISSALS_KEY, dismissals);
}

/** The `HH:MM` of `time` on the day of `now`, or `null` for an unusable time. */
export function routineDueAt(time: string, now: number): number | null {
  if (!isValidTime(time)) return null;

  const [hours, minutes] = time.split(":").map(Number);
  const due = new Date(now);
  due.setHours(hours, minutes, 0, 0);
  return due.getTime();
}

/** True for a time the form and the routine can both use. */
export function isValidTime(value: string): boolean {
  return TIME_PATTERN.test(value.trim());
}

// ---------------------------------------------------------------------------
//  The settings form
// ---------------------------------------------------------------------------

/** What the form holds while the user edits: raw input text, not numbers. */
export type NotificationDraft = {
  /** The chosen plant preset, or `null` for a custom setup. */
  presetId: string | null;
  warnings: Record<ReadingMetricKey, { enabled: boolean; low: string; high: string }>;
  routineEnabled: boolean;
  routineEveryDays: string;
  routineTime: string;
  routineLabel: string;
};

/** Fills the form from the stored rules. */
export function toDraft(settings: DeviceNotificationSettings): NotificationDraft {
  const warnings = {} as NotificationDraft["warnings"];

  for (const metric of READING_METRICS) {
    const rule = settings.warnings[metric.key];
    warnings[metric.key] = {
      enabled: rule.enabled,
      low: rule.low === null ? "" : String(rule.low),
      high: rule.high === null ? "" : String(rule.high),
    };
  }

  return {
    presetId: settings.presetId,
    warnings,
    routineEnabled: settings.routine.enabled,
    routineEveryDays: String(settings.routine.everyDays),
    routineTime: settings.routine.time,
    routineLabel: settings.routine.label,
  };
}

/**
 * Turns the form into rules, or into the one message explaining what is wrong
 * with it — empty fields mean "no limit on this side", which is not an error.
 */
export function fromDraft(
  draft: NotificationDraft,
): { settings: DeviceNotificationSettings } | { error: string } {
  const warnings = {} as Record<ReadingMetricKey, MetricWarning>;

  for (const metric of READING_METRICS) {
    const rule = draft.warnings[metric.key];

    let low: number | null;
    let high: number | null;

    try {
      low = parseLimit(rule.low, metric.key);
      high = parseLimit(rule.high, metric.key);
    } catch (cause) {
      return { error: cause instanceof Error ? cause.message : "Limite inválido." };
    }

    if (low !== null && high !== null && low >= high) {
      return {
        error: `Em "${metric.label}", o limite de baixo precisa ser menor que o de cima.`,
      };
    }

    warnings[metric.key] = { enabled: rule.enabled, low, high };
  }

  if (draft.routineEnabled && !isValidTime(draft.routineTime)) {
    return { error: "Informe o horário da rotina como 09:00." };
  }

  const everyDays = parseRoutineDays(draft.routineEveryDays);
  if (draft.routineEnabled && everyDays === null) {
    return { error: `A rotina pode ser a cada 1 a ${ROUTINE_DAYS_MAX} dias.` };
  }

  return {
    settings: {
      presetId: draft.presetId,
      warnings,
      routine: {
        enabled: draft.routineEnabled,
        everyDays: everyDays ?? 1,
        time: draft.routineTime.trim(),
        label: draft.routineLabel.trim() || defaultSettings().routine.label,
      },
    },
  };
}

/** Reads the repeat interval, or `null` when it is not a whole day count. */
function parseRoutineDays(text: string): number | null {
  const value = Number(text.trim());
  if (!Number.isInteger(value) || value < 1 || value > ROUTINE_DAYS_MAX) return null;
  return value;
}

/** Reads one threshold field, throwing a message the form can show. */
function parseLimit(text: string, key: ReadingMetricKey): number | null {
  const trimmed = text.trim();
  if (!trimmed) return null;

  // A pt-BR keyboard offers a comma, and both separators mean the same thing.
  const value = Number(trimmed.replace(",", "."));
  const { min, max } = LIMIT_RANGE[key];
  const label = metricLabel(key);

  if (!Number.isFinite(value)) throw new Error(`Use um número no limite de ${label}.`);
  if (value < min || value > max) {
    throw new Error(`O limite de ${label} fica entre ${min} e ${max} ${METRIC_UNITS[key]}.`);
  }

  return value;
}

function metricLabel(key: ReadingMetricKey): string {
  return READING_METRICS.find((metric) => metric.key === key)?.name ?? key;
}

// ---------------------------------------------------------------------------
//  Evaluation
// ---------------------------------------------------------------------------

function warningsFor(device: Device, settings: DeviceNotificationSettings): AppNotification[] {
  const readings = device.readings;
  if (!readings || device.status === "offline") return [];

  const found: AppNotification[] = [];

  for (const metric of READING_METRICS) {
    const rule = settings.warnings[metric.key];
    if (!rule.enabled) continue;

    const value = readings[metric.key];
    if (typeof value !== "number") continue;

    for (const side of ["low", "high"] as const) {
      const limit = rule[side];
      if (limit === null) continue;
      if (side === "low" ? value >= limit : value <= limit) continue;

      found.push({
        id: `warning:${device.id}:${metric.key}:${side}`,
        kind: "warning",
        deviceId: device.id,
        deviceName: device.name,
        title: WARNING_TITLES[metric.key][side],
        // Both values carry their unit, so "abaixo do limite de 200 lx" reads
        // as a comparison of the same thing.
        detail:
          `${metric.name} em ${metric.format(value)}, ` +
          `${side === "low" ? "abaixo" : "acima"} do limite de ${metric.format(limit)}.`,
        at: readings.capturedAt,
      });
    }
  }

  return found;
}

function routineFor(
  device: Device,
  settings: DeviceNotificationSettings,
  now: number,
): AppNotification | null {
  const routine = settings.routine;
  if (!routine.enabled) return null;

  const due = routineDueAt(routine.time, now);
  if (due === null || due > now) return null;

  return {
    id: `routine:${device.id}`,
    kind: "routine",
    deviceId: device.id,
    deviceName: device.name,
    title: routine.label,
    detail:
      routine.everyDays === 1
        ? `Rotina diária às ${routine.time}.`
        : `Rotina a cada ${routine.everyDays} dias, às ${routine.time}.`,
    at: new Date(due).toISOString(),
    everyDays: routine.everyDays,
  };
}

/** Warnings are what the vase is asking for; they read before the reminders. */
function rank(notification: AppNotification): number {
  return notification.kind === "warning" ? 0 : 1;
}

function stillDismissed(
  notification: AppNotification,
  dismissedAt: string | undefined,
  now: number,
): boolean {
  if (!dismissedAt) return false;

  const when = Date.parse(dismissedAt);
  if (Number.isNaN(when)) return false;

  // A warning is snoozed for an hour; a routine marked done stays quiet until
  // its own interval has passed (the next day, for a daily one).
  return notification.kind === "warning"
    ? now - when < WARNING_SNOOZE_MS
    : localDaysBetween(when, now) < (notification.everyDays ?? 1);
}

function pruneDismissals(map: DismissalMap, now: number): DismissalMap {
  const kept: DismissalMap = {};

  for (const [id, at] of Object.entries(map)) {
    const when = Date.parse(at);
    if (Number.isNaN(when) || now - when > DISMISSAL_KEEP_MS) continue;
    kept[id] = at;
  }

  return kept;
}

function localDaysBetween(a: number, b: number): number {
  const first = new Date(a);
  const second = new Date(b);

  first.setHours(0, 0, 0, 0);
  second.setHours(0, 0, 0, 0);

  // Rounding keeps a DST change from turning seven days into "six".
  return Math.round((second.getTime() - first.getTime()) / DAY_MS);
}

// ---------------------------------------------------------------------------
//  Storage
// ---------------------------------------------------------------------------

/**
 * Storage is best effort: a webview with `localStorage` turned off still gets a
 * working centre, it just forgets the rules when the app closes.
 */
function readStoredSettings(): SettingsMap {
  // Drop the pre-lux key instead of leaving a stale copy next to the current
  // one; it is never read again.
  try {
    window.localStorage.removeItem(LEGACY_SETTINGS_KEY);
  } catch {
    // Storage can be unavailable; nothing to clean up.
  }

  const raw = readStored(SETTINGS_KEY);
  const stored = asRecord(raw);
  if (!stored) return {};

  const map: SettingsMap = {};
  for (const [deviceId, value] of Object.entries(stored)) {
    map[deviceId] = normalizeSettings(value);
  }

  return map;
}

function readStoredDismissals(): DismissalMap {
  const raw = readStored(DISMISSALS_KEY);
  const stored = asRecord(raw);
  if (!stored) return {};

  const map: DismissalMap = {};
  for (const [id, value] of Object.entries(stored)) {
    if (typeof value === "string") map[id] = value;
  }

  return map;
}

/**
 * Rebuilds rules from whatever storage holds. Anything missing or malformed
 * falls back to the default for that field, so a half-written entry from an
 * older version still opens.
 */
export function normalizeSettings(value: unknown): DeviceNotificationSettings {
  const defaults = defaultSettings();
  const stored = asRecord(value);
  const storedWarnings = asRecord(stored?.warnings);
  const storedRoutine = asRecord(stored?.routine);

  const warnings = {} as Record<ReadingMetricKey, MetricWarning>;
  for (const metric of READING_METRICS) {
    warnings[metric.key] = normalizeWarning(
      storedWarnings?.[metric.key],
      defaults.warnings[metric.key],
    );
  }

  const presetId = PLANT_PRESETS.some((preset) => preset.id === stored?.presetId)
    ? (stored?.presetId as string)
    : null;

  const time = storedRoutine?.time;
  const label = storedRoutine?.label;
  const everyDays = storedRoutine?.everyDays;

  return {
    presetId,
    warnings,
    routine: {
      enabled: booleanOr(storedRoutine?.enabled, defaults.routine.enabled),
      everyDays:
        typeof everyDays === "number" && Number.isInteger(everyDays)
          ? Math.min(ROUTINE_DAYS_MAX, Math.max(1, everyDays))
          : defaults.routine.everyDays,
      time: typeof time === "string" && isValidTime(time) ? time.trim() : defaults.routine.time,
      label:
        typeof label === "string" && label.trim()
          ? label.trim().slice(0, ROUTINE_LABEL_MAX)
          : defaults.routine.label,
    },
  };
}

function normalizeWarning(value: unknown, fallback: MetricWarning): MetricWarning {
  const rule = asRecord(value);
  if (!rule) return { ...fallback };

  return {
    enabled: booleanOr(rule.enabled, fallback.enabled),
    low: numberOrNull(rule.low),
    high: numberOrNull(rule.high),
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
}

function booleanOr(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function readStored(key: string): unknown {
  try {
    const raw = window.localStorage.getItem(key);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function writeStored(key: string, value: unknown): void {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage can be unavailable; the reactive stores still drive the UI.
  }
}
