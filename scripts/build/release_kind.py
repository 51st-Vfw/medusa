#!/usr/bin/env python3
"""Decide how a BKE release tag is published on GitHub.

[BKE] BKE is a beta while its major version is 0: a BKEv0.y.z tag makes a pre-release, and BKEv1.0.0 and later
make normal releases. GitHub's "Latest" badge goes to the newest normal release, so a pre-release is never marked
latest.

Usage: release_kind.py <tag>   (prints prerelease=... and make_latest=... lines for $GITHUB_OUTPUT)
"""

import re
import sys

RELEASE_TAG = re.compile(r"^BKEv(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def release_flags(tag: str) -> dict[str, str]:
    m = RELEASE_TAG.match(tag)
    if not m:
        raise ValueError(f"{tag!r} is not a BKE release tag (BKEv<major>.<minor>.<patch>)")
    prerelease = m.group(1) == "0"
    return {
        "prerelease": "true" if prerelease else "false",
        "make_latest": "false" if prerelease else "true",
    }


def step_outputs(tag: str) -> str:
    return "".join(f"{key}={value}\n" for key, value in release_flags(tag).items())


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: release_kind.py <tag>")
    try:
        sys.stdout.write(step_outputs(sys.argv[1]))
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
