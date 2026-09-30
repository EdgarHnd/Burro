#!/usr/bin/env bash
# Build a real app bundle and launch it with a stable macOS identity.
set -euo pipefail
MODE="${1:-run}"
CONFIGURATION="${CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "CONFIGURATION must be debug or release" >&2; exit 2 ;; esac
APP_NAME="Burro"
BUNDLE_ID="local.burro.worktrees"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--build-only) ;;
  *) echo "usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
cd "$ROOT_DIR"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(cat BUILD_NUMBER)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid version metadata" >&2; exit 2; }
if [[ ! -f Resources/AppIcon.icns || script/generate_icon.swift -nt Resources/AppIcon.icns ]]; then
  swift script/generate_icon.swift Resources/AppIcon.iconset
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi
# Match only this bundle; avoid stopping unrelated applications with the same name.
for pid in $(pgrep -x "$APP_NAME" || true); do
  executable="$(ps -p "$pid" -o comm=)"
  if [[ "$executable" == "$APP_BINARY" ]]; then kill "$pid"; fi
done
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BUILD_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIconDark</string>
</dict></plist>
PLIST
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIconDark.icns"
  # Refresh the legacy resource too when updating an existing development bundle.
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
fi
RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/Burro_BurroCore.bundle"
# SwiftPM uses either a flat resource bundle or a macOS Contents/Resources layout.
if [[ ! -f "$RESOURCE_BUNDLE/remote_probe.py" && ! -f "$RESOURCE_BUNDLE/Contents/Resources/remote_probe.py" ]]; then
  echo "The required remote reader resource is missing: $RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_CONTENTS/Resources/"
cp -R "$(dirname "$BUILD_BINARY")/Burro_Burro.bundle" "$APP_CONTENTS/Resources/"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
verify_app() {
  for pid in $(pgrep -x "$APP_NAME" || true); do
    if [[ "$(ps -p "$pid" -o comm=)" == "$APP_BINARY" ]]; then return 0; fi
  done
  echo "The expected Burro executable was not found after launch" >&2
  return 1
}
case "$MODE" in
  --build-only) echo "$APP_BUNDLE" ;;
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 2; verify_app; echo "Burro is running: $APP_BUNDLE" ;;
esac
