#!/usr/bin/env bash
# Verifies a packaged PadelID.ipa before it is published:
#   - layout, bundle id, version and architecture;
#   - no App Transport Security exceptions;
#   - no test bundles, debug hooks, local endpoints or credentials.
#
#   scripts/ios/verify-ipa.sh PadelID.ipa 1.0.0
set -euo pipefail

ipa="$1"
expected_version="$2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

unzip -q "$ipa" -d "$work"
app="$work/Payload/PadelID.app"
[ -d "$app" ] || { echo "Payload/PadelID.app is missing"; exit 1; }
plist="$app/Info.plist"

fail() { echo "IPA check failed: $*"; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

[ "$(value CFBundleIdentifier)" = "app.padelid.ios" ] || fail "unexpected bundle id $(value CFBundleIdentifier)"
[ "$(value CFBundleShortVersionString)" = "$expected_version" ] || fail "version $(value CFBundleShortVersionString) != $expected_version"
[ "$(value CFBundleDisplayName)" = "Padel ID" ] || fail "unexpected display name"
[ -z "$(value NSAppTransportSecurity)" ] || fail "release build carries App Transport Security exceptions"
[ -f "$app/PrivacyInfo.xcprivacy" ] || fail "privacy manifest is missing"
[ -f "$app/Assets.car" ] || fail "compiled asset catalog is missing"

binary="$app/$(value CFBundleExecutable)"
lipo -info "$binary" | grep -q "arm64" || fail "binary is not arm64"
if find "$app" \( -name "*.xctest" -o -name "XCTest*" -o -name "*.xctestrun" \) | grep -q .; then
  fail "test bundles found in the app"
fi
if find "$app" \( -name "*.debug.dylib" -o -name "__preview.dylib" -o -name "*.json" \) | grep -q .; then
  find "$app" \( -name "*.debug.dylib" -o -name "__preview.dylib" -o -name "*.json" \) | sed "s|$work/||"
  fail "debug, preview or test payload found in the app"
fi

# Strings that must never ship: debug-only hooks, local endpoints, direct
# Supabase access and any credential material.
# (Swift stores literals of up to 15 bytes inline in code, so the debug hooks
# use longer names to stay detectable.)
forbidden=(
  "PADELID_UITEST_API_BASE_URL"
  "-padelid-uitest-reset-state"
  "supabase.co"
  "service_role"
  "sb_secret_"
  "sb_publishable_"
  "PADELID_GATEWAY"
  "BEGIN PRIVATE KEY"
  "eyJhbGciOi"
  "eyJ0eXAiOi"
)
for pattern in "${forbidden[@]}"; do
  if grep -r -a -F -l -- "$pattern" "$app" >/dev/null 2>&1; then
    grep -r -a -F -l -- "$pattern" "$app" | sed "s|$work/||"
    fail "found forbidden string '$pattern'"
  fi
done
grep -a -F -q "https://padel-id-gamma.vercel.app" "$binary" || fail "production API endpoint not found in the binary"

echo "IPA OK: $(value CFBundleDisplayName) $(value CFBundleShortVersionString) ($(value CFBundleVersion)), $(du -h "$ipa" | cut -f1)"
