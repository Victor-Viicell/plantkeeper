#!/usr/bin/env python3
"""Add a release signingConfig to Tauri's generated Android project.

`tauri android init` creates `src-tauri/gen/android/app/build.gradle.kts` without
a signing config, and the release APK would be unsigned. This script inserts the
config documented at https://v2.tauri.app/distribute/sign/android/ and wires the
release build type to it.

Run after `tauri android init`, with `keystore.properties` already in
`src-tauri/gen/android/`. It is idempotent: an already-patched file is left as is.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_BUILD_GRADLE = Path("src-tauri/gen/android/app/build.gradle.kts")

SIGNING_CONFIG = """    signingConfigs {
        create("release") {
            val keystorePropertiesFile = rootProject.file("keystore.properties")
            val keystoreProperties = Properties()
            if (keystorePropertiesFile.exists()) {
                keystoreProperties.load(keystorePropertiesFile.inputStream())
            }
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
"""

RELEASE_LINE = 'signingConfig = signingConfigs.getByName("release")'


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_BUILD_GRADLE

    if not path.exists():
        print(f"error: {path} does not exist; run `tauri android init` first", file=sys.stderr)
        return 1

    source = path.read_text(encoding="utf-8")

    if "signingConfigs" in source:
        print(f"{path} already has a signingConfigs block; nothing to do")
        return 0

    if "import java.util.Properties" not in source:
        source = "import java.util.Properties\n" + source

    if "    buildTypes {" not in source:
        print(f"error: could not find the buildTypes block in {path}", file=sys.stderr)
        return 1

    source = source.replace("    buildTypes {", SIGNING_CONFIG + "    buildTypes {", 1)

    source, replacements = re.subn(
        r'(getByName\("release"\)\s*\{)',
        rf"\1\n            {RELEASE_LINE}",
        source,
        count=1,
    )

    if replacements != 1:
        print(f"error: could not find the release build type in {path}", file=sys.stderr)
        return 1

    path.write_text(source, encoding="utf-8")
    print(f"patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
