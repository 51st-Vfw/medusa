#!/usr/bin/env python3

import sys
import tempfile
import unittest
from pathlib import Path

BUILD_DIR = Path(__file__).parent
sys.path.insert(0, str(BUILD_DIR))

import extract_changelog_section  # noqa: E402
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


if __name__ == "__main__":
    unittest.main()
