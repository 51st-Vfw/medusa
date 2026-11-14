#!/usr/bin/env python3

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BUILD_DIR = Path(__file__).parent
REPO_ROOT = BUILD_DIR.parent.parent
sys.path.insert(0, str(BUILD_DIR))

import bump_version  # noqa: E402

FORK = "https://github.com/51st-Vfw/medusa"
UPSTREAM = "https://github.com/medusa-iads/medusa"

PYPROJECT = (
    '[project]\nname = "medusa-bke"\nversion = "0.0.1"\nreadme = "README.md"\n\n'
    '[tool.uv]\nrequired-version = "==0.10.12"\n\n'
    '[tool.medusa-bke]\nmedusa-base = "1.6.0"\n'
)

UV_LOCK = (
    "version = 1\nrevision = 3\n\n"
    '[[package]]\nname = "lizard"\nversion = "1.23.0"\n\n'
    '[[package]]\nname = "medusa-bke"\nversion = "0.0.1"\nsource = { virtual = "." }\n'
)

# The upstream history carries an en dash and a closing curly quote: U+201D is E2 80 9D in UTF-8, and 0x9D has
# no cp1252 character, so a cp1252 read of this file fails outright.
UPSTREAM_TAIL = (
    "## [Medusa (upstream) history]\n\n"
    "## [1.6.0] - 2026-09-24\n\n- Suppression lasts 30–120 seconds (“short”).\n\n"
    "## [1.0.0] - 2026-04-07\n\n- Initial release\n\n"
    f"[Unreleased]: {FORK}/compare/BKEv0.0.1...HEAD\n"
    f"[0.0.1]: {FORK}/releases/tag/BKEv0.0.1\n"
    f"[Medusa (upstream) history]: {UPSTREAM}/blob/main/CHANGELOG.md\n"
    f"[1.6.0]: {UPSTREAM}/compare/v1.0.0...v1.6.0\n"
    f"[1.0.0]: {UPSTREAM}/releases/tag/v1.0.0\n"
)

CHANGELOG = (
    "# Changelog\n\n"
    "## [Unreleased]\n\n### Added\n\n### Fixed\n\n- A gun no longer counts as a missile.\n\n"
    "## [0.0.1] - 2026-11-11\n\nBased on Medusa 1.6.0.\n\n### Added\n\n- First\n\n" + UPSTREAM_TAIL
)

README = "# Medusa\n\n**Medusa IADS - Black Knight Edition (BKE) v0.0.1**, based on Medusa v1.6.0.\n"


def fake_lock(pyproject_text: str, lock_text: str, root: Path) -> str:
    """Stands in for uv: a virtual project's lock records only the project version."""
    version = bump_version.read_version(pyproject_text)
    return lock_text.replace('name = "medusa-bke"\nversion = "0.0.1"', f'name = "medusa-bke"\nversion = "{version}"')


