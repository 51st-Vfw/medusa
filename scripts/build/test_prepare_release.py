#!/usr/bin/env python3

import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from prepare_release import prepare_release, read_version


class PrepareReleaseTest(unittest.TestCase):
    def test_creates_versioned_artifacts_and_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build_dir = root / "dist"
            release_dir = build_dir / "release"
            build_dir.mkdir()
            artifacts = {
                "medusa-bke.lua": b"bundled\n",
                "medusa-bke-thin.lua": b"thin\n",
            }
            for name, content in artifacts.items():
                (build_dir / name).write_bytes(content)

            release_names = prepare_release(build_dir, release_dir, "1.2.3")

            self.assertEqual(
                release_names,
                ["medusa-bke.lua", "medusa-bke-thin.lua", "medusa-bke.zip", "medusa-bke-thin.zip"],
            )
            for name, content in artifacts.items():
                self.assertEqual((release_dir / name).read_bytes(), content)
            archive_names = release_names[2:]
            expected_members = ["medusa-bke-1.2.3.lua", "medusa-bke-thin-1.2.3.lua"]
            for archive_name, member_name, content in zip(
                archive_names, expected_members, artifacts.values(), strict=True
            ):
                with zipfile.ZipFile(release_dir / archive_name) as archive:
                    self.assertEqual(archive.namelist(), [member_name])
                    self.assertEqual(archive.read(member_name), content)
            expected_checksums = "\n".join(
                f"{hashlib.sha256((release_dir / name).read_bytes()).hexdigest()}  {name}"
                for name in release_names
            )
            self.assertEqual((release_dir / "SHA256SUMS.txt").read_text(), expected_checksums + "\n")

    def test_rejects_invalid_project_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project_file = Path(directory) / "pyproject.toml"
            project_file.write_text('[project]\nversion = "next"\n', encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "invalid project version"):
                read_version(project_file)


if __name__ == "__main__":
    unittest.main()
