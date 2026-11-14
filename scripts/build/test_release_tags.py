#!/usr/bin/env python3

import io
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BUILD_DIR = Path(__file__).parent
sys.path.insert(0, str(BUILD_DIR))

import extract_changelog_section  # noqa: E402
import release_kind  # noqa: E402
import tag_version  # noqa: E402


class ReleaseTagTest(unittest.TestCase):
    def test_release_tags_carry_the_bke_prefix(self) -> None:
        self.assertEqual(tag_version.release_tag("0.0.1"), "BKEv0.0.1")

    def test_changelog_section_is_found_from_a_bke_tag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory) / "CHANGELOG.md"
            changelog.write_text(
                "# Changelog\n\n## [Unreleased]\n\n## [0.0.1] - 2026-11-11\n\n### Added\n\n- First\n\n"
                "## [1.6.0] - 2026-09-24\n\n- Stock\n",
                encoding="utf-8",
            )
            body = extract_changelog_section.extract_section("BKEv0.0.1", changelog)
            self.assertIn("- First", body)
            self.assertNotIn("Stock", body)

    def _run_main(self, tag: str, changelog_text: str) -> tuple[int, Path]:
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        changelog = directory / "CHANGELOG.md"
        changelog.write_text(changelog_text, encoding="utf-8")
        out = directory / "RELEASE_NOTES.md"
        argv = ["extract_changelog_section.py", tag, str(changelog), str(out)]
        with mock.patch.object(sys, "argv", argv), mock.patch("sys.stderr", new_callable=io.StringIO):
            try:
                extract_changelog_section.main()
            except SystemExit as stop:
                return int(stop.code or 0), out
        return 0, out

    def test_a_missing_changelog_section_fails_the_release(self) -> None:
        code, out = self._run_main("BKEv0.2.0", "# Changelog\n\n## [0.1.0] - 2026-11-13\n\n- First\n")
        self.assertNotEqual(code, 0)
        self.assertFalse(out.exists())

    def test_an_empty_changelog_section_fails_the_release(self) -> None:
        changelog = "# Changelog\n\n## [0.2.0] - 2026-11-14\n\n## [0.1.0] - 2026-11-13\n\n- First\n"
        code, out = self._run_main("BKEv0.2.0", changelog)
        self.assertNotEqual(code, 0)
        self.assertFalse(out.exists())

    def test_a_present_changelog_section_is_written_as_the_release_notes(self) -> None:
        code, out = self._run_main("BKEv0.1.0", "# Changelog\n\n## [0.1.0] - 2026-11-13\n\n- First\n")
        self.assertEqual(code, 0)
        self.assertEqual(out.read_text(encoding="utf-8"), "- First\n")


class ReleaseKindTest(unittest.TestCase):
    def test_a_0_x_tag_makes_a_pre_release_that_is_not_marked_latest(self) -> None:
        self.assertEqual(release_kind.release_flags("BKEv0.1.0"), {"prerelease": "true", "make_latest": "false"})
        self.assertEqual(release_kind.release_flags("BKEv0.12.3"), {"prerelease": "true", "make_latest": "false"})

    def test_1_0_0_and_later_make_a_normal_latest_release(self) -> None:
        self.assertEqual(release_kind.release_flags("BKEv1.0.0"), {"prerelease": "false", "make_latest": "true"})
        self.assertEqual(release_kind.release_flags("BKEv10.2.0"), {"prerelease": "false", "make_latest": "true"})

    def test_a_tag_that_is_not_a_bke_release_tag_is_refused(self) -> None:
        for tag in ("v0.1.0", "BKEv0.1", "BKEv0.1.0-rc1", "BKEv00.1.0x"):
            with self.assertRaises(ValueError, msg=tag):
                release_kind.release_flags(tag)

    def test_the_flags_are_printed_as_github_step_outputs(self) -> None:
        self.assertEqual(release_kind.step_outputs("BKEv0.1.0"), "prerelease=true\nmake_latest=false\n")


if __name__ == "__main__":
    unittest.main()