class TempRepo:
    def __init__(self, changelog: str = CHANGELOG) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        self.write("pyproject.toml", PYPROJECT)
        self.write("uv.lock", UV_LOCK)
        self.write("CHANGELOG.md", changelog)
        self.write("README.md", README)

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))

    def read(self, name: str) -> str:
        return (self.root / name).read_bytes().decode("utf-8")

    def snapshot(self) -> dict[str, bytes]:
        return {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

    def close(self) -> None:
        self._dir.cleanup()


class ChangelogLinkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def test_bke_links_are_written_as_bkev_tags(self) -> None:
        bump_version.bump(self.repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        changelog = self.repo.read("CHANGELOG.md")
        self.assertIn(f"[Unreleased]: {FORK}/compare/BKEv0.1.0...HEAD\n", changelog)
        self.assertIn(f"[0.1.0]: {FORK}/compare/BKEv0.0.1...BKEv0.1.0\n", changelog)
        self.assertIn(f"[0.0.1]: {FORK}/releases/tag/BKEv0.0.1\n", changelog)
        self.assertIn("## [0.1.0] - 2026-12-01\n", changelog)
        self.assertIn("- A gun no longer counts as a missile.", changelog.split("## [0.1.0]")[1].split("## [0.0.1]")[0])

    def test_medusa_history_and_its_links_are_left_as_they_are(self) -> None:
        bump_version.bump(self.repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        changelog = self.repo.read("CHANGELOG.md")
        upstream_links = UPSTREAM_TAIL[UPSTREAM_TAIL.index("[Medusa (upstream) history]:") :]
        self.assertTrue(changelog.endswith(upstream_links))
        upstream_sections = UPSTREAM_TAIL[: UPSTREAM_TAIL.index("[Unreleased]:")]
        self.assertIn(upstream_sections, changelog)

    def test_link_base_comes_from_the_changelog_not_the_git_remote(self) -> None:
        with mock.patch("subprocess.check_output", return_value="https://github.com/someone/private-dev.git\n"):
            bump_version.bump(self.repo.root, bump_version.VersionPart.PATCH, today="2026-12-01", lock=fake_lock)
        changelog = self.repo.read("CHANGELOG.md")
        self.assertNotIn("private-dev", changelog)
        self.assertIn(f"[0.0.2]: {FORK}/compare/BKEv0.0.1...BKEv0.0.2\n", changelog)

    def test_real_changelog_keeps_every_medusa_link(self) -> None:
        real = (REPO_ROOT / "CHANGELOG.md").read_bytes().decode("utf-8")
        # Right after a release [Unreleased] is empty, and a bump with nothing to release is refused.
        real = real.replace("## [Unreleased]\n", "## [Unreleased]\n\n### Fixed\n\n- A test entry.\n", 1)
        old =bump_version.read_version((REPO_ROOT / "pyproject.toml").read_bytes().decode("utf-8"))
        new = bump_version.bump_version(old, bump_version.VersionPart.MINOR)
        released = bump_version.release_changelog(real, old, new, "2026-12-01")
        tail = real[real.index("[Medusa (upstream) history]:") :]
        self.assertTrue(released.endswith(tail))
        self.assertIn(f"[Unreleased]: {FORK}/compare/BKEv{new}...HEAD\n[{new}]: {FORK}/compare/BKEv{old}...BKEv{new}\n", released)
        history = real[real.index("## [Medusa (upstream) history]") : real.index("[Unreleased]:")]
        self.assertIn(history, released)


class EncodingTest(unittest.TestCase):
    def test_non_ascii_text_round_trips_as_utf8_with_lf(self) -> None:
        repo = TempRepo()
        self.addCleanup(repo.close)
        bump_version.bump(repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        raw = (repo.root / "CHANGELOG.md").read_bytes()
        self.assertIn("30–120 seconds (“short”)".encode("utf-8"), raw)
        self.assertNotIn(b"\r", raw)
        for name in ("pyproject.toml", "uv.lock", "README.md"):
            self.assertNotIn(b"\r", (repo.root / name).read_bytes(), name)


class AtomicBumpTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)
        self.before = self.repo.snapshot()

    def test_a_failed_lock_writes_nothing(self) -> None:
        def failing_lock(pyproject_text: str, lock_text: str, root: Path) -> str:
            raise bump_version.BumpError("uv refused")

        with self.assertRaises(bump_version.BumpError):
            bump_version.bump(self.repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=failing_lock)
        self.assertEqual(self.repo.snapshot(), self.before)

    def test_the_lock_runs_before_any_file_is_written(self) -> None:
        seen = {}

        def watching_lock(pyproject_text: str, lock_text: str, root: Path) -> str:
            seen["tree"] = self.repo.snapshot()
            seen["version"] = bump_version.read_version(pyproject_text)
            return fake_lock(pyproject_text, lock_text, root)

        bump_version.bump(self.repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=watching_lock)
        self.assertEqual(seen["tree"], self.before)
        self.assertEqual(seen["version"], "0.1.0")
        self.assertIn('name = "medusa-bke"\nversion = "0.1.0"', self.repo.read("uv.lock"))
        self.assertIn('version = "0.1.0"', self.repo.read("pyproject.toml"))

    def test_a_changelog_without_the_bke_unreleased_link_writes_nothing(self) -> None:
        self.repo.write("CHANGELOG.md", CHANGELOG.replace(f"[Unreleased]: {FORK}/compare/BKEv0.0.1...HEAD\n", ""))
        before = self.repo.snapshot()
        with self.assertRaises(bump_version.BumpError):
            bump_version.bump(self.repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        self.assertEqual(self.repo.snapshot(), before)

    def test_a_failed_write_restores_the_files_already_written(self) -> None:
        real_replace = bump_version.os.replace
        calls = []

        def flaky_replace(src, dst):
            calls.append(dst)
            if len(calls) == 3:
                raise OSError("disk full")
            return real_replace(src, dst)

        with mock.patch.object(bump_version.os, "replace", side_effect=flaky_replace):
            with self.assertRaises(OSError):
                bump_version.bump(self.repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        self.assertEqual(self.repo.snapshot(), self.before)


class VersionLiteralTest(unittest.TestCase):
    def test_published_version_literals_follow_the_bump(self) -> None:
        text = (
            "**Medusa IADS - Black Knight Edition (BKE) v0.0.1**, based on Medusa v1.6.0.\n"
            '| `Medusa.version` | `"BKEv0.0.1"` | a dev build reads `"BKEv0.0.1-dev-<branch>"` |\n'
            "named with its version inside (`medusa-bke-0.0.1.lua`), (`medusa-bke-thin-0.0.1.lua`)\n"
            '          placeholder: "0.0.1"\n'
            "uses: astral-sh/setup-uv@abc # v10.0.1\n"
            "BKEv0.0.10 stays\n"
        )
        updated = bump_version.update_version_literals(text, "0.0.1", "0.1.0")
        self.assertEqual(
            updated,
            "**Medusa IADS - Black Knight Edition (BKE) v0.1.0**, based on Medusa v1.6.0.\n"
            '| `Medusa.version` | `"BKEv0.1.0"` | a dev build reads `"BKEv0.1.0-dev-<branch>"` |\n'
            "named with its version inside (`medusa-bke-0.1.0.lua`), (`medusa-bke-thin-0.1.0.lua`)\n"
            '          placeholder: "0.1.0"\n'
            "uses: astral-sh/setup-uv@abc # v10.0.1\n"
            "BKEv0.0.10 stays\n",
        )

    def test_the_bump_updates_the_readme_literal(self) -> None:
        repo = TempRepo()
        self.addCleanup(repo.close)
        bump_version.bump(repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        self.assertIn("(BKE) v0.1.0**", repo.read("README.md"))

    def test_the_changelog_history_keeps_its_old_version_links(self) -> None:
        repo = TempRepo(CHANGELOG.replace("Based on Medusa 1.6.0.", f"See [docs]({FORK}/blob/BKEv0.0.1/docs/x.md)."))
        self.addCleanup(repo.close)
        bump_version.bump(repo.root, bump_version.VersionPart.MINOR, today="2026-12-01", lock=fake_lock)
        self.assertIn(f"({FORK}/blob/BKEv0.0.1/docs/x.md)", repo.read("CHANGELOG.md"))


class PinnedUvTest(unittest.TestCase):
    def test_the_pinned_uv_version_is_read_from_pyproject(self) -> None:
        self.assertEqual(bump_version.pinned_uv_version(PYPROJECT), "0.10.12")

    def test_a_different_uv_runs_the_pinned_one_through_uv_tool_run(self) -> None:
        self.assertEqual(bump_version.uv_lock_command("0.10.12", "uv 0.10.12 (abc 2026-01-01)"), ["uv", "lock"])
        self.assertEqual(
            bump_version.uv_lock_command("0.10.12", "uv 0.12.10 (abc 2026-09-04)"),
            ["uv", "tool", "run", "uv@0.10.12", "lock"],
        )


if __name__ == "__main__":
    unittest.main()
