#!/usr/bin/env python3
"""Check native database defaults, generated manifests, and upgrade refusal."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CHART = ROOT / "charts" / "attune"
POSTGRES_IMAGE = "postgres:18.6-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873"
CNPG_IMAGE = "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:79be0d10e78b7ac4520cf6c5db199a8bb7f6de53b3229f47e90cab5865528a0d"


def render(upgrade=False, external=False, cutover=False):
    command = ["helm", "template", "native-test", str(CHART),
               "--set", "security.existingSecret=native-runtime",
               "--set", "database.postgresql.enabled=true",
               "--set", "database.postgresql.provisioning.enabled=true",
               "--set", "database.postgresql.admin.existingSecret=native-admin"]
    if upgrade:
        command.append("--is-upgrade")
    if external:
        command.extend(["--set", "database.postgresql.enabled=false",
                        "--set", "database.postgresql.provisioning.enabled=false",
                        "--set", "database.host=external.example.invalid"])
    if cutover:
        command.extend(["--set", "database.postgresql.majorUpgradePolicy=startFresh",
                        "--set", "database.postgresql.majorUpgradeStage=cutover"])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def preflight(documents):
    return next(doc for doc in documents if doc.get("kind") == "Job"
                and doc["metadata"]["labels"]["app.kubernetes.io/component"] == "database-preflight")


class NativePostgresqlTests(unittest.TestCase):
    def test_bundled_image_and_provisioner_are_native(self):
        documents = render()
        database = next(doc for doc in documents if doc.get("kind") == "StatefulSet"
                        and doc["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/component"] == "postgresql")
        self.assertEqual(database["spec"]["template"]["spec"]["containers"][0]["image"], POSTGRES_IMAGE)
        provisioner = next(doc for doc in documents if doc.get("kind") == "Job"
                          and doc["metadata"]["labels"]["app.kubernetes.io/component"] == "provision-postgresql")
        script = provisioner["spec"]["template"]["spec"]["containers"][0]["args"][0]
        self.assertNotIn("timescaledb", script)
        self.assertIn("pgcrypto", script)
        self.assertIn("uuid-ossp", script)
        self.assertFalse(any(doc.get("kind") == "Job" and
                             doc["metadata"]["labels"].get("app.kubernetes.io/component") == "database-preflight"
                             for doc in documents))

    def test_upgrade_guard_precedes_mutations_in_every_database_mode(self):
        for external, cutover in [(False, False), (True, False), (False, True)]:
            with self.subTest(external=external, cutover=cutover):
                documents = render(upgrade=True, external=external, cutover=cutover)
                guard = preflight(documents)
                annotations = guard["metadata"]["annotations"]
                self.assertEqual(annotations["helm.sh/hook"], "pre-upgrade")
                self.assertEqual(annotations["helm.sh/hook-weight"], "-60")
                self.assertEqual(guard["spec"]["activeDeadlineSeconds"], 180)
                self.assertEqual(guard["spec"]["backoffLimit"], 0)
                container = guard["spec"]["template"]["spec"]["containers"][0]
                self.assertEqual(container["image"], POSTGRES_IMAGE)
                for doc in documents:
                    hooks = doc["metadata"].get("annotations", {})
                    if hooks.get("helm.sh/hook") == "pre-upgrade" and doc != guard:
                        self.assertGreater(int(hooks.get("helm.sh/hook-weight", "0")), -60)

    def test_guard_accepts_native_and_refuses_timescale_old_versions_and_bad_results(self):
        script = preflight(render(upgrade=True))["spec"]["template"]["spec"]["containers"][0]["args"][0]
        with tempfile.TemporaryDirectory(prefix="native-preflight-") as directory:
            stub = Path(directory) / "psql"
            stub.write_text('#!/bin/sh\n[ "$PGOPTIONS" = "-c statement_timeout=10000 -c default_transaction_read_only=on" ] || exit 99\nprintf "%s\\n" "$PROBE_RESULT"\nexit "${PROBE_EXIT:-0}"\n')
            stub.chmod(0o700)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       DB_HOST="test-db", DB_PORT="5432", DB_USER="attune",
                       DB_PASSWORD="unused-test-password", DB_NAME="attune")
            env.pop("DATABASE_FALLBACK_HOST", None)
            for value, exit_code, accepted in [("16|f", "0", True), ("18|f", "0", True),
                                               ("16|t", "0", False), ("18|t", "0", False),
                                               ("15|f", "0", False), ("bad|f", "0", False),
                                               ("", "0", False), ("18|f", "2", False)]:
                with self.subTest(value=value, exit_code=exit_code):
                    result = subprocess.run(["/bin/sh", "-ec", script],
                                            env=dict(env, PROBE_RESULT=value, PROBE_EXIT=exit_code),
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                    if value.endswith("|t"):
                        self.assertIn("conversion is not supported", result.stderr)

    def test_bundled_guard_falls_back_only_on_connection_failure(self):
        script = preflight(render(upgrade=True))["spec"]["template"]["spec"]["containers"][0]["args"][0]
        with tempfile.TemporaryDirectory(prefix="native-fallback-") as directory:
            stub = Path(directory) / "psql"
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$PGHOST" >> "$PROBE_CALLS"\n[ "$PGHOST" != "missing-maintenance" ] || exit 2\nprintf "%s\\n" "$PROBE_RESULT"\n')
            stub.chmod(0o700)
            calls = Path(directory) / "calls"
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       DB_HOST="missing-maintenance", DATABASE_FALLBACK_HOST="ordinary-db",
                       DB_PORT="5432", DB_USER="attune", DB_PASSWORD="unused-test-password",
                       DB_NAME="attune", PROBE_CALLS=str(calls), PROBE_RESULT="18|f")
            result = subprocess.run(["/bin/sh", "-ec", script], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["missing-maintenance", "ordinary-db"])
            calls.unlink()
            result = subprocess.run(["/bin/sh", "-ec", script], env=dict(env, DB_HOST="ordinary-db", PROBE_RESULT="18|t"),
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls.read_text().splitlines(), ["ordinary-db"])

    def test_generated_cnpg_image_identity_and_extensions(self):
        with tempfile.TemporaryDirectory(prefix="native-cnpg-") as directory:
            subprocess.run([str(ROOT / "scripts/generate-attune-setup.sh"), "--output-dir", directory],
                           check=True, capture_output=True, text=True)
            catalog, cluster = list(yaml.safe_load_all((Path(directory) / "postgresql.yaml").read_text()))
            self.assertEqual(catalog["spec"]["images"], [{"major": 18, "image": CNPG_IMAGE}])
            self.assertEqual(cluster["metadata"]["name"], "attune-postgresql")
            self.assertEqual(cluster["spec"]["postgresUID"], 26)
            self.assertEqual(cluster["spec"]["postgresGID"], 102)
            self.assertTrue(cluster["spec"]["bootstrap"]["initdb"]["dataChecksums"])
            text = (Path(directory) / "postgresql.yaml").read_text()
            self.assertNotIn("timescaledb", text)
            self.assertNotIn("shared_preload_libraries", text)
            self.assertIn("pgcrypto", text)
            self.assertIn("uuid-ossp", text)

    def test_legacy_setup_is_refused_without_overwriting_files(self):
        with tempfile.TemporaryDirectory(prefix="native-legacy-") as directory:
            legacy = Path(directory) / "timescaledb.yaml"
            legacy.write_text("existing database manifest\n")
            values = Path(directory) / "values.yaml"
            values.write_text("existing values\n")
            result = subprocess.run([str(ROOT / "scripts/generate-attune-setup.sh"), "--output-dir", directory, "--force"],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("use a new output directory", result.stderr)
            self.assertEqual(legacy.read_text(), "existing database manifest\n")
            self.assertEqual(values.read_text(), "existing values\n")
            self.assertFalse((Path(directory) / "credentials.state").exists())


if __name__ == "__main__":
    unittest.main()
