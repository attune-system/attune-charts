#!/usr/bin/env python3
"""Verify worker Secret selection and child-environment configuration.

Run with Python 3, PyYAML, and Helm on PATH:
    python3 scripts/test-worker-environments.py
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parent.parent / "charts" / "attune"
SERVICE_KEYS = {
    "worker": {
        "ATTUNE__DATABASE__URL", "ATTUNE__MESSAGE_QUEUE__URL",
        "ATTUNE__SECURITY__JWT_SECRET", "ATTUNE__SECURITY__ENCRYPTION_KEY",
    },
    "sensor": {
        "ATTUNE__DATABASE__URL", "ATTUNE__MESSAGE_QUEUE__URL",
        "ATTUNE__SECURITY__JWT_SECRET",
    },
}
DATABASE_KEYS = {"DB_HOST", "DB_PORT", "DB_USER", "DB_PASSWORD", "DB_NAME", "DB_SCHEMA", "PGSSLMODE"}


def render(overrides=None, *settings):
    with tempfile.TemporaryDirectory(prefix="attune-worker-environment-") as directory:
        values = Path(directory) / "values.yaml"
        values.write_text(yaml.safe_dump(overrides or {}))
        command = ["helm", "template", "environment-test", str(CHART),
                   "--set", "security.existingSecret=runtime-test", "--values", str(values)]
        for setting in settings:
            command.extend(["--set", setting])
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        return [document for document in yaml.safe_load_all(result.stdout) if document]


def worker_pods(documents):
    return [document["spec"]["template"]["spec"] for document in documents
            if document.get("kind") == "Deployment"
            and document["metadata"]["labels"].get("app.kubernetes.io/component", "").startswith(
                ("action-worker-", "sensor-worker-"))]


def secret_keys(container):
    return {entry["valueFrom"]["secretKeyRef"]["key"] for entry in container.get("env", [])
            if "secretKeyRef" in entry.get("valueFrom", {})}


class WorkerEnvironmentTests(unittest.TestCase):
    def test_default_pools_import_only_required_service_and_init_credentials(self):
        self.check_pools(render())
        self.check_pools(render(None, "database.postgresql.enabled=false", "rabbitmq.provisioning.enabled=true",
                                "rabbitmq.admin.existingSecret=broker-admin-test"))
        self.check_pools(render(None, "storage.mode=object", "storage.object.bucket=environment-test",
                                "storage.object.region=us-east-1", "storage.object.endpoint=https://storage.example.invalid"))

    def check_pools(self, documents):
        pods = worker_pods(documents)
        self.assertEqual(len(pods), 2)
        for pod in pods:
            for container in pod["containers"]:
                self.assertNotIn("envFrom", container)
                self.assertEqual(secret_keys(container), SERVICE_KEYS[container["name"]])
            for container in pod["initContainers"]:
                self.assertNotIn("envFrom", container)
                expected = {
                    "wait-for-schema": DATABASE_KEYS,
                    "wait-for-rabbitmq-credentials": {"RABBITMQ_USER", "RABBITMQ_PASSWORD"},
                }.get(container["name"], set())
                if container["name"] == "wait-for-schema" and any(entry["name"] == "DB_HOST" and "value" in entry for entry in container["env"]):
                    expected = DATABASE_KEYS - {"DB_HOST"}
                self.assertEqual(secret_keys(container), expected)
                if container["name"] == "wait-for-schema":
                    ssl = next(entry for entry in container["env"] if entry["name"] == "PGSSLMODE")
                    self.assertTrue(ssl["valueFrom"]["secretKeyRef"]["optional"])

    def test_passthrough_names_are_rendered_per_pool_without_importing_extra_secrets(self):
        documents = render({
            "actionWorkers": [{"name": "actions", "image": "example.invalid/actions:test",
                               "passthroughEnv": ["HTTPS_PROXY", "SSL_CERT_FILE"]}],
            "sensorWorkers": [{"name": "sensors", "image": "example.invalid/sensors:test",
                               "passthroughEnv": ["NO_PROXY"]}],
        })
        for pod in worker_pods(documents):
            container = pod["containers"][0]
            role = container["name"]
            name = f"ATTUNE__{'WORKER' if role == 'worker' else 'SENSOR'}__PASSTHROUGH_ENV"
            entry = next(entry for entry in container["env"] if entry["name"] == name)
            self.assertEqual(entry["value"], "HTTPS_PROXY,SSL_CERT_FILE" if role == "worker" else "NO_PROXY")
            self.assertEqual(secret_keys(container), SERVICE_KEYS[role])

    def test_invalid_and_reserved_passthrough_names_fail_schema_validation(self):
        for names in [["ATTUNE_API_TOKEN"], ["attune__security__jwt_secret"], ["HTTP_*"], [""], ["HTTP_PROXY", "HTTP_PROXY"]]:
            for role in ["actionWorkers", "sensorWorkers"]:
                with self.subTest(names=names, role=role), self.assertRaises(subprocess.CalledProcessError):
                    render({role: [{"name": "invalid", "image": "example.invalid/runtime:test",
                                    "passthroughEnv": names}]})

    def test_postgresql_cutover_preserves_mutation_host_without_restoring_broad_imports(self):
        documents = render(None,
                           "database.postgresql.enabled=true",
                           "database.postgresql.majorUpgradePolicy=refuse",
                           "database.postgresql.majorUpgradeStage=complete")
        for pod in worker_pods(documents):
            schema = next(container for container in pod["initContainers"] if container["name"] == "wait-for-schema")
            host = next(entry for entry in schema["env"] if entry["name"] == "DB_HOST")
            self.assertIn("value", host)
            self.assertTrue(host["value"].endswith("-postgresql-maintenance"))
            self.assertEqual(secret_keys(schema), DATABASE_KEYS - {"DB_HOST"})
            self.assertNotIn("envFrom", schema)

    def test_rendered_broker_probe_authenticates_after_a_rejected_attempt(self):
        pod = worker_pods(render(None, "rabbitmq.provisioning.enabled=true",
                                 "rabbitmq.admin.existingSecret=broker-admin-test"))[0]
        probe = next(container for container in pod["initContainers"]
                     if container["name"] == "wait-for-rabbitmq-credentials")
        self.assertEqual(secret_keys(probe), {"RABBITMQ_USER", "RABBITMQ_PASSWORD"})
        with tempfile.TemporaryDirectory(prefix="attune-broker-environment-") as directory:
            script = Path(directory) / "probe.py"
            script.write_text(probe["args"][0])
            result = subprocess.run([sys.executable, str(CHART.parent.parent / "scripts" / "test-rabbitmq-amqp-probe.py"), str(script)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
