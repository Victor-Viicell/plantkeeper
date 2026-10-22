/**
 * Devices live in Supabase, not on the phone. The vase uploads readings under
 * its own `device_uid`, and the app only ever sees the rows it has claimed.
 *
 * Connecting is a short handshake built around a code the device shows (its
 * LCD, or the label on the box):
 *   1. the user types the code into the app;
 *   2. `claim_device()` binds that row to the signed-in account.
 *
 * With real sign-in (the default in `auth.ts`) this talks to the project
 * described by the IoT project's `supabase/schema.sql`, keyed by the session's
 * uid. Flipping `USE_MOCK_AUTH` to true switches the same handshake to a local
 * stand-in that keeps the shapes the backend returns, for offline UI work.
 */
import { isMockAuthEnabled } from "./auth";
import { getSupabase } from "./supabase";

export type DeviceStatus = "online" | "offline";

/** The newest upload from a device, as shown on its card. */
export type DeviceReadings = {
  soil: number | null;
  light: number | null;
  temperature: number | null;
  humidity: number | null;
  /** ISO timestamp of the sample. */
  capturedAt: string;
};

export type Device = {
  id: string;
  name: string;
  /** The identifier flashed into the firmware; unique per vase. */
  hardwareId: string;
  status: DeviceStatus;
  lastSeenAt: string | null;
  readings: DeviceReadings | null;
};

export const STATUS_LABELS: Record<DeviceStatus, string> = {
  online: "Online",
  offline: "Offline",
};

/**
 * The four values a reading carries, in the order every screen shows them, with
 * the range a chart should draw them against (`null` = scale to the samples).
 * Shared so a label or a unit never drifts between the list and the detail view.
 *
 * `format` is what a person reads; `axisFormat` is what the chart's scale shows,
 * where the unit would only repeat on every tick.
 */
export const READING_METRICS: ReadonlyArray<{
  key: "soil" | "light" | "temperature" | "humidity";
  label: string;
  max: number | null;
  format: (value: number | null) => string;
  axisFormat: (value: number | null) => string;
}> = [
  // The two ADC channels are reported as an index on the sensor's own scale, not
  // as a unit: nothing here is calibrated, so "58/100" claims nothing that
  // "58%" would not.
  { key: "soil", label: "Umidade do solo", max: 100, format: formatIndex, axisFormat: formatIndexTick },
  { key: "light", label: "Luz", max: 100, format: formatIndex, axisFormat: formatIndexTick },
  // The DHT22 reports real units, so these two keep theirs.
  {
    key: "temperature",
    label: "Temperatura do ar",
    max: null,
    format: formatTemperature,
    axisFormat: formatTemperature,
  },
  { key: "humidity", label: "Umidade do ar", max: 100, format: formatPercent, axisFormat: formatPercent },
];

export type ReadingMetricKey = (typeof READING_METRICS)[number]["key"];

/** The label and formatting for one metric, e.g. to title a chart. */
export function readingMetric(key: ReadingMetricKey) {
  return READING_METRICS.find((metric) => metric.key === key) ?? READING_METRICS[0];
}

/**
 * A device counts as online while it keeps publishing. It uploads every 15 s,
 * so a minute of silence is a dropped connection, not a slow battery.
 */
const ONLINE_WINDOW_MS = 60_000;

/** How often `Home` re-reads the device list. */
export const DEVICE_REFRESH_MS = 15_000;

/**
 * How many samples the detail view charts. The vase publishes every 15 s, so
 * this is the last 15 minutes: enough to see a trend, small enough to stay one
 * cheap page off the `(device_id, created_at desc)` index.
 */
export const HISTORY_LIMIT = 60;

const MOCK_STORAGE_KEY = "plantkeeper.devices";

/**
 * Spacing of the stand-in history. The vase publishes every 15 s, so the mock
 * curve is sampled on the same beat the real one would be.
 */
const MOCK_SAMPLE_MS = 15_000;

/** Rows as PostgREST returns them. */
type DeviceRow = {
  id: string;
  name: string | null;
  device_uid: string;
  last_seen: string | null;
};

type ReadingRow = {
  soil: number | null;
  light: number | null;
  temperature: number | null;
  humidity: number | null;
  created_at: string;
};

/** A device row carrying the newest reading PostgREST embedded alongside it. */
type DeviceWithReadingsRow = DeviceRow & { readings: ReadingRow[] | null };

