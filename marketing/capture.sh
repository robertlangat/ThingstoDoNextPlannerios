#!/bin/bash
# Captures App Store screenshots from the iOS / watchOS simulators (run on macOS after a simulator build).
# Sizes produced: iPhone 6.9" 1320x2868, iPad 13" 2064x2752, Apple Watch Series 10 46mm 416x496.
set -euo pipefail

APP="build/sim/Build/Products/Debug-iphonesimulator/ThingsToDoNext.app"
WATCHAPP="build/sim/Build/Products/Debug-watchsimulator/ThingsToDoNextWatch.app"
BUNDLE="com.robertlangat.thingstodonext"
OUT="${1:-store/raw}"
SCENES="today focus calendar planner editor mine"

runtime() { # latest available runtime for a platform (iOS / watchOS)
  xcrun simctl list runtimes -j | python3 -c "
import json, sys
r = [x for x in json.load(sys.stdin)['runtimes'] if x['platform'] == '$1' and x['isAvailable']]
print(r[-1]['identifier'])"
}

devicetype() { # first device type whose name contains each of the given words, in preference order
  xcrun simctl list devicetypes -j | python3 -c "
import json, sys
types = json.load(sys.stdin)['devicetypes']
for want in sys.argv[1:]:
    for t in types:
        if want in t['name']:
            print(t['identifier']); sys.exit(0)
sys.exit('no device type for ' + ', '.join(sys.argv[1:]))" "$@"
}

boot() { # name type runtime -> udid
  local udid
  udid=$(xcrun simctl create "$1" "$2" "$3")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  echo "$udid"
}

capture_ios() { # folder, device-type names...
  local folder="$1"; shift
  local type udid
  type=$(devicetype "$@")
  udid=$(boot "shots-$folder" "$type" "$(runtime iOS)")
  mkdir -p "$OUT/$folder"
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$udid" "$APP"
  # Warm-up launch (first launch is slow)
  xcrun simctl launch "$udid" "$BUNDLE" -ScreenshotScene today >/dev/null; sleep 12
  for scene in $SCENES; do
    xcrun simctl terminate "$udid" "$BUNDLE" || true
    xcrun simctl launch "$udid" "$BUNDLE" -ScreenshotScene "$scene" >/dev/null
    sleep 7
    xcrun simctl io "$udid" screenshot "$OUT/$folder/$scene.png"
    echo "captured $folder/$scene"
  done
  xcrun simctl shutdown "$udid"; xcrun simctl delete "$udid"
}

capture_watch() {
  local type udid
  type=$(devicetype "Apple Watch Series 10 (46mm)" "Apple Watch Ultra 2 (49mm)" "Apple Watch Series 9 (45mm)")
  udid=$(boot "shots-watch" "$type" "$(runtime watchOS)")
  mkdir -p "$OUT/watch"
  xcrun simctl install "$udid" "$WATCHAPP"
  xcrun simctl launch "$udid" "$BUNDLE.watchkitapp" -ScreenshotScene today >/dev/null; sleep 12
  xcrun simctl io "$udid" screenshot "$OUT/watch/today.png"
  echo "captured watch/today"
  xcrun simctl shutdown "$udid"; xcrun simctl delete "$udid"
}

capture_ios iphone "iPhone 16 Pro Max" "iPhone 17 Pro Max" "iPhone 15 Pro Max"
capture_ios ipad "iPad Pro 13-inch (M4)" "iPad Pro 13-inch (M5)" "iPad Air 13-inch (M3)" "iPad Air 13-inch (M2)"
capture_watch || echo "::warning::Watch screenshot failed"
ls -R "$OUT"
