#!/usr/bin/env python3
"""Prints the XCTest activity log of every failed test in an xcresult bundle.

Usage: failed-activities.py <path.xcresult> [max lines per test]

The CI job log only shows the activities of the last test that ran; this
puts the steps that led to each failure into the test summary.
"""
import json
import subprocess
import sys


def xcresult(*args):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", *args, "--compact"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def walk(activities, depth, lines):
    for activity in activities or []:
        lines.append("  " * depth + activity.get("title", "?"))
        walk(activity.get("childActivities"), depth + 1, lines)


def main():
    path = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 1200
    summary = xcresult("summary", "--path", path)
    seen = set()
    for failure in summary.get("testFailures", []):
        test_id = failure.get("testIdentifierString")
        if not test_id or test_id in seen:
            continue
        seen.add(test_id)
        try:
            details = xcresult("activities", "--test-id", test_id, "--path", path)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
            print(f"-- activities of {test_id} unavailable: {error}")
            continue
        for run in details.get("testRuns", []):
            lines = []
            walk(run.get("activities"), 0, lines)
            print(f"-- last {min(limit, len(lines))} of {len(lines)} activities of {test_id}")
            print("\n".join(lines[-limit:]))


if __name__ == "__main__":
    main()
