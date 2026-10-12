#!/usr/bin/env python3
"""Release origin gate regressions: prevent shipping a test/unsafe endpoint."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).with_name("verify-api-url.py")
spec = importlib.util.spec_from_file_location("verify_api_url", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseOriginTests(unittest.TestCase):
    def test_fallback_only_allows_complete_gateway(self):
        for url in ["", "https://api.example.com", "https://project.supabase.co/functions/v1/gateway"]:
            self.assertTrue(module.valid_fallback(url))
        for url in ["https://project.supabase.co/rest/v1", "https://project.supabase.co/auth/v1",
                    "https://project.supabase.co/functions/v1/account", "https://project.supabase.co/functions/v1/gateway?token=x",
                    "http://project.supabase.co/functions/v1/gateway", "https://127.0.0.1/functions/v1/gateway"]:
            self.assertFalse(module.valid_fallback(url))

    def test_public_https_origins(self):
        for origin in ["https://padel-id-gamma.vercel.app", "https://api-padel.shiftregister.ru", "https://api.example.com:443/"]:
            with self.subTest(origin=origin):
                self.assertTrue(module.valid_origin(origin))

    def test_rejects_credentials_local_network_and_misrouting(self):
        for origin in ["http://api.example.com", "https://user:password@api.example.com", "https://localhost", "https://127.0.0.1",
                       "https://192.168.1.1", "https://[::1]", "https://[fc00::1]", "https://api.local", "https://api.test",
                       "https://api.example.com/v1", "https://api.example.com?token=x", "https://api.example.com#test",
                       "https://api.example.com:3000", "https://api..example.com", "https://-api.example.com", " https://api.example.com"]:
            with self.subTest(origin=origin):
                self.assertFalse(module.valid_origin(origin))

    def test_build_gate_fails_for_missing_origin(self):
        result = subprocess.run([sys.executable, str(SCRIPT), ""], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"public HTTPS origin", result.stderr)


if __name__ == "__main__":
    unittest.main()
