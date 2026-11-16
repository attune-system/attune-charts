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
            shutil.copytree(ROOT / "charts/attune", root / "charts/attune", dirs_exist_ok=True)
            for name in ("scripts/test-acceptance-image-pins.py", "scripts/verify.sh", "docs/published-images-0.11.0.json"):
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
            for component in ("api", "executor", "notifier", "supervisor", "mcp", "web", "migrations", "initUser", "agent"):
                self.assertEqual(values["images"][component]["digest"], "", component)
            self.assertEqual(values["corePack"], before_values["corePack"])
            self.assertEqual(values["images"]["initPacks"], before_values["images"]["initPacks"])
            for name in ("README.md", "charts/attune/README.md"):
                self.assertIn(f"Chart `{expected_chart}` targets Attune `{target_version}`", (root / name).read_text())
                self.assertNotIn(f"targets Attune `{chart['appVersion']}`", (root / name).read_text())
            # Exercise the real downstream suite after the updater, including
            # tag fallback and exact package/index checks used by verify.sh.
            packages = root / "packages"
            packages.mkdir()
            subprocess.run(["helm", "package", str(root / "charts/attune"),
                            "--destination", str(packages)], check=True, capture_output=True)
            subprocess.run(["helm", "repo", "index", str(packages), "--url", "packages"],
                           check=True, capture_output=True)
            shutil.move(packages / "index.yaml", root / "index.yaml")
            downstream = subprocess.run(["python3", str(root / "scripts/test-acceptance-image-pins.py")],
                                        capture_output=True, text=True, timeout=90)
            self.assertEqual(downstream.returncode, 0, downstream.stdout + downstream.stderr)
            before = {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertEqual(before, {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()})


if __name__ == "__main__":
    unittest.main()
