import { mount } from "ripple";
import { App } from "./App.tsrx";
import { clearStaleNativeNotifications } from "./utils/nativeNotifications";

// Drop schedules and toasts written by an older app version before anything
// else can render them again. No-op outside the Tauri shell.
void clearStaleNativeNotifications();

const root = document.getElementById("root");

if (root) {
  mount(App, { target: root });
}
