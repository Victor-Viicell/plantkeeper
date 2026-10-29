# Plantkeeper

Companion app for a plant vase that reports soil moisture, light, air
temperature and air humidity. The vase itself is an ESP32 — the sibling
**IoT Project** folder — which publishes a reading every 15 seconds. This app is
how you give that vase a network, claim it as yours, name it, and watch its
readings.

The firmware still publishes two of the four readings as an index on each
module's own 0–100 scale. The app turns them into the units a person reads:
soil as a percentage estimate, and the LDR index as approximate illuminance in
lux (about 1 lx in the dark to 10 000 lx in direct sun, on a logarithmic curve).
The DHT22 reports real units (`24,3 °C`, `51%`). None of these are calibrated
measurements — the light figure is an estimate for the screen.

It is built with [Ripple](https://www.ripple-ts.com) (`.tsrx` components) inside
a Tauri shell. The shipping target is Android, where Bluetooth is how the vase
gets onto your Wi-Fi; a browser tab is the fast path for UI work. The interface
is in Portuguese (pt-BR).

## Quick start

```bash
bun install
bun run dev          # http://localhost:1420
```

Sign-in is **real**: the app talks to the Supabase project named in `.env`, and
the Google button starts the OAuth flow. For offline UI work, set
`USE_MOCK_AUTH` to `true` in `src/utils/auth.ts` — sign-in then accepts anything
and the device layer serves a local stand-in seeded with the claim code
`PLANT-4K7Q`.

Bluetooth provisioning needs the native shell. Google sign-in also works in the
browser tab, but the shipping path is Android:

```bash
bun run tauri android dev     # emulator or device
```

On the first run, generate the Android Studio project with
`bun run tauri android init`; it creates `src-tauri/gen/android`. Local release
builds also need the signing setup described in
[Android releases](#android-releases-github-actions).

`minSdk` is 26 (Android 8.0), not Tauri's default 24, because
`tauri-plugin-blec` requires it. It lives in `src-tauri/tauri.conf.json` as
`bundle.android.minSdkVersion`, so both the generated Gradle project and the
Rust NDK linker use it. If `src-tauri/gen/android` was generated before this
setting existed, delete it and re-run `bun run tauri android init`.

Read [Backend setup](#backend-setup) and [Authentication](#authentication) for
the dashboard steps behind the live flow — both have settings that are easy to
miss.

## Android releases (GitHub Actions)

`.github/workflows/android-release.yml` builds a **signed universal APK** and
attaches it to a GitHub release. It runs on:

- a pushed tag matching `v*` (for example `v0.1.0`);
- manual `workflow_dispatch`, optionally with a tag (defaults to `v<app version>`).

The runner initializes `src-tauri/gen/android` when it is not present, so the
generated Android project does not need to be committed. It then injects the
release signing config into the generated `app/build.gradle.kts` and builds with
`tauri android build --apk`. The APK is verified with `apksigner` before it is
attached to the release and uploaded as a workflow artifact.

Secrets (Settings → Secrets and variables → Actions → **New repository
secret**):

| Secret | Meaning |
| --- | --- |
| `ANDROID_KEY_BASE64` | single-line base64 of the `.jks` |
| `ANDROID_KEY_ALIAS` | key alias used with `keytool` |
| `ANDROID_KEY_PASSWORD` | key password |
| `ANDROID_KEYSTORE_PASSWORD` | store password (optional; falls back to `ANDROID_KEY_PASSWORD`) |
| `VITE_SUPABASE_URL` | Supabase project URL embedded in the bundle |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | publishable/anon key embedded in the bundle |

The two `VITE_` values are public by design — Vite inlines them into the app — but
they are still kept as secrets so a release cannot be built against the wrong
backend by accident. They are the same values as the local `.env`.

Create the keystore once and keep it somewhere safe — losing it means an
installed app can no longer be updated with the same signature:

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
base64 -w0 upload-keystore.jks > upload-keystore.b64
# macOS: base64 -i upload-keystore.jks | tr -d '\n' > upload-keystore.b64
```

If `keytool` is not on `PATH`, use the JDK bundled with Android Studio (for
example `/opt/android-studio/jbr/bin/keytool`).

Copy the **single-line** contents of `upload-keystore.b64` into
`ANDROID_KEY_BASE64`, the alias (`upload` above) into `ANDROID_KEY_ALIAS`, and
the passwords into `ANDROID_KEY_PASSWORD` / `ANDROID_KEYSTORE_PASSWORD`.

The Supabase values are the same as your local `.env`:

```bash
grep -E '^VITE_SUPABASE_(URL|PUBLISHABLE_KEY)=' .env
```

Use the **publishable/anon** key, never the service-role key. Use a tag that
matches the app version (`v` + the `version` in `src-tauri/tauri.conf.json`) so
the release and the APK version agree.

The workflow needs `contents: write` permission (already declared in the file),
and a `GITHUB_TOKEN` is used for the release; no personal token is required.

## Backend setup

The app and the firmware share **one** Supabase project —
`zubizzqwjteajycnwesf` — named in `.env` (app) and in the IoT project's
`config.py` (host) with its key in `credentials.py` (device). Both have to agree
or a claimed vase will never show readings.

1. **Apply the schema.** Paste the IoT project's
   `supabase/schema.sql` into Dashboard → SQL Editor → New query → Run. It
   creates `devices`, `readings`, the three RPCs, the RLS policies and the
   indexes. Re-running it is safe, with one exception: it drops the retired
   `rain` column, so the `rain` values already stored are lost. That column
   only ever held the rain module's raw analog output, and nothing reads it any
   more.

   Then seed the vase. The device secret is not committed, so copy
   `supabase/seed.example.sql` to `supabase/seed.local.sql`, fill in
   `device_secret` and run that too. It creates device `vase-01` with claim code
   `PLANT-4K7Q`, and re-running it is safe.

   Re-run it after pulling a change to that file. The app renames a vase with a
   direct `update` and releases one through the `release_device()` RPC; both need
   the grant and the policy that file declares. Without them, renaming fails with
   `permission denied` and `release_device()` does not exist at all.

   Dropping `rain` also changed `ingest_reading()`'s argument list, so **apply
   this together with the firmware**: the old 7-argument function is dropped and
   a 6-argument one takes its place, and a board still sending `p_rain` gets a
   `function not found` from PostgREST until it is re-flashed.
2. **Keep the secret in step.** `device_uid` and `claim_code` live in
   `config.py`; `DEVICE_SECRET` and `SUPABASE_KEY` live in the IoT project's
   `credentials.py`, created from `credentials.example.py` (both files are
   gitignored). The secret must match the one in `seed.local.sql`, or
   `ingest_reading` rejects every sample.
3. **Let the firmware in.** The device authenticates with the project's
   publishable key over PostgREST, so `anon` needs `EXECUTE` on
   `ingest_reading()` and on the no-table `ping()` health probe. Those two
   functions are the entire unauthenticated surface: `anon` has no table
   grants, so it cannot read or write `devices`/`readings` directly.

The schema is written to be exercised against a real Postgres rather than only
applied. With Supabase's `auth` schema and roles shimmed, the full file runs and
the ownership model can be checked end to end: that a second user cannot re-claim
a vase, cannot see or rename it, and cannot reassign its owner; that `anon` can
only reach `ingest_reading()` and `ping()`; and that releasing works solely
through `release_device()`. Worth running before applying a change to that file
— there is no committed harness for it yet.

## Authentication

The app boots through three screens: a splash, then the Google sign-in page
(`src/pages/Login.tsrx`) when there is no session, then the main app
(`src/pages/Home.tsrx`) once there is one.

**Sign-in is real.** `src/utils/auth.ts` still holds the `USE_MOCK_AUTH` flag,
but it is `false`: the Google button runs the PKCE flow and the device layer
reads and writes Supabase. Setting it to `true` switches the same four functions
(`getSession`, `onAuthStateChange`, `signInWithGoogle`, `signOut`) and the device
queries to a local stand-in, persisted under the `plantkeeper.mock-session`
localStorage key — useful for offline UI work, never for shipping. The device
layer follows the same flag, because with no Supabase session there is nothing
for RLS to key on.

The real flow is PKCE (`src/utils/supabase.ts`) and has two halves, picked by
`src/utils/auth.ts` when the button is pressed:

- **An ordinary browser tab** (`bun run dev`, opened in the browser). That is a
  normal origin, so the usual full-page redirect works and the callback lands
  back on the app. Useful for UI work; not the shipping path.
- **The Android app** (`isTauri()` is true). A webview cannot receive an
  `http(s)` redirect and Google refuses to render its consent screen inside one,
  so the app asks Supabase for the authorization URL with
  `skipBrowserRedirect`, opens it in the system browser (via
  `tauri-plugin-opener`), and the browser comes back through a **deep link**. The
  scheme is `com.viicell.plantkeeper` and the callback is
  `com.viicell.plantkeeper://login-callback`; both are `DEEP_LINK_SCHEME` /
  `REDIRECT_TO` in `src/utils/auth.ts`. The redirect carries a one-time `code`
  (never a token), which `exchangeCodeForSession` trades for the session. The
  whole wait is abandoned after 5 minutes.

The scheme is a custom URI scheme rather than a verified App Link: it needs no
`.well-known/assetlinks.json`, and PKCE means a hijacked code is useless without
the verifier. Switch to App Links if the app ever ships from a public store and
you want the link verified.

The scheme itself is declared once, in `src-tauri/tauri.conf.json` under
`plugins.deep-link.mobile`. The Tauri CLI reads it when building for Android and
generates the matching `<intent-filter>` in the app manifest (inside an
`<!-- DEEP LINK PLUGIN. AUTO-GENERATED. DO NOT REMOVE. -->` block) — there is no
manifest to edit by hand. `"deep-link:default"` in
`src-tauri/capabilities/default.json` is a separate thing: it is the permission
that lets the webview call the plugin's `get_current` command.

Android may restart the app while the browser holds the consent screen. The
deep link then arrives as a cold start rather than an event, so `App.tsrx` calls
`resumePendingSignIn()` on boot to finish the exchange — that is why boot awaits
one more thing besides `getSession()`.

Before switching sign-in back on:

1. **In the Supabase dashboard**, the Google provider is already enabled under
   Authentication → Providers (with its OAuth client ID and secret). Confirm
   that Authentication → URL Configuration → Redirect URLs lists:
   - `com.viicell.plantkeeper://login-callback` for the app
   - `http://localhost:1420` for a browser tab

   A redirect that is not on the list is replaced with the project's Site URL,
   which the app never sees — sign-in would simply time out.
2. **For the Android build**, have an Android SDK, NDK and JDK on the machine,
   add the Rust targets (`rustup target add aarch64-linux-android` plus the ones
   for your emulator, e.g. `x86_64-linux-android`), and generate the native
   project once:

   ```bash
   bun run tauri android init
   bun run tauri android dev      # emulator or device
   ```

   `android init` is what creates `src-tauri/gen/android`; the deep-link intent
   filter is injected into its manifest on each build.

`tauri dev` on the desktop no longer completes sign-in: desktop is not a target,
and without the single-instance plugin a Windows/Linux deep link would only
reach a fresh process. Use `bun run tauri android dev`, or a plain
`bun run dev` tab for UI work.

Copy `.env.example` to `.env` and fill in `VITE_SUPABASE_URL` and
`VITE_SUPABASE_PUBLISHABLE_KEY`.

## Connecting a device

A vase joins in two steps: it needs a network, and it needs to be tied to your
account. The **+** button on the home screen does both.

### 1. Wi-Fi over Bluetooth

A vase with no stored network advertises a small GATT service. Tap **Procurar
dispositivos**, pick the vase from the list, type your Wi-Fi name and password,
and send. The vase reports progress back as it connects, and the app shows it
(`Entrando na rede…` → `Wi-Fi configurado!`).

This is real BLE, so it only works in the installed Tauri app — a browser has no
Bluetooth: Web Bluetooth is not available in the Tauri webview, so the transport
is `tauri-plugin-blec` (btleplug) through `src-tauri`. In a browser the sheet
says so and offers the claim-code path instead.

`src/utils/provisioning.ts` owns the app side:

- `scanForVases()` — filters advertisements by name prefix and service UUID.
- `provisionDevice(address, credentials, onStatus)` — connects, reads the
  device's identity, sends the credentials, and waits for the reported outcome.

The wire contract lives in the IoT project's `config.py`; the UUIDs are repeated
in `provisioning.ts` and must stay in step:

| Characteristic | Direction | Carries |
| --- | --- | --- |
| `…0001` service | — | wrapper for the three below |
| `…0002` config | write | `{"ssid": …, "password": …}` |
| `…0003` status | read + notify | `{"state": …}` progress |
| `…0004` info | read | `{"name", "uid", "claimCode"}` |

A write carries only MTU−3 bytes, so the blob is sent as 20-byte chunks
(chunked over *bytes*, not characters, so an accented password cannot be split
mid-codepoint) and reassembled on the board. The device never exposes
`DEVICE_SECRET` over the air.

### 2. Claiming

The device's identity includes its claim code, so provisioning normally fills
the code in and claims automatically. You can also type it by hand — tap **+**,
enter e.g. `PLANT-4K7Q`, and the app calls the `claim_device` RPC before listing
the device with its newest readings from `public.readings`.

`src/utils/devices.ts` owns that half:

- `connectDevice(code)` — claims a device and returns it.
- `loadDevices()` — every device the account owns, each with its latest reading
  and an `online`/`offline` status derived from `last_seen` (a device that has
  not published for a minute counts as offline). The home screen re-reads the
  list every 15 s.
- `loadDeviceHistory(id)` — the newest `HISTORY_LIMIT` samples, oldest first,
  which is what the detail view charts.
- `renameDevice(id, name)` and `releaseDevice(id)` — the two writes the app
  makes directly to `devices` (see [The screens](#the-screens)).

Every operation also has a local stand-in (`claimMockDevice`, `mockHistory`, …),
used only when `USE_MOCK_AUTH` is flipped on for offline UI work.

With real sign-in the device layer talks to the project described by the IoT
project's `supabase/schema.sql`. Flipping `USE_MOCK_AUTH` to `true` switches
both sign-in and the device layer to a local stand-in seeded with `PLANT-4K7Q`
that keeps the shapes the backend returns — there is no Supabase session for RLS
to key on in that mode.

### Re-provisioning

The vase advertises only when it has nothing to go on: no credentials in flash
and none compiled into `config.py`. Once provisioned it joins the network on
boot and stays quiet over Bluetooth. Changing the Wi-Fi password does not need a
wipe — if the stored network fails at boot, the board reopens Bluetooth for 60 s.
Moving the vase to a different account does need a wipe, since the stored
credentials stay valid.

The LCD is the vase's pairing surface: it shows the claim code for a couple of
seconds on every boot, and keeps it on screen whenever there is no network —
never configured, freshly reset, or the stored network failed. The same code is
printed to the serial monitor, so a board without an LCD is still usable.

## The screens

**The list** is the home screen. Each card carries the four latest values, when
they were captured, and an `Online`/`Offline` pill. A device counts as online
while it keeps publishing, so a minute of silence is a dropped connection rather
than a slow battery. The header has a refresh button; the list also re-reads
itself every 15 s on its own.

A failed poll does **not** throw the list away. If a list is already on screen,
the failure becomes a banner above it saying the readings may be behind, and the
next successful poll clears it. Only an empty screen turns into a full error page
with a retry button.

**Tapping a card** opens that device's detail view:

- the latest values and how old they are;
- a chart of the last `HISTORY_LIMIT` samples (60 — about 15 minutes at one
  reading per 15 s), switchable between the four metrics. Soil and air humidity
  are drawn against a fixed 0–100 scale so two visits are comparable; light
  (lux) and temperature scale to their own range. The chart keeps following the
  vase while it is open;
- **rename** — the name is stored on `devices.name`;
- **remove** — releases the vase back to unclaimed. The rows are not deleted:
  the vase keeps its identity and its readings, and the same claim code works
  again (for you or for someone else). It asks for confirmation first, because
  the app cannot undo a release on someone else's behalf;
- **avisos e rotina** — the rules behind that vase's notifications: a plant
  preset, which readings should warn, and how often its routine repeats.

Renaming is a direct `update` on `devices`, scoped by the `devices_update_own`
policy, and it reads the row back — so an update that matched nothing (a vase
released in another tab, say) is reported instead of looking successful.

Releasing is **not** a table update, and cannot be: because `devices_select_own`
keys on `owner_id = auth.uid()`, an `UPDATE` that clears `owner_id` produces a row
the caller can no longer `SELECT`, and Postgres rejects the whole statement — no
`WITH CHECK` can grant what the SELECT policy forbids. It calls the
`release_device()` RPC instead, which runs as the table owner and re-checks
ownership itself. See `releaseCloudDevice()` in `src/utils/devices.ts`.

**The bell** in the header opens the notification centre. It lists what is wrong
or due right now, and everything in it is worked out on the client from readings
the app already has — nothing there talks to Supabase.

- **Warnings** come from the newest reading of a vase: soil below 35%, light
  below 200 lx, air above 32 °C, and so on. The limits are per vase, an empty
  field means "no limit on that side", and the values a new vase starts with are
  the usual ones for a potted plant — air humidity is recorded but stays quiet
  until asked to speak. A vase that stopped reporting raises no warnings: its
  newest reading is stale, and an alert about it would be about a pot nobody has
  touched since the vase went quiet.
- **Presets** for the plants people usually keep — succulent/cactus, fern,
  tropical foliage, low-light plants, orchid and herbs — fill the warning limits
  and the routine in one tap. They are deliberately generous starting points for
  someone who does not know the species, not horticultural truth; every field
  stays editable, and changing one switches the vase to "custom".
- **Routines** are a reminder every N days at a fixed time — "Regar a samambaia"
  every 3 days at 08:00 — one per vase, off until switched on. A routine stays
  due until it is marked done; marking it done ("Feito") starts the next
  interval.
- **Dispensar** hides a warning for an hour; **Feito** marks a routine as done
  and it returns after its interval. Both come back on their own, so neither can
  hide a problem for good. **Abrir** jumps to the vase a notification is about.

The rules and the dismissals are per device and kept in `localStorage`
(`plantkeeper.notification-settings.v2` and
`plantkeeper.notification-dismissals`), next to the device stand-in: they survive
a reload, need no backend, and behave the same with real sign-in and with the
offline stand-in. The settings key is versioned because light limits changed
from the sensor's 0–100 index to lux; older settings are ignored. They are **not**
synced to the account, so a fresh install starts from the defaults again — and
releasing a vase forgets its rules along with it.

### Notifications on the phone

The Tauri build mirrors the in-app centre to the operating system:

- on the first Home mount the app asks for notification permission and creates
the Android channel **Avisos das plantas**;
- warnings are delivered as soon as the app observes the reading — at most once
per warning per day, so the 15 s poll cannot turn into a stream of alerts;
- routines are scheduled on the phone for the next eight occurrences, so they
fire even when the app is closed. Marking one **Feito** moves its schedule to
the next interval;
- a warning cannot be scheduled ahead of time because the next reading is not
known yet. True background warnings would need push (FCM/APNs) and a server-side
check; the native notification here fires while the app is open or when it
resumes.

In a browser tab the OS integration is skipped, and the bell remains the only
place alerts appear. The dedupe map lives in
`plantkeeper.native-alerts.v1`.

A version marker (`plantkeeper.native-notifications.version`) clears schedules
and delivered toasts from an older build on the first launch after an update,
so an installed phone does not keep showing notifications written with previous
labels or units. Bump `NATIVE_VERSION` in `src/utils/nativeNotifications.ts`
whenever the notification copy or ids change.

## Recommended IDE Setup

- [VS Code](https://code.visualstudio.com/)
- [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode)
- [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)

`.tsrx` editing and type checking come from the `@tsrx/typescript-plugin` dev
dependency (wired up through `tsconfig.json`), not from a separate extension.
`bun run build` runs `tsrx-tsc --noEmit` first, so type errors fail the build.
