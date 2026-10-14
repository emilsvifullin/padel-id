#!/usr/bin/env python3
"""Validate a build-time production origin without contacting it."""
import ipaddress
import os
import re
import sys
from urllib.parse import urlsplit


def valid_origin(raw: str) -> bool:
    try:
        url = urlsplit(raw)
        host = url.hostname or ""
        if (url.scheme != "https" or url.username is not None or url.password is not None
                or url.port not in (None, 443) or url.path not in ("", "/")
                or url.query or url.fragment or any(c.isspace() for c in raw)):
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            return ("." in host and len(host) <= 253
                    and not host.endswith((".local", ".localhost", ".test", ".invalid", ".internal", ".home.arpa"))
                    and all(re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", label)
                            for label in host.split(".")))
    except ValueError:
        return False


def valid_fallback(raw: str) -> bool:
    """Zero or more gateway origins separated by single spaces."""
    if not raw:
        return True
    entries = raw.split(" ")
    return len(set(entries)) == len(entries) and all(valid_fallback_entry(entry) for entry in entries)


def valid_fallback_entry(raw: str) -> bool:
    if not raw:
        return False
    try:
        url = urlsplit(raw)
        # A complete copy of the gateway, never raw Auth/rest/storage endpoints.
        if url.path not in ("", "/", "/functions/v1/gateway") or url.query or url.fragment:
            return False
        return valid_origin(url._replace(path="").geturl()) and not any(c.isspace() for c in raw)
    except ValueError:
        return False


if __name__ == "__main__":
    origin = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("PADELID_API_BASE_URL", "")
    if not valid_origin(origin):
        sys.exit("Production API must be a public HTTPS origin, without credentials, path, query or fragment")
    fallback = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("PADELID_API_FALLBACK_URL", "")
    if not valid_fallback(fallback):
        sys.exit("Fallbacks must be public HTTPS gateway origins (or /functions/v1/gateway endpoints) separated by single spaces")
    print("Production API origin validated")
