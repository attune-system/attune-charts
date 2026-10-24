#!/usr/bin/env python3
"""Offline publisher and Helm admission-order regressions. No cluster required."""
import importlib.util
import base64
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import yaml

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("admission", ROOT / "charts/attune/files/bootstrap-admission.py")
admission = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(admission)

READY = {"pack_publication": {"protocol_version": 1, "client_version": 1, "revision": "authenticated-pack-publication-1", "authorization": "registrar", "components": ["immutable_release", "atomic_deployment"]}}


class PublisherTests(unittest.TestCase):
    def test_callable_but_unversioned_client_is_rejected(self):
        publisher = SimpleNamespace(publish_core=mock.Mock())
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=mock.Mock()))
        with mock.patch.object(admission.importlib.util, "spec_from_file_location", return_value=spec), mock.patch.object(admission.importlib.util, "module_from_spec", return_value=publisher):
            with self.assertRaisesRegex(RuntimeError, "client version/revision"):
                admission.publish("http://api")
        publisher.publish_core.assert_not_called()

    def setUp(self):
        env = mock.patch.dict(os.environ, {"ATTUNE_API_URL":"http://api", "ATTUNE_CORE_PACK_VERSION":"1.0.4", "ATTUNE_CORE_PACK_DIGEST":"abc"}, clear=True)
        env.start()
        self.addCleanup(env.stop)

    def test_protocol_skew_denies_before_publication(self):
        for protocol in (None, 0, "1", True):
            ready = {"pack_publication": dict(READY["pack_publication"], protocol_version=protocol)}
            with self.subTest(protocol=protocol), mock.patch.object(admission, "get", return_value=ready), mock.patch.object(admission, "publish") as publish:
                with self.assertRaisesRegex(RuntimeError, "protocol 1"):
                    admission.run("publish")
                publish.assert_not_called()

    def test_publish_checks_exact_admitted_content_without_waiting_for_hosts(self):
        with mock.patch.object(admission, "get", side_effect=[READY, {"core":{"version":"1.0.4", "digest":"abc", "release_id":2, "policy_revision":3}}]) as get, mock.patch.object(admission, "publish") as publish:
            admission.run("publish")
        publish.assert_called_once_with("http://api")
        self.assertEqual([call.args[1] for call in get.call_args_list], ["/health/ready", "/health/bootstrap"])

    def test_failed_upgrade_is_not_hidden_and_performs_no_cleanup_mutation(self):
        with mock.patch.object(admission, "get", return_value=READY) as get, mock.patch.object(admission, "publish", side_effect=RuntimeError("admission denied")):
            with self.assertRaisesRegex(RuntimeError, "admission denied"):
                admission.run("publish")
        self.assertEqual([call.args[1] for call in get.call_args_list], ["/health/ready"])

    def test_wrong_digest_fails_even_if_old_publisher_reports_success(self):
        with mock.patch.object(admission, "get", side_effect=[READY, {"core":{"version":"1.0.4", "digest":"wrong", "release_id":2, "policy_revision":3}}]), mock.patch.object(admission, "publish"):
            with self.assertRaisesRegex(RuntimeError, "digest"):
                admission.run("publish")

    def test_content_wait_is_separate_and_has_no_registrar_or_publisher(self):
        with mock.patch.object(admission, "get", side_effect=[READY, {"status":"ready"}, {"core":{"version":"1.0.4", "digest":"abc", "release_id":2, "policy_revision":3}}]) as get, mock.patch.object(admission, "publish") as publish:
            admission.run("wait")
        publish.assert_not_called()
        self.assertEqual([call.args[1] for call in get.call_args_list], ["/health/ready", "/health/content", "/health/bootstrap"])

    def test_incomplete_component_set_authorization_and_client_skew_deny(self):
        for field, value in (("components", []), ("components", sorted(admission.COMPONENTS) + ["runtime_policy"]), ("components", [1]), ("authorization", "anonymous"), ("revision", "managed-pack-admission-1"), ("client_version", 0), ("client_version", True), ("protocol_version", True)):
            ready = {"pack_publication": dict(READY["pack_publication"], **{field: value})}
            with self.subTest(field=field), mock.patch.object(admission, "get", return_value=ready), mock.patch.object(admission, "publish") as publish:
                with self.assertRaisesRegex(RuntimeError, "component contract"):
                    admission.run("publish")
                publish.assert_not_called()

    def test_managed_runtime_gate_is_not_a_publication_prerequisite(self):
        admission.require_contract(dict(READY, bootstrap_admission={"enabled": False}))
        for contract in (None, [], "invalid"):
            with self.subTest(contract=contract), self.assertRaisesRegex(RuntimeError, "component contract"):
                admission.require_contract({"pack_publication": contract})
        with self.assertRaisesRegex(RuntimeError, "component contract"):
            admission.require_contract({"bootstrap_admission_protocol": 1, "bootstrap_admission": {"enabled": True}})

    def test_versioned_bundled_client_requires_exact_publication_components(self):
        for components in (None, frozenset(), frozenset(admission.COMPONENTS | {"runtime_policy"}), frozenset(admission.COMPONENTS)):
            publisher = SimpleNamespace(publish_core=mock.Mock(), BOOTSTRAP_CLIENT_VERSION=1,
                                        BOOTSTRAP_REVISION=admission.REVISION, BOOTSTRAP_COMPONENTS=components)
            spec = SimpleNamespace(loader=SimpleNamespace(exec_module=mock.Mock()))
            with self.subTest(components=components), mock.patch.object(admission.importlib.util, "spec_from_file_location", return_value=spec), mock.patch.object(admission.importlib.util, "module_from_spec", return_value=publisher):
                if components == admission.COMPONENTS:
                    admission.publish("http://api")
                    publisher.publish_core.assert_called_once_with("http://api", Path("/source/packs/core"))
                else:
                    with self.assertRaisesRegex(RuntimeError, "components mismatch"):
                        admission.publish("http://api")
                    publisher.publish_core.assert_not_called()

    def test_post_publication_requires_release_version_digest_and_policy(self):
        core = {"version": "1.0.4", "digest": "abc", "release_id": 2, "policy_revision": 3}
        for field in core:
            with self.subTest(field=field), mock.patch.object(admission, "get", side_effect=[READY, {"core": dict(core, **{field: None})}]), mock.patch.object(admission, "publish"):
                with self.assertRaisesRegex(RuntimeError, "active core release"):
                    admission.run("publish")

    def test_old_client_entrypoint_is_rejected_before_calling_main(self):
        old = SimpleNamespace(main=mock.Mock())
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=mock.Mock()))
        with mock.patch.object(admission.importlib.util, "spec_from_file_location", return_value=spec), mock.patch.object(admission.importlib.util, "module_from_spec", return_value=old):
            with self.assertRaisesRegex(RuntimeError, "publish_core"):
                admission.publish("http://api")
        old.main.assert_not_called()


