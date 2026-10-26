#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DESTINATION="${1:-build/FortiBreak.app}"
mkdir -p build "$DESTINATION/Contents/MacOS" "$DESTINATION/Contents/Resources"
TARGET=arm64-apple-macosx14.0
VERSION="${FORTIBREAK_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${FORTIBREAK_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
xcrun clang -target "$TARGET" -c Sources/PTY.c -o build/PTY.o
xcrun clang -target "$TARGET" -DFB_PRIVILEGED_RUNTIME -c Sources/PTY.c -o build/PTY-privileged.o
xcrun swiftc -target "$TARGET" -D PRIVILEGED_RUNTIME -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Helper.swift build/PTY-privileged.o -o "$DESTINATION/Contents/MacOS/FortiBreakHelper" -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Broker.swift Sources/DaemonMain.swift -o "$DESTINATION/Contents/MacOS/FortiBreakDaemon" -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/InstallerMain.swift -o "$DESTINATION/Contents/MacOS/FortiBreakInstaller" -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Store.swift Sources/App.swift -o "$DESTINATION/Contents/MacOS/FortiBreak" -framework SwiftUI -framework AppKit -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Tests/CoreTests.swift -o build/CoreTests
build/CoreTests
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Store.swift Tests/DiagnosticsTests.swift -o build/DiagnosticsTests -framework AppKit -framework Security
build/DiagnosticsTests
xcrun clang -target "$TARGET" Tests/PTYTests.c build/PTY.o -o build/PTYTests
build/PTYTests
python3 Tests/helper_fixture.py
python3 Tests/saml_fixture.py
python3 Tests/broker_fixture.py
xcrun swiftc Sources/Icon.swift -o build/Icon -framework AppKit
build/Icon build/icon.png
mkdir -p build/FortiBreak.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon.png --out "build/FortiBreak.iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" build/icon.png --out "build/FortiBreak.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/FortiBreak.iconset -o "$DESTINATION/Contents/Resources/FortiBreak.icns"
python3 scripts/bundle_runtime.py "$DESTINATION"
# The bundled Homebrew engine runs only on the macOS it was bottled for, or newer.
ENGINE_MIN_OS="$(xcrun vtool -show-build "$DESTINATION/Contents/Helpers/openfortivpn" | awk '/minos/{print $2; exit}')"
python3 - "$DESTINATION" "$VERSION" "$BUILD_NUMBER" "${ENGINE_MIN_OS:-14.0}" <<'PY'
import plistlib,sys,pathlib
p=pathlib.Path(sys.argv[1])/'Contents'/'Info.plist'
minimum=max('14.0',sys.argv[4],key=lambda v:tuple(int(x) for x in v.split('.')))
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='eu.local.fortibreak',CFBundleName='FortiBreak',CFBundleDisplayName='FortiBreak',CFBundleExecutable='FortiBreak',CFBundlePackageType='APPL',CFBundleShortVersionString=sys.argv[2],CFBundleVersion=sys.argv[3],CFBundleIconFile='FortiBreak',LSMinimumSystemVersion=minimum,NSHighResolutionCapable=True,NSHumanReadableCopyright='FortiBreak. Independent of Fortinet.')))
PY
for executable in FortiBreakHelper FortiBreakDaemon FortiBreakInstaller; do
  codesign --force --sign - --options runtime --timestamp=none --identifier "eu.local.fortibreak.$executable" "$DESTINATION/Contents/MacOS/$executable"
done
for runtime in openfortivpn libssl.4.dylib libcrypto.4.dylib; do
  codesign --force --sign - --timestamp=none "$DESTINATION/Contents/Helpers/$runtime"
done
python3 scripts/install_manifest.py "$DESTINATION"
codesign --force --sign - --options runtime --timestamp=none "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
python3 Tests/runtime_fixture.py "$DESTINATION"
printf 'Built and verified %s %s (%s)\n' "$DESTINATION" "$VERSION" "$BUILD_NUMBER"
