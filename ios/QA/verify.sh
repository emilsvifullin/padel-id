#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
qa="$repo/ios/QA"
output="${TENNIS_QA_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/tennis-qa.XXXXXX")}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
echo "QA results: $output"

xcrun swiftc "$repo/ios/PadelID/App/TrainingPricing.swift" "$qa/PricingCheck.swift" -o "$output/PricingCheck"
"$output/PricingCheck" | tee "$output/pricing.log"
xcodebuild -project "$repo/ios/PadelID.xcodeproj" -scheme "Tennis ID - Проверка" \
  -configuration Preview -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$output/AppBuild" -clonedSourcePackagesDirPath "$output/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO build | tee "$output/build.log"

device_type="${TENNIS_QA_DEVICE_TYPE:-iPhone-17-Pro-Max}"
runtime="${TENNIS_QA_RUNTIME:-27-2}"
device="$(xcrun simctl create "Tennis ID QA ${CI_RUN_ID:-$$}" \
  "com.apple.CoreSimulator.SimDeviceType.$device_type" "com.apple.CoreSimulator.SimRuntime.iOS-$runtime")"
trap 'xcrun simctl shutdown "$device" 2>/dev/null || true; xcrun simctl delete "$device" 2>/dev/null || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl status_bar "$device" override --time '9:41' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
xcrun simctl install "$device" "$output/AppBuild/Build/Products/Preview-iphonesimulator/PadelID.app"
data="$(xcrun simctl get_app_container "$device" app.padelid.ios.preview data)"
xcrun simctl spawn "$device" defaults write "$data/Library/Preferences/app.padelid.ios.preview" \
  tennis-preview-player-account -data "$(xxd -p "$qa/Fixtures/support.json" | tr -d '\n')"
xcodebuild -project "$qa/TennisCabinetCheck.xcodeproj" -scheme TennisCabinetCheck \
  -destination "id=$device" -derivedDataPath "$output/TestBuild" -resultBundlePath "$output/TennisID.xcresult" \
  -parallel-testing-enabled NO "$@" test | tee "$output/tests.log"