class HelmTests(unittest.TestCase):
    def test_default_core_pins_select_the_canonical_source_release_without_fake_digest(self):
        values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
        self.assertEqual(values["corePack"]["version"], "1.0.4")
        self.assertEqual(values["images"]["initPacks"]["tag"], "core-" + values["corePack"]["version"])
        self.assertEqual(values["corePack"]["digest"], "")
        for path in (ROOT / "charts/attune/values.yaml", ROOT / "scripts/verify.sh"):
            self.assertNotIn("1.0.3", path.read_text())

    def test_helm_wait_all_regular_workloads_can_start_before_publication_hook(self):
        for mode in ("sharedVolume", "object"):
            command = ["helm", "template", "wait-dag", str(ROOT / "charts/attune"), "--set", "security.existingSecret=e-test", "--set", "mcp.enabled=true", "--set", f"storage.mode={mode}", "--set", "storage.object.bucket=e-test", "--set", "storage.object.region=us-east-1", "--set", "storage.object.endpoint=http://storage.invalid"]
            docs = [doc for doc in yaml.safe_load_all(subprocess.run(command, check=True, capture_output=True, text=True, timeout=30).stdout) if doc]
            workloads = [doc for doc in docs if doc["kind"] in ("Deployment", "StatefulSet", "DaemonSet", "Job")]
            components = set()
            for workload in workloads:
                component = workload["spec"]["template"]["metadata"].get("labels", {}).get("app.kubernetes.io/component", "")
                components.add(component)
                hook = workload["metadata"].get("annotations", {}).get("helm.sh/hook", "")
                if hook:
                    continue
                pod = workload["spec"]["template"]["spec"]
                # Helm --wait waits ordinary Pods before post-install hooks.
                # Check ALL init containers and probes, not just the web Pod.
                readiness = [container.get("readinessProbe", {}) for container in pod.get("containers", [])]
                startup = yaml.safe_dump(pod.get("initContainers", []) + readiness)
                with self.subTest(mode=mode, workload=workload["metadata"]["name"]):
                    for forbidden in ("/health/content", "/health/bootstrap", "content-ready", "bootstrap-admission.py"):
                        self.assertNotIn(forbidden, startup)
            self.assertTrue({"api", "executor", "web", "mcp", "notifier", "supervisor"}.issubset(components), components)
            self.assertTrue(any("action-worker" in component for component in components), components)
            self.assertTrue(any("sensor-worker" in component for component in components), components)
            publication = next(doc for doc in workloads if doc["metadata"]["labels"].get("app.kubernetes.io/component") == "init-packs")
            self.assertEqual(publication["metadata"]["annotations"]["helm.sh/hook"], "post-install")
            self.assertEqual(publication["spec"]["template"]["spec"]["containers"][0]["args"], ["publish"])

    def test_cutover_lookup_fixture_renders_read_only_preflight_and_retains_migration_mounts(self):
        with tempfile.TemporaryDirectory(prefix="e-bootstrap-chart-") as directory:
            chart = Path(directory) / "attune"
            shutil.copytree(ROOT / "charts/attune", chart)
            # Only lookup responses are mocked in this private rendering fixture.
            # No cluster, production files or ordinary template logic is modified.
            for relative in ("templates/_helpers.tpl", "templates/jobs.yaml"):
                path = chart / relative
                source = path.read_text()
                for suffix in ("packs", "runtime-envs", "artifacts"):
                    expression = 'lookup "v1" "PersistentVolumeClaim" .Release.Namespace (printf "%s-' + suffix + '" (include "attune.fullname" .))'
                    source = source.replace(expression, 'dict "metadata" (dict "name" "fixture-' + suffix + '")')
                path.write_text(source)
            command = ["helm", "template", "bootstrap-test", str(chart), "--is-upgrade", "--set", "security.existingSecret=e-test", "--set", "storage.mode=object", "--set", "storage.object.migrateFromSharedVolume=true", "--set", "storage.object.bucket=e-test", "--set", "storage.object.region=us-east-1", "--set", "storage.object.endpoint=http://storage.invalid"]
            result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
            docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
            preflight = next(doc for doc in docs if doc["kind"] == "Job" and doc["metadata"]["labels"].get("app.kubernetes.io/component") == "upgrade-pack-releases")
            pod = preflight["spec"]["template"]["spec"]
            self.assertNotIn("volumes", pod)
            values = yaml.safe_load((ROOT / "charts/attune/values.yaml").read_text())
            image = values["database"]["postgresql"]["image"]
            self.assertEqual(pod["containers"][0]["image"], image["repository"] + ":" + image["tag"])
            script = pod["containers"][0]["args"][0]
            self.assertIn("BEGIN READ ONLY;", script)
            self.assertIn("pr.object_key IS NULL AND pr.archive_path IS NULL", script)
            self.assertNotIn("pack_runtime_policy", script)
            self.assertNotIn("API readmission", script)
            subprocess.run(["/bin/sh", "-n"], input=script, text=True, capture_output=True, check=True)
            migration = next(doc for doc in docs if doc["kind"] == "Job" and doc["metadata"]["labels"].get("app.kubernetes.io/component") == "migrate-storage")
            mounts = migration["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
            self.assertTrue({"legacy-packs", "legacy-artifacts"}.issubset({mount["name"] for mount in mounts}))

    def test_cutover_preflight_cannot_invoke_a_legacy_release_freezer(self):
        source = (ROOT / "charts/attune/templates/jobs.yaml").read_text()
        self.assertNotIn("--upgrade-pack-releases", source)
        self.assertNotIn("load_core_pack.py", source)
        self.assertIn("BEGIN READ ONLY;", source)
        self.assertIn('SET search_path TO :"schema", public;', source)
        body = source.split('              export PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=5\n', 1)[1].split('          envFrom:', 1)[0]
        script = '\n'.join(line[14:] for line in body.splitlines())
        subprocess.run(["/bin/sh", "-n"], input=script, text=True, check=True, capture_output=True)

    def test_both_modes_use_revision_api_and_post_api_hook_order(self):
        for mode in ("sharedVolume", "object"):
            for upgrade, required in ((False, False), (True, False), (True, True)):
                with self.subTest(mode=mode, upgrade=upgrade, required=required):
                    command = ["helm", "template", "bootstrap-test", str(ROOT / "charts/attune"), "--set", "security.existingSecret=e-test", "--set", f"storage.mode={mode}", "--set", f"corePack.requiredOnUpgrade={str(required).lower()}", "--set", "corePack.digest=" + "a" * 64, "--set", "storage.object.bucket=e-test", "--set", "storage.object.region=us-east-1", "--set", "storage.object.endpoint=http://storage.invalid"]
                    if upgrade:
                        command.append("--is-upgrade")
                    rendered = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30).stdout
                    docs = [doc for doc in yaml.safe_load_all(rendered) if doc]
                    job = next(doc for doc in docs if doc["kind"] == "Job" and doc["metadata"]["labels"].get("app.kubernetes.io/component") == "init-packs")
                    hook = job["metadata"].get("annotations", {}).get("helm.sh/hook")
                    self.assertEqual(hook, "post-upgrade" if upgrade and required else None if upgrade else "post-install")
                    pod = job["spec"]["template"]["spec"]
                    container = pod["containers"][0]
                    env = {item["name"]:item.get("value") for item in container["env"]}
                    self.assertEqual(env["ATTUNE_BOOTSTRAP_MODE"], "api")
                    self.assertEqual(env["ATTUNE_CORE_PACK_DIGEST"], "a" * 64)
                    self.assertEqual(env["ATTUNE_CORE_PACK_VERSION"], "1.0.4")
                    self.assertTrue(container["image"].endswith("/init-packs:core-1.0.4"))
                    self.assertTrue(env["ATTUNE_API_URL"].endswith("-api-r1:8080"))
                    self.assertEqual(container["args"], ["publish"])
                    self.assertNotIn("envFrom", container)
                    credential = next(item for item in container["env"] if item["name"] == "ATTUNE_BOOTSTRAP_TOKEN")
                    self.assertEqual(credential["valueFrom"]["secretKeyRef"]["key"], "ATTUNE_BOOTSTRAP_TOKEN")
                    self.assertFalse(any("persistentVolumeClaim" in volume for volume in pod["volumes"]))
                    self.assertNotIn(".attune-bootstrap-r", rendered)
                    content = next((doc for doc in docs if doc["kind"] == "Job" and doc["metadata"]["labels"].get("app.kubernetes.io/component") == "content-ready"), None)
                    if upgrade and not required:
                        self.assertIsNone(content, "optional reconciliation must not block Helm on a new core release")
                        continue
                    self.assertEqual(content["metadata"]["annotations"]["helm.sh/hook-weight"], "10")
                    self.assertEqual(content["spec"]["template"]["spec"]["containers"][0]["args"], ["wait"])
                    content_container = content["spec"]["template"]["spec"]["containers"][0]
                    self.assertEqual(content_container["image"], container["image"])
                    content_env = {item["name"]: item.get("value") for item in content_container["env"]}
                    self.assertEqual(content_env["ATTUNE_CORE_PACK_VERSION"], "1.0.4")
                    self.assertEqual(content_env["ATTUNE_CORE_PACK_DIGEST"], "a" * 64)
                    self.assertNotIn("envFrom", content["spec"]["template"]["spec"]["containers"][0])
                    api = next(doc for doc in docs if doc["kind"] == "Deployment" and doc["spec"]["template"]["metadata"]["labels"].get("app.kubernetes.io/component") == "api")
                    self.assertEqual(api["spec"]["template"]["spec"]["containers"][0]["readinessProbe"]["httpGet"]["path"], "/health/ready")
                    self.assertEqual(any("persistentVolumeClaim" in volume for volume in api["spec"]["template"]["spec"]["volumes"]), mode == "sharedVolume")
                    self.assertTrue(any(doc["kind"] == "Service" and doc["spec"].get("selector", {}).get("attune.dev/release-revision") == "1" for doc in docs))


