#!/usr/bin/env bash
# Prints "<udid><TAB><name><TAB><paired|unpaired>" for every real iPhone this Mac knows about.
tmp=$(mktemp)
xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1
python3 - "$tmp" <<'PY'
import json, re, sys
for d in json.load(open(sys.argv[1]))['result']['devices']:
    hp, cp, dp = d.get('hardwareProperties', {}), d.get('connectionProperties', {}), d.get('deviceProperties', {})
    udid = hp.get('udid', '')
    if hp.get('platform') == 'iOS' and hp.get('deviceType') == 'iPhone' and re.fullmatch(r'[0-9A-F]{8}-[0-9A-F]{16}', udid):
        print(f"{udid}\t{dp.get('name', 'iPhone')}\t{cp.get('pairingState', 'unpaired')}")
PY
rm -f "$tmp"
