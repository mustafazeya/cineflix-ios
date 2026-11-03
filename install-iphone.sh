#!/usr/bin/env bash
# Builds CineFlix and installs it on connected iPhones.
#   ./install-iphone.sh                   -> every paired iPhone
#   ./install-iphone.sh <device-id> ...   -> only those
#   ./install-iphone.sh --no-launch ...   -> don't open the app afterwards (used by the daily job)
set -uo pipefail
cd "$(dirname "$0")"
launch=1
if [ "${1:-}" = "--no-launch" ]; then launch=0; shift; fi

[ -f Config/Secrets.xcconfig ] || echo "Note: Config/Secrets.xcconfig missing; the app will ask for a TMDB token."
xcodegen generate >/dev/null
bundle_id=$(awk -F= '/^[[:space:]]*CF_BUNDLE_ID[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); v=$2} END {print v}' Config/App.xcconfig Config/Signing.xcconfig 2>/dev/null)

if [ "$#" -gt 0 ]; then
  devices=("$@")
else
  devices=()
  while IFS=$'\t' read -r udid name pairing; do
    if [ "$pairing" = "paired" ]; then devices+=("$udid"); else echo "Skipping $name: not paired with this Mac (connect it and tap Trust)."; fi
  done < <(scripts/list-iphones.sh)
fi
if [ "${#devices[@]}" -eq 0 ]; then
  echo "No paired iPhone found. Connect one (USB or same Wi-Fi) and unlock it." >&2
  exit 1
fi

failed=0
for device in "${devices[@]}"; do
  echo "== $device"
  # Each device gets its own build so the signing profile includes it.
  # Xcode sometimes lists a reachable phone late ("Unable to find a destination"), so wait and retry a few times.
  built=0
  for attempt in 1 2 3 4; do
    out=$(xcodebuild -project CineFlix.xcodeproj -scheme CineFlix -configuration Release \
        -destination "id=$device" -derivedDataPath "build/device-$device" -allowProvisioningUpdates -quiet build 2>&1) && { built=1; break; }
    if grep -Eq "Unable to find a (destination|device)" <<<"$out" && [ "$attempt" -lt 4 ]; then
      echo "Xcode does not list $device yet; retrying in 20 s ($attempt/4)"; sleep 20
    else
      echo "$out" | tail -40; break
    fi
  done
  [ "$built" = 1 ] || { echo "Build failed for $device"; failed=1; continue; }
  app=$(find "build/device-$device/Build/Products/Release-iphoneos" -maxdepth 1 -name CineFlix.app | head -1)
  if ! xcrun devicectl device install app --device "$device" "$app" >/dev/null; then
    echo "Install failed for $device"; failed=1; continue
  fi
  if [ "$launch" = 1 ]; then
    xcrun devicectl device process launch --device "$device" "$bundle_id" >/dev/null 2>&1 \
      || echo "Installed. If it doesn't open: Settings > General > VPN & Device Management > trust your developer certificate."
  fi
  echo "Installed on $device"
done
exit $failed
