#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_dir="$(mktemp -d)"
repository_url="packages"
attune_version="$(awk -F '"' '/^appVersion:/ { print $2; exit }' "$root_dir/charts/attune/Chart.yaml")"
trap 'rm -rf "$render_dir"' EXIT

for chart in "$root_dir"/charts/*; do
  chart_name="$(basename "$chart")"
  helm lint --strict "$chart"
  helm template verify "$chart" --namespace verify > "$render_dir/$chart_name.yaml"
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
    -strict -summary < "$render_dir/$chart_name.yaml"

  mkdir -p "$render_dir/generated" "$render_dir/generated-$chart_name" "$render_dir/committed-$chart_name"
  helm package "$chart" --destination "$render_dir/generated" >/dev/null
  generated_packages=("$render_dir/generated/$chart_name-"*.tgz)
  if [[ "${#generated_packages[@]}" -ne 1 ]]; then
    printf 'expected one generated package for %s\n' "$chart_name" >&2
    exit 1
  fi
  package_name="$(basename "${generated_packages[0]}")"
  if [[ ! -f "$root_dir/packages/$package_name" ]]; then
    printf 'missing committed package %s\n' "$package_name" >&2
    exit 1
  fi

  actual_digest="$(sha256sum "$root_dir/packages/$package_name")"
  actual_digest="${actual_digest%% *}"
  indexed_digest="$({
    docker run --rm -i \
      -e CHART_NAME="$chart_name" \
      -e PACKAGE_URL="$repository_url/$package_name" \
      mikefarah/yq:4.47.2 \
      eval --no-doc \
      '.entries[strenv(CHART_NAME)][] | select(.urls[] == strenv(PACKAGE_URL)) | .digest' - \
      < "$root_dir/index.yaml"
  })"
  if [[ "$actual_digest" != "$indexed_digest" ]]; then
    printf 'index digest for %s is stale\n' "$package_name" >&2
    exit 1
  fi

  tar -xzf "${generated_packages[0]}" -C "$render_dir/generated-$chart_name"
  tar -xzf "$root_dir/packages/$package_name" -C "$render_dir/committed-$chart_name"
  diff -ru "$render_dir/generated-$chart_name" "$render_dir/committed-$chart_name"
done

mapfile -t deployment_names < <(
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment") | .metadata.name' - \
    < "$render_dir/attune.yaml"
)

for expected_name in \
  verify-attune-action-worker-full \
  verify-attune-sensor-worker-default; do
  found=false
  for deployment_name in "${deployment_names[@]}"; do
    if [[ "$deployment_name" == "$expected_name" ]]; then
      found=true
      break
    fi
  done
  if [[ "$found" != true ]]; then
    printf 'missing rendered Deployment %s\n' "$expected_name" >&2
    exit 1
  fi
done

helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --set global.imageTag="$attune_version" \
  --set security.existingSecret=attune-service-secrets \
  --set database.postgresql.admin.existingSecret=attune-postgresql-admin \
  --set database.postgresql.admin.usernameKey=username \
  --set database.postgresql.admin.passwordKey=password \
  --set database.postgresql.provisioning.enabled=true \
  --set rabbitmq.admin.existingSecret=attune-rabbitmq-admin \
  --set rabbitmq.admin.usernameKey=username \
  --set rabbitmq.admin.passwordKey=password \
  --set rabbitmq.provisioning.enabled=true \
  > "$render_dir/attune-upgrade.yaml"

helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --set security.existingSecret=attune-service-secrets \
  --set database.postgresql.admin.existingSecret=attune-postgresql-admin \
  --set database.postgresql.admin.usernameKey=username \
  --set database.postgresql.admin.passwordKey=password \
  --set database.postgresql.provisioning.enabled=true \
  --set rabbitmq.admin.existingSecret=attune-rabbitmq-admin \
  --set rabbitmq.admin.usernameKey=username \
  --set rabbitmq.admin.passwordKey=password \
  --set rabbitmq.provisioning.enabled=true \
  > "$render_dir/attune-existing-secrets.yaml"

external_secret_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Secret")] | length' - \
    < "$render_dir/attune-existing-secrets.yaml"
})"

if [[ "$external_secret_count" -ne 0 ]]; then
  printf 'expected no rendered Secrets when all existing Secrets are configured\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --set database.postgresql.provisioning.enabled=true \
  > /dev/null 2>&1; then
  printf 'PostgreSQL provisioning rendered without required existing Secrets\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --set rabbitmq.provisioning.enabled=true \
  > /dev/null 2>&1; then
  printf 'RabbitMQ provisioning rendered without required existing Secrets\n' >&2
  exit 1
fi

mapfile -t job_hooks < <(
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job") | .metadata.annotations."helm.sh/hook"' - \
    < "$render_dir/attune-upgrade.yaml"
)

if [[ "${#job_hooks[@]}" -ne 5 ]]; then
  printf 'expected five upgrade Jobs, found %d\n' "${#job_hooks[@]}" >&2
  exit 1
fi

for hook in "${job_hooks[@]}"; do
  if [[ "$hook" != pre-upgrade ]]; then
    printf 'upgrade Job has hook %s, expected pre-upgrade\n' "$hook" >&2
    exit 1
  fi
done
