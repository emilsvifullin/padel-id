#!/usr/bin/env python3
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class PushConfigurationTests(unittest.TestCase):
    def check_config(self, success, **values):
        env = {key: value for key, value in os.environ.items()
               if key not in ("PADELID_PUSH_ENABLED", "PADELID_APNS_ENVIRONMENT", "CODE_SIGN_ENTITLEMENTS")}
        env.update(CONFIGURATION="Release", SRCROOT=str(Path(__file__).resolve().parents[2] / "ios"))
        env.update(values)
        result = subprocess.run(["python3", str(Path(__file__).with_name("verify-push-config.py"))],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_disabled_needs_no_push_profile(self):
        self.check_config(True, PADELID_PUSH_ENABLED="NO")

    def test_enabled_requires_entitlements(self):
        self.check_config(False, PADELID_PUSH_ENABLED="YES", PADELID_APNS_ENVIRONMENT="production")

    def test_release_cannot_use_development(self):
        self.check_config(False, PADELID_PUSH_ENABLED="YES", PADELID_APNS_ENVIRONMENT="development",
                          CODE_SIGN_ENTITLEMENTS="PadelID/Resources/PadelID-Push.entitlements")

    def test_valid_production_template(self):
        self.check_config(True, PADELID_PUSH_ENABLED="YES", PADELID_APNS_ENVIRONMENT="production",
                          CODE_SIGN_ENTITLEMENTS="PadelID/Resources/PadelID-Push.entitlements")

    def test_missing_or_mismatched_aps_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "push.entitlements"
            for contents in ({}, {"aps-environment": "development"}):
                target.write_bytes(plistlib.dumps(contents))
                self.check_config(False, PADELID_PUSH_ENABLED="YES", PADELID_APNS_ENVIRONMENT="production",
                                  CODE_SIGN_ENTITLEMENTS=str(target))


if __name__ == "__main__":
    unittest.main()
