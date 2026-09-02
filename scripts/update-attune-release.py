#!/usr/bin/env python3

import re
import sys
from pathlib import Path


def version_tuple(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value)
    if not match:
        raise SystemExit(f"expected a stable version such as 0.5.1, got {value!r}")
    return tuple(int(part) for part in match.groups())


def replace_once(path: Path, pattern: str, replacement: str) -> None:
    content = path.read_text()
    updated, count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected one version field matching {pattern!r} in {path}")
    path.write_text(updated)


if len(sys.argv) != 2:
    raise SystemExit(f"usage: {Path(sys.argv[0]).name} <stable-attune-version>")

target_version = sys.argv[1].removeprefix("v")
target = version_tuple(target_version)
root = Path(__file__).resolve().parent.parent
chart_path = root / "charts/attune/Chart.yaml"
values_path = root / "charts/attune/values.yaml"
readme_path = root / "README.md"

chart = chart_path.read_text()
chart_version_match = re.search(r"^version: (\S+)$", chart, re.MULTILINE)
app_version_match = re.search(r'^appVersion: "(\S+)"$', chart, re.MULTILINE)
if not chart_version_match or not app_version_match:
    raise SystemExit(f"could not read chart versions from {chart_path}")

chart_version = version_tuple(chart_version_match.group(1))
app_version = version_tuple(app_version_match.group(1))
if target <= app_version:
    print(f"Attune chart already targets {app_version_match.group(1)}; no update needed")
    raise SystemExit(0)

if target > chart_version:
    next_chart_version = target_version
else:
    next_chart_version = f"{chart_version[0]}.{chart_version[1]}.{chart_version[2] + 1}"

replace_once(chart_path, r"^version: \S+$", f"version: {next_chart_version}")
replace_once(chart_path, r'^appVersion: "\S+"$', f'appVersion: "{target_version}"')
replace_once(values_path, r'^  imageTag: "\S+"$', f'  imageTag: "{target_version}"')
replace_once(
    readme_path,
    r"^(\| `attune` \| )`[^`]+`( \|)",
    rf"\g<1>`{next_chart_version}`\g<2>",
)
replace_once(
    readme_path,
    r"^(The platform chart pulls Attune )`[^`]+`( images from)$",
    rf"\g<1>`{target_version}`\g<2>",
)

print(f"Updated Attune chart {next_chart_version} to application {target_version}")
