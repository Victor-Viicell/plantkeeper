#!/usr/bin/env python3
"""Make the Android shell resize for the software keyboard.

`tauri android init` generates an edge-to-edge activity (`enableEdgeToEdge()`),
and on an edge-to-edge window Android stops shrinking the window when the
keyboard opens: the WebView keeps its full height and anything anchored to the
bottom of the page — the add-device sheet, a form at the end of a scroll — ends
up behind the keys.

This script patches the generated project so the taller of the keyboard and the
system navigation bar is applied as padding on the content frame — which shrinks
the WebView and with it the CSS viewport, so sheets and fields lift clear. It
also declares `adjustResize` on the activity for the devices and API levels where
the system still resizes the window (there the IME inset is zero, so nothing is
padded twice), and paints the window in the app's own backdrop colour so the
padding strip is invisible.

Run after `tauri android init`. It is idempotent: an already-patched project is
left as is.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_MANIFEST = Path("src-tauri/gen/android/app/src/main/AndroidManifest.xml")
DEFAULT_ACTIVITY = Path("src-tauri/gen/android/app/src/main/java")

MARKER = "patch-android-keyboard"

ACTIVITY_TEMPLATE = """package {package}

import android.os.Bundle
import android.view.View
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

// Generated stub, then patched by .github/scripts/{marker}.py.
class MainActivity : TauriActivity() {{
  override fun onCreate(savedInstanceState: Bundle?) {{
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)

    // Edge-to-edge means the system no longer shrinks the window for the
    // software keyboard, and the WebView does not report the navigation bar as a
    // safe area either: the page keeps full height and both the keys and the
    // three-button bar end up drawn over the bottom of the layout. Padding the
    // content frame by whichever is taller shrinks the WebView — and with it the
    // CSS viewport — so sheets and fields lift clear of both.
    val content = findViewById<View>(android.R.id.content)
    val baseBottom = content.paddingBottom

    ViewCompat.setOnApplyWindowInsetsListener(content) {{ view, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
      val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
      view.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, baseBottom + maxOf(bars, keyboard))
      insets
    }}
  }}
}}
"""

THEME_BACKGROUNDS = {
    "values": "#FFE9EEE9",
    "values-night": "#FF1B1F1B",
}


def patch_theme(res_dir: Path, night: str, color: str) -> int:
    """Give the window the app's own backdrop, so the inset padding is invisible."""
    path = res_dir / night / "themes.xml"
    item = f'        <item name="android:windowBackground">{color}</item>\n'

    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)

        # Reuse the light style's full opening tag: a style redefined in
        # values-night replaces the light one rather than merging with it, so a
        # night copy without the parent would drop the Material theme on the app.
        tag = theme_style_tag(res_dir)
        if tag is None:
            print(f"error: could not find the app theme to patch {path}", file=sys.stderr)
            return 1

        path.write_text(
            '<resources xmlns:tools="http://schemas.android.com/tools">\n'
            f"    {tag}\n{item}    </style>\n"
            "</resources>\n",
            encoding="utf-8",
        )
        print(f"created {path}")
        return 0

    source = path.read_text(encoding="utf-8")

    if "android:windowBackground" in source:
        print(f"{path} already sets a window background")
        return 0

    patched, count = re.subn(r"(<style[^>]*>\n)", r"\1" + item, source, count=1)
    if count != 1:
        print(f"error: could not find a style block in {path}", file=sys.stderr)
        return 1

    path.write_text(patched, encoding="utf-8")
    print(f"patched {path}")
    return 0


def theme_style_tag(res_dir: Path) -> str | None:
    path = res_dir / "values" / "themes.xml"
    if not path.exists():
        return None

    match = re.search(r"<style\b[^>]*>", path.read_text(encoding="utf-8"))

    return match.group(0) if match else None


def patch_manifest(path: Path) -> int:
    source = path.read_text(encoding="utf-8")

    if "android:windowSoftInputMode" in source:
        patched, count = re.subn(
            r'android:windowSoftInputMode="[^"]*"',
            'android:windowSoftInputMode="adjustResize"',
            source,
            count=1,
        )
        if count and patched != source:
            path.write_text(patched, encoding="utf-8")
            print(f"set adjustResize in {path}")
        else:
            print(f"{path} already declares adjustResize")
        return 0

    patched, count = re.subn(
        r'\n(\s*)android:name="\.MainActivity"',
        '\n\\1android:windowSoftInputMode="adjustResize"\\n\\1android:name=".MainActivity"',
        source,
        count=1,
    )

    if count != 1:
        print(f"error: could not find the MainActivity element in {path}", file=sys.stderr)
        return 1

    path.write_text(patched, encoding="utf-8")
    print(f"added adjustResize to {path}")
    return 0


def find_activity(root: Path) -> Path | None:
    if not root.is_dir():
        return None

    matches = sorted(root.rglob("MainActivity.kt"))

    return matches[0] if matches else None


def patch_activity(path: Path) -> int:
    source = path.read_text(encoding="utf-8")

    if MARKER in source:
        print(f"{path} already patched; nothing to do")
        return 0

    package = re.search(r"^package\s+([\w.]+)", source, re.MULTILINE)
    if not package:
        print(f"error: no package declaration in {path}", file=sys.stderr)
        return 1

    path.write_text(
        ACTIVITY_TEMPLATE.format(package=package.group(1), marker=MARKER),
        encoding="utf-8",
    )
    print(f"patched {path}")
    return 0


def main() -> int:
    args = sys.argv[1:]

    manifest = Path(args[0]) if args else DEFAULT_MANIFEST
    activity_root = Path(args[1]) if len(args) > 1 else DEFAULT_ACTIVITY

    if not manifest.exists():
        print(f"error: {manifest} does not exist; run `tauri android init` first", file=sys.stderr)
        return 1

    activity = find_activity(activity_root)
    if activity is None:
        print(f"error: no MainActivity.kt under {activity_root}", file=sys.stderr)
        return 1

    results = [patch_manifest(manifest), patch_activity(activity)]

    res_dir = manifest.parent / "res"
    results += [patch_theme(res_dir, night, color) for night, color in THEME_BACKGROUNDS.items()]

    return max(results)


if __name__ == "__main__":
    raise SystemExit(main())
