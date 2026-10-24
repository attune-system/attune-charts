#!/usr/bin/env python3
"""Publish through the bundled API client, or wait for application content."""
import argparse
import json
import os
import importlib.util
from pathlib import Path
import time
import urllib.error
import urllib.request

REVISION = "authenticated-pack-publication-1"
COMPONENTS = {"immutable_release", "atomic_deployment"}


def require_contract(ready):
    # Publication still requires the registrar's authority. The broader managed
    # runtime admission gate is a separate contract, not a bootstrap prerequisite.
    contract = ready.get("pack_publication", {})
    if (not isinstance(contract, dict)
            or type(contract.get("protocol_version")) is not int
            or contract["protocol_version"] != 1
            or contract.get("authorization") != "registrar"
            or type(contract.get("client_version")) is not int
            or contract["client_version"] != 1
            or contract.get("revision") != REVISION
            or not isinstance(contract.get("components"), list)
            or not all(isinstance(item, str) for item in contract["components"])
            or set(contract["components"]) != COMPONENTS):
        raise RuntimeError("API authenticated publication protocol 1/component contract is unavailable; deploy coordinated compatible images")


def get(base, path):
    with urllib.request.urlopen(base + path, timeout=5) as response:
        return json.load(response)


def wait(base, path, deadline):
    while time.monotonic() < deadline:
        try:
            return get(base, path)
        except (OSError, urllib.error.URLError):
            time.sleep(1)
    raise TimeoutError(f"readiness deadline exceeded for {path}")


def publish(base):
    spec = importlib.util.spec_from_file_location("bundled_core_publisher", "/scripts/bootstrap_core_pack.py")
    publisher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(publisher)
    method = getattr(publisher, "publish_core", None)
    if not callable(method):
        raise RuntimeError("bundled publisher lacks API-only publish_core; deploy compatible init-packs image")
    client_version = getattr(publisher, "BOOTSTRAP_CLIENT_VERSION", None)
    if (type(client_version) is not int or client_version != 1
            or getattr(publisher, "BOOTSTRAP_REVISION", None) != REVISION
            or getattr(publisher, "BOOTSTRAP_COMPONENTS", None) != COMPONENTS):
        raise RuntimeError("bundled publisher client version/revision/components mismatch; deploy compatible init-packs image")
    method(base, Path(os.environ.get("SOURCE_PACKS_DIR", "/source/packs")) / "core")


def run(command):
    base = os.environ["ATTUNE_API_URL"].rstrip("/")
    deadline = time.monotonic() + min(300, max(1, int(os.environ.get("ATTUNE_BOOTSTRAP_TIMEOUT_SECONDS", "300"))))
    ready = wait(base, "/health/ready", deadline)
    require_contract(ready)
    if command == "wait":
        wait(base, "/health/content", deadline)
    version = os.environ.get("ATTUNE_CORE_PACK_VERSION")
    if not version:
        raise RuntimeError("ATTUNE_CORE_PACK_VERSION is required before publishing")
    # Never invoke the old SQL loader, /init-packs.sh, or a publisher main()
    # which may wait for hosts that cannot start until publication completes.
    if command == "publish":
        publish(base)
    core = get(base, "/health/bootstrap")["core"]
    if (core["version"] != version or not core.get("release_id")
            or not core.get("digest") or not core.get("policy_revision")):
        raise RuntimeError("active core release does not match admitted bootstrap content")
    digest = os.environ.get("ATTUNE_CORE_PACK_DIGEST")
    if digest and core["digest"] != digest:
        raise RuntimeError("admitted core digest does not match the required digest")


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="Example: bootstrap-admission.py publish")
    parser.add_argument("command", choices=("publish", "wait"))
    run(parser.parse_args().command)


if __name__ == "__main__":
    main()
