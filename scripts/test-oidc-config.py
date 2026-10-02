#!/usr/bin/env python3
"""Verify rendered OIDC configuration and API-only credential delivery.

Run with Python 3, Docker, and Helm on PATH:
    python3 scripts/test-oidc-config.py
"""

import json
import subprocess
import unittest
from pathlib import Path

CHART = Path(__file__).resolve().parent.parent / "charts" / "attune"


def read_yaml(content: str, expression: str, all_documents: bool = False):
    result = subprocess.run(
        [
            "docker", "run", "--rm", "-i", "mikefarah/yq:4.47.2",
            "eval-all" if all_documents else "eval", "--no-doc", "-o=json", expression, "-",
        ],
        input=content, check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def render(*settings: str) -> list[dict]:
    command = ["helm", "template", "oidc-test", str(CHART)]
    for setting in ["security.existingSecret=runtime-test", *settings]:
        command.extend(["--set", setting])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return read_yaml(result.stdout, "[.]", all_documents=True)


def oidc_config(documents: list[dict]) -> dict:
    config = next(
        document["data"]["config.yaml"]
        for document in documents
        if document["kind"] == "ConfigMap" and "config.yaml" in document["data"]
    )
    return read_yaml(config, ".security.oidc")


class OidcConfigTests(unittest.TestCase):
    def test_default_uses_primary_registration_without_an_empty_override(self):
        oidc = oidc_config(render())
        self.assertNotIn("device_client", oidc)
        self.assertIs(oidc["require_groups"], False)

    def test_native_registration_and_group_policy_reach_application_config(self):
        documents = render(
            "security.oidc.enabled=true",
            "security.oidc.discoveryUrl=https://example.okta.com/.well-known/openid-configuration",
            "security.oidc.clientId=web-client",
            "security.oidc.redirectUri=https://attune.example.com/auth/callback",
            "security.oidc.scopes={groups}",
            "security.oidc.requireGroups=true",
            "security.oidc.deviceClient.clientId=native-client",
            "security.identitySecret.existingSecret=oidc-credentials",
        )
        oidc = oidc_config(documents)
        self.assertEqual(oidc["client_id"], "web-client")
        self.assertEqual(oidc["scopes"], ["groups"])
        self.assertIs(oidc["require_groups"], True)
        self.assertEqual(
            oidc["device_client"],
            {"client_id": "native-client", "client_secret": None},
        )
        credential_consumers = [
            container["name"]
            for document in documents
            if document["kind"] == "Deployment"
            for container in document["spec"]["template"]["spec"]["containers"]
            if any(
                entry.get("secretRef", {}).get("name") == "oidc-credentials"
                for entry in container.get("envFrom", [])
            )
        ]
        self.assertEqual(credential_consumers, ["api"])

    def test_chart_rejects_device_secrets_in_values_and_blank_client_ids(self):
        for setting in [
            "security.oidc.deviceClient.clientSecret=must-use-a-secret",
            "security.oidc.deviceClient.clientId=   ",
        ]:
            with self.subTest(setting=setting), self.assertRaises(subprocess.CalledProcessError):
                render(setting)


if __name__ == "__main__":
    unittest.main()
