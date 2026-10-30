#!/usr/bin/env python3
"""Release updates keep chart metadata, images and documentation aligned."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent


class ReleaseUpdateTests(unittest.TestCase):
    def test_update_and_repeat_preserve_independent_core_pins(self):
        with tempfile.TemporaryDirectory(prefix="attune-chart-release-") as directory:
            root = Path(directory)
            for name in ("scripts/update-attune-release.py", "charts/attune/Chart.yaml",
                         "charts/attune/values.yaml", "charts/attune/README.md", "README.md"):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            chart = yaml.safe_load((root / "charts/attune/Chart.yaml").read_text())
            major, minor, patch = map(int, chart["version"].split("."))
            app_major, app_minor, app_patch = map(int, chart["appVersion"].split("."))
            target = (app_major, app_minor, app_patch + 1)
            target_version = ".".join(map(str, target))
            expected_chart = target_version if target > (major, minor, patch) else f"{major}.{minor}.{patch + 1}"
            before_values = yaml.safe_load((root / "charts/attune/values.yaml").read_text())
            command = ["python3", str(root / "scripts/update-attune-release.py"), target_version]
            subprocess.run(command, check=True, capture_output=True, text=True)
            updated = yaml.safe_load((root / "charts/attune/Chart.yaml").read_text())
            values = yaml.safe_load((root / "charts/attune/values.yaml").read_text())
            self.assertEqual(updated["version"], expected_chart)
            self.assertEqual(updated["appVersion"], target_version)
            self.assertEqual(values["global"]["imageTag"], target_version)
            self.assertEqual(values["corePack"], before_values["corePack"])
            self.assertEqual(values["images"]["initPacks"], before_values["images"]["initPacks"])
            for name in ("README.md", "charts/attune/README.md"):
                self.assertIn(f"Chart `{expected_chart}` targets Attune `{target_version}`", (root / name).read_text())
                self.assertNotIn(f"targets Attune `{chart['appVersion']}`", (root / name).read_text())
            before = {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertEqual(before, {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()})


if __name__ == "__main__":
    unittest.main()
