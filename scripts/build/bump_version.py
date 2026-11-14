#!/usr/bin/env python3
"""Bump the project version.

[BKE] One bump updates pyproject.toml, uv.lock, CHANGELOG.md and the version named in the published docs. Every new
file is built in memory first, and the lock is computed in a temporary copy of the project, so a failure at any step
(an empty [Unreleased] section, a uv that refuses to run) leaves the tree exactly as it was.
"""

import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from datetime import date
from enum import StrEnum
from pathlib import Path


PRINT_NEXT_ARGUMENT = "--next"
VERSION_PATTERN = re.compile(r'(version\s*=\s*")(\d+\.\d+\.\d+)(")')

# [BKE] Only BKE's own link references are written. They point at the fork's BKEv<version> tags, and the fork's
# address is taken from the existing [Unreleased] link so a bump made in any clone writes the published address.
# The Medusa (upstream) history keeps its own links to the official Medusa repository.
UNRELEASED_LINK = re.compile(
    r"^\[Unreleased\]: (?P<base>\S+)/compare/BKEv(?P<previous>\d+\.\d+\.\d+)\.\.\.HEAD[ \t]*$", re.MULTILINE
)
UNRELEASED_SECTION = re.compile(r"(?ms)^## \[Unreleased\][ \t]*\n(.*?)(?=^## \[|\Z)")

# [BKE] Published files that name the current BKE version. The CHANGELOG is not among them: its released sections
# keep the version they were released as.
VERSION_LITERAL_FILES = (
    "README.md",
    "docs/README.md",
    "docs/api.md",
    "docs/installation.md",
    "docs/quick-start.md",
    ".github/ISSUE_TEMPLATE/bug.yml",
)
VERSION_LITERAL_GLOBS = ("docs/differences-from-medusa-*.md",)
# The forms the version takes there: "BKEv0.1.0" (also "BKEv0.1.0-dev-<branch>"), "(BKE) v0.1.0", the zip member
# names "medusa-bke-0.1.0.lua" / "medusa-bke-thin-0.1.0.lua", and the issue form's placeholder: "0.1.0".
VERSION_LITERAL_PREFIXES = (r"BKEv", r"\(BKE\) v", r"medusa-bke-", r"medusa-bke-thin-", r'placeholder: "')


class VersionPart(StrEnum):
    MAJOR = "major"
    MINOR = "minor"
    PATCH = "patch"


class BumpError(Exception):
    """A bump step failed; nothing has been written."""


LockRunner = Callable[[str, str, Path], str]


def bump_version(version: str, part: VersionPart) -> str:
    major, minor, patch = map(int, version.split("."))
    if part is VersionPart.MAJOR:
        major += 1
        minor = 0
        patch = 0
    elif part is VersionPart.MINOR:
        minor += 1
        patch = 0
    elif part is VersionPart.PATCH:
        patch += 1
    return f"{major}.{minor}.{patch}"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_version(pyproject_text: str) -> str:
    match = VERSION_PATTERN.search(pyproject_text)
    if not match:
        raise BumpError("No version field found in pyproject.toml")
    return match.group(2)


def set_version(pyproject_text: str, new_version: str) -> str:
    return VERSION_PATTERN.sub(lambda m: f"{m.group(1)}{new_version}{m.group(3)}", pyproject_text, count=1)


def strip_empty_sections(body: str) -> str:
    """Remove ### Category headers that have no entries below them."""
    lines = body.split("\n")
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # Check if this is a ### header
        if line.strip().startswith("### "):
            # Look ahead to see if there's any content before next ### or end
            has_content = False
            j = i + 1
            while j < len(lines):
                next_line = lines[j].strip()
                if next_line.startswith("### ") or next_line.startswith("## "):
                    break
                if next_line and not next_line.startswith("###"):
                    has_content = True
                    break
                j += 1
            if has_content:
                result.append(line)
            # else: skip this empty section header
        else:
            result.append(line)
        i += 1

    # Clean up multiple consecutive blank lines
    cleaned = []
    prev_blank = False
    for line in result:
        is_blank = not line.strip()
        if is_blank and prev_blank:
            continue
        cleaned.append(line)
        prev_blank = is_blank

    return "\n".join(cleaned)