/** A claimed device plus the code that claimed it, while auth is mocked. */
type MockDevice = {
  id: string;
  name: string;
  hardwareId: string;
  claimCode: string;
};

/** Codes the local stand-in accepts, mirroring the seed row in schema.sql. */
const MOCK_CLAIM_CODES: Record<string, { name: string; hardwareId: string }> = {
  "PLANT-4K7Q": { name: "Vaso protótipo", hardwareId: "vase-01" },
};

// Kept in memory so the list survives even when localStorage is unavailable.
let mockFallback: MockDevice[] = [];

/**
 * Every device the signed-in account has claimed. Throws a user-facing message
 * when the backend cannot be reached.
 */
export async function loadDevices(): Promise<Device[]> {
  return isMockAuthEnabled() ? loadMockDevices() : loadCloudDevices();
}

/**
 * Binds a device to the current account using the code it shows. Resolves to
 * the freshly connected device, or throws a message the sheet can display.
 */
export async function connectDevice(claimCode: string): Promise<Device> {
  const code = claimCode.trim().toUpperCase();
  if (!code) throw new Error("Informe o código do dispositivo.");

  return isMockAuthEnabled() ? claimMockDevice(code) : claimCloudDevice(code);
}

/**
 * Renames a device the account owns. Resolves once the new name is stored, or
 * throws a message the caller can display.
 */
export async function renameDevice(deviceId: string, name: string): Promise<void> {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("Dê um nome ao dispositivo.");

  return isMockAuthEnabled() ? renameMockDevice(deviceId, trimmed) : renameCloudDevice(deviceId, trimmed);
}

/**
 * Releases a device back to unclaimed, so it can be claimed again — by this
 * account or another one. The rows are not deleted: the vase keeps its
 * identity and its readings, and `claim_device()` can hand it out again.
 */
export async function releaseDevice(deviceId: string): Promise<void> {
  return isMockAuthEnabled() ? releaseMockDevice(deviceId) : releaseCloudDevice(deviceId);
}

/**
 * The device's recent samples, oldest first, ready to be charted. Resolves to
 * an empty array for a device that has never reported.
 */
export async function loadDeviceHistory(deviceId: string): Promise<DeviceReadings[]> {
  return isMockAuthEnabled() ? mockHistory(deviceId, HISTORY_LIMIT) : loadCloudHistory(deviceId);
}

// ---------------------------------------------------------------------------
//  Supabase
// ---------------------------------------------------------------------------

async function loadCloudDevices(): Promise<Device[]> {
  const { data, error } = await getSupabase()
    .from("devices")
    .select(
      "id, name, device_uid, last_seen, readings(soil, light, temperature, humidity, created_at)",
    )
    .order("created_at", { ascending: true })
    // One round trip for the whole list: every device arrives with its newest
    // reading attached instead of one readings query per device. The embedded
    // `order … limit 1` still leans on the `(device_id, created_at desc)` index.
    .order("created_at", { referencedTable: "readings", ascending: false })
    .limit(1, { referencedTable: "readings" });

  if (error) throw new Error("Não foi possível carregar seus dispositivos.");

  const rows = (data ?? []) as DeviceWithReadingsRow[];
  return rows.map((row) => toDevice(row, latestReading(row.readings)));
}

async function loadCloudHistory(deviceId: string): Promise<DeviceReadings[]> {
  const { data, error } = await getSupabase()
    .from("readings")
    .select("soil, light, temperature, humidity, created_at")
    .eq("device_id", deviceId)
    // Newest first is the order the index serves; the chart reads left to
    // right, so the page is flipped once it arrives.
    .order("created_at", { ascending: false })
    .limit(HISTORY_LIMIT);

  if (error) throw new Error("Não foi possível carregar o histórico.");

  return ((data ?? []) as ReadingRow[]).map(toReadings).reverse();
}

async function renameCloudDevice(deviceId: string, name: string): Promise<void> {
  // The row comes back so a write that matched nothing — a device released in
  // another tab, say — is reported instead of silently looking like success.
  const { data, error } = await getSupabase()
    .from("devices")
    .update({ name })
    .eq("id", deviceId)
    .select("id");

  if (error) throw new Error("Não foi possível renomear o dispositivo.");
  if (!data || data.length === 0) throw new Error("Este dispositivo não pertence mais à sua conta.");
}

