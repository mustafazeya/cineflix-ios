#!/usr/bin/env bash
# Daily background reinstall of CineFlix on every paired iPhone (keeps the 7-day free-team signature fresh).
# Run hourly by the LaunchAgent; each iPhone is reinstalled only when its own last success is older
# than 20 hours, so it catches up whenever the Mac is awake and that iPhone is reachable.
#   scripts/auto-install.sh          normal run
#   scripts/auto-install.sh --force  reinstall on all reachable iPhones now
set -uo pipefail
cd "$(dirname "$0")/.."

state_dir="$HOME/Library/Application Support/CineFlix"
lock="$state_dir/install.lock"
log="logs/auto-install.log"
mkdir -p "$state_dir" logs
if [ -f "$log" ] && [ "$(stat -f%z "$log")" -gt 1048576 ]; then tail -n 400 "$log" > "$log.tmp" && mv "$log.tmp" "$log"; fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { echo "[$(ts)] $*"; }
notify() { osascript -e "display notification \"$1\" with title \"CineFlix\"" >/dev/null 2>&1; }

force=0; [ "${1:-}" = "--force" ] && force=1

# Which phones are due (per-device stamp)?
due=()
names=()
while IFS=$'\t' read -r udid name pairing; do
  [ "$pairing" = "paired" ] || continue
  stamp="$state_dir/last-install-$udid"
  if [ "$force" = 0 ] && [ -f "$stamp" ] && [ $(( $(date +%s) - $(cat "$stamp") )) -lt 72000 ]; then continue; fi
  due+=("$udid"); names+=("$name")
done < <(scripts/list-iphones.sh)
[ "${#due[@]}" -eq 0 ] && exit 0

if ! mkdir "$lock" 2>/dev/null; then
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rmdir "$lock"; mkdir "$lock"; else exit 0; fi
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

for i in "${!due[@]}"; do
  udid="${due[$i]}"; name="${names[$i]}"
  # Skip phones that aren't reachable right now (asleep, away from Wi-Fi, cable unplugged).
  if ! xcrun devicectl device info details --device "$udid" >/dev/null 2>&1; then
    say "$name not reachable; will retry next hour"
    continue
  fi
  say "installing on $name ($udid)"
  if ./install-iphone.sh --no-launch "$udid" >> "$log" 2>&1; then
    date +%s > "$state_dir/last-install-$udid"
    say "installed OK on $name"
    notify "CineFlix reinstalled on $name"
  else
    say "install FAILED on $name (see above); will retry next hour"
    notify "CineFlix reinstall failed on $name. See cineflix-ios/logs/auto-install.log"
  fi
done