class SetupTests(unittest.TestCase):
    def test_existing_token_is_isolated_and_missing_token_has_staged_guidance(self):
        for token in ("fixture-deployment-token", ""):
            with self.subTest(has_token=bool(token)), tempfile.TemporaryDirectory(prefix="attune-setup-token-") as directory:
                env = {key: value for key, value in os.environ.items() if not key.startswith("ATTUNE_SETUP_")}
                if token:
                    env["ATTUNE_SETUP_BOOTSTRAP_TOKEN"] = token
                result = subprocess.run(
                    [str(ROOT / "scripts/generate-attune-setup.sh"), "--database-mode", "bundled",
                     "--output-dir", directory], env=env, check=True, capture_output=True, text=True, timeout=30)
                output = Path(directory)
                secrets = list(yaml.safe_load_all((output / "secrets.yaml").read_text()))
                values = yaml.safe_load((output / "values.yaml").read_text())
                self.assertEqual(values["corePack"]["deploymentTokenSecret"], "attune-deployment")
                runtime = next(secret for secret in secrets if secret["metadata"]["name"] == "attune-runtime")
                self.assertNotIn("ATTUNE_BOOTSTRAP_TOKEN", runtime["data"])
                self.assertEqual((output / "secrets.yaml").stat().st_mode & 0o077, 0)
                if token:
                    deployment = next(secret for secret in secrets if secret["metadata"]["name"] == "attune-deployment")
                    self.assertEqual(base64.b64decode(deployment["data"]["ATTUNE_BOOTSTRAP_TOKEN"]).decode(), token)
                    for name in ("values.yaml", "credentials.state"):
                        self.assertNotIn(token, (output / name).read_text())
                        self.assertNotIn(base64.b64encode(token.encode()).decode(), (output / name).read_text())
                    self.assertNotIn(token, result.stdout + result.stderr)
                else:
                    self.assertFalse(any(secret["metadata"]["name"] == "attune-deployment" for secret in secrets))
                    self.assertIn("staged first-install procedure", result.stdout)


if __name__ == "__main__":
    unittest.main()