async function releaseCloudDevice(deviceId: string): Promise<void> {
  // An RPC, not a table update: clearing `owner_id` from the app is impossible
  // under row level security, because the released row no longer satisfies the
  // SELECT policy the UPDATE has to re-check. `release_device()` runs as the
  // table owner and re-checks ownership itself. See the IoT project's schema.sql.
  const { data, error } = await getSupabase().rpc("release_device", { p_id: deviceId });

  if (error) throw new Error(describeReleaseError(error));
  if (typeof data !== "string") throw new Error("O dispositivo não foi liberado.");
}

/** Maps the Postgres errors `release_device()` raises onto copy the user can act on. */
function describeReleaseError(error: { code?: string; message?: string }): string {
  if (error.code === "22023") return "Este dispositivo não pertence mais à sua conta.";
  if (error.code === "28000") return "Entre na sua conta para remover um dispositivo.";
  return error.message || "Não foi possível remover o dispositivo.";
}

/** The embedded readings arrive newest first, so the first one is the latest. */
function latestReading(rows: ReadingRow[] | null): DeviceReadings | null {
  const row = rows?.[0];
  return row ? toReadings(row) : null;
}

async function claimCloudDevice(code: string): Promise<Device> {
  const { data: deviceId, error } = await getSupabase().rpc("claim_device", { p_code: code });
  if (error) throw new Error(describeClaimError(error));
  if (typeof deviceId !== "string") throw new Error("O dispositivo não informou um identificador.");

  const { data, error: fetchError } = await getSupabase()
    .from("devices")
    .select("id, name, device_uid, last_seen")
    .eq("id", deviceId)
    .maybeSingle();

  if (fetchError || !data) throw new Error("Dispositivo conectado, mas não foi possível carregá-lo.");
  return toDevice(data as DeviceRow, null);
}

/** Maps the Postgres errors `claim_device()` raises onto copy the user can act on. */
function describeClaimError(error: { code?: string; message?: string }): string {
  if (error.code === "22023") return "Código inválido ou já usado por outra conta.";
  if (error.code === "28000") return "Entre na sua conta para conectar um dispositivo.";
  return error.message || "Não foi possível conectar o dispositivo.";
}

// ---------------------------------------------------------------------------
//  Local stand-in (used while sign-in is mocked)
// ---------------------------------------------------------------------------

async function loadMockDevices(): Promise<Device[]> {
  const now = Date.now();
  return readMockDevices().map((device) => ({
    id: device.id,
    name: device.name,
    hardwareId: device.hardwareId,
    status: "online" as const,
    lastSeenAt: new Date(now).toISOString(),
    readings: mockReadings(device.hardwareId, now),
  }));
}

async function claimMockDevice(code: string): Promise<Device> {
  const claimed = readMockDevices();
  const already = claimed.find((device) => device.claimCode === code);
  const seed = MOCK_CLAIM_CODES[code];
  const hardwareId = already?.hardwareId ?? seed?.hardwareId;

  if (!hardwareId) throw new Error("Código inválido ou já usado por outra conta.");

  const name = already?.name ?? seed?.name ?? "Vaso conectado";
  if (!already) {
    writeMockDevices([...claimed, { id: `mock-${hardwareId}`, name, hardwareId, claimCode: code }]);
  }

  const now = Date.now();
  return {
    id: `mock-${hardwareId}`,
    name,
    hardwareId,
    status: "online",
    lastSeenAt: new Date(now).toISOString(),
    readings: mockReadings(hardwareId, now),
  };
}

async function renameMockDevice(deviceId: string, name: string): Promise<void> {
  const devices = readMockDevices();
  if (!devices.some((device) => device.id === deviceId)) {
    throw new Error("Este dispositivo não pertence mais à sua conta.");
  }

  writeMockDevices(
    devices.map((device) => (device.id === deviceId ? { ...device, name } : device)),
  );
}

async function releaseMockDevice(deviceId: string): Promise<void> {
  const devices = readMockDevices();
  if (!devices.some((device) => device.id === deviceId)) {
    throw new Error("Este dispositivo não pertence mais à sua conta.");
  }

  writeMockDevices(devices.filter((device) => device.id !== deviceId));
}

/** The same deterministic curve, replayed backwards one sample at a time. */
function mockHistory(deviceId: string, limit: number): DeviceReadings[] {
  const hardwareId =
    readMockDevices().find((device) => device.id === deviceId)?.hardwareId ?? "mock";
  const now = Date.now();

  const points: DeviceReadings[] = [];
  for (let index = limit - 1; index >= 0; index -= 1) {
    points.push(mockReadings(hardwareId, now - index * MOCK_SAMPLE_MS));
  }

  return points;
}

