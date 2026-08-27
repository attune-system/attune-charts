#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages_dir="$root_dir/packages"
repository_url="https://raw.githubusercontent.com/attune-system/attune-charts/main/packages"

mkdir -p "$packages_dir"

for chart in "$root_dir"/charts/*; do
  helm package "$chart" --destination "$packages_dir"
done

if [[ -f "$root_dir/index.yaml" ]]; then
  helm repo index "$packages_dir" --url "$repository_url" --merge "$root_dir/index.yaml"
else
  helm repo index "$packages_dir" --url "$repository_url"
fi
mv "$packages_dir/index.yaml" "$root_dir/index.yaml"
