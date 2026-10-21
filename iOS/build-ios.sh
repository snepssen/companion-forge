#!/usr/bin/env bash
# Build the iPhone and iPad app and install it on a connected device.
#
#   iOS/build-ios.sh                # build, install on the first connected iPhone or iPad
#   iOS/build-ios.sh --device iPad  # on the first connected iPad (or a name, like "iPhone 17")
#   iOS/build-ios.sh --no-install
#
# The voice is the polyglot snepssen (scripts/polyglot-voice.sh); espeak-ng and its data come
# with the voice-core package; the VAD model from models/. The language model
# and the memory's embedder are not bundled: the app fetches them (2.3 to 5 GB,
# best on Wi-Fi). MLX needs a real GPU, so there is no Simulator build.
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
REPO="$(cd .. && pwd)"
VOICE="$("$REPO/scripts/polyglot-voice.sh")"

"$REPO/scripts/fetch-models.sh"
mkdir -p Resources
rm -f Resources/en_US-snepssen-medium.onnx Resources/en_US-snepssen-medium.onnx.json
cp "$VOICE" Resources/snepssen-polyglot.onnx
cp "$VOICE.json" Resources/snepssen-polyglot.onnx.json
cp "$REPO/models/silero_vad.onnx" Resources/
echo "voice: $VOICE"

xcodegen generate --quiet
# Remove only the generated app, keeping dependency and build caches: a
# no-op build must never leave an old bundle to install.
APP="$IOS/.build/Build/Products/Release-iphoneos/Companion.app"
rm -rf "$APP"
xcodebuild -project Companion.xcodeproj -scheme CompanionPhone -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$IOS/.build" \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation -quiet build
[ -d "$APP" ] || { echo "build produced no app; refusing to install" >&2; exit 1; }
[ -s "$APP/VoiceCore_VoiceCore.bundle/espeak-ng-data/phontab" ] \
  || { echo "error: voice-core's espeak-ng data is missing from the app" >&2; exit 1; }
[ -n "$(find "$APP" -name default.metallib)" ] || { echo "error: MLX's Metal library is missing" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "built: $APP ($(du -sh "$APP" | cut -f1))"

[ "${1:-}" = "--no-install" ] && exit 0
WANT="iPhone|iPad"
[ "${1:-}" = "--device" ] && WANT="${2:?a device, like iPad or \"iPhone 17\"}"
LINE="$(xcrun devicectl list devices 2>/dev/null | grep -E "$WANT" | grep -E "available|connected" | head -1 || true)"
DEVICE="$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i}' <<< "$LINE" | head -1)"
[ -n "$DEVICE" ] || {
  echo "no $WANT connected and available. A new device needs unlocking, 'Trust This Computer', and" >&2
  echo "Developer Mode on (Settings → Privacy & Security → Developer Mode); see: xcrun devicectl list devices" >&2
  exit 1
}
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.snepssen.companion >/dev/null \
  && echo "launched on $(awk '{print $1, $2}' <<< "$LINE" | sed 's/  *$//')"
