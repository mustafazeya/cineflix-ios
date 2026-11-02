#!/usr/bin/env bash
# Installs (or removes) a LaunchAgent that runs scripts/auto-install.sh every hour, so a free-team build
# is reinstalled before its 7-day signature expires.
#   scripts/install-launchagent.sh            install and start
#   scripts/install-launchagent.sh --print    show the plist, change nothing
#   scripts/install-launchagent.sh --remove   stop and delete it
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
label="io.github.cineflix.auto-install"
plist="$HOME/Library/LaunchAgents/$label.plist"

render() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$root/scripts/auto-install.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$root/logs/auto-install.log</string>
  <key>StandardErrorPath</key><string>$root/logs/auto-install.log</string>
</dict>
</plist>
EOF
}

case "${1:-}" in
  --print) render ;;
  --remove)
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "Removed $label" ;;
  "")
    mkdir -p logs "$HOME/Library/LaunchAgents"
    render > "$plist"
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "Installed $label. It runs hourly and reinstalls each paired iPhone when its last install is over 20 hours old." ;;
  *) echo "Usage: $0 [--print|--remove]" >&2; exit 1 ;;
esac
