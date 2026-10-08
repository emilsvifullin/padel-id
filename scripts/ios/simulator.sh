#!/usr/bin/env bash
# Creates and boots a fresh simulator on the newest installed iOS runtime and
# applies the appearance and text size used for a test configuration.
#
#   scripts/ios/simulator.sh "iPhone 17 Pro" light large
#
# Prints the simulator UDID on stdout.
set -euo pipefail

device_name="$1"
appearance="${2:-light}"
content_size="${3:-large}"

runtime=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: tuple(int(p) for p in r["version"].split(".")))
print(runtimes[-1]["identifier"])
')

device_type=$(xcrun simctl list devicetypes --json | DEVICE="$device_name" python3 -c '
import json, os, sys
name = os.environ["DEVICE"]
for t in json.load(sys.stdin)["devicetypes"]:
    if t["name"] == name:
        print(t["identifier"])
        break
else:
    sys.exit(f"Unknown device type: {name}")
')

udid=$(xcrun simctl create "PadelID ${device_name}" "$device_type" "$runtime")
xcrun simctl boot "$udid" >&2
xcrun simctl bootstatus "$udid" -b >&2
xcrun simctl ui "$udid" appearance "$appearance" >&2
xcrun simctl ui "$udid" content_size "$content_size" >&2
xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >&2
echo "Simulator $udid: $device_name, $runtime, $appearance, $content_size" >&2
echo "$udid"
