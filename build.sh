#!/usr/bin/env bash
# Build Companion.app.
#
# xcodebuild rather than `swift build`: MLX compiles Metal shaders, which only
# Xcode's build system does. The voice is the polyglot snepssen, English
# included; there is no separate English model to fetch. espeak-ng and its
# data come with the voice-core package; Silero VAD is fetched once into
# models/. The language model (3.5-5 GB) is not bundled: it is
# downloaded from the app's settings into ~/Library/Application Support/
# Companion/Models, or found in this checkout's models/ or interpreter-forge's.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/Companion.app"
CONF="${1:-Release}"
DERIVED="$ROOT/.build/xcode"
PRODUCTS="$DERIVED/Build/Products/$CONF"
# The polyglot snepssen: voice-polyglot's newest export beside this checkout,
# else its latest release (scripts/polyglot-voice.sh).
VOICE="$("$ROOT/scripts/polyglot-voice.sh")"
"$ROOT/scripts/fetch-models.sh"
"$ROOT/scripts/build-dictionary.sh"

echo "checks…"
swift run -q cccheck

echo "building ($CONF)…"
for scheme in Companion ccrun; do
  rm -f "$PRODUCTS/$scheme"
  xcodebuild -scheme "$scheme" -configuration "$CONF" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation -quiet build
  [ -s "$PRODUCTS/$scheme" ] && [ -x "$PRODUCTS/$scheme" ] || {
    echo "error: build produced no $scheme executable; refusing to package" >&2; exit 1;
  }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Companion" "$APP/Contents/MacOS/Companion"

# SwiftPM resource bundles (MLX's Metal library among them) belong in
# Contents/Resources, where Bundle.module looks.
bundles=0
while IFS= read -r b; do
  cp -R "$b" "$APP/Contents/Resources/"
  bundles=$((bundles + 1))
done < <(find "$PRODUCTS" -maxdepth 1 -name '*.bundle')
[ -n "$(find "$APP/Contents/Resources" -name default.metallib)" ] || { echo "error: MLX's Metal library is missing" >&2; exit 1; }
[ -s "$APP/Contents/Resources/VoiceCore_VoiceCore.bundle/Contents/Resources/espeak-ng-data/phontab" ] \
  || { echo "error: voice-core's espeak-ng data is missing from the app" >&2; exit 1; }

cp "$VOICE" "$APP/Contents/Resources/snepssen-polyglot.onnx"
cp "$VOICE.json" "$APP/Contents/Resources/snepssen-polyglot.onnx.json"
echo "voice: $VOICE"
cp "$ROOT/models/silero_vad.onnx" "$APP/Contents/Resources/"
cp "$ROOT/models/dictionary.sqlite" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"  # ccrun --icon, then iconutil

# The bundle ID is com.snepssen.companion, shared with the iOS app
# (iOS/project.yml) and the Keychain service (Vault.swift: the memory key
# is already stored there, with no access group). Preferences and saved
# state written under the previous Mac ID, local.companion-core.companion,
# are moved on first launch (BundleMigration).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Companion</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.snepssen.companion</string>
  <key>CFBundleName</key><string>Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Companion listens so you can talk with it. Everything it hears stays on this Mac.</string>
  <key>NSCameraUsageDescription</key>
  <string>Companion watches for who is talking so it can turn to them. Nothing it sees is kept or leaves this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "built: $APP  ($CONF, $bundles resource bundles, $(du -sh "$APP" | cut -f1))"
