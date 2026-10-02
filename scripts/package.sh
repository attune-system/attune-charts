#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages_dir="$root_dir/packages"
repository_url="packages"

mkdir -p "$packages_dir"

if [[ "$#" -eq 0 ]]; then
  charts=("$root_dir"/charts/*)
else
  charts=()
  for name in "$@"; do
    if [[ ! "$name" =~ ^[a-z0-9-]+$ || ! -f "$root_dir/charts/$name/Chart.yaml" ]]; then
      printf 'unknown chart: %s\n' "$name" >&2
      exit 1
    fi
    charts+=("$root_dir/charts/$name")
  done
fi

for chart in "${charts[@]}"; do
  helm package "$chart" --destination "$packages_dir"
done

if [[ -f "$root_dir/index.yaml" ]]; then
  helm repo index "$packages_dir" --url "$repository_url" --merge "$root_dir/index.yaml"
else
  helm repo index "$packages_dir" --url "$repository_url"
fi
mv "$packages_dir/index.yaml" "$root_dir/index.yaml"
