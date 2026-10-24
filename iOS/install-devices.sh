#!/usr/bin/env bash
# Rebuild the iPhone and iPad app and install it on every connected iPhone
# and iPad, for your own use.
#
#   iOS/install-devices.sh                    # every paired iPhone and iPad
#   iOS/install-devices.sh "iPhone 17" iPad   # only these: part of a name or model, or a UDID
#   iOS/install-devices.sh --both             # interpreter-forge's app too, from beside this checkout
#   iOS/install-devices.sh --list             # what it would install on, and stop
#
# The build is build-ios.sh's (the polyglot voice, VAD, the bundle and
# signature checks), run once with --no-install; this installs that one app
# on each device and launches it. Signing is project.yml's: team BAZ45QTU23,
# automatic. With a free (personal) team the app stops opening seven days
# after it was built, so this is meant to be run again within the week; the
# date is printed below. Installing over the old app keeps its data and
# downloaded models.
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
APP_NAME="Companion"
BUNDLE_ID="com.snepssen.companion"
APP="$IOS/.build/Build/Products/Release-iphoneos/$APP_NAME.app"
WORKSHOP="${WORKSHOP_ROOT:-$(cd ../.. && pwd)}"
SIBLING="$WORKSHOP/interpreter-forge/apple/iOS/install-devices.sh"

BOTH=0 LIST=0 WANT=()
for arg in "$@"; do
  case "$arg" in
    --both) BOTH=1 ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $arg (see --help)" >&2; exit 2 ;;
    *) WANT+=("$arg") ;;
  esac
done

# Paired, physical iPhones and iPads, one "udid<TAB>name<TAB>model<TAB>developer mode" per line.
# "disconnected" in devicectl's JSON only means no tunnel is open yet; it opens one when asked.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || {
  echo "error: xcrun devicectl could not list devices (is Xcode installed and selected?)" >&2; exit 1;
}
DEVICES="$(/usr/bin/python3 -I - "$TMP/devices.json" ${WANT[@]+"${WANT[@]}"} <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = [w.lower() for w in sys.argv[2:]]
found = set()
for d in devices:
    hw, props, conn = d["hardwareProperties"], d["deviceProperties"], d["connectionProperties"]
    if hw.get("reality") != "physical" or hw.get("deviceType") not in ("iPhone", "iPad"):
        continue
    if conn.get("pairingState") != "paired":
        continue
    udid, name, model = hw.get("udid", ""), props.get("name", ""), hw.get("marketingName", hw.get("deviceType"))
    keys = (udid.lower(), name.lower(), model.lower(), hw.get("deviceType", "").lower())
    hits = [w for w in wanted if w == keys[0] or any(w in k for k in keys[1:])]
    if wanted and not hits:
        continue
    found.update(hits)
    print("\t".join((udid, name, model, props.get("developerModeStatus", "unknown"))))
for w in wanted:
    if w not in found:
        print("\t".join(("", w, "", "nomatch")))
PY
)"

NOMATCH="$(awk -F'\t' '$4 == "nomatch" {print $2}' <<< "$DEVICES")"
DEVICES="$(awk -F'\t' '$4 != "nomatch"' <<< "$DEVICES")"
[ -z "$NOMATCH" ] || echo "no paired iPhone or iPad matches: $(tr '\n' ' ' <<< "$NOMATCH")" >&2
if [ -z "$DEVICES" ]; then
  echo "no paired iPhone or iPad to install on. Connect it by cable once, unlock it, tap 'Trust This Computer'," >&2
  echo "and turn on Developer Mode (Settings → Privacy & Security); then see: xcrun devicectl list devices" >&2
  echo "To check the build alone: iOS/build-ios.sh --no-install" >&2
  exit 1
fi
echo "$APP_NAME will go on:"
awk -F'\t' '{printf "  %s (%s)%s\n", $2, $3, ($4 == "enabled" ? "" : "  developer mode: " $4)}' <<< "$DEVICES"
[ "$LIST" = 1 ] && { [ -z "$NOMATCH" ]; exit; }

echo "building $APP_NAME…"
if ! "$IOS/build-ios.sh" --no-install 2>&1 | tee "$TMP/build.log"; then
  BUILD_FAILED=1
  if grep -q "No Accounts" "$TMP/build.log"; then
    BUILD_WHY="Xcode is signed out of your Apple ID, so it can't renew the free signing:"
    BUILD_WHY="$BUILD_WHY Xcode → Settings → Accounts → +, sign in, then run this again"
  elif grep -qE "No profiles for|provisioning profile" "$TMP/build.log"; then
    BUILD_WHY="no signing profile for $BUNDLE_ID: in Xcode, open $APP_NAME.xcodeproj, pick a device and Run once"
  else
    BUILD_WHY="see the xcodebuild errors above"
  fi
else
  BUILD_FAILED=0
fi

RESULTS=() FAILED=0
if [ "$BUILD_FAILED" = 0 ]; then
  EXPIRES="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
  while IFS=$'\t' read -r udid name model devmode; do
    label="$name ($model)"
    echo "installing on $label…"
    if ! xcrun devicectl device install app --device "$udid" "$APP" </dev/null >"$TMP/install.log" 2>&1; then
      reason="$(grep -iE 'error|fail|unable|not ' "$TMP/install.log" | head -3 | tr '\n' ' ')"
      case "$reason" in
        *ocked*) reason="$reason— unlock it and run this again" ;;
        *rofile*|*rovision*) reason="$reason— a device new to the team: in Xcode, open $APP_NAME.xcodeproj, pick the device and Run once" ;;
        *aximum*|*limit*) reason="$reason— a free team allows three of your apps on a device; delete one you no longer use" ;;
      esac
      [ "$devmode" = "enabled" ] || reason="$reason (Developer Mode is $devmode)"
      RESULTS+=("FAILED     $label: ${reason:-see xcrun devicectl device install app --device $udid}")
      FAILED=1
      continue
    fi
    if xcrun devicectl device process launch --terminate-existing --device "$udid" "$BUNDLE_ID" </dev/null >"$TMP/launch.log" 2>&1; then
      RESULTS+=("installed  $label, and launched")
    else
      RESULTS+=("installed  $label, not launched (locked? open it from the home screen)")
    fi
  done <<< "$DEVICES"
fi

echo
echo "$APP_NAME:"
if [ "$BUILD_FAILED" = 1 ]; then
  echo "  FAILED     the build, so nothing was installed: $BUILD_WHY"
  FAILED=1
else
  for r in "${RESULTS[@]}"; do echo "  $r"; done
  [ -n "$EXPIRES" ] && echo "  this build's signing expires $EXPIRES; run this again before then"
fi
[ -z "$NOMATCH" ] || { echo "  FAILED     not found: $(tr '\n' ' ' <<< "$NOMATCH")"; FAILED=1; }

if [ "$BOTH" = 1 ]; then
  echo
  if [ -x "$SIBLING" ]; then
    "$SIBLING" ${WANT[@]+"${WANT[@]}"} || FAILED=1
  else
    echo "interpreter-forge: FAILED, no $SIBLING (set WORKSHOP_ROOT to the folder holding both checkouts)"
    FAILED=1
  fi
fi
exit "$FAILED"