function readMockDevices(): MockDevice[] {
  try {
    const raw = window.localStorage.getItem(MOCK_STORAGE_KEY);
    if (!raw) return mockFallback;
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as MockDevice[]) : mockFallback;
  } catch {
    return mockFallback;
  }
}

function writeMockDevices(devices: MockDevice[]): void {
  mockFallback = devices;
  try {
    window.localStorage.setItem(MOCK_STORAGE_KEY, JSON.stringify(devices));
  } catch {
    // Storage can be unavailable; the in-memory list still drives the UI.
  }
}

/**
 * Plausible, slowly moving numbers so the stand-in behaves like a vase that is
 * actually reporting. Deterministic per device, so the card does not jump.
 */
function mockReadings(hardwareId: string, now: number): DeviceReadings {
  const phase = (hash(hardwareId) % 360) * (Math.PI / 180);
  const swing = (periodMs: number, offset: number) => Math.sin(now / periodMs + phase + offset);
  /** One of the two ADC channels: an index, 0-100. */
  const level = (base: number, span: number, periodMs: number, offset: number) =>
    clamp(Math.round(base + span * swing(periodMs, offset)));

  return {
    soil: level(42, 18, 900_000, 0),
    light: level(55, 35, 600_000, 3.1),
    temperature: Math.round((24 + 4 * swing(1_800_000, 0.6)) * 10) / 10,
    humidity: level(58, 12, 1_500_000, 2.4),
    capturedAt: new Date(now).toISOString(),
  };
}

function hash(value: string): number {
  let result = 0;
  for (let index = 0; index < value.length; index += 1) {
    result = (result * 31 + value.charCodeAt(index)) >>> 0;
  }
  return result;
}

function clamp(percent: number): number {
  return Math.min(100, Math.max(0, percent));
}

// ---------------------------------------------------------------------------
//  Shared helpers
// ---------------------------------------------------------------------------

function toDevice(row: DeviceRow, readings: DeviceReadings | null): Device {
  return {
    id: row.id,
    name: row.name?.trim() || "Vaso sem nome",
    hardwareId: row.device_uid,
    status: isOnline(row.last_seen) ? "online" : "offline",
    lastSeenAt: row.last_seen,
    readings,
  };
}

function toReadings(row: ReadingRow): DeviceReadings {
  return {
    soil: row.soil,
    light: row.light,
    temperature: row.temperature,
    humidity: row.humidity,
    capturedAt: row.created_at,
  };
}

function isOnline(lastSeenAt: string | null): boolean {
  if (!lastSeenAt) return false;
  const seen = new Date(lastSeenAt).getTime();
  return !Number.isNaN(seen) && Date.now() - seen < ONLINE_WINDOW_MS;
}

/** The secondary line under a device's name. */
export function describeDevice(device: Device): string {
  return `${device.hardwareId} · ${formatLastSeen(device.lastSeenAt)}`;
}

export function formatLastSeen(lastSeenAt: string | null): string {
  if (!lastSeenAt) return "Nunca conectado";

  const seen = new Date(lastSeenAt).getTime();
  if (Number.isNaN(seen)) return "Nunca conectado";

  const seconds = Math.max(0, Math.round((Date.now() - seen) / 1000));
  if (seconds < 60) return "Agora mesmo";

  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min atrás`;

  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h atrás`;

  const days = Math.round(hours / 24);
  if (days < 7) return `${days} d atrás`;

  return new Date(seen).toLocaleDateString("pt-BR");
}

export function formatPercent(value: number | null): string {
  return typeof value === "number" ? `${Math.round(value)}%` : "—";
}

/**
 * An ADC channel, shown as a position on the sensor's own 0-100 scale. The
 * firmware divides a raw 12-bit sample by 4095, so this is an index — calling it
 * a percentage would claim a calibration that has never been done.
 */
export function formatIndex(value: number | null): string {
  return typeof value === "number" ? `${Math.round(value)}/100` : "—";
}

/** The same index without the scale, for a chart tick. */
export function formatIndexTick(value: number | null): string {
  return typeof value === "number" ? String(Math.round(value)) : "—";
}

export function formatTemperature(value: number | null): string {
  return typeof value === "number" ? `${value.toFixed(1)} °C` : "—";
}