def check_unreleased_content(content: str) -> bool:
    """Check if the Unreleased section has any actual entries."""
    m = UNRELEASED_SECTION.search(content)
    if not m:
        return False
    body = m.group(1)
    # Check for any line that starts with - or * (an actual entry)
    return bool(re.search(r"^\s*[-*]", body, re.MULTILINE))


def update_bke_links(content: str, old_version: str, new_version: str) -> str:
    """Point [Unreleased] at the new tag and add the new version's compare link below it; touch no other link."""
    m = UNRELEASED_LINK.search(content)
    if not m:
        raise BumpError(
            "CHANGELOG.md has no '[Unreleased]: <fork>/compare/BKEv<version>...HEAD' link reference to update"
        )
    if m.group("previous") != old_version:
        raise BumpError(
            f"CHANGELOG.md's [Unreleased] link compares from BKEv{m.group('previous')}, "
            f"but pyproject.toml is at {old_version}"
        )
    # A Markdown link label is defined once; a second [x.y.z] definition would silently lose to the first.
    if re.search(rf"^\[{re.escape(new_version)}\]:", content, re.MULTILINE):
        raise BumpError(f"CHANGELOG.md already defines a [{new_version}] link reference")
    base = m.group("base")
    links = (
        f"[Unreleased]: {base}/compare/BKEv{new_version}...HEAD\n"
        f"[{new_version}]: {base}/compare/BKEv{old_version}...BKEv{new_version}"
    )
    return content[: m.start()] + links + content[m.end() :]


def release_changelog(content: str, old_version: str, new_version: str, today: str) -> str:
    """Move the [Unreleased] entries into a new version section dated today and update BKE's link references."""
    if re.search(rf"^## \[{re.escape(new_version)}\]", content, re.MULTILINE):
        raise BumpError(f"CHANGELOG.md already has a [{new_version}] section")
    m = UNRELEASED_SECTION.search(content)
    if not m:
        raise BumpError("CHANGELOG.md has no ## [Unreleased] section")
    if not check_unreleased_content(content):
        raise BumpError("CHANGELOG.md's [Unreleased] section has no entries; there is nothing to release")
    body = strip_empty_sections(m.group(1).strip()).strip()
    released = f"## [Unreleased]\n\n## [{new_version}] - {today}\n\n{body}\n\n"
    content = content[: m.start()] + released + content[m.end() :]
    return update_bke_links(content, old_version, new_version)


def update_version_literals(text: str, old_version: str, new_version: str) -> str:
    prefixes = "|".join(VERSION_LITERAL_PREFIXES)
    # Not followed by another digit or ".digit", so 0.0.1 never matches inside 0.0.10.
    pattern = re.compile(rf"({prefixes}){re.escape(old_version)}(?!\.?\d)")
    return pattern.sub(lambda m: m.group(1) + new_version, text)


def version_literal_paths(root: Path) -> list[Path]:
    paths = [root / name for name in VERSION_LITERAL_FILES]
    for pattern in VERSION_LITERAL_GLOBS:
        paths.extend(sorted(root.glob(pattern)))
    return [path for path in paths if path.is_file()]


def pinned_uv_version(pyproject_text: str) -> str | None:
    m = re.search(r'^required-version\s*=\s*"==(\d+\.\d+\.\d+)"', pyproject_text, re.MULTILINE)
    return m.group(1) if m else None


def uv_lock_command(pinned: str | None, running_version_line: str) -> list[str]:
    """`uv lock` when the installed uv is the pinned one; otherwise run the pinned uv through `uv tool run`."""
    fields = running_version_line.split()
    running = fields[1] if len(fields) > 1 else ""
    if pinned is None or running == pinned:
        return ["uv", "lock"]
    return ["uv", "tool", "run", f"uv@{pinned}", "lock"]


