#!/usr/bin/env bash
# Run auto-refresh.sh every half hour (and at login) as a launchd agent, so
# the free-signed app is re-signed on your iPhone and iPad over Wi-Fi before
# it stops opening. Nothing runs while this Mac sleeps; launchd catches up on wake.
#
#   iOS/auto-refresh-agent.sh install     # start it (again, after moving this checkout)
#   iOS/auto-refresh-agent.sh uninstall   # stop it
#   iOS/auto-refresh-agent.sh status      # is it loaded, what is due, the log's end
#   iOS/auto-refresh-agent.sh run         # run a check now, through launchd
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
LABEL="com.snepssen.companion.refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/companion-forge-refresh.log"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  install)
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$IOS/auto-refresh.sh</string></array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "installed: checks every 30 minutes; log: $LOG"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled"
    ;;
  status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then echo "agent: loaded ($PLIST)"; else echo "agent: not loaded"; fi
    "$IOS/auto-refresh.sh" --status || true
    [ -f "$LOG" ] && { echo "--- $LOG"; tail -15 "$LOG"; }
    ;;
  run)
    launchctl kickstart "$DOMAIN/$LABEL" && echo "started; follow it with: tail -f \"$LOG\""
    ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
