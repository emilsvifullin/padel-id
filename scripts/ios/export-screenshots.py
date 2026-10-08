#!/usr/bin/env python3
"""Exports the screenshots attached by UI tests from an .xcresult bundle.

Attachments are named "PadelID-NN-screen" by the UI tests; the files are
written as <output>/<prefix>PadelID-NN-screen.png.

Usage: export-screenshots.py <result.xcresult> <output dir> [prefix]
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    result, output = Path(sys.argv[1]), Path(sys.argv[2])
    prefix = sys.argv[3] if len(sys.argv) > 3 else ""
    if not result.exists():
        print(f"No result bundle at {result}")
        return 0
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", tmp],
            check=True,
        )
        manifest = json.loads((Path(tmp) / "manifest.json").read_text())
        count = 0
        for test in manifest:
            for attachment in test.get("attachments", []):
                exported = Path(tmp) / attachment["exportedFileName"]
                name = attachment.get("suggestedHumanReadableName") or exported.name
                name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", name)
                if not name.startswith("PadelID-") and not attachment.get("isAssociatedWithFailure"):
                    continue
                if attachment.get("isAssociatedWithFailure"):
                    test_name = re.sub(r"\W+", "_", test.get("testIdentifier", "test")).strip("_")
                    name = f"failure-{test_name}{exported.suffix}"
                shutil.copy(exported, output / f"{prefix}{name}")
                count += 1
    print(f"Exported {count} screenshots to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
