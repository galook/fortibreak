#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DESTINATION="${1:-../../outputs/ClearGate.app}"
mkdir -p build "$DESTINATION/Contents/MacOS" "$DESTINATION/Contents/Resources"
TARGET=arm64-apple-macosx14.0
xcrun clang -target "$TARGET" -c Sources/PTY.c -o build/PTY.o
xcrun clang -target "$TARGET" -DCG_PRIVILEGED_RUNTIME -c Sources/PTY.c -o build/PTY-privileged.o
xcrun swiftc -target "$TARGET" -D PRIVILEGED_RUNTIME -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Helper.swift build/PTY-privileged.o -o "$DESTINATION/Contents/MacOS/ClearGateHelper" -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Broker.swift Sources/DaemonMain.swift -o "$DESTINATION/Contents/MacOS/ClearGateDaemon" -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/InstallerMain.swift -o "$DESTINATION/Contents/MacOS/ClearGateInstaller" -framework Security
xcrun swiftc -target "$TARGET" -parse-as-library Sources/Core.swift Sources/Privileged.swift Sources/Store.swift Sources/App.swift -o "$DESTINATION/Contents/MacOS/ClearGate" -framework SwiftUI -framework AppKit -framework Security
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
mkdir -p build/ClearGate.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon.png --out "build/ClearGate.iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" build/icon.png --out "build/ClearGate.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/ClearGate.iconset -o "$DESTINATION/Contents/Resources/ClearGate.icns"
python3 - "$DESTINATION" <<'PY'
import plistlib,sys,pathlib
p=pathlib.Path(sys.argv[1])/'Contents'/'Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='eu.local.cleargate',CFBundleName='ClearGate',CFBundleDisplayName='ClearGate',CFBundleExecutable='ClearGate',CFBundlePackageType='APPL',CFBundleShortVersionString='0.3.0',CFBundleVersion='5',CFBundleIconFile='ClearGate',LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True,NSHumanReadableCopyright='ClearGate local prototype. Independent of Fortinet.')))
PY
for executable in ClearGateHelper ClearGateDaemon ClearGateInstaller; do
  codesign --force --sign - --options runtime --timestamp=none --identifier "eu.local.cleargate.$executable" "$DESTINATION/Contents/MacOS/$executable"
done
python3 scripts/install_manifest.py "$DESTINATION"
codesign --force --sign - --options runtime --timestamp=none "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
python3 Tests/runtime_fixture.py "$DESTINATION"
printf 'Built and verified %s\n' "$DESTINATION"
