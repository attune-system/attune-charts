"""Offline source contracts only. Helm rendering and cluster acceptance are central."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parent.parent


class Pins(unittest.TestCase):
    def test_no_image_or_pack_digest_is_invented_in_defaults(self):
        values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
        self.assertTrue(all(image["digest"] == "" for image in values["images"].values()))
        self.assertEqual(values["corePack"]["digest"], "")
        self.assertEqual(str(values["corePack"]["version"]), "1.0.4")

    def test_digest_path_requires_full_manifest_digest_and_preserves_tag_fallback(self):
        source = (ROOT / "charts/attune/templates/_helpers.tpl").read_text()
        self.assertIn('regexMatch "^sha256:[0-9a-f]{64}$" $image.digest', source)
        self.assertIn('printf "%s@%s" $name $image.digest', source)
        self.assertIn('printf "%s:%s" $name $tag', source)
        self.assertIn('fail "images.*.digest', source)


if __name__ == "__main__":
    unittest.main()
