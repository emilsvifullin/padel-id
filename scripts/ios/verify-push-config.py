#!/usr/bin/env python3
"""Fail before signing if a remote-push build lacks matching entitlements."""
import os
from pathlib import Path
import plistlib
import sys

if os.environ.get("PADELID_PUSH_ENABLED", "NO").upper() not in ("YES", "TRUE", "1"):
    sys.exit(0)
environment = os.environ.get("PADELID_APNS_ENVIRONMENT", "")
if environment not in ("production", "development"):
    sys.exit("Push builds require PADELID_APNS_ENVIRONMENT=production or development")
if os.environ.get("CONFIGURATION") == "Release" and environment != "production":
    sys.exit("Release push builds require the production APNs environment")
raw = os.environ.get("CODE_SIGN_ENTITLEMENTS", "")
if not raw:
    sys.exit("Push builds require CODE_SIGN_ENTITLEMENTS and an APNs-enabled provisioning profile")
path = Path(raw)
if not path.is_absolute():
    path = Path(os.environ.get("SRCROOT", ".")) / path
try:
    with path.open("rb") as source:
        value = plistlib.load(source).get("aps-environment", "")
except (OSError, plistlib.InvalidFileException):
    sys.exit("Push entitlements file is missing or invalid")
if value not in (environment, "$(PADELID_APNS_ENVIRONMENT)"):
    sys.exit("Push entitlements do not match the selected APNs environment")
print("Push build configuration is valid; signed profile/device delivery still require verification")
