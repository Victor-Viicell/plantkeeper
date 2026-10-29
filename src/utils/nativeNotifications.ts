/**
 * OS-level notifications for the phone (and, incidentally, the desktop window).
 *
 * The in-app bell is worked out from readings the app already has. This module
 * mirrors those alerts to the system notification centre and, on mobile, also
 * schedules the care routines ahead of time so they fire while the app is closed.
 *
 * Warnings cannot be scheduled natively: the next reading is unknown until the
 * vase uploads it. They are delivered as soon as the app observes them.
 */
import { isTauri } from "@tauri-apps/api/core";
import {
  Importance,
  Schedule,
  Visibility,
  cancelAll,
  createChannel,
  isPermissionGranted,
  removeActive,
  removeAllActive,
  requestPermission,
  sendNotification,
} from "@tauri-apps/plugin-notification";
import type { Device } from "./devices";
import {
  deviceSettings,
  isValidTime,
  ROUTINE_DAYS_MAX,
  type AppNotification,
  type NotificationState,
} from "./notifications";

const CHANNEL_ID = "plantkeeper-alerts";
const CHANNEL_NAME = "Avisos das plantas";
const SHOWN_KEY = "plantkeeper.native-alerts.v1";
const VERSION_KEY = "plantkeeper.native-notifications.version";

/**
 * Bump this whenever notification copy, ids or scheduling changes. On the first
 * launch after an update the old schedules are cancelled, the tray is cleared
 * and the dedupe map is dropped, so an installed build does not keep showing
 * notifications written by the previous format.
 */
const NATIVE_VERSION = 2;

/** The pre-lux settings key; no longer read, only removed on migration. */
const LEGACY_SETTINGS_KEY = "plantkeeper.notification-settings";

/** How long a delivered alert is remembered, so it is not repeated. */
const SHOWN_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** How many future occurrences each mobile routine is scheduled for. */
const SCHEDULE_AHEAD = 8;

type ShownMap = Record<string, number>;

let permission: Promise<boolean> | null = null;

/**
 * Serializes the native work. The effects can fire in quick succession while a
 * device list loads; without this, two calls could read the same dedupe map and
 * deliver the same alert twice, or cancel a schedule that is being rebuilt.
 */
let queue: Promise<void> = Promise.resolve();

function enqueue(task: () => Promise<void>): Promise<void> {
  // Notifications are best effort: a failed native call must not surface as an
  // unhandled rejection or stall the queue for the next alert.
  queue = queue.then(task, task).catch(() => undefined);
  return queue;
}

/** True on the phone webviews this app ships on, where schedules are supported. */
function isMobile(): boolean {
  return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
}

/**
 * Asks once per session, then reuses the answer. Denying is not fatal: the
 * in-app bell keeps working, there is just nothing outside the app.
 */
export function ensureNotificationPermission(): Promise<boolean> {
  if (!isTauri()) return Promise.resolve(false);

  if (!permission) {
    permission = (async () => {
      let granted = await isPermissionGranted();
      if (!granted) granted = (await requestPermission()) === "granted";
      if (granted) await ensureChannel();
      await migrateNativeFormat();
      return granted;
    })().catch(() => false);
  }

  return permission;
}

/**
 * One-time cleanup after an app update. Android keeps scheduled notifications
 * across launches, so without this the next updates could deliver titles and
 * units from the previous build even though the UI already shows the new ones.
 */
async function migrateNativeFormat(): Promise<void> {
  let stored: number | null = null;

  try {
    stored = Number(window.localStorage.getItem(VERSION_KEY));
  } catch {
    return;
  }

  if (stored === NATIVE_VERSION) return;

  await cancelAll().catch(() => {
    // Nothing scheduled, or the platform refused to clear it.
  });
  await removeAllActive().catch(() => {
    // The tray may be empty, or permission may have just been denied.
  });

  try {
    window.localStorage.removeItem(SHOWN_KEY);
    window.localStorage.removeItem(LEGACY_SETTINGS_KEY);
    window.localStorage.setItem(VERSION_KEY, String(NATIVE_VERSION));
  } catch {
    // Storage can be unavailable; the next launch will try again.
  }
}

