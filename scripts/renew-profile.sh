#!/usr/bin/env bash
# Free Apple accounts sign apps for 7 days. Xcode keeps reusing its cached signing profile until it has fully
# expired, so a reinstall just before that puts back a copy that dies the same day. This removes the cached profile
# for one bundle id when less than DAYS (default 4) are left, so the next build asks Apple for a fresh 7 days.
#   scripts/renew-profile.sh <bundle-id> [days]
# Prints "renewed" when it removed a profile.
set -uo pipefail
bundle_id="${1:?bundle id}"; days="${2:-4}"
renewed=0
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.mobileprovision "$dir"/*.provisionprofile; do
    [ -f "$f" ] || continue
    due=$(security cms -D -i "$f" 2>/dev/null | python3 -c '
import sys, plistlib, datetime
try:
    p = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
app = p.get("Entitlements", {}).get("application-identifier", "")
if app.split(".", 1)[-1] != sys.argv[1]:
    sys.exit(0)
left = p["ExpirationDate"] - datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
print("due" if left < datetime.timedelta(days=float(sys.argv[2])) else "ok")
' "$bundle_id" "$days")
    if [ "$due" = "due" ]; then rm -f "$f"; renewed=1; fi
  done
done
[ "$renewed" = 1 ] && echo renewed
exit 0
