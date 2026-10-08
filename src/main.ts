import { mount } from "ripple";
import { App } from "./App.tsrx";

const root = document.getElementById("root");

if (root) {
  mount(App, { target: root });
}
