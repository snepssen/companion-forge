#!/usr/bin/env bash
# Keep the free-signed app opening: re-sign and reinstall it on each paired
# iPhone and iPad before its seven days run out, whenever the device can be
# reached (on the same Wi-Fi as this Mac, or by cable).
#
#   iOS/auto-refresh.sh                 # check now; renew what is due and reachable
#   iOS/auto-refresh.sh "iPhone 17"     # only these devices (part of a name or model, or a UDID)
#   iOS/auto-refresh.sh --status        # when each device's app expires, and stop
#   RENEW_DAYS=8 iOS/auto-refresh.sh    # treat everything as due (a test run)
#
# Meant to be run every half hour by launchd: iOS/auto-refresh-agent.sh install.
# Cheap when nothing is due (it reads a state file). When a device is due
# (under RENEW_DAYS, default 3, days left) and answers, it builds once
# (build-ios.sh), makes sure the signing is a fresh seven days, installs with
# install-devices.sh --no-build and records the new expiry. Wi-Fi needs the
# device to have been paired with this Mac by cable once, and to be unlocked
# now and then; a failure is retried at the next check and shown as a
# notification when the expiry is close.
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
BUNDLE_ID="com.snepssen.companion"
APP="$IOS/.build/Build/Products/Release-iphoneos/Companion.app"
STATE_DIR="$HOME/Library/Application Support/companion-forge"
STATE="$STATE_DIR/refresh-state.tsv"      # udid<TAB>expiry (epoch)<TAB>name
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
RENEW_DAYS="${RENEW_DAYS:-3}"
FRESH_HOURS="${FRESH_HOURS:-144}"   # a build with less signing left than this gets a fresh profile
mkdir -p "$STATE_DIR"; touch "$STATE"

STATUS=0 WANT=()
for arg in "$@"; do
  case "$arg" in
    --status) STATUS=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $arg (see --help)" >&2; exit 2 ;;
    *) WANT+=("$arg") ;;
  esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() {  # title, message
  /usr/bin/osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' \
    "$1" "$2" >/dev/null 2>&1 || true
}
# Notify at most once every 6 hours per key, so a half-hourly check doesn't nag.
notify_sparingly() {  # key, title, message
  local mark="$STATE_DIR/notified-$1"
  if [ ! -f "$mark" ] || [ $(( $(date +%s) - $(stat -f %m "$mark") )) -gt 21600 ]; then
    notify "$2" "$3"; touch "$mark"
  fi
}
within() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }  # seconds, command…
iso_to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0; }
when() { date -r "$1" '+%a %d %b %H:%M'; }
app_expiry() {
  local iso; iso="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
  [ -n "$iso" ] && iso_to_epoch "$iso" || echo 0
}
# Names of the reachable devices the built app's profile doesn't list.
missing_devices() {
  local listed d; listed="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ProvisionedDevices json -o - - 2>/dev/null || true)"
  for d in "${REACH[@]}"; do
    case "$listed" in *"\"${d%%$'\t'*}\""*) ;; *) printf '%s ' "${d#*$'\t'}" ;; esac
  done
}
missing_udid() {  # the first of them, by UDID
  local listed d; listed="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ProvisionedDevices json -o - - 2>/dev/null || true)"
  for d in "${REACH[@]}"; do
    case "$listed" in *"\"${d%%$'\t'*}\""*) ;; *) echo "${d%%$'\t'*}"; return ;; esac
  done
}
state_expiry() { awk -F'\t' -v u="$1" '$1 == u {print $2; f=1} END {if (!f) print 0}' "$STATE"; }
record() {  # udid, expiry, name
  { awk -F'\t' -v u="$1" '$1 != u' "$STATE"; printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } > "$STATE.new" && mv "$STATE.new" "$STATE"
}

# One run at a time (a build can outlast the half hour).
LOCK="$STATE_DIR/refresh.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( $(date +%s) - $(stat -f %m "$LOCK") )) -lt 7200 ]; then exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK"   # left behind by a run that died
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$LOCK"' EXIT

# Paired, physical iPhones and iPads: "udid<TAB>name" per line.
within 60 xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || {
  log "xcrun devicectl could not list devices"; exit 1;
}
DEVICES="$(/usr/bin/python3 -I - "$TMP/devices.json" ${WANT[@]+"${WANT[@]}"} <<'PY'
import json, sys
wanted = [w.lower() for w in sys.argv[2:]]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, props, conn = d["hardwareProperties"], d["deviceProperties"], d["connectionProperties"]
    if hw.get("reality") != "physical" or hw.get("deviceType") not in ("iPhone", "iPad"):
        continue
    if conn.get("pairingState") != "paired":
        continue
    udid, name = hw.get("udid", ""), props.get("name", "")
    keys = (udid.lower(), name.lower(), hw.get("marketingName", "").lower(), hw.get("deviceType", "").lower())
    if wanted and not any(w == keys[0] or any(w in k for k in keys[1:]) for w in wanted):
        continue
    print(f"{udid}\t{name}")
PY
)"
[ -n "$DEVICES" ] || { log "no paired iPhone or iPad${WANT[*]:+ matching ${WANT[*]}}"; exit 0; }