def run_uv_lock(pyproject_text: str, lock_text: str, root: Path) -> str:
    """Lock the bumped project in a temporary copy and return the new uv.lock text."""
    try:
        running = subprocess.check_output(["uv", "--version"], text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise BumpError(f"uv is required to update uv.lock: {exc}") from exc
    command = uv_lock_command(pinned_uv_version(pyproject_text), running)
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "pyproject.toml").write_bytes(pyproject_text.encode("utf-8"))
        (work / "uv.lock").write_bytes(lock_text.encode("utf-8"))
        readme = root / "README.md"
        if readme.is_file():
            (work / "README.md").write_bytes(readme.read_bytes())
        result = subprocess.run(command, cwd=work, capture_output=True, text=True)
        if result.returncode != 0:
            raise BumpError(f"`{' '.join(command)}` failed:\n{result.stderr.strip()}")
        return read_text(work / "uv.lock")


def plan_bump(root: Path, part: VersionPart, today: str, lock: LockRunner) -> tuple[str, str, dict[Path, str]]:
    """Build every changed file in memory; returns (old version, new version, {path: new text})."""
    pyproject_path = root / "pyproject.toml"
    if not pyproject_path.is_file():
        raise BumpError("pyproject.toml not found in current directory")
    pyproject = read_text(pyproject_path)
    old_version = read_version(pyproject)
    new_version = bump_version(old_version, part)
    new_pyproject = set_version(pyproject, new_version)

    files: dict[Path, str] = {pyproject_path: new_pyproject}
    changelog_path = root / "CHANGELOG.md"
    if not changelog_path.is_file():
        raise BumpError("CHANGELOG.md not found in current directory")
    files[changelog_path] = release_changelog(read_text(changelog_path), old_version, new_version, today)

    for path in version_literal_paths(root):
        text = read_text(path)
        updated = update_version_literals(text, old_version, new_version)
        if updated != text:
            files[path] = updated

    lock_path = root / "uv.lock"
    if lock_path.is_file():
        new_lock = lock(new_pyproject, read_text(lock_path), root)
        if f'version = "{new_version}"' not in new_lock:
            raise BumpError(f"the new uv.lock does not record version {new_version}")
        files[lock_path] = new_lock
    return old_version, new_version, files


def write_files(files: dict[Path, str]) -> None:
    """Write UTF-8 with LF line endings; if any write fails, put back the files already written."""
    originals = {path: path.read_bytes() for path in files}
    written: list[Path] = []
    try:
        for path, text in files.items():
            temporary = path.with_name(path.name + ".bump-tmp")
            temporary.write_bytes(text.encode("utf-8"))
            try:
                os.replace(temporary, path)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
            written.append(path)
    except BaseException:
        for path in written:
            path.write_bytes(originals[path])
        raise


def bump(
    root: Path, part: VersionPart, today: str | None = None, lock: LockRunner = run_uv_lock
) -> tuple[str, str, list[Path]]:
    """Bump and write; returns (old version, new version, the files written)."""
    old_version, new_version, files = plan_bump(root, part, today or date.today().isoformat(), lock)
    write_files(files)
    return old_version, new_version, list(files)


def main():
    usage = f"Usage: bump_version.py [major|minor|patch] [{PRINT_NEXT_ARGUMENT}]"
    if len(sys.argv) not in {2, 3} or (len(sys.argv) == 3 and sys.argv[2] != PRINT_NEXT_ARGUMENT):
        print(usage)
        sys.exit(1)
    try:
        part = VersionPart(sys.argv[1])
    except ValueError:
        print(usage)
        sys.exit(1)

    root = Path.cwd()
    try:
        if len(sys.argv) == 3:
            pyproject_path = root / "pyproject.toml"
            if not pyproject_path.is_file():
                raise BumpError("pyproject.toml not found in current directory")
            print(bump_version(read_version(read_text(pyproject_path)), part))
            return
        old_version, new_version, written = bump(root, part)
    except BumpError as exc:
        print(f"Bump failed, nothing written: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"Bumped {part.value} version: {old_version} -> {new_version}")
    for path in written:
        print(f"  updated {path.relative_to(root).as_posix()}")


if __name__ == "__main__":
    main()
