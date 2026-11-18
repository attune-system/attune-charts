#!/usr/bin/env python3
"""Render-only execution-host security contracts; synthetic pins are not images.

Packaged capability and rollout/custody behavior still require real integration
validation. These fixtures do not attest image contents or deploy a cluster.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

import yaml

CHART = Path(__file__).resolve().parent.parent / "charts" / "attune"
OLD_DIGEST = "sha256:24346320bee236e86e256a34f666359bf8c6c2a2db1c8c63c89060788e98ed4f"


def fixture():
    return {
        "security": {"existingSecret": "cp-runtime-fixture"},
        "workloadLaunch": {"apiUrl": "https://cp.example.invalid/",
                           "agentImage": {"digest": "sha256:" + "a" * 64}},
        "actionWorkers": [{"name": "actions", "image": "example.invalid/host@sha256:" + "b" * 64,
                           "enrollmentSecret": {"name": "action-enrollment"}}],
        "sensorWorkers": [{"name": "sensors", "image": "example.invalid/host@sha256:" + "b" * 64,
                           "enrollmentSecret": {"name": "sensor-enrollment"}}],
    }


def render(values):
    with tempfile.TemporaryDirectory(prefix="attune-host-chart-") as directory:
        path = Path(directory) / "values.yaml"
        path.write_text(yaml.safe_dump(values))
        return subprocess.run(["helm", "template", "host-test", str(CHART), "-f", str(path)],
                              capture_output=True, text=True, check=False)


def documents(values):
    result = render(values)
    if result.returncode:
        raise AssertionError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def hosts(items):
    return [item for item in items if item.get("kind") == "Deployment"
            and item["metadata"]["labels"].get("app.kubernetes.io/component", "").startswith(
                ("action-worker-", "sensor-worker-"))]


class HostContractTests(unittest.TestCase):
    def test_authority_mounts_and_credential_scope(self):
        items = documents(fixture())
        deployments = hosts(items)
        self.assertEqual(len(deployments), 2)
        seen_secrets, seen_claims = set(), set()
        for deployment in deployments:
            pod = deployment["spec"]["template"]["spec"]
            self.assertFalse(pod["automountServiceAccountToken"])
            self.assertFalse(pod.get("hostPID", False))
            self.assertFalse(pod.get("hostIPC", False))
            self.assertFalse(pod.get("hostNetwork", False))
            self.assertEqual([item["name"] for item in pod["initContainers"]], ["init-agent"])
            main = pod["containers"][0]
            env = {item["name"]: item for item in main["env"]}
            self.assertEqual(set(env), {"ATTUNE_API_URL", "ATTUNE_WORKLOAD_ENROLLMENT_TOKEN",
                                      "ATTUNE_WORKLOAD_CUSTODY_DIR", "SSL_CERT_FILE", "HOME", "TMPDIR", "RUST_LOG"})
            self.assertFalse(main.get("envFrom"))
            self.assertEqual(env["ATTUNE_WORKLOAD_CUSTODY_DIR"]["value"], "/var/lib/attune/custody/host")
            secret = env["ATTUNE_WORKLOAD_ENROLLMENT_TOKEN"]["valueFrom"]["secretKeyRef"]
            self.assertNotEqual(secret["name"], "cp-runtime-fixture")
            self.assertNotIn(secret["name"], seen_secrets)
            seen_secrets.add(secret["name"])
            self.assertEqual(secret["key"], "token")
            self.assertEqual({volume["name"] for volume in pod["volumes"]}, {"agent-bin", "custody", "scratch"})
            self.assertFalse(any("hostPath" in volume for volume in pod["volumes"]))
            claim = next(volume["persistentVolumeClaim"]["claimName"] for volume in pod["volumes"] if volume["name"] == "custody")
            self.assertNotIn(claim, seen_claims)
            seen_claims.add(claim)
            for container in [*pod["initContainers"], *pod["containers"]]:
                context = container["securityContext"]
                self.assertFalse(context["allowPrivilegeEscalation"])
                self.assertTrue(context["readOnlyRootFilesystem"])
                self.assertEqual(context["capabilities"], {"drop": ["ALL"]})
            mounts = {mount["name"]: mount for mount in main["volumeMounts"]}
            self.assertTrue(mounts["agent-bin"]["readOnly"])
            self.assertEqual(mounts["custody"]["mountPath"], "/var/lib/attune/custody")

    def test_rollout_and_retained_custody_are_singleton(self):
        items = documents(fixture())
        for deployment in hosts(items):
            self.assertEqual(deployment["spec"]["replicas"], 1)
            self.assertEqual(deployment["spec"]["strategy"], {"type": "Recreate"})
            self.assertEqual(deployment["spec"]["progressDeadlineSeconds"], 600)
            self.assertGreaterEqual(deployment["spec"]["template"]["spec"]["terminationGracePeriodSeconds"], 120)
        claims = [item for item in items if item.get("kind") == "PersistentVolumeClaim"
                  and item["metadata"]["labels"].get("app.kubernetes.io/component", "").startswith(("action-worker-", "sensor-worker-"))]
        self.assertEqual(len(claims), 2)
        by_name = {claim["metadata"]["name"]: claim for claim in claims}
        references = set()
        for deployment in hosts(items):
            pod = deployment["spec"]["template"]["spec"]
            name = next(v["persistentVolumeClaim"]["claimName"] for v in pod["volumes"] if v["name"] == "custody")
            self.assertNotIn(name, references)
            references.add(name)
            self.assertEqual(by_name[name]["metadata"]["labels"]["app.kubernetes.io/component"],
                             deployment["metadata"]["labels"]["app.kubernetes.io/component"])
        self.assertEqual(references, set(by_name))
        for claim in claims:
            self.assertEqual(claim["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
            self.assertFalse(claim["metadata"].get("ownerReferences"))
            self.assertEqual(claim["spec"]["accessModes"], ["ReadWriteOnce"])

    def test_replicas_shared_enrollment_and_shared_pvc_are_rejected(self):
        for value in [0, 2]:
            values = fixture(); values["actionWorkers"][0]["replicas"] = value
            self.assertNotEqual(render(values).returncode, 0)
        values = fixture(); values["sensorWorkers"][0]["enrollmentSecret"]["name"] = "action-enrollment"
        self.assertIn("unique enrollment", render(values).stderr)
        values = fixture()
        for role in ["actionWorkers", "sensorWorkers"]:
            values[role][0]["custody"] = {"existingClaim": "shared-custody"}
        self.assertIn("unique custody", render(values).stderr)
        values = fixture(); values["actionWorkers"][0]["stopGracePeriod"] = 45
        self.assertNotEqual(render(values).returncode, 0)

    def test_old_image_and_missing_prerequisites_are_rejected(self):
        self.assertNotEqual(render({"security": {"existingSecret": "cp-runtime-fixture"}}).returncode, 0)
        for digest in ["", OLD_DIGEST, "sha256:invalid"]:
            values = fixture(); values["workloadLaunch"]["agentImage"]["digest"] = digest
            self.assertNotEqual(render(values).returncode, 0)
        values = fixture(); values["workloadLaunch"]["verified"] = True
        self.assertNotEqual(render(values).returncode, 0)
        values = fixture(); values["actionWorkers"][0]["enrollmentSecret"]["name"] = ""
        self.assertNotEqual(render(values).returncode, 0)

    def test_https_origin_and_removed_legacy_settings(self):
        for url in ["http://cp.example.invalid/", "https://user:password@cp.example.invalid/",
                    "https://cp.example.invalid/?token=secret", "https://cp.example.invalid/api/v1"]:
            values = fixture(); values["workloadLaunch"]["apiUrl"] = url
            self.assertNotEqual(render(values).returncode, 0)
        for name, value in [("runtimes", ["python"]), ("passthroughEnv", ["JWT_SECRET"]),
                            ("maxDatabaseConnections", 5), ("allowInsecureNotifierWs", True),
                            ("podSecurityContext", {"fsGroup": 2000}),
                            ("containerSecurityContext", {"runAsUser": 0})]:
            values = fixture(); values["actionWorkers"][0][name] = value
            self.assertNotEqual(render(values).returncode, 0)
        values = fixture(); values["sensorWorkers"][0]["env"] = [{"name": "ATTUNE_CONFIG", "value": "/shared/config.yaml"}]
        self.assertNotEqual(render(values).returncode, 0)

    def test_storage_modes_cannot_add_host_pack_runtime_or_artifact_mounts(self):
        for mode in ["sharedVolume", "object"]:
            for local in ["emptyDir", "genericEphemeralVolume"]:
                if mode == "sharedVolume" and local != "emptyDir":
                    continue
                values = fixture()
                values["storage"] = {"mode": mode, "local": {"mode": local},
                                     "object": {"bucket": "fixture", "region": "us-east-1"}}
                for deployment in hosts(documents(values)):
                    pod = deployment["spec"]["template"]["spec"]
                    self.assertEqual({v["name"] for v in pod["volumes"]}, {"agent-bin", "custody", "scratch"})
                    self.assertTrue(any("persistentVolumeClaim" in v for v in pod["volumes"]))

    def test_generator_requires_real_contract_inputs_and_never_mints_enrollment(self):
        generator = CHART.parent.parent / "scripts/generate-attune-setup.sh"
        args = ["--workload-api-url", "https://cp.example.invalid/",
                "--workload-agent-digest", "sha256:" + "a" * 64,
                "--action-enrollment-secret", "action-enrollment",
                "--sensor-enrollment-secret", "sensor-enrollment"]
        with tempfile.TemporaryDirectory(prefix="attune-host-setup-") as directory:
            environment = {"PATH": os.environ["PATH"]}
            missing = subprocess.run([str(generator), "--output-dir", directory],
                                     env=environment, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(missing.returncode, 0)
            self.assertFalse((Path(directory) / "credentials.state").exists())
            subprocess.run([str(generator), *args, "--output-dir", directory],
                           env=environment, check=True, capture_output=True, text=True, timeout=30)
            values = yaml.safe_load((Path(directory) / "values.yaml").read_text())
            self.assertEqual(values["workloadLaunch"]["agentImage"]["digest"], "sha256:" + "a" * 64)
            self.assertEqual(values["actionWorkers"][0]["enrollmentSecret"]["name"], "action-enrollment")
            self.assertEqual(values["sensorWorkers"][0]["enrollmentSecret"]["name"], "sensor-enrollment")
            secrets = list(yaml.safe_load_all((Path(directory) / "secrets.yaml").read_text()))
            self.assertFalse(any(d["metadata"]["name"] in {"action-enrollment", "sensor-enrollment"} for d in secrets))
            self.assertEqual(len(hosts(documents(values))), 2)

    def test_probe_is_minimal_offline_and_checks_exact_protocol(self):
        items = documents(fixture())
        for deployment in hosts(items):
            script = deployment["spec"]["template"]["spec"]["initContainers"][0]["args"][0]
            self.assertIn("env -i PATH=", script)
            self.assertIn("--workload-host-contract", script)
            self.assertIn("for binary in attune-agent attune-sensor-agent", script)
            self.assertIn("cmp -s", script)
            self.assertIn("ca-certificates.crt", script)
            self.assertNotIn("curl", script)
            self.assertNotIn("wget", script)
            self.assertNotIn("DB_", script)
            self.assertNotIn("JWT", script)


if __name__ == "__main__":
    unittest.main()
