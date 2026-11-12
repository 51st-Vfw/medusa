#!/usr/bin/env python3

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("stamp-placeholders.py")
MODULE_SPEC = importlib.util.spec_from_file_location("stamp_placeholders", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
STAMP_PLACEHOLDERS = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(STAMP_PLACEHOLDERS)


class StampPlaceholdersTest(unittest.TestCase):
    def test_release_tag_uses_exact_version(self) -> None:
        environment = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/tags/v1.2.3",
            "GITHUB_REF_NAME": "v1.2.3",
        }

        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(STAMP_PLACEHOLDERS.compute_effective_version("1.2.3"), "1.2.3")

    def test_bke_release_tag_uses_exact_version(self) -> None:
        environment = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF": "refs/tags/BKEv0.0.1",
            "GITHUB_REF_NAME": "BKEv0.0.1",
        }

        with patch.dict(os.environ, environment, clear=True):
            self.assertEqual(STAMP_PLACEHOLDERS.compute_effective_version("0.0.1"), "0.0.1")


class MedusaBaseTest(unittest.TestCase):
    def test_reads_medusa_base_from_pyproject(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project_file = Path(directory) / "pyproject.toml"
            project_file.write_text(
                '[project]\nversion = "0.0.1"\n\n[tool.medusa-bke]\nmedusa-base = "1.6.0"\n', encoding="utf-8"
            )
            self.assertEqual(STAMP_PLACEHOLDERS.read_medusa_base(project_file), "1.6.0")

    def test_stamps_version_and_medusa_base(self) -> None:
        stamper = STAMP_PLACEHOLDERS.PlaceholderStamper({"VERSION": "0.0.1", "MEDUSA_BASE": "1.6.0"})
        self.assertEqual(
            stamper.stamp_text('Medusa.version = "{{VERSION}}"; Medusa.baseVersion = "{{MEDUSA_BASE}}"'),
            'Medusa.version = "0.0.1"; Medusa.baseVersion = "1.6.0"',
        )


if __name__ == "__main__":
    unittest.main()
