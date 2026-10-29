// The software keyboard can cover the bottom of the screen instead of shrinking
// the page: on those WebViews a sheet pinned to the bottom, or a form at the end
// of a scroll, ends up buried under the keys. The viewport meta asks modern
// WebViews to resize the layout instead (see index.html); this module covers the
// ones that do not. It publishes the covered height as --keyboard-inset so CSS
// can lift the affected surfaces, and nudges the focused field back into view.

/** Shorter than this is browser chrome, not a keyboard. */
const MIN_KEYBOARD_HEIGHT = 80;

/** Air kept between the focused field and the keys. */
const FIELD_MARGIN = 16;

type ViewportMetrics = { height: number; offsetTop: number };

/** Height, in CSS px, that the on-screen keyboard covers. 0 when it is closed. */
export function keyboardInset(innerHeight: number, viewport: ViewportMetrics | null): number {
  if (!viewport) return 0;

  const covered = innerHeight - viewport.height - viewport.offsetTop;
  return covered >= MIN_KEYBOARD_HEIGHT ? Math.round(covered) : 0;
}

const NON_TEXT_INPUTS = new Set([
  "button",
  "checkbox",
  "color",
  "file",
  "hidden",
  "image",
  "radio",
  "range",
  "reset",
  "submit",
]);

function isTextField(target: EventTarget | null): target is HTMLElement {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  if (target.tagName === "TEXTAREA") return true;

  return target.tagName === "INPUT" && !NON_TEXT_INPUTS.has((target as HTMLInputElement).type);
}

/** The nearest ancestor that actually scrolls, or the document. */
function scrollParentOf(element: HTMLElement): Element | null {
  for (let parent = element.parentElement; parent; parent = parent.parentElement) {
    const { overflowY } = getComputedStyle(parent);

    if (
      (overflowY === "auto" || overflowY === "scroll" || overflowY === "overlay") &&
      parent.scrollHeight > parent.clientHeight
    ) {
      return parent;
    }
  }

  return document.scrollingElement;
}

/**
 * Wires the visual viewport to --keyboard-inset and keeps the focused field
 * above the keyboard. Idempotent enough to be called once at startup.
 */
export function installKeyboardInset(): void {
  if (typeof window === "undefined") return;

  const root = document.documentElement;
  let focused: HTMLElement | null = null;

  const reveal = () => {
    if (!focused || !focused.isConnected) return;

    const viewport = window.visualViewport;
    const top = viewport?.offsetTop ?? 0;
    const bottom = top + (viewport?.height ?? window.innerHeight);
    const box = focused.getBoundingClientRect();

    const behindKeys = box.bottom - (bottom - FIELD_MARGIN);
    const aboveScreen = top + FIELD_MARGIN - box.top;

    if (behindKeys <= 0 && aboveScreen <= 0) return;

    const scroller = scrollParentOf(focused);
    if (!scroller) return;

    scroller.scrollBy({
      top: behindKeys > 0 ? behindKeys : -aboveScreen,
      behavior: "auto",
    });
  };

  // Runs straight from the event rather than from an animation frame: the frame
  // is throttled while the page is hidden, and the variable has to be right the
  // moment the layout is measured.
  const sync = () => {
    const inset = keyboardInset(window.innerHeight, window.visualViewport ?? null);

    root.style.setProperty("--keyboard-inset", `${inset}px`);
    reveal();
  };

  const handleFocusIn = (event: FocusEvent) => {
    focused = isTextField(event.target) ? event.target : null;

    if (focused) {
      // The keyboard slides in over a couple of frames; measuring once is not enough.
      window.setTimeout(sync, 120);
      window.setTimeout(sync, 320);
    }

    sync();
  };

  const handleFocusOut = () => {
    // Focus can move between two fields of the same form; only clear it when the
    // new target really is not a text field.
    window.setTimeout(() => {
      if (!isTextField(document.activeElement)) focused = null;

      sync();
    }, 60);
  };

  window.visualViewport?.addEventListener("resize", sync);
  window.visualViewport?.addEventListener("scroll", sync);
  window.addEventListener("resize", sync);
  window.addEventListener("orientationchange", sync);
  document.addEventListener("focusin", handleFocusIn);
  document.addEventListener("focusout", handleFocusOut);

  sync();
}
