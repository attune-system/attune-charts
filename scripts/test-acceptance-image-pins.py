"""Offline pin/render/package contracts; no image compatibility or live proof."""
from pathlib import Path
import hashlib
import subprocess
import tarfile
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parent.parent


class Pins(unittest.TestCase):
    def test_historical_published_provenance(self):
        record = yaml.safe_load((ROOT / "docs/published-images-0.11.0.json").read_text())
        self.assertEqual(record["release"], "0.11.0")
        self.assertEqual(record["source_revision"], "67b2f572a75f5057e1dd5978258fd7910d2564c9")
        self.assertEqual(len(record["images"]), 9)
        self.assertEqual(record["core_archive"]["sha256"], "82a032962e28cf288a77e23273202e021428550cd655ba2c7776f3a98281e638")
        self.assertNotEqual(record["core_archive"]["sha256"], record["images"]["init-packs"]["digest"].removeprefix("sha256:"))
        for published in record["images"].values():
            self.assertRegex(published["digest"], r"^sha256:[0-9a-f]{64}$")
            self.assertEqual(set(published["platforms"]), {"amd64", "arm64"})
            for platform in published["platforms"].values():
                self.assertEqual(platform["source_revision"], record["source_revision"])
                self.assertRegex(platform["digest"], r"^sha256:[0-9a-f]{64}$")
                self.assertRegex(platform["config_digest"], r"^sha256:[0-9a-f]{64}$")

    def test_current_release_selection(self):
        values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
        record = yaml.safe_load((ROOT / "docs/published-images-0.11.0.json").read_text())
        current = values["global"]["imageTag"]
        for key, image in values["images"].items():
            published = record["images"][image["repository"].split("/")[-1]]
            if current == record["release"] or key == "initPacks":
                self.assertEqual(image["digest"], published["digest"], key)
            else:
                # The updater advances tags and clears stale platform digests;
                # the historical snapshot must not block that generated PR.
                self.assertGreater(tuple(map(int, current.split("."))),
                                   tuple(map(int, record["release"].split("."))))
                self.assertEqual(image["digest"], "", key)
        self.assertEqual(values["corePack"]["digest"], record["core_archive"]["sha256"])
        self.assertEqual(str(values["corePack"]["version"]), "1.0.7")

    def test_platform_override_does_not_retag_core_publication_or_wait(self):
        values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
        rendered = subprocess.run(
            ["helm", "template", "pins", str(ROOT / "charts/attune"),
             "--set", "security.existingSecret=fixture-runtime",
             "--set-string", "global.imageTag=fixture-platform"],
            check=True, capture_output=True, text=True, timeout=30).stdout
        documents = [doc for doc in yaml.safe_load_all(rendered) if doc]
        jobs = {doc["metadata"]["labels"].get("app.kubernetes.io/component"):
                doc["spec"]["template"]["spec"]["containers"][0]
                for doc in documents if doc["kind"] == "Job"}
        for component in ("init-packs", "content-ready"):
            container = jobs[component]
            self.assertEqual(container["image"], "ghcr.io/attune-system/attune/init-packs@" +
                             values["images"]["initPacks"]["digest"])
            env = {item["name"]: item.get("value") for item in container["env"]}
            self.assertEqual(env["ATTUNE_CORE_PACK_VERSION"], "1.0.7")
            self.assertEqual(env["ATTUNE_CORE_PACK_DIGEST"], values["corePack"]["digest"])
        api = next(doc for doc in documents if doc["kind"] == "Deployment"
                   and doc["spec"]["template"]["metadata"]["labels"].get("app.kubernetes.io/component") == "api")
        self.assertEqual(api["spec"]["template"]["spec"]["containers"][0]["image"],
                         "ghcr.io/attune-system/attune/api" +
                         ("@" + values["images"]["api"]["digest"]
                          if values["images"]["api"]["digest"]
                          else ":fixture-platform"))

    def test_published_agent_is_injected_in_both_storage_modes(self):
        values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
        agent = "ghcr.io/attune-system/attune/agent" + ("@" + values["images"]["agent"]["digest"]
                 if values["images"]["agent"]["digest"] else ":" + values["global"]["imageTag"])
        for mode in ("sharedVolume", "object"):
            rendered = subprocess.run(
                ["helm", "template", "published", str(ROOT / "charts/attune"),
                 "--set", "security.existingSecret=fixture-runtime", "--set", "storage.mode=" + mode,
                 "--set", "storage.object.bucket=fixture", "--set", "storage.object.region=us-east-1",
                 "--set", "storage.object.endpoint=http://storage.invalid"],
                check=True, capture_output=True, text=True, timeout=30).stdout
            pools = [doc for doc in yaml.safe_load_all(rendered) if doc and doc["kind"] == "Deployment"
                     and doc["metadata"]["labels"].get("app.kubernetes.io/component", "").startswith(
                         ("action-worker-", "sensor-worker-"))]
            self.assertEqual(len(pools), 2)
            for pool in pools:
                init = next(c for c in pool["spec"]["template"]["spec"]["initContainers"]
                            if c["name"] == "init-agent")
                self.assertEqual(init["image"], agent)

    def test_verify_script_image_expectation_preserves_digest_precedence(self):
        # Execute the owning full verifier's expectation code, not a test copy.
        script = (ROOT / "scripts/verify.sh").read_text().split("<<'PYIMAGE'\n", 1)[1].split("\nPYIMAGE", 1)[0]
        values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
        image = values["images"]["initPacks"]
        published = image["digest"]
        with tempfile.TemporaryDirectory(prefix="attune-verifier-image-") as directory:
            path = Path(directory) / "values.yaml"
            for digest, tag, expected in ((published, "ignored", "@" + published),
                                          ("", "core-1.0.7", ":core-1.0.7"),
                                          ("", "", ":" + values["global"]["imageTag"])):
                with self.subTest(digest=digest, tag=tag):
                    image.update(digest=digest, tag=tag)
                    path.write_text(yaml.safe_dump(values))
                    actual = subprocess.run(["python3", "-", str(path)], input=script,
                                            text=True, capture_output=True, check=True).stdout.strip()
                    self.assertEqual(actual, "ghcr.io/attune-system/attune/init-packs" + expected)

    def test_staged_core_pins_preserve_explicit_injected_agent_override(self):
        # Deliberately synthetic, offline-only image bytes; this is selection
        # plumbing, never evidence of a published or compatible agent image.
        agent_digest = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory(prefix="attune-staged-pins-") as directory:
            values_path = Path(directory) / "values.yaml"
            for mode in ("sharedVolume", "object"):
                for upgrade, version, required in ((True, "1.0.5", False),
                                                    (True, "1.0.7", False),
                                                    (True, "1.0.7", True),
                                                    (False, "1.0.7", False)):
                    with self.subTest(mode=mode, upgrade=upgrade, core=version, required=required):
                        pack_image_digest = "sha256:" + "c" * 64
                        archive_digest = "a" * 64
                        values_path.write_text(yaml.safe_dump({
                            "security": {"existingSecret": "fixture-runtime"},
                            "storage": {"mode": mode, "object": {"bucket": "fixture-bucket",
                                        "region": "us-east-1", "endpoint": "https://storage.invalid"}},
                            "images": {"agent": {"repository": "fixture-agent",
                                                  "digest": agent_digest},
                                       "initPacks": {"tag": "core-" + version, "digest": pack_image_digest}},
                            "corePack": {"version": version, "digest": archive_digest,
                                         "requiredOnUpgrade": required},
                        }))
                        command = ["helm", "template", "staged", str(ROOT / "charts/attune"),
                                   "--values", str(values_path)]
                        if upgrade:
                            command.append("--is-upgrade")
                        rendered = subprocess.run(command, check=True, capture_output=True,
                                                  text=True, timeout=30).stdout
                        docs = [doc for doc in yaml.safe_load_all(rendered) if doc]
                        pools = [doc for doc in docs if doc["kind"] == "Deployment"
                                 and doc["metadata"]["labels"].get("app.kubernetes.io/component", "").startswith(
                                     ("action-worker-", "sensor-worker-"))]
                        self.assertEqual(len(pools), 2)
                        for pool in pools:
                            pod = pool["spec"]["template"]["spec"]
                            agent = next(item for item in pod["initContainers"] if item["name"] == "init-agent")
                            self.assertEqual(agent["image"], "ghcr.io/attune-system/fixture-agent@" + agent_digest)
                            self.assertEqual(pod["containers"][0]["command"][0], "/opt/attune/agent/attune-agent"
                                             if pod["containers"][0]["name"] == "worker"
                                             else "/opt/attune/agent/attune-sensor-agent")
                        job = next(doc for doc in docs if doc["kind"] == "Job"
                                   and doc["metadata"]["labels"].get("app.kubernetes.io/component") == "init-packs")
                        expected_hook = "post-upgrade" if upgrade and required else None if upgrade else "post-install"
                        self.assertEqual(job["metadata"].get("annotations", {}).get("helm.sh/hook"), expected_hook)
                        container = job["spec"]["template"]["spec"]["containers"][0]
                        self.assertEqual(container["image"], "ghcr.io/attune-system/attune/init-packs@" + pack_image_digest)
                        env = {entry["name"]: entry.get("value") for entry in container["env"]}
                        self.assertEqual(env["ATTUNE_CORE_PACK_VERSION"], version)
                        self.assertEqual(env["ATTUNE_CORE_PACK_DIGEST"], archive_digest)
                        self.assertEqual(env["ATTUNE_BOOTSTRAP_MODE"], "api")

    def test_packaged_bytes_match_source_and_index_digest(self):
        chart_dir = ROOT / "charts/attune"
        chart = yaml.safe_load((chart_dir / "Chart.yaml").read_text())
        archive = ROOT / "packages" / f"attune-{chart['version']}.tgz"
        index = yaml.safe_load((ROOT / "index.yaml").read_text())
        entry, = [entry for entry in index["entries"]["attune"]
                  if entry["version"] == chart["version"]]
        self.assertEqual(entry["appVersion"], chart["appVersion"])
        self.assertEqual(entry["urls"], [f"packages/{archive.name}"])
        self.assertEqual(entry["digest"], hashlib.sha256(archive.read_bytes()).hexdigest())
        with tarfile.open(archive) as package:
            committed = {member.name: package.extractfile(member).read()
                         for member in package.getmembers() if member.isfile()}
        # Helm may normalize chart metadata; compare its complete packaged file
        # bytes against a fresh Helm package, not just selected pin fields.
        with tempfile.TemporaryDirectory(prefix="attune-pin-package-") as directory:
            subprocess.run(["helm", "package", str(chart_dir), "--destination", directory],
                           check=True, capture_output=True, text=True, timeout=30)
            with tarfile.open(Path(directory) / archive.name) as package:
                fresh = {member.name: package.extractfile(member).read()
                         for member in package.getmembers() if member.isfile()}
        self.assertEqual(committed, fresh)

    def test_digest_path_requires_full_manifest_digest_and_preserves_tag_fallback(self):
        source = (ROOT / "charts/attune/templates/_helpers.tpl").read_text()
        self.assertIn('regexMatch "^sha256:[0-9a-f]{64}$" $image.digest', source)
        self.assertIn('printf "%s@%s" $name $image.digest', source)
        self.assertIn('printf "%s:%s" $name $tag', source)
        self.assertIn('fail "images.*.digest', source)


if __name__ == "__main__":
    unittest.main()