/**
 * Runs the update cleanup without asking for permission. Called once at app
 * startup, before sign-in, so schedules left by an older build cannot fire with
 * old labels while the user is still on the login screen.
 */
export function clearStaleNativeNotifications(): Promise<void> {
  if (!isTauri()) return Promise.resolve();
  return enqueue(migrateNativeFormat);
}

/** Android groups notifications into channels; the other platforms ignore it. */
async function ensureChannel(): Promise<void> {
  if (!/Android/i.test(navigator.userAgent)) return;

  await createChannel({
    id: CHANNEL_ID,
    name: CHANNEL_NAME,
    description: "Solo, luz, temperatura e rotinas do Plantkeeper",
    importance: Importance.High,
    visibility: Visibility.Public,
    vibration: true,
  }).catch(() => {
    // An existing channel can refuse updates; notifications still deliver.
  });
}

function readShown(): ShownMap {
  try {
    const raw = window.localStorage.getItem(SHOWN_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    return typeof parsed === "object" && parsed !== null ? (parsed as ShownMap) : {};
  } catch {
    return {};
  }
}

function writeShown(map: ShownMap): void {
  try {
    window.localStorage.setItem(SHOWN_KEY, JSON.stringify(map));
  } catch {
    // The in-memory dedupe still holds for this session.
  }
}

function pruneShown(map: ShownMap, now: number): ShownMap {
  const next: ShownMap = {};

  for (const [key, stamp] of Object.entries(map)) {
    if (typeof stamp === "number" && now - stamp < SHOWN_TTL_MS) next[key] = stamp;
  }

  return next;
}

/** Local Y-M-D, so "once a day" changes at the user's midnight. */
function localDay(now: number): string {
  const date = new Date(now);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(
    date.getDate(),
  ).padStart(2, "0")}`;
}

/** A stable positive 32-bit id, which is what the notification APIs accept. */
function nativeId(seed: string): number {
  let hash = 2166136261;
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash & 0x7fffffff;
}

function routineNativeId(deviceId: string, due: Date): number {
  return nativeId(
    `routine:${deviceId}:${localDay(due.getTime())}:${due.getHours()}:${due.getMinutes()}`,
  );
}

/**
 * Sends every alert in `notifications` that has not already been delivered to
 * this device. A warning is delivered at most once a day; a routine is delivered
 * once per due occurrence. The same notification id is reused, so an alert that
 * the OS scheduled and one the foreground send observes replace each other
 * instead of stacking.
 */
export function sendNativeAlerts(
  notifications: AppNotification[],
  now: number = Date.now(),
): Promise<void> {
  return enqueue(() => deliverNativeAlerts(notifications, now));
}

async function deliverNativeAlerts(
  notifications: AppNotification[],
  now: number,
): Promise<void> {
  if (!(await ensureNotificationPermission())) return;

  const shown = pruneShown(readShown(), now);
  const day = localDay(now);
  let changed = false;

  for (const notification of notifications) {
    const isRoutine = notification.kind === "routine";
    const key = isRoutine ? `${notification.id}@${notification.at}` : `${notification.id}@${day}`;
    if (shown[key]) continue;

    const due = Date.parse(notification.at);
    const id =
      isRoutine && !Number.isNaN(due)
        ? routineNativeId(notification.deviceId, new Date(due))
        : nativeId(`warning:${notification.id}:${day}`);

    try {
      sendNotification({
        id,
        title: isRoutine ? notification.title : `${notification.deviceName}: ${notification.title}`,
        body: isRoutine
          ? `${notification.deviceName} · ${notification.detail}`
          : notification.detail,
        channelId: CHANNEL_ID,
        group: isRoutine ? "plantkeeper-routines" : "plantkeeper-warnings",
        autoCancel: true,
        extra: { notificationId: notification.id, deviceId: notification.deviceId },
      });

      shown[key] = now;
      changed = true;
    } catch {
      // Permission can be revoked while the app runs; the in-app centre remains.
    }
  }

  if (changed) writeShown(shown);
}

/**
 * Removes the OS copy when the user dismisses the alert inside the app, and
 * forgets its dedupe entry so a warning can notify again after the snooze.
 */
export function dismissNativeAlert(notification: AppNotification, now: number = Date.now()): void {
  if (!isTauri()) return;

  const isRoutine = notification.kind === "routine";
  const day = localDay(now);
  const due = Date.parse(notification.at);
  const id =
    isRoutine && !Number.isNaN(due)
      ? routineNativeId(notification.deviceId, new Date(due))
      : nativeId(`warning:${notification.id}:${day}`);
  const key = isRoutine ? `${notification.id}@${notification.at}` : `${notification.id}@${day}`;

  const shown = pruneShown(readShown(), now);
  if (shown[key]) {
    delete shown[key];
    writeShown(shown);
  }

  void removeActive([{ id }]).catch(() => {
    // The notification may already be gone; nothing else to do.
  });
}

/** The next occurrence of `time` strictly after `after`, in local time. */
function nextOccurrence(time: string, after: number): Date {
  const [hours, minutes] = time.split(":").map(Number);
  const due = new Date(after);
  due.setHours(hours, minutes, 0, 0);

  if (due.getTime() <= after) due.setDate(due.getDate() + 1);
  return due;
}

/**
 * Mirrors the enabled routines onto the phone's scheduler. `cancelAll` clears
 * the previous batch before the new one is written, because the notification
 * plugin has no way to query schedules by tag; this app is the only source of
 * scheduled notifications in the webview.
 *
 * The first occurrence starts at the next time of day. A routine marked done in
 * the app anchors the next run to that day plus its interval, so "Feito" also
 * moves the native schedule.
 */
export function syncRoutineSchedules(
  devices: Device[],
  state: NotificationState,
  now: number = Date.now(),
): Promise<void> {
  return enqueue(() => writeRoutineSchedules(devices, state, now));
}

async function writeRoutineSchedules(
  devices: Device[],
  state: NotificationState,
  now: number,
): Promise<void> {
  if (!isTauri() || !isMobile()) return;
  if (!(await ensureNotificationPermission())) return;

  await cancelAll().catch(() => {
    // Nothing scheduled yet, or the platform refused to clear it.
  });

  for (const device of devices) {
    const routine = deviceSettings(state, device.id).routine;
    if (!routine.enabled || !isValidTime(routine.time)) continue;

    const everyDays = Math.min(ROUTINE_DAYS_MAX, Math.max(1, routine.everyDays));
    const doneAt = state.dismissals[`routine:${device.id}`];
    const done = doneAt ? Date.parse(doneAt) : Number.NaN;

    // Schedule at least a minute ahead: iOS rejects immediate triggers.
    let first = nextOccurrence(routine.time, now + 60_000);

    if (!Number.isNaN(done)) {
      const anchored = new Date(done);
      const [hours, minutes] = routine.time.split(":").map(Number);
      anchored.setHours(hours, minutes, 0, 0);
      anchored.setDate(anchored.getDate() + everyDays);

      if (anchored.getTime() > now + 60_000) first = anchored;
    }

    const occurrence = new Date(first);

    for (let index = 0; index < SCHEDULE_AHEAD; index += 1) {
      try {
        sendNotification({
          id: routineNativeId(device.id, occurrence),
          title: routine.label,
          body: `${device.name} · ${
            everyDays === 1 ? "todos os dias" : `a cada ${everyDays} dias`
          }`,
          channelId: CHANNEL_ID,
          group: "plantkeeper-routines",
          schedule: Schedule.at(new Date(occurrence), false, true),
          autoCancel: true,
          extra: { notificationId: `routine:${device.id}`, deviceId: device.id },
        });
      } catch {
        // One rejected occurrence should not stop the remaining ones.
      }

      occurrence.setDate(occurrence.getDate() + everyDays);
    }
  }
}
