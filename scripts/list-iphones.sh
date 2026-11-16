#!/usr/bin/env bash
# Prints "<udid><TAB><name><TAB><paired|unpaired>" for every real iPhone this Mac knows about.
# If ~/Library/Application Support/CineFlix/devices.txt exists, only the UDIDs listed there are shown (one per line,
# "#" starts a comment), so a borrowed or visiting phone never gets the app by accident.
tmp=$(mktemp)
xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1
python3 - "$tmp" <<'PY'
import json, os, re, sys
allow = None
allow_file = os.path.expanduser('~/Library/Application Support/CineFlix/devices.txt')
if os.path.exists(allow_file):
    allow = {l.split('#')[0].strip() for l in open(allow_file) if l.split('#')[0].strip()}
for d in json.load(open(sys.argv[1]))['result']['devices']:
    hp, cp, dp = d.get('hardwareProperties', {}), d.get('connectionProperties', {}), d.get('deviceProperties', {})
    udid = hp.get('udid', '')
    if allow is not None and udid not in allow:
        continue
    if hp.get('platform') == 'iOS' and hp.get('deviceType') == 'iPhone' and re.fullmatch(r'[0-9A-F]{8}-[0-9A-F]{16}', udid):
        print(f"{udid}\t{dp.get('name', 'iPhone')}\t{cp.get('pairingState', 'unpaired')}")
PY
rm -f "$tmp"
