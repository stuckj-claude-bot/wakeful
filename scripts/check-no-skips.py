#!/usr/bin/env python3
"""Fail if any test was skipped, or if a report ran no tests at all.

A skipped test is indistinguishable from a passing one in a green build. A test
that cannot run in some context is kept out of it by *marker* (the D-Bus tests
are `-m dbus`, deselected by default), so it is never scheduled there, rather
than scheduled and skipped.

Usage: check-no-skips.py <junit.xml> [<junit.xml> ...]
"""

import sys
import xml.etree.ElementTree as ET


def read(path):
    """Return (number of testcases, [(classname, name, message)] skipped)."""
    root = ET.parse(path).getroot()
    cases = list(root.iter("testcase"))
    skipped = []
    for case in cases:
        for skip in case.findall("skipped"):
            skipped.append(
                (
                    case.get("classname", "?"),
                    case.get("name", "?"),
                    (skip.get("message") or skip.text or "").strip(),
                )
            )
    return len(cases), skipped


def main(argv):
    if len(argv) < 2:
        print("usage: check-no-skips.py <junit.xml> [...]", file=sys.stderr)
        return 2

    failed = False
    for path in argv[1:]:
        try:
            count, skips = read(path)
        except FileNotFoundError:
            print(f"::error::expected JUnit report not found: {path}")
            failed = True
            continue
        except ET.ParseError as exc:
            print(f"::error::could not parse JUnit report {path}: {exc}")
            failed = True
            continue

        if count == 0:
            failed = True
            print(f"::error::{path} ran no tests")
        elif skips:
            failed = True
            print(f"::error::{len(skips)} skipped test(s) in {path}")
            for classname, name, message in skips:
                print(f"  - {classname}.{name}: {message}")
        else:
            print(f"{count} tests, none skipped, in {path}")

    if failed:
        print(
            "\nA skipped test means a precondition silently went unmet. Either fix the\n"
            "environment so the test runs, or give the test a marker so it is never\n"
            "scheduled in this context."
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
