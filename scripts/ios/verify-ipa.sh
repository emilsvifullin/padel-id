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
expected_api="${3:-https://padel-id-gamma.vercel.app}"
expected_fallback="${4:-}"
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
[ "$(value CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName)" = "AppIcon" ] || fail "default lime icon is not configured"
for icon in AppIconCharcoal AppIconBall; do
  [ "$(value CFBundleIcons:CFBundleAlternateIcons:$icon:CFBundleIconName)" = "$icon" ] || fail "alternate icon $icon is missing"
done

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
[ "$(value PadelIDAPIBaseURL)" = "$expected_api" ] || fail "production API origin does not match the expected release configuration"
[ "$(value PadelIDAPIFallbackURL)" = "$expected_fallback" ] || fail "gateway fallback does not match the expected release configuration"
python3 "$(dirname "$0")/verify-api-url.py" "$(value PadelIDAPIBaseURL)" "$(value PadelIDAPIFallbackURL)" || fail "invalid production gateway configuration"
push_enabled="$(value PadelIDRemotePushEnabled)"
case "$push_enabled" in
  YES|TRUE|true|1)
    codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null || fail "push-enabled IPA is not signed"
    python3 - "$work/entitlements.plist" <<'PY' || fail "push-enabled IPA lacks production APNs entitlements"
import plistlib,sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
if entitlements.get('aps-environment') != 'production':
    sys.exit(1)
PY
    [ -f "$app/embedded.mobileprovision" ] || fail "push-enabled IPA lacks a provisioning profile"
    security cms -D -i "$app/embedded.mobileprovision" > "$work/profile.plist" 2>/dev/null || fail "cannot read push provisioning profile"
    python3 - "$work/profile.plist" <<'PY' || fail "profile does not permit production push"
import plistlib,sys
with open(sys.argv[1], 'rb') as source:
    profile = plistlib.load(source)
if profile.get('Entitlements', {}).get('aps-environment') != 'production':
    sys.exit(1)
PY
    ;;
  NO|FALSE|false|0|'') ;;
  *) fail "invalid remote push build flag" ;;
esac
# A Supabase hostname is permitted only as the explicitly reviewed gateway
# URL above. It must not be hardcoded in the executable or other resources.
while IFS= read -r found; do
  [ "$found" = "$plist" ] || fail "hardcoded direct Supabase endpoint in ${found#$work/}"
done < <(grep -r -a -F -l -- "supabase.co" "$app" || true)

echo "IPA OK: $(value CFBundleDisplayName) $(value CFBundleShortVersionString) ($(value CFBundleVersion)), $(du -h "$ipa" | cut -f1)"
