#!/usr/bin/env python3
"""Check Helm link values, and optionally both built containers.

python3 scripts/test-site-community-links.py
python3 scripts/test-site-community-links.py --site-image attune-site:runtime-test \
    --docs-image attune-docs-site:runtime-test
"""

import argparse
import http.client
import json
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
INVITES = [
    "https://join.slack.com/t/attune-dev/shared_invite/invite-a~token",
    "https://join.slack.com/t/attune-dev/shared_invite/invite-b?x=1&y=2",
]


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def check_chart(name):
    templates = []
    images = []
    with tempfile.TemporaryDirectory() as directory:
        values = Path(directory) / "values.yaml"
        for invite in ["", *INVITES]:
            values.write_text(yaml.safe_dump({"slackInviteUrl": invite}))
            documents = yaml.safe_load_all(command(
                "helm", "template", "links-test", str(ROOT / "charts" / name),
                "--values", str(values),
            ))
            deployment = next(doc for doc in documents if doc and doc["kind"] == "Deployment")
            template = deployment["spec"]["template"]
            container = template["spec"]["containers"][0]
            entry = next(item for item in container["env"] if item["name"] == "SLACK_INVITE_URL")
            assert entry["value"] == invite, entry
            templates.append(template)
            images.append(container["image"])
    assert templates[1] != templates[2], "URL rotation did not change the pod template"
    assert len(set(images)) == 1, "URL rotation changed the image"
    print(f"{name}: Helm value rotates env without changing the image")


@contextmanager
def container(image, invite):
    identifier = command(
        "docker", "run", "--detach", "--publish", "127.0.0.1::8080",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=16m,mode=1777",
        "--env", f"SLACK_INVITE_URL={invite}",
        "--env", "SMTP_HOST=smtp.example.com", "--env", "SMTP_FROM=site@example.com",
        image,
    )
    try:
        yield identifier
    finally:
        command("docker", "rm", "--force", identifier)


def request(port, path, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read().decode()
    finally:
        connection.close()


def wait_ready(identifier):
    for _ in range(100):
        state = json.loads(command("docker", "inspect", identifier))[0]
        if state["State"]["Status"] == "exited":
            raise AssertionError(command("docker", "logs", identifier))
        bindings = state["NetworkSettings"]["Ports"].get("8080/tcp")
        if not bindings:
            time.sleep(0.1)
            continue
        port = int(bindings[0]["HostPort"])
        try:
            if request(port, "/healthz")[0] == 200:
                return port
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.1)
    raise AssertionError(command("docker", "logs", identifier))


def check_image(image):
    homepages = []
    for invite in ["", *INVITES]:
        with container(image, invite) as identifier:
            port = wait_ready(identifier)
            status, _, homepage = request(port, "/")
            assert status == 200
            assert 'href="/community/slack/"' in homepage, "missing stable Slack anchor"
            assert "join.slack.com" not in homepage, "invite remains baked into homepage"
            homepages.append(homepage)
            for path in ["/community/slack/", "/community/slack", "/community/slack/?next=https://other.example"]:
                for method in ["GET", "HEAD"]:
                    status, headers, body = request(port, path, method)
                    assert headers.get("Cache-Control") == "no-store", headers
                    assert headers.get("X-Content-Type-Options") == "nosniff", headers
                    if invite:
                        assert status == 302, status
                        assert headers.get("Location") == invite, headers
                    elif path != "/community/slack":
                        assert status == 200, status
                        if method == "GET":
                            assert 'http-equiv="refresh"' in body and "join.slack.com" in body
                    if method == "HEAD":
                        assert body == ""
            assert request(port, "/community/slack/unknown")[0] == 404
    assert homepages[0] == homepages[1] == homepages[2], "runtime rotation mutated HTML"
    for invite in [
        "http://example.com/invite", "https://", "https://user:pass@example.com/invite",
        "https://example.com/$host", 'https://example.com/";return 200;#',
        "https://example.com/\nheader", "https://example.com:bad/invite",
        "https://example.com/\\path",
    ]:
        with container(image, invite) as identifier:
            try:
                code = subprocess.check_output(["docker", "wait", identifier], text=True, timeout=15).strip()
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f"invalid invite {invite!r} did not fail startup:\n"
                                     + command("docker", "logs", identifier)) from error
            assert code != "0", "invalid runtime URL did not fail startup"
            assert "SLACK_INVITE_URL" in command("docker", "logs", identifier)
    print(f"{image}: same image serves both invites, fallback works, invalid env fails startup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-image")
    parser.add_argument("--docs-image")
    args = parser.parse_args()
    for name in ["attune-site", "attune-docs-site"]:
        check_chart(name)
    for image in [args.site_image, args.docs_image]:
        if image:
            check_image(image)


if __name__ == "__main__":
    main()
