/**
 * Bluetooth provisioning: the phone hands the vase its Wi-Fi credentials.
 *
 * The vase only advertises this service while it has no network, so finding one
 * means it is genuinely unconfigured. The credentials travel as one JSON blob;
 * a BLE write carries only MTU-3 bytes, so the blob is sent as byte-sized
 * chunks and reassembled on the board (see the IoT project's ble_provision.py).
 *
 * The UUIDs below must match `config.py` on the device.
 */
import {
  checkPermissions,
  connect,
  disconnect,
  getAdapterState,
  readString,
  send,
  startScan,
  stopScan,
  subscribeString,
} from "@mnlphlp/plugin-blec";

const SERVICE_UUID = "7a1e0001-6d3c-4f2b-9c8a-5e1d2f3a4b5c";
const CONFIG_UUID = "7a1e0002-6d3c-4f2b-9c8a-5e1d2f3a4b5c";
const STATUS_UUID = "7a1e0003-6d3c-4f2b-9c8a-5e1d2f3a4b5c";
const INFO_UUID = "7a1e0004-6d3c-4f2b-9c8a-5e1d2f3a4b5c";

/** Advertised names all start with this, which the scan filters on. */
const NAME_PREFIX = "Plantkeeper";

/**
 * Conservative chunk: the default BLE MTU of 23 leaves 20 bytes of payload, and
 * the board's stack does not negotiate a larger one.
 */
const CHUNK_BYTES = 20;

const SCAN_TIMEOUT_MS = 8_000;
const PROVISION_TIMEOUT_MS = 60_000;

export type ProvisioningDevice = {
  address: string;
  name: string;
  /** Signal strength, for showing the nearest vase first. */
  rssi: number;
};

export type ProvisioningStatus = {
  state: string;
  message?: string;
  ssid?: string;
  ip?: string;
};

/** What the vase reports about itself before it is given any credentials. */
export type DeviceInfo = {
  name: string;
  uid: string;
  claimCode: string;
};

export type WifiCredentials = {
  ssid: string;
  password: string;
};

/**
 * The plugin talks to the Tauri backend, which a plain browser does not have.
 * Feature-detect so the UI can explain itself instead of throwing IPC errors.
 */
export function isBluetoothAvailable(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Whether the machine actually has a usable Bluetooth adapter. */
async function isAdapterOn(): Promise<boolean> {
  if (!isBluetoothAvailable()) return false;
  return (await getAdapterState()) === "On";
}

/**
 * Looks for vases that are waiting to be configured. Resolves with whatever was
 * seen before the scan window closed.
 */
export async function scanForVases(): Promise<ProvisioningDevice[]> {
  if (!isBluetoothAvailable()) {
    throw new Error("A configuração por Bluetooth só funciona no aplicativo.");
  }

  if (!(await checkPermissions(true))) {
    throw new Error("Permissão de Bluetooth negada.");
  }

  if (!(await isAdapterOn())) {
    throw new Error("Ligue o Bluetooth do computador e tente de novo.");
  }

  const found = new Map<string, ProvisioningDevice>();

  try {
    await startScan((devices) => {
      for (const device of devices) {
        if (!looksLikeVase(device)) continue;
        found.set(device.address, {
          address: device.address,
          name: device.name || "Vaso sem nome",
          rssi: device.rssi,
        });
      }
    }, SCAN_TIMEOUT_MS);
  } finally {
    // The scan window may still be open when the caller moves on.
    await stopScan().catch(() => undefined);
  }

  return [...found.values()].sort((a, b) => b.rssi - a.rssi);
}

/**
 * Connects, sends the network, and waits for the vase to report that it joined.
 * Resolves with the device's identity once it is online, and disconnects either
 * way so the radio is free for the next attempt.
 */
export async function provisionDevice(
  address: string,
  credentials: WifiCredentials,
  onStatus?: (status: ProvisioningStatus) => void,
): Promise<DeviceInfo> {
  if (!isBluetoothAvailable()) {
    throw new Error("A configuração por Bluetooth só funciona no aplicativo.");
  }

  let settled: (status: ProvisioningStatus) => void = () => undefined;
  const terminal = new Promise<ProvisioningStatus>((resolve) => {
    settled = resolve;
  });

  try {
    await connect(address, null);

    const info = parseDeviceInfo(await readString(INFO_UUID, SERVICE_UUID));

    await subscribeString(STATUS_UUID, SERVICE_UUID, (data) => {
      const status = parseStatus(data);
      onStatus?.(status);
      if (status.state === "connected" || status.state === "failed" || status.state === "timeout") {
        settled(status);
      }
    });

    await writeCredentials(credentials);

    const result = await withTimeout(terminal, PROVISION_TIMEOUT_MS);
    if (result.state !== "connected") {
      throw new Error(result.message || "O dispositivo não conseguiu entrar na rede.");
    }

    return info;
  } finally {
    await disconnect().catch(() => undefined);
  }
}

// ---------------------------------------------------------------------------
//  Internals
// ---------------------------------------------------------------------------

function looksLikeVase(device: { name: string; services: string[] }): boolean {
  if (device.name?.startsWith(NAME_PREFIX)) return true;
  return device.services?.some((uuid) => uuid.toLowerCase() === SERVICE_UUID);
}

/**
 * Sends the blob as MTU-sized chunks. Bytes, not characters: a password with an
 * accented letter must not be split mid-codepoint.
 */
async function writeCredentials(credentials: WifiCredentials): Promise<void> {
  const payload = JSON.stringify({
    ssid: credentials.ssid,
    password: credentials.password,
  });
  const bytes = new TextEncoder().encode(payload);

  for (let offset = 0; offset < bytes.length; offset += CHUNK_BYTES) {
    const chunk = [...bytes.subarray(offset, offset + CHUNK_BYTES)];
    // With response: the board assembles the blob in order, and a dropped write
    // would otherwise leave it waiting forever.
    await send(CONFIG_UUID, chunk, "withResponse", SERVICE_UUID);
  }
}

function parseDeviceInfo(raw: string): DeviceInfo {
  try {
    const parsed = JSON.parse(raw) as Partial<DeviceInfo>;
    return {
      name: parsed.name ?? NAME_PREFIX,
      uid: parsed.uid ?? "",
      claimCode: parsed.claimCode ?? "",
    };
  } catch {
    return { name: NAME_PREFIX, uid: "", claimCode: "" };
  }
}

function parseStatus(raw: string): ProvisioningStatus {
  try {
    return JSON.parse(raw) as ProvisioningStatus;
  } catch {
    return { state: "unknown" };
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("O dispositivo demorou demais para responder.")), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (cause) => {
        clearTimeout(timer);
        reject(cause);
      },
    );
  });
}
