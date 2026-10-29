import { effect, track } from "ripple";
import {
  isBluetoothAvailable,
  provisionDevice,
  scanForVases,
  type ProvisioningDevice,
  type ProvisioningStatus,
} from "../utils/provisioning";

/** Progress copy for the states the vase reports over Bluetooth. */
const STATUS_TEXT: Record<string, string> = {
  advertising: "Aguardando o app…",
  idle: "Conectado ao vaso.",
  received: "Credenciais recebidas…",
  connecting: "Entrando na rede…",
  connected: "Wi-Fi configurado!",
  failed: "Não entrou na rede.",
  timeout: "Tempo esgotado.",
};

function describeError(cause: unknown, fallback: string): string {
  return cause instanceof Error && cause.message ? cause.message : fallback;
}

function describeStatus(status: ProvisioningStatus): string {
  return status.message ?? STATUS_TEXT[status.state] ?? "Configurando…";
}

export function AddDeviceFab({
  onConnect,
}: {
  onConnect: (claimCode: string) => Promise<string | null>;
}) @{
  const open = track(false);

  // Claiming: what the user types, or what the vase reports over Bluetooth.
  const claimCode = track("");
  const busy = track(false);
  const error = track<string | null>(null);

  // Bluetooth provisioning.
  const scanning = track(false);
  const found = track<ProvisioningDevice[]>([]);
  const selected = track<ProvisioningDevice | null>(null);
  const wifiSsid = track("");
  const wifiPassword = track("");
  const provisioning = track(false);
  const progress = track<string | null>(null);
  const bluetoothError = track<string | null>(null);

  effect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && open.value) {
        open.value = false;
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  });

  function resetBluetooth() {
    found.value = [];
    selected.value = null;
    wifiSsid.value = "";
    wifiPassword.value = "";
    scanning.value = false;
    provisioning.value = false;
    progress.value = null;
    bluetoothError.value = null;
  }

  function close() {
    open.value = false;
    error.value = null;
    claimCode.value = "";
    resetBluetooth();
  }

  /** Binds the device to the account; closes the sheet once it works. */
  function runClaim(code: string): Promise<void> {
    busy.value = true;
    error.value = null;

    return onConnect(code).then((message) => {
      busy.value = false;

      if (message) {
        error.value = message;
        return;
      }

      close();
    });
  }

  function submitClaim(event: SubmitEvent) {
    event.preventDefault();

    const code = claimCode.value.trim();
    if (!code || busy.value) return;

    void runClaim(code);
  }

  function findVases() {
    found.value = [];
    selected.value = null;
    progress.value = null;
    bluetoothError.value = null;
    scanning.value = true;

    scanForVases()
      .then((devices) => {
        found.value = devices;
        if (devices.length === 0) {
          bluetoothError.value = "Nenhum vaso encontrado. Aproxime e tente de novo.";
        }
      })
      .catch((cause) => {
        bluetoothError.value = describeError(cause, "Não foi possível procurar dispositivos.");
      })
      .finally(() => {
        scanning.value = false;
      });
  }

  function choose(device: ProvisioningDevice) {
    selected.value = device;
    bluetoothError.value = null;
    progress.value = null;
  }

  function sendWifi(event: SubmitEvent) {
    event.preventDefault();

    const target = selected.value;
    const ssid = wifiSsid.value.trim();
    if (!target || !ssid || provisioning.value) return;

    provisioning.value = true;
    bluetoothError.value = null;
    progress.value = "Enviando as credenciais…";

    provisionDevice(target.address, { ssid, password: wifiPassword.value }, (status) => {
      progress.value = describeStatus(status);
    })
      .then((info) => {
        provisioning.value = false;
        progress.value = STATUS_TEXT.connected;

        // The vase told us which code it carries, so claiming needs no typing.
        if (!info.claimCode) return Promise.resolve();

        claimCode.value = info.claimCode;
        return runClaim(info.claimCode);
      })
      .catch((cause) => {
        provisioning.value = false;
        progress.value = null;
        bluetoothError.value = describeError(cause, "Não foi possível configurar o dispositivo.");
      });
  }

  <>
    <style>
      /* Covers the viewport but lets every click through, so the FAB can sit
         over the page without blocking it. */
      .fab-layer {
        position: fixed;
        inset: 0;
        z-index: 20;
        display: flex;
        justify-content: center;
        pointer-events: none;
      }

      /* Matches the page column, so the FAB hugs the column edge instead of the
         window edge on a wide screen. */
      .fab-anchor {
        position: relative;
        width: 100%;
        max-width: var(--app-max-width);
      }

      .fab {
        position: absolute;
        right: max(1.25rem, env(safe-area-inset-right));
        bottom: calc(1.25rem + env(safe-area-inset-bottom));
        width: 3.5rem;
        height: 3.5rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: 0;
        border: none;
        border-radius: 50%;
        background: var(--app-accent);
        color: #ffffff;
        box-shadow: 0 10px 24px rgba(31, 111, 63, 0.36);
        cursor: pointer;
        pointer-events: auto;
        touch-action: manipulation;
        transition: transform 0.2s ease, box-shadow 0.2s ease, opacity 0.2s ease;
      }

      .fab:active {
        transform: scale(0.94);
      }

      .fab:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 3px;
      }

      @media (hover: hover) {
        .fab:hover {
          transform: scale(1.05);
          box-shadow: 0 14px 30px rgba(31, 111, 63, 0.42);
        }
      }

      .fab-icon {
        width: 1.5rem;
        height: 1.5rem;
      }

      .sheet-layer {
        position: fixed;
        inset: 0;
        z-index: 30;
        display: flex;
        align-items: flex-end;
        justify-content: center;
        background: rgba(12, 20, 14, 0.45);
        animation: plantkeeper-fade-in 0.18s ease-out;
      }

      .sheet {
        width: 100%;
        max-width: var(--app-max-width);
        /* Leaves a strip of backdrop on every screen, so tapping outside can
           always dismiss the sheet even when the content is tall. */
        max-height: calc(100% - 2.5rem);
        overflow-y: auto;
        overscroll-behavior: contain;
        display: flex;
        flex-direction: column;
        gap: 1rem;
        padding: 1.25rem max(1.25rem, env(safe-area-inset-right))
          calc(1.25rem + env(safe-area-inset-bottom)) max(1.25rem, env(safe-area-inset-left));
        border-radius: 1.5rem 1.5rem 0 0;
        background: var(--app-card);
        box-shadow: 0 -10px 40px rgba(0, 0, 0, 0.28);
        animation: plantkeeper-sheet-up 0.22s ease-out;
      }

      .sheet-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
      }

      .sheet-title {
        margin: 0;
        font-size: 1.125rem;
      }

      .sheet-close {
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

      .sheet-close:active {
        background: var(--app-surface);
      }

      .sheet-close:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .sheet-close:hover {
          background: var(--app-surface);
        }
      }

      .sheet-lead {
        margin: 0;
        font-size: 0.9375rem;
        line-height: 1.45;
        color: var(--app-text-muted);
      }

      .add-form {
        display: flex;
        flex-direction: column;
        gap: 0.5rem;
      }

      .add-label {
        font-size: 0.8125rem;
        font-weight: 600;
        letter-spacing: 0.01em;
      }

      /* 1rem text keeps mobile browsers from zooming on focus, and the height
         keeps the field a comfortable thumb target. */
      .add-input {
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

      .add-input::placeholder {
        color: var(--app-text-muted);
      }

      .add-input:focus {
        outline: none;
        border-color: var(--app-accent);
        box-shadow: 0 0 0 3px rgba(52, 168, 83, 0.18);
      }

      /* Claim codes are short and read aloud, so shout them back. */
      .add-code {
        font-weight: 600;
        letter-spacing: 0.14em;
        text-transform: uppercase;
      }

      .add-error {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.4;
        color: var(--app-callout);
      }

      .add-submit {
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

      .add-submit:active:not(:disabled) {
        opacity: 0.8;
      }

      .add-submit:disabled {
        cursor: not-allowed;
        opacity: 0.45;
      }

      .add-submit:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 3px;
      }

      @media (hover: hover) {
        .add-submit:hover:not(:disabled) {
          opacity: 0.9;
        }
      }

      /* Bluetooth block, above the manual claim form. */
      .ble {
        display: flex;
        flex-direction: column;
        gap: 0.5rem;
      }

      .ble-title {
        margin: 0;
        font-size: 0.9375rem;
      }

      .ble-note {
        margin: 0;
        font-size: 0.8125rem;
        line-height: 1.45;
        color: var(--app-text-muted);
      }

      .ble-list {
        list-style: none;
        display: flex;
        flex-direction: column;
        gap: 0.375rem;
        margin: 0;
        padding: 0;
      }

      /* Whole row is the target: picking a vase is the only thing this list
         does, so there is no separate button to aim at. */
      .ble-device {
        width: 100%;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.75rem;
        min-height: 3rem;
        padding: 0.625rem 1rem;
        border: 1px solid var(--app-control-border);
        border-radius: 0.875rem;
        background: var(--app-surface);
        color: inherit;
        font-family: inherit;
        font-size: 0.9375rem;
        text-align: left;
        cursor: pointer;
        touch-action: manipulation;
        transition: border-color 0.2s ease;
      }

      .ble-device:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      @media (hover: hover) {
        .ble-device:hover {
          border-color: var(--app-accent);
        }
      }

      .ble-device-name {
        overflow: hidden;
        font-weight: 600;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .ble-device-meta {
        flex: none;
        font-size: 0.75rem;
        color: var(--app-text-muted);
      }

      .ble-actions {
        display: flex;
        align-items: center;
        gap: 0.75rem;
      }

      .ble-actions .add-submit {
        flex: 1;
      }

      .ble-link {
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

      .ble-link:disabled {
        cursor: not-allowed;
        opacity: 0.5;
      }

      .ble-link:focus-visible {
        outline: 2px solid var(--app-accent);
        outline-offset: 2px;
      }

      .ble-progress {
        margin: 0;
        font-size: 0.8125rem;
        font-weight: 600;
        color: var(--app-accent);
      }

      .ble-divider {
        height: 1px;
        margin: 0.25rem 0;
        border: none;
        background: var(--app-border);
      }

      @keyframes plantkeeper-fade-in {
        from {
          opacity: 0;
        }
        to {
          opacity: 1;
        }
      }

      @keyframes plantkeeper-sheet-up {
        from {
          transform: translateY(100%);
        }
        to {
          transform: translateY(0);
        }
      }

      @media (prefers-reduced-motion: reduce) {
        .sheet-layer,
        .sheet {
          animation: none;
        }
      }

      /* Phones held sideways have very little height to spare. */
      @media (orientation: landscape) and (max-height: 32rem) {
        .sheet {
          gap: 0.75rem;
          padding-block: 1rem;
        }

        .ble-device {
          padding-block: 0.5rem;
        }
      }
    </style>

    <div class="fab-layer">
      <div class="fab-anchor">
        <button
          class="fab"
          type="button"
          aria-label="Conectar um vaso"
          aria-haspopup="dialog"
          aria-expanded={open.value}
          onClick={() => {
            open.value = true;
          }}
        >
          <svg class="fab-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M12 5v14M5 12h14"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
            />
          </svg>
        </button>
      </div>
    </div>

    @if (open.value) {
      <div class="sheet-layer" onClick={close}>
        <section
          class="sheet"
          role="dialog"
          aria-modal="true"
          aria-labelledby="add-device-title"
          onClick={(event) => event.stopPropagation()}
        >
          <div class="sheet-header">
            <h2 class="sheet-title" id="add-device-title">Conectar vaso</h2>
            <button class="sheet-close" type="button" aria-label="Fechar" onClick={close}>
              <svg class="fab-icon" viewBox="0 0 24 24" aria-hidden="true">
                <path
                  d="M6 6l12 12M18 6L6 18"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                />
              </svg>
            </button>
          </div>

          <p class="sheet-lead">
            Ligue o vaso e envie o Wi-Fi do celular por Bluetooth. Depois, confirme o
            código que ele mostra.
          </p>

          <section class="ble">
            <h3 class="ble-title">Wi-Fi do vaso</h3>

            @if (!isBluetoothAvailable()) {
              <p class="ble-note">
                A configuração por Bluetooth funciona no app instalado. No navegador,
                use o código do vaso abaixo.
              </p>
            } @else if (!selected.value) {
              <>
                <p class="ble-note">
                  Aproxime o vaso e procure.
                </p>

                <button
                  class="add-submit"
                  type="button"
                  disabled={scanning.value}
                  onClick={findVases}
                >
                  {scanning.value ? "Procurando…" : "Procurar"}
                </button>

                @if (found.value.length > 0) {
                  <ul class="ble-list">
                    @for (const device of found.value; key device.address) {
                      <li>
                        <button
                          class="ble-device"
                          type="button"
                          onClick={() => choose(device)}
                        >
                          <span class="ble-device-name">{device.name}</span>
                          <span class="ble-device-meta">{device.rssi} dBm</span>
                        </button>
                      </li>
                    }
                  </ul>
                }
              </>
            } @else {
              <>
                <p class="ble-note">
                  Enviando a rede para <strong>{selected.value.name}</strong>.
                </p>

                <form class="add-form" onSubmit={sendWifi}>
                  <label class="add-label" for="ble-ssid">Rede</label>
                  <input
                    class="add-input"
                    id="ble-ssid"
                    type="text"
                    placeholder="Wi-Fi de casa"
                    autoComplete="off"
                    autoCapitalize="none"
                    spellcheck={false}
                    maxLength={32}
                    value={wifiSsid.value}
                    onInput={(event) => {
                      wifiSsid.value = event.currentTarget.value;
                    }}
                  />

                  <label class="add-label" for="ble-password">Senha</label>
                  <input
                    class="add-input"
                    id="ble-password"
                    type="password"
                    placeholder="Senha da rede"
                    autoComplete="off"
                    autoCapitalize="none"
                    spellcheck={false}
                    maxLength={63}
                    value={wifiPassword.value}
                    onInput={(event) => {
                      wifiPassword.value = event.currentTarget.value;
                    }}
                  />

                  <div class="ble-actions">
                    <button
                      class="add-submit"
                      type="submit"
                      disabled={provisioning.value || !wifiSsid.value.trim()}
                    >
                      {provisioning.value ? "Enviando…" : "Enviar"}
                    </button>
                    <button
                      class="ble-link"
                      type="button"
                      disabled={provisioning.value}
                      onClick={resetBluetooth}
                    >
                      Trocar
                    </button>
                  </div>
                </form>

                @if (progress.value) {
                  <p class="ble-progress" role="status">{progress.value}</p>
                }
              </>
            }

            @if (bluetoothError.value) {
              <p class="add-error" role="alert">{bluetoothError.value}</p>
            }
          </section>

          <hr class="ble-divider" />

          <form class="add-form" onSubmit={submitClaim}>
            <label class="add-label" for="device-claim-code">Código do vaso</label>
            <input
              class="add-input add-code"
              id="device-claim-code"
              type="text"
              placeholder="PLANT-4K7Q"
              autoComplete="off"
              autoCapitalize="characters"
              spellcheck={false}
              maxLength={32}
              value={claimCode.value}
              onInput={(event) => {
                claimCode.value = event.currentTarget.value;
              }}
            />

            @if (error.value) {
              <p class="add-error" role="alert">{error.value}</p>
            }

            <button
              class="add-submit"
              type="submit"
              disabled={busy.value || !claimCode.value.trim()}
            >
              {busy.value ? "Conectando…" : "Conectar"}
            </button>
          </form>
        </section>
      </div>
    }
  </>
}