NOW="$(date +%s)" DUE=() SUMMARY=()
while IFS=$'\t' read -r udid name; do
  exp="$(state_expiry "$udid")"
  if [ "$exp" = 0 ]; then
    SUMMARY+=("$name: never installed by this script")
    DUE+=("$udid"$'\t'"$name")
  else
    SUMMARY+=("$name: $( [ "$exp" -gt "$NOW" ] && echo "opens until" || echo "EXPIRED") $(when "$exp")")
    if [ $(( exp - NOW )) -lt $(( RENEW_DAYS * 86400 )) ]; then DUE+=("$udid"$'\t'"$name"); fi
  fi
done <<< "$DEVICES"
if [ "$STATUS" = 1 ]; then printf '%s\n' "${SUMMARY[@]}"; exit 0; fi
if [ ${#DUE[@]} = 0 ]; then exit 0; fi   # the common case: say nothing

# Which of the due devices answer now? (devicectl opens a tunnel over cable or Wi-Fi.)
REACH=()
for d in "${DUE[@]}"; do
  udid="${d%%$'\t'*}" name="${d#*$'\t'}"
  if within 45 xcrun devicectl device info details --device "$udid" >/dev/null 2>&1; then
    REACH+=("$d")
  else
    exp="$(state_expiry "$udid")"
    if [ "$exp" != 0 ] && [ $(( exp - NOW )) -lt 86400 ]; then
      notify_sparingly "unreachable-$udid" "Companion needs re-signing" \
        "$name can't be reached, and the app stops opening $(when "$exp"). Bring it onto this Wi-Fi, unlocked, or plug it in."
    fi
  fi
done
log "due: $(printf '%s\n' "${DUE[@]}" | cut -f2 | paste -sd, -); reachable: $(printf '%s\n' ${REACH[@]+"${REACH[@]}"} | cut -f2 | paste -sd, -)"
[ ${#REACH[@]} -gt 0 ] || exit 0

# After a failed build, wait two hours before trying again.
if [ -f "$STATE_DIR/build-failed" ] && [ $(( NOW - $(stat -f %m "$STATE_DIR/build-failed") )) -lt 7200 ]; then
  log "the last build failed under two hours ago; waiting"; exit 0
fi
build() {  # [udid of a device to register]
  if REGISTER_DEVICE="${1:-}" "$IOS/build-ios.sh" --no-install > "$TMP/build.log" 2>&1; then rm -f "$STATE_DIR/build-failed"; return 0; fi
  touch "$STATE_DIR/build-failed"
  local why="see $TMP/build.log"
  if grep -q "No Accounts" "$TMP/build.log"; then why="Xcode is signed out of your Apple ID: Xcode → Settings → Accounts"
  fi
  tail -30 "$TMP/build.log"
  log "build failed: $why"
  notify_sparingly build "Companion re-signing failed" "The build failed: $why"
  return 1
}
log "building"
build || exit 1
EXP="$(app_expiry)"
# Xcode reuses a free profile until it runs out, so an early rebuild can carry
# the old expiry, or leave out a device registered after the profile was made
# (which then refuses the app: "its integrity could not be verified"). Then set
# this app's cached profiles aside and build again, so Xcode asks Apple for a
# fresh seven days covering every device.
MISSING="$(missing_devices)"
if [ $(( EXP - NOW )) -lt $(( FRESH_HOURS * 3600 )) ] || [ -n "$MISSING" ]; then
  if [ -n "$MISSING" ]; then log "the build's profile leaves out $MISSING; asking Xcode for a fresh profile"
  else log "the build's signing runs out $(when "$EXP"); asking Xcode for a fresh profile"; fi
  ASIDE="$STATE_DIR/old-profiles/$(date +%Y%m%d-%H%M%S)"
  for p in "$PROFILES"/*.mobileprovision "$PROFILES"/*.provisionprofile; do
    [ -f "$p" ] || continue
    appid="$(security cms -D -i "$p" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
    case "$appid" in *."$BUNDLE_ID") mkdir -p "$ASIDE"; mv "$p" "$ASIDE/" ;; esac
  done
  build "$(missing_udid)" || exit 1
  EXP="$(app_expiry)"
  log "signing now runs out $(when "$EXP")"
fi

FAILED=0
for d in "${REACH[@]}"; do
  udid="${d%%$'\t'*}" name="${d#*$'\t'}"
  if "$IOS/install-devices.sh" --no-build "$udid" > "$TMP/install.log" 2>&1; then
    record "$udid" "$EXP" "$name"
    log "installed on $name; opens until $(when "$EXP")"
    rm -f "$STATE_DIR/notified-install-$udid"
    notify "Companion re-signed" "$name: opens until $(when "$EXP")"
  else
    FAILED=1
    reason="$(grep -E '^  FAILED' "$TMP/install.log" | head -1 | sed 's/^  FAILED *//')"
    log "install on $name failed: ${reason:-$(tail -5 "$TMP/install.log")}"
    exp="$(state_expiry "$udid")"
    if [ "$exp" = 0 ] || [ $(( exp - NOW )) -lt 86400 ]; then
      notify_sparingly "install-$udid" "Companion re-signing failed" "$name: ${reason:-install failed}"
    fi
  fi
done
exit "$FAILED"
