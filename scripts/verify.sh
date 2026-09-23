#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_dir="$(mktemp -d)"
repository_url="packages"
attune_version="$(awk -F '"' '/^appVersion:/ { print $2; exit }' "$root_dir/charts/attune/Chart.yaml")"
trap 'rm -rf "$render_dir"' EXIT

setup_generator=(
  env
  ATTUNE_SETUP_DATABASE_PASSWORD=database-password-123456
  ATTUNE_SETUP_DATABASE_ADMIN_PASSWORD=database-admin-password-123456
  ATTUNE_SETUP_RABBITMQ_PASSWORD=rabbitmq-password-123456
  ATTUNE_SETUP_RABBITMQ_ADMIN_PASSWORD=rabbitmq-admin-password-123456
  ATTUNE_SETUP_JWT_SECRET=jwt-secret-with-at-least-32-characters
  ATTUNE_SETUP_ENCRYPTION_KEY=encryption-key-with-at-least-32-characters
  "$root_dir/scripts/generate-attune-setup.sh"
)
helm_316=(docker run --rm -i -v "$root_dir:/work" -w /work alpine/helm:3.16.1)

"${setup_generator[@]}" \
    --namespace verify \
    --release verify \
    --cluster-name verify-timescaledb \
    --storage-class verify-storage \
    --shared-storage-rwx-class verify-rwx-storage \
    --ingress-host attune.example.com \
    --ingress-class traefik.io \
    --ingress-tls-secret attune.example.com-tls \
    --confirm-bootstrap-password-changed \
    --output-dir "$render_dir/setup" >/dev/null

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/setup/namespace.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/setup/secrets.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  < "$render_dir/setup/timescaledb.yaml"

database_password="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-timescaledb-bootstrap") | .data.password | @base64d' - \
    < "$render_dir/setup/secrets.yaml"
})"
runtime_database_password="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data.DB_PASSWORD | @base64d' - \
    < "$render_dir/setup/secrets.yaml"
})"
if [[ "$database_password" != "$runtime_database_password" ]]; then
  printf 'generated CNPG and Attune database credentials differ\n' >&2
  exit 1
fi

runtime_database_host="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data.DB_HOST | @base64d' - \
    < "$render_dir/setup/secrets.yaml"
})"
values_database_host="$({
  docker run --rm -i mikefarah/yq:4.47.2 '.database.host' - \
    < "$render_dir/setup/values.yaml"
})"
if [[ "$runtime_database_host" != "$values_database_host" ]]; then
  printf 'generated CNPG host differs between values and runtime Secret\n' >&2
  exit 1
fi

helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$render_dir/setup/values.yaml" > "$render_dir/attune-cnpg.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --values "$render_dir/setup/values.yaml" > "$render_dir/attune-cnpg-upgrade.yaml"

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-cnpg.yaml"

external_major_preflight_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "postgresql-major-preflight")] | length' - \
    < "$render_dir/attune-cnpg-upgrade.yaml"
})"
if [[ "$external_major_preflight_count" -ne 0 ]]; then
  printf 'external PostgreSQL upgrade rendered the bundled major preflight\n' >&2
  exit 1
fi

notifier_port="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | .notifier.port' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$notifier_port" != 8081 ]]; then
  printf 'rendered application config is missing the notifier listener\n' >&2
  exit 1
fi

database_budget_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment") as $deployment | $deployment.spec.template.spec.containers[] | .env[]? | select(.name == "ATTUNE__DATABASE__MAX_CONNECTIONS") | select((($deployment.spec.template.metadata.labels."app.kubernetes.io/component" | test("^(api|executor)$")) and .value == "10") or (($deployment.spec.template.metadata.labels."app.kubernetes.io/component" | test("^(supervisor|notifier|action-worker-|sensor-worker-)")) and .value == "5"))] | length' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$database_budget_count" -ne 6 ]]; then
  printf 'rendered workloads are missing explicit database connection budgets\n' >&2
  exit 1
fi

api_stream_settings_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "api" and .spec.template.spec.terminationGracePeriodSeconds == 30) | .spec.template.spec.containers[] | select(.name == "api") | .env[] | select((.name == "ATTUNE__SERVER__EXECUTION_LOG_STREAM_GLOBAL_LIMIT" and .value == "100") or (.name == "ATTUNE__SERVER__EXECUTION_LOG_STREAM_PER_IDENTITY_LIMIT" and .value == "5") or (.name == "ATTUNE__SERVER__EXECUTION_LOG_STREAM_LEASE_SECONDS" and .value == "45") or (.name == "ATTUNE__SERVER__EXECUTION_LOG_STREAM_HEARTBEAT_SECONDS" and .value == "10") or (.name == "ATTUNE__SERVER__SHUTDOWN_GRACE_PERIOD" and .value == "25"))] | length' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$api_stream_settings_count" -ne 5 ]]; then
  printf 'rendered API stream limits or shutdown grace period differ from defaults\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=attune-service-secrets \
  --set api.executionLogStreams.leaseSeconds=20 \
  --set api.executionLogStreams.heartbeatSeconds=10 \
  > /dev/null 2>&1; then
  printf 'execution log stream lease rendered without a full renewal retry interval\n' >&2
  exit 1
fi

helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=attune-service-secrets \
  --set api.executionLogStreams.leaseSeconds=21 \
  --set api.executionLogStreams.heartbeatSeconds=10 \
  > /dev/null

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=attune-service-secrets \
  --set database.postgresql.maxConnections=99 \
  > /dev/null 2>&1; then
  printf 'bundled PostgreSQL rendered below the rolling connection budget\n' >&2
  exit 1
fi

nginx_config="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "ConfigMap") | .data."nginx.conf"' - \
    < "$render_dir/attune-cnpg.yaml"
})"
for directive in 'proxy_buffering off;' 'proxy_request_buffering off;' 'proxy_read_timeout 1h;' 'proxy_send_timeout 1h;'; do
  if [[ "$nginx_config" != *"$directive"* ]]; then
    printf 'web nginx config is missing SSE directive: %s\n' "$directive" >&2
    exit 1
  fi
done

ingress_stream_annotations="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Ingress") | [.metadata.annotations."nginx.ingress.kubernetes.io/proxy-buffering", .metadata.annotations."nginx.ingress.kubernetes.io/proxy-read-timeout", .metadata.annotations."nginx.ingress.kubernetes.io/proxy-send-timeout"] | join(",")' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$ingress_stream_annotations" != "off,3600,3600" ]]; then
  printf 'ingress SSE buffering and timeout defaults are missing\n' >&2
  exit 1
fi

migration_database_url_override_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "migrations") | .spec.template.spec.containers[] | select(.name == "migrations") | .env[] | select(.name == "ATTUNE__DATABASE__URL" and .value == "")] | length' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$migration_database_url_override_count" -ne 1 ]]; then
  printf 'migration Job does not force the 0.5.3 index seeder to use DB_* connection fields\n' >&2
  exit 1
fi

rabbitmq_probe="$render_dir/rabbitmq-amqp-probe.py"
docker run --rm -i mikefarah/yq:4.47.2 \
  eval-all --no-doc 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "api") | .spec.template.spec.initContainers[] | select(.name == "wait-for-rabbitmq-credentials") | .args[0]' - \
  < "$render_dir/attune-cnpg.yaml" > "$rabbitmq_probe"
rabbitmq_wait_script="$(< "$rabbitmq_probe")"
if [[ "$rabbitmq_wait_script" != *'AMQP'* || "$rabbitmq_wait_script" == *'/api/whoami'* ]]; then
  printf 'RabbitMQ credential wait does not authenticate over AMQP\n' >&2
  exit 1
fi
python3 -m py_compile "$rabbitmq_probe"
python3 "$root_dir/scripts/test-rabbitmq-amqp-probe.py" "$rabbitmq_probe"

rabbitmq_provisioning_script="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "provision-rabbitmq") | .spec.template.spec.containers[] | select(.name == "provision-rabbitmq") | .args[0]' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$rabbitmq_provisioning_script" == *'/api/whoami'* ]]; then
  printf 'RabbitMQ provisioner verifies an untagged service user through the management API\n' >&2
  exit 1
fi

shared_pvc_configuration="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "PersistentVolumeClaim") | [.metadata.name, .spec.accessModes[0], .spec.storageClassName] | @tsv' - \
    < "$render_dir/attune-cnpg.yaml"
})"
expected_shared_pvc_configuration=$'verify-attune-packs\tReadWriteMany\tverify-rwx-storage\tverify-attune-runtime-envs\tReadWriteMany\tverify-rwx-storage\tverify-attune-artifacts\tReadWriteMany\tverify-rwx-storage'
if [[ "$shared_pvc_configuration" != "$expected_shared_pvc_configuration" ]]; then
  printf 'generated multi-node setup did not configure all shared PVCs for RWX\n' >&2
  exit 1
fi

helm lint --strict "$root_dir/charts/attune" \
  --values "$root_dir/charts/attune/ci/shared-volume-values.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$root_dir/charts/attune/ci/shared-volume-values.yaml" \
  > "$render_dir/attune-shared-volume.yaml"

helm lint --strict "$root_dir/charts/attune" \
  --values "$root_dir/charts/attune/ci/object-values.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$root_dir/charts/attune/ci/object-values.yaml" \
  > "$render_dir/attune-object.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --values "$root_dir/charts/attune/ci/object-values.yaml" \
  > "$render_dir/attune-object-upgrade.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --values "$root_dir/charts/attune/ci/shared-volume-values.yaml" \
  --set database.postgresql.majorUpgradePolicy=startFresh \
  --set database.postgresql.majorUpgradeStage=cutover \
  --set rabbitmq.majorUpgradePolicy=startFresh \
  > "$render_dir/attune-postgresql-cutover.yaml"

helm lint --strict "$root_dir/charts/attune" \
  --values "$root_dir/charts/attune/ci/object-ephemeral-values.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$root_dir/charts/attune/ci/object-ephemeral-values.yaml" \
  > "$render_dir/attune-object-ephemeral.yaml"

helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$root_dir/charts/attune/ci/object-values.yaml" \
  --set database.postgresql.admin.existingSecret=verify-postgresql-admin \
  --set database.postgresql.admin.usernameKey=username \
  --set database.postgresql.admin.passwordKey=password \
  --set database.postgresql.provisioning.enabled=true \
  --set rabbitmq.admin.existingSecret=verify-rabbitmq-admin \
  --set rabbitmq.admin.usernameKey=username \
  --set rabbitmq.admin.passwordKey=password \
  --set rabbitmq.provisioning.enabled=true \
  > "$render_dir/attune-restricted.yaml"

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-shared-volume.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-object.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-object-upgrade.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-postgresql-cutover.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-object-ephemeral.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-restricted.yaml"

if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --values "$root_dir/charts/attune/ci/shared-volume-values.yaml" \
  --set database.postgresql.majorUpgradePolicy=startFresh \
  > /dev/null 2>&1; then
  printf 'schema accepted startFresh+complete PostgreSQL major-upgrade values\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$root_dir/charts/attune/ci/shared-volume-values.yaml" \
  --set database.postgresql.majorUpgradePolicy=startFresh \
  --set database.postgresql.majorUpgradeStage=cutover \
  > /dev/null 2>&1; then
  printf 'chart accepted PostgreSQL cutover during install\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --values "$root_dir/charts/attune/ci/shared-volume-values.yaml" \
  --set database.postgresql.enabled=false \
  --set database.host=postgresql.example.com \
  --set database.postgresql.majorUpgradePolicy=startFresh \
  --set database.postgresql.majorUpgradeStage=cutover \
  > /dev/null 2>&1; then
  printf 'chart accepted PostgreSQL cutover with an external database\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --is-upgrade \
  --values "$root_dir/charts/attune/ci/object-values.yaml" \
  --set storage.object.migrateFromSharedVolume=true \
  --set database.postgresql.majorUpgradePolicy=startFresh \
  --set database.postgresql.majorUpgradeStage=cutover \
  > /dev/null 2>&1; then
  printf 'chart accepted simultaneous PostgreSQL and storage cutovers\n' >&2
  exit 1
fi

install_major_preflight_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "postgresql-major-preflight")] | length' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$install_major_preflight_count" -ne 0 ]]; then
  printf 'PostgreSQL major preflight rendered during install\n' >&2
  exit 1
fi

cutover_deployment_contract="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment") | .spec.replicas] | [length, ([.[] | select(. == 0)] | length)] | @tsv' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
cutover_non_preflight_job_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" != "postgresql-major-preflight")] | length' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
if [[ "$cutover_deployment_contract" != $'7\t7' || "$cutover_non_preflight_job_count" -ne 0 ]]; then
  printf 'PostgreSQL cutover did not stop every Attune Deployment and suppress dependent Jobs: %s, %s Jobs\n' "$cutover_deployment_contract" "$cutover_non_preflight_job_count" >&2
  exit 1
fi

cutover_rabbitmq_guard="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "StatefulSet" and .spec.template.metadata.labels."app.kubernetes.io/component" == "rabbitmq") | .spec.template.spec.initContainers[] | select(.name == "guard-rabbitmq-major-upgrade") | .args[0]' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
if [[ "$cutover_rabbitmq_guard" != *'"startFresh" != startFresh'* ]]; then
  printf 'PostgreSQL cutover does not explicitly authorize the destructive RabbitMQ 4 reset\n' >&2
  exit 1
fi

cutover_service_contract="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Service" and (.metadata.name == "verify-attune-postgresql" or .metadata.name == "verify-attune-postgresql-maintenance")) | [.metadata.name, .spec.selector."attune.dev/postgresql-major"] | @tsv' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
expected_cutover_service_contract=$'verify-attune-postgresql\tcutover-blocked\tverify-attune-postgresql-maintenance\t18'
if [[ "$cutover_service_contract" != "$expected_cutover_service_contract" ]]; then
  printf 'PostgreSQL cutover Service selectors are unsafe: %s\n' "$cutover_service_contract" >&2
  exit 1
fi

postgresql_major_label="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "StatefulSet" and .metadata.name == "verify-attune-postgresql") | .spec.template.metadata.labels."attune.dev/postgresql-major"' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
if [[ "$postgresql_major_label" != 18 ]]; then
  printf 'PostgreSQL 18 StatefulSet Pod label is missing\n' >&2
  exit 1
fi

cutover_preflight_contract="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "postgresql-major-preflight") | [.metadata.annotations."helm.sh/hook", .metadata.annotations."helm.sh/hook-weight", .spec.activeDeadlineSeconds, .spec.backoffLimit] | @tsv' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
cutover_preflight_script="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "postgresql-major-preflight") | .spec.template.spec.containers[0].args[0]' - \
    < "$render_dir/attune-postgresql-cutover.yaml"
})"
if [[ "$cutover_preflight_contract" != $'pre-upgrade\t-50\t180\t0' ]] || \
   [[ "$cutover_preflight_script" != *"default_transaction_read_only=on"* ]] || \
   [[ "$cutover_preflight_script" != *'ordinary_major="$(server_major "$ORDINARY_DB_HOST"'* ]] || \
   [[ "$cutover_preflight_script" != *'"$ordinary_major" = 16'* ]] || \
   [[ "$cutover_preflight_script" != *'"$maintenance_major" = 18'* ]]; then
  printf 'PostgreSQL cutover preflight is not bounded, read-only, or retry-safe\n' >&2
  exit 1
fi

restricted_pod_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job") | .spec.template.spec] | length' - \
    < "$render_dir/attune-restricted.yaml"
})"
restricted_compliant_pod_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job") | select(.spec.template.spec.securityContext.runAsNonRoot == true and .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault")] | length' - \
    < "$render_dir/attune-restricted.yaml"
})"
restricted_container_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job") | (.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?)] | length' - \
    < "$render_dir/attune-restricted.yaml"
})"
restricted_compliant_container_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job") | (.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?) | select(.securityContext.runAsUser > 0 and .securityContext.privileged != true and .securityContext.allowPrivilegeEscalation == false and (.securityContext.capabilities.drop | contains(["ALL"])))] | length' - \
    < "$render_dir/attune-restricted.yaml"
})"
if [[ "$restricted_pod_count" -eq 0 || "$restricted_pod_count" -ne "$restricted_compliant_pod_count" ]]; then
  printf 'restricted security context reached %s of %s rendered Pods\n' \
    "$restricted_compliant_pod_count" "$restricted_pod_count" >&2
  exit 1
fi
if [[ "$restricted_container_count" -eq 0 || "$restricted_container_count" -ne "$restricted_compliant_container_count" ]]; then
  printf 'restricted security context reached %s of %s rendered containers\n' \
    "$restricted_compliant_container_count" "$restricted_container_count" >&2
  exit 1
fi
restricted_unsafe_added_capability_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job") | (.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?) | .securityContext.capabilities.add[]? | select(. != "NET_BIND_SERVICE")] | length' - \
    < "$render_dir/attune-restricted.yaml"
})"
if [[ "$restricted_unsafe_added_capability_count" -ne 0 ]]; then
  printf 'restricted security contexts rendered disallowed added capabilities\n' >&2
  exit 1
fi

web_restricted_contract="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "web") | [.spec.template.spec.containers[0].securityContext.runAsUser, .spec.template.spec.containers[0].securityContext.runAsGroup, (.spec.template.spec.containers[0].securityContext.capabilities.add | join(",")), ([.spec.template.spec.volumes[] | select(.name == "nginx-cache" or .name == "nginx-run" or .name == "runtime-config")] | length)] | @tsv' - \
    < "$render_dir/attune-restricted.yaml"
})"
if [[ "$web_restricted_contract" != $'101\t101\tNET_BIND_SERVICE\t3' ]]; then
  printf 'web restricted runtime contract is incomplete: %s\n' "$web_restricted_contract" >&2
  exit 1
fi

worker_security_override="$({
  helm template verify "$root_dir/charts/attune" \
    --namespace verify \
    --values "$root_dir/charts/attune/ci/object-values.yaml" \
    --set-json 'actionWorkers=[{"name":"custom","image":"python:3.12","podSecurityContext":{"fsGroup":2000},"containerSecurityContext":{"runAsUser":2000,"runAsGroup":2000}}]' | \
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "action-worker-custom")] | .[0] | [.spec.template.spec.securityContext.fsGroup, (.spec.template.spec.containers[] | select(.name == "worker") | .securityContext.runAsUser), (.spec.template.spec.containers[] | select(.name == "worker") | .securityContext.runAsGroup)] | @tsv' -
})"
if [[ "$worker_security_override" != $'2000\t2000\t2000' ]]; then
  printf 'worker security context override did not reach the rendered Pod: %s\n' \
    "$worker_security_override" >&2
  exit 1
fi

worker_fs_group_policy_override="$({
  helm template verify "$root_dir/charts/attune" \
    --namespace verify \
    --values "$root_dir/charts/attune/ci/shared-volume-values.yaml" \
    --set-json 'actionWorkers=[{"name":"custom","image":"python:3.12","podSecurityContext":{"fsGroupChangePolicy":"Always"}}]' | \
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "action-worker-custom")] | .[0] | [.spec.template.spec.securityContext.fsGroup, .spec.template.spec.securityContext.fsGroupChangePolicy] | @tsv' -
})"
if [[ "$worker_fs_group_policy_override" != $'1000\tAlways' ]]; then
  printf 'worker fsGroup fallback overwrote the explicit change policy: %s\n' \
    "$worker_fs_group_policy_override" >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set workloadSecurity.podSecurityContext.runAsNonRoot=false \
  > /dev/null 2>&1; then
  printf 'restricted workload security accepted runAsNonRoot=false\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set workloadSecurity.containerSecurityContext.allowPrivilegeEscalation=true \
  > /dev/null 2>&1; then
  printf 'restricted workload security accepted privilege escalation\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set-json 'actionWorkers=[{"name":"unsafe","image":"python:3.12","containerSecurityContext":{"runAsUser":0}}]' \
  > /dev/null 2>&1; then
  printf 'restricted worker override accepted root UID\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set-json 'actionWorkers=[{"name":"unsafe","image":"python:3.12","containerSecurityContext":{"capabilities":{"add":["SYS_ADMIN"]}}}]' \
  > /dev/null 2>&1; then
  printf 'restricted worker override accepted SYS_ADMIN\n' >&2
  exit 1
fi
if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set-json 'actionWorkers=[{"name":"unsafe","image":"python:3.12","podSecurityContext":{"seccompProfile":{"type":"Unconfined"}}}]' \
  > /dev/null 2>&1; then
  printf 'restricted worker override accepted unconfined seccomp\n' >&2
  exit 1
fi

default_worker_empty_dir_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" and (.metadata.labels."app.kubernetes.io/component" | test("^(action|sensor)-worker-"))) | .spec.template.spec.volumes[] | select((.name == "packs" or .name == "runtime-envs") and has("emptyDir") and .emptyDir.sizeLimit != null)] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$default_worker_empty_dir_count" -ne 4 ]]; then
  printf 'default object mode rendered %s bounded emptyDir worker caches, expected 4\n' "$default_worker_empty_dir_count" >&2
  exit 1
fi

default_ephemeral_claim_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment") | .spec.template.spec.volumes[]? | select(has("ephemeral"))] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$default_ephemeral_claim_count" -ne 0 ]]; then
  printf 'default object mode rendered generic ephemeral claims\n' >&2
  exit 1
fi

ephemeral_claim_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment") | .spec.template.spec.volumes[]? | select(has("ephemeral"))] | length' - \
    < "$render_dir/attune-object-ephemeral.yaml"
})"
if [[ "$ephemeral_claim_count" -ne 4 ]]; then
  printf 'object generic ephemeral mode rendered %s inline claims, expected 4\n' "$ephemeral_claim_count" >&2
  exit 1
fi

ephemeral_cache_claims="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment" and (.metadata.labels."app.kubernetes.io/component" | test("^(action|sensor)-worker-"))) as $deployment | $deployment.spec.template.spec.volumes[] | select(.name == "packs" or .name == "runtime-envs") | [$deployment.metadata.labels."app.kubernetes.io/component", .name, (.ephemeral.volumeClaimTemplate.spec.accessModes | join(",")), .ephemeral.volumeClaimTemplate.spec.resources.requests.storage, .ephemeral.volumeClaimTemplate.spec.storageClassName] | @tsv' - \
    < "$render_dir/attune-object-ephemeral.yaml"
})"
expected_ephemeral_cache_claims=$'action-worker-full\tpacks\tReadWriteOnce\t2Gi\tverify-rwo-storage\naction-worker-full\truntime-envs\tReadWriteOnce\t10Gi\tverify-rwo-storage\nsensor-worker-default\tpacks\tReadWriteOnce\t2Gi\tverify-rwo-storage\nsensor-worker-default\truntime-envs\tReadWriteOnce\t10Gi\tverify-rwo-storage'
if [[ "$ephemeral_cache_claims" != "$expected_ephemeral_cache_claims" ]]; then
  printf 'object generic ephemeral cache claims differ from the expected per-Pod RWO claims:\n%s\n' "$ephemeral_cache_claims" >&2
  exit 1
fi

ephemeral_worker_kinds="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.labels."app.kubernetes.io/component" | test("^(action|sensor)-worker-")) | [.metadata.name, .kind] | @tsv' - \
    < "$render_dir/attune-object-ephemeral.yaml"
})"
expected_ephemeral_worker_kinds=$'verify-attune-action-worker-full\tDeployment\tverify-attune-sensor-worker-default\tDeployment'
if [[ "$ephemeral_worker_kinds" != "$expected_ephemeral_worker_kinds" ]]; then
  printf 'generic ephemeral cache mode changed worker workload kinds:\n%s\n' "$ephemeral_worker_kinds" >&2
  exit 1
fi

default_worker_identity="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment" and (.metadata.labels."app.kubernetes.io/component" | test("^(action|sensor)-worker-"))) | [.metadata.name, .metadata.labels, .spec.selector, .spec.template.metadata, .spec.template.spec.serviceAccountName] | @json' - \
    < "$render_dir/attune-object.yaml"
})"
ephemeral_worker_identity="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment" and (.metadata.labels."app.kubernetes.io/component" | test("^(action|sensor)-worker-"))) | [.metadata.name, .metadata.labels, .spec.selector, .spec.template.metadata, .spec.template.spec.serviceAccountName] | @json' - \
    < "$render_dir/attune-object-ephemeral.yaml"
})"
if [[ "$ephemeral_worker_identity" != "$default_worker_identity" ]]; then
  printf 'generic ephemeral cache mode changed worker identity\n' >&2
  exit 1
fi

ephemeral_standalone_cache_pvc_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("(packs|runtime-envs)")))] | length' - \
    < "$render_dir/attune-object-ephemeral.yaml"
})"
if [[ "$ephemeral_standalone_cache_pvc_count" -ne 0 ]]; then
  printf 'generic ephemeral cache mode rendered a standalone cache PVC\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set storage.local.mode=sharedVolume \
  > /dev/null 2>&1; then
  printf 'chart schema accepted a shared local cache mode\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set storage.local.mode=genericEphemeralVolume \
  > /dev/null 2>&1; then
  printf 'chart schema accepted generic ephemeral caches with shared-volume storage\n' >&2
  exit 1
fi

object_shared_claim_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-(packs|runtime-envs|artifacts)$")))] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$object_shared_claim_count" -ne 0 ]]; then
  printf 'object mode rendered shared pack, runtime, or artifact claims\n' >&2
  exit 1
fi

shared_claim_keep_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-(packs|runtime-envs|artifacts)$")) and .metadata.annotations."helm.sh/resource-policy" == "keep")] | length' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$shared_claim_keep_count" -ne 3 ]]; then
  printf 'expected all shared storage claims to carry the Helm keep policy\n' >&2
  exit 1
fi

retained_claim_lookup_count="$(grep -c 'lookup "v1" "PersistentVolumeClaim"' "$root_dir/charts/attune/templates/pvc.yaml")"
if [[ "$retained_claim_lookup_count" -ne 3 ]]; then
  printf 'object-mode transitions do not preserve all live shared claims in the upgraded manifest\n' >&2
  exit 1
fi

object_local_security_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select((.kind == "Deployment" or .kind == "Job") and .spec.template.spec.securityContext.fsGroup == 1000 and .spec.template.spec.securityContext.fsGroupChangePolicy == "OnRootMismatch")] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$object_local_security_count" -ne 6 ]]; then
  printf 'expected six object-mode Pods to get writable local-volume group ownership, found %s\n' "$object_local_security_count" >&2
  exit 1
fi

shared_local_security_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "Job") | select(.spec.template.metadata.labels."app.kubernetes.io/component" == "api" or .spec.template.metadata.labels."app.kubernetes.io/component" == "executor" or .spec.template.metadata.labels."app.kubernetes.io/component" == "supervisor" or .spec.template.metadata.labels."app.kubernetes.io/component" == "init-packs") | select(.spec.template.spec.securityContext.fsGroup != null)] | length' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$shared_local_security_count" -ne 0 ]]; then
  printf 'object-local volume group ownership escaped to shared-volume consumers\n' >&2
  exit 1
fi

custom_local_security_count="$({
  helm template verify "$root_dir/charts/attune" \
    --namespace verify \
    --values "$root_dir/charts/attune/ci/object-values.yaml" \
    --set storage.local.podSecurityContext.fsGroup=2000 | \
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select((.kind == "Deployment" or .kind == "Job") and .spec.template.spec.securityContext.fsGroup == 2000)] | length' -
})"
if [[ "$custom_local_security_count" -ne 6 ]]; then
  printf 'custom object-mode local-volume fsGroup did not reach every writable Pod\n' >&2
  exit 1
fi

object_unbounded_local_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.volumes[]? | select(has("emptyDir") and (.name == "packs" or .name == "runtime-envs" or .name == "artifacts" or .name == "pack-staging")) | select(.emptyDir.sizeLimit == null)] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$object_unbounded_local_count" -ne 0 ]]; then
  printf 'object mode rendered an unbounded local storage volume\n' >&2
  exit 1
fi

object_bounded_local_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.volumes[]? | select(has("emptyDir") and (.name == "packs" or .name == "runtime-envs" or .name == "artifacts" or .name == "pack-staging"))] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$object_bounded_local_count" -ne 11 ]]; then
  printf 'object mode rendered %s bounded storage volumes, expected 11\n' "$object_bounded_local_count" >&2
  exit 1
fi

log_buffer_reference_count="$(grep -c 'log-buffer\|/opt/attune/log-buffer' "$render_dir/attune-object.yaml" || true)"
if [[ "$log_buffer_reference_count" -ne 0 ]]; then
  printf 'object mode rendered an unused log-buffer volume or mount\n' >&2
  exit 1
fi

rendered_log_limits="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | [.artifacts.log_segment_max_bytes, .artifacts.flush_interval_ms] | @tsv' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$rendered_log_limits" != $'65536\t500' ]]; then
  printf 'rendered application config has the wrong runtime-log loss window: %s\n' "$rendered_log_limits" >&2
  exit 1
fi

custom_log_limits="$({
  helm template verify "$root_dir/charts/attune" \
    --set security.existingSecret=verify-runtime \
    --set artifacts.logSegmentMaxBytes=12345 \
    --set artifacts.flushIntervalMs=678 | \
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | [.artifacts.log_segment_max_bytes, .artifacts.flush_interval_ms] | @tsv' -
})"
if [[ "$custom_log_limits" != $'12345\t678' ]]; then
  printf 'operator runtime-log values did not reach application config: %s\n' "$custom_log_limits" >&2
  exit 1
fi

if grep -q 'name: wait-for-packs' "$render_dir/attune-object.yaml"; then
  printf 'object mode retained a filesystem wait-for-packs init container\n' >&2
  exit 1
fi

shared_bootstrap_marker='.attune-bootstrap-r1'
if ! grep -q "$shared_bootstrap_marker" "$render_dir/attune-shared-volume.yaml"; then
  printf 'shared-volume bootstrap does not use a revision-specific completion marker\n' >&2
  exit 1
fi
if ! grep -Fq '.attune-bootstrap-r{{ .Release.Revision }}' "$root_dir/charts/attune/templates/jobs.yaml"; then
  printf 'shared-volume bootstrap marker is not tied to the Helm release revision\n' >&2
  exit 1
fi

if grep -Eq 'name: wait-for-(packs|core-pack)' "$render_dir/attune-shared-volume.yaml"; then
  printf 'shared-volume workloads still wait for content bootstrap\n' >&2
  exit 1
fi

shared_platform_wait_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "wait-for-api-platform" and (.args[0] | contains("/health/ready")) and (.args[0] | contains("timed out after 300s")))] | length' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$shared_platform_wait_count" -ne 3 ]]; then
  printf 'executor and worker pools do not use the bounded platform-readiness wait\n' >&2
  exit 1
fi

api_probe_contract="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "api") | [.spec.template.spec.containers[0].readinessProbe.httpGet.path, .spec.template.spec.containers[0].livenessProbe.httpGet.path] | @tsv' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$api_probe_contract" != $'/health/ready\t/health/live' ]]; then
  printf 'API probes do not separate platform readiness and process liveness: %s\n' "$api_probe_contract" >&2
  exit 1
fi

ordinary_api_selector_revision="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Service" and .metadata.name == "verify-attune-api") | .spec.selector."attune.dev/release-revision" // "absent"' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$ordinary_api_selector_revision" != absent ]]; then
  printf 'ordinary internal API Service is pinned to one release revision\n' >&2
  exit 1
fi

object_init_packs_hook="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "init-packs") | .metadata.annotations."helm.sh/hook"' - \
    < "$render_dir/attune-object-upgrade.yaml"
})"
if [[ "$object_init_packs_hook" != post-upgrade ]]; then
  printf 'object-mode init-packs upgrade Job is not a post-upgrade hook\n' >&2
  exit 1
fi

object_init_user_hook="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "init-user") | .metadata.annotations."helm.sh/hook"' - \
    < "$render_dir/attune-object-upgrade.yaml"
})"
if [[ "$object_init_user_hook" != pre-upgrade ]]; then
  printf 'object-mode init-user upgrade Job is not a pre-upgrade hook\n' >&2
  exit 1
fi

object_init_packs_script="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "init-packs") | .spec.template.spec.containers[] | select(.name == "init-packs") | .args[0]' - \
    < "$render_dir/attune-object-upgrade.yaml"
})"
if [[ "$object_init_packs_script" != *'ATTUNE_API_URL'*/health/ready* || "$object_init_packs_script" != *'waiting for api'* ]]; then
  printf 'object-mode init-packs does not wait for platform API readiness before bootstrap\n' >&2
  exit 1
fi

object_init_packs_api_url="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "init-packs") | .spec.template.spec.containers[] | select(.name == "init-packs") | .env[] | select(.name == "ATTUNE_API_URL") | .value' - \
    < "$render_dir/attune-object-upgrade.yaml"
})"
if [[ "$object_init_packs_api_url" != 'http://verify-attune-api-r1:8080' ]]; then
  printf 'object-mode init-packs is not pinned to the target release revision: %s\n' "$object_init_packs_api_url" >&2
  exit 1
fi

revision_api_selector="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Service" and .metadata.name == "verify-attune-api-r1") | .spec.selector."attune.dev/release-revision"' - \
    < "$render_dir/attune-object-upgrade.yaml"
})"
if [[ "$revision_api_selector" != 1 ]]; then
  printf 'revision API Service does not select the rendered release revision\n' >&2
  exit 1
fi

fresh_object_storage_migration_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.metadata.labels."app.kubernetes.io/component" == "upgrade-pack-releases" or .metadata.labels."app.kubernetes.io/component" == "migrate-storage")] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$fresh_object_storage_migration_count" -ne 0 ]]; then
  printf 'fresh object install rendered shared-volume migration Jobs\n' >&2
  exit 1
fi

if ! grep -q 'migrateFromSharedVolume: false' "$root_dir/charts/attune/values.yaml"; then
  printf 'shared-volume migration opt-in does not default to false\n' >&2
  exit 1
fi
for storage_cutover_contract in \
  'command: \["/usr/local/bin/attune-service"\]' \
  'args: \["--upgrade-pack-releases"\]' \
  'args: \["migrate-storage"\]' \
  'helm.sh/hook-weight: "-8"' \
  'helm.sh/hook-weight: "-7"' \
  'previousReleaseUsesObjectStorage' \
  'lookup "v1" "PersistentVolumeClaim"'; do
  if ! grep -Eq "$storage_cutover_contract" "$root_dir/charts/attune/templates/jobs.yaml" "$root_dir/charts/attune/templates/_helpers.tpl"; then
    printf 'storage cutover template is missing contract %s\n' "$storage_cutover_contract" >&2
    exit 1
  fi
done

storage_cutover_command_count="$(grep -c 'command: \["/usr/local/bin/attune-service"\]' "$root_dir/charts/attune/templates/jobs.yaml")"
if [[ "$storage_cutover_command_count" -ne 2 ]]; then
  printf 'storage cutover expected two runtime service commands, found %s\n' "$storage_cutover_command_count" >&2
  exit 1
fi

rabbitmq_cookie_init_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "StatefulSet" and .spec.template.metadata.labels."app.kubernetes.io/component" == "rabbitmq") | .spec.template.spec.initContainers[] | select(.name == "ensure-cookie-permissions" and (.args[0] | contains("chmod 0600 /var/lib/rabbitmq/.erlang.cookie")))] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$rabbitmq_cookie_init_count" -ne 1 ]]; then
  printf 'RabbitMQ expected one cookie permission init container, found %s\n' "$rabbitmq_cookie_init_count" >&2
  exit 1
fi

major_upgrade_guard_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select((.name == "guard-postgresql-major-upgrade" and (.args[0] | contains("startFresh+cutover stage"))) or (.name == "guard-rabbitmq-major-upgrade" and (.args[0] | contains("majorUpgradePolicy=startFresh"))))] | length' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$major_upgrade_guard_count" -ne 2 ]]; then
  printf 'bundled infrastructure expected two major-version data guards, found %s\n' "$major_upgrade_guard_count" >&2
  exit 1
fi

bundled_image_contract="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "StatefulSet" and (.metadata.name == "verify-attune-postgresql" or .metadata.name == "verify-attune-rabbitmq")) | [.metadata.name, .spec.template.spec.containers[0].image] | @tsv' - \
    < "$render_dir/attune-object.yaml"
})"
expected_bundled_image_contract=$'verify-attune-postgresql\ttimescale/timescaledb:2.30.1-pg18@sha256:9dede0e3ccc071cf71935b17f76bf243331df0b1575338c8ac294640fcf12a36\tverify-attune-rabbitmq\trabbitmq:4.3.6-management-alpine@sha256:1aab4d911053f3ee4ff9bb231f5192ebd6a12281f8044910256a667fdb04108d'
if [[ "$bundled_image_contract" != "$expected_bundled_image_contract" ]]; then
  printf 'bundled infrastructure images are not pinned to the expected digests:\n%s\n' "$bundled_image_contract" >&2
  exit 1
fi

rabbitmq_provisioning_ttl="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "provision-rabbitmq") | .spec.ttlSecondsAfterFinished // "absent"' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$rabbitmq_provisioning_ttl" != absent ]]; then
  printf 'RabbitMQ provisioning Job TTL can race Helm resource waiting\n' >&2
  exit 1
fi

object_content_wait_count="$(grep -Ec 'name: wait-for-(core-pack|packs)' "$render_dir/attune-object.yaml" || true)"
if [[ "$object_content_wait_count" -ne 0 ]]; then
  printf 'object-mode workloads still wait for content readiness\n' >&2
  exit 1
fi

object_identity_consumers="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment" and .spec.template.spec.serviceAccountName != null) | .spec.template.metadata.labels."app.kubernetes.io/component"] | sort | join(",")' - \
    < "$render_dir/attune-object.yaml"
})"
if [[ "$object_identity_consumers" != 'api,supervisor' ]]; then
  printf 'object identity escaped API and supervisor: %s\n' "$object_identity_consumers" >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=verify-runtime \
  --set storage.mode=object \
  --set storage.object.bucket=verify-attune-objects \
  --set storage.object.region=us-east-1 \
  --set api.storageMode=sharedVolume \
  > /dev/null 2>&1; then
  printf 'chart schema accepted a mixed per-service storage mode\n' >&2
  exit 1
fi

"${helm_316[@]}" template verify charts/attune \
  --namespace verify \
  --set-string security.existingSecret=verify-runtime \
  --set-json packRegistry.standardIndexRef=null > "$render_dir/attune-rancher-null.yaml"
if ! grep -q 'value: "b50e4e6d5003717505c7b894f14b8049de32c735"' "$render_dir/attune-rancher-null.yaml"; then
  printf 'Rancher null override did not restore the pinned standard index ref\n' >&2
  exit 1
fi

"${helm_316[@]}" template verify charts/attune \
  --namespace verify \
  --set-string security.existingSecret=verify-runtime \
  --set-json web.ingress.className=null \
  --set-json security.oidc.discoveryUrl=null \
  --set-json web.config.apiUrl=null \
  --set-json database.host=null \
  --set-json rabbitmq.host=null \
  --set-json api.resources=null \
  --set-json images.api.tag=null \
  --set-json sharedStorage.packs.storageClassName=null \
  --set-string sharedStorage.packs.size=1e6 \
  --set-json actionWorkers=null \
  --set-json sensorWorkers=null \
  > "$render_dir/attune-optional-values.yaml"

"${helm_316[@]}" template verify charts/attune \
  --namespace verify \
  --set-string security.existingSecret=verify-runtime \
  --set-json 'actionWorkers=[{"name":"minimal-action","image":"python:3.12"}]' \
  --set-json 'sensorWorkers=[{"name":"minimal-sensor","image":"python:3.12"}]' \
  > "$render_dir/attune-minimal-workers.yaml"

if "${helm_316[@]}" template verify charts/attune \
  --namespace verify \
  --set-string security.existingSecret=verify-runtime \
  --set-json 'actionWorkers=[{"name":"stopped","image":"python:3.12","replicas":0}]' \
  > /dev/null 2>&1; then
  printf 'chart accepted a worker replica count that templates cannot preserve\n' >&2
  exit 1
fi

if rancher_type_error="$({
  "${helm_316[@]}" template verify charts/attune \
    --namespace verify \
    --set-string security.existingSecret=verify-runtime \
    --set-json 'packRegistry.standardIndexRef={}' 2>&1
})"; then
  printf 'chart accepted a map for packRegistry.standardIndexRef\n' >&2
  exit 1
fi
if [[ "$rancher_type_error" != *standardIndexRef* ||
  "$rancher_type_error" == *regexMatch* ||
  "$rancher_type_error" == *'wrong type for value'* ||
  "$rancher_type_error" == *'YAML parse error'* ]]; then
  printf 'chart returned an unhelpful standardIndexRef type error\n' >&2
  exit 1
fi

if rancher_scalar_error="$({
  "${helm_316[@]}" template verify charts/attune \
    --namespace verify \
    --set-string security.existingSecret=verify-runtime \
    --set-string 'api.service.type=foo: bar' 2>&1
})"; then
  printf 'chart accepted an invalid service type\n' >&2
  exit 1
fi
if [[ "$rancher_scalar_error" != *api.service.type* ||
  "$rancher_scalar_error" == *'YAML parse error'* ]]; then
  printf 'chart returned an unhelpful Rancher scalar error\n' >&2
  exit 1
fi

if grep -Eq 'kind: (Secret|StatefulSet).*postgresql|name: verify-attune-postgresql' \
  "$render_dir/attune-cnpg.yaml"; then
  printf 'external CNPG configuration rendered bundled PostgreSQL resources\n' >&2
  exit 1
fi

if ! grep -q 'name: "verify-attune-provision-rabbitmq-' "$render_dir/attune-cnpg.yaml"; then
  printf 'generated setup did not render RabbitMQ provisioning\n' >&2
  exit 1
fi

if ! grep -q 'image: docker.io/timescale/timescaledb-ha:pg18.6-ts2.30.1@sha256:131bfdf82ec0dfe42eaa3f4a189f8e04b7b1dc2b27705cfd921e55ebef339840' \
  "$render_dir/setup/timescaledb.yaml"; then
  printf 'generated setup does not pin the expected TimescaleDB image\n' >&2
  exit 1
fi
if [[ "$(grep -c 'major: 18' "$render_dir/setup/timescaledb.yaml")" -ne 2 ]]; then
  printf 'generated setup does not declare PostgreSQL major version 18\n' >&2
  exit 1
fi

cp -a "$render_dir/setup" "$render_dir/setup-bundled"
"${setup_generator[@]}" \
    --database-mode bundled \
    --namespace verify \
    --release verify \
    --output-dir "$render_dir/setup-bundled" \
    --force >/dev/null

if [[ -e "$render_dir/setup-bundled/timescaledb.yaml" ]]; then
  printf 'bundled mode retained a stale CNPG manifest\n' >&2
  exit 1
fi

bundled_runtime_database_password="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data.DB_PASSWORD | @base64d' - \
    < "$render_dir/setup-bundled/secrets.yaml"
})"
if [[ "$bundled_runtime_database_password" != "$database_password" ]]; then
  printf 'mode transition changed the database service password\n' >&2
  exit 1
fi
cnpg_encryption_key="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data."ATTUNE__SECURITY__ENCRYPTION_KEY"' - \
    < "$render_dir/setup/secrets.yaml"
})"
bundled_encryption_key="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data."ATTUNE__SECURITY__ENCRYPTION_KEY"' - \
    < "$render_dir/setup-bundled/secrets.yaml"
})"
if [[ "$cnpg_encryption_key" != "$bundled_encryption_key" ]]; then
  printf 'mode transition changed Attune encryption key\n' >&2
  exit 1
fi

helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$render_dir/setup-bundled/values.yaml" > "$render_dir/attune-bundled.yaml"

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/setup-bundled/secrets.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-bundled.yaml"

for bundled_resource in \
  verify-attune-postgresql \
  verify-attune-rabbitmq \
  verify-attune-provision-postgresql- \
  verify-attune-provision-rabbitmq-; do
  if ! grep -q "name: \"${bundled_resource}" "$render_dir/attune-bundled.yaml"; then
    printf 'bundled setup did not render %s\n' "$bundled_resource" >&2
    exit 1
  fi
done

rabbitmq_password_reconciliations="$({
  grep -Fc 'body={"password": os.environ["RABBITMQ_PASSWORD"], "tags": ""}' \
    "$render_dir/attune-bundled.yaml"
})"
if [[ "$rabbitmq_password_reconciliations" -ne 2 ]]; then
  printf 'RabbitMQ provisioner does not reconcile both new and existing user passwords\n' >&2
  exit 1
fi
if grep -q 'body={"password_hash": existing_user\["password_hash"\]' "$render_dir/attune-bundled.yaml"; then
  printf 'RabbitMQ provisioner preserves a stale existing user password\n' >&2
  exit 1
fi

ATTUNE_SETUP_DATABASE_PASSWORD='external@database:password' \
ATTUNE_SETUP_RABBITMQ_PASSWORD='external@rabbitmq:password' \
ATTUNE_SETUP_JWT_SECRET=jwt-secret-with-at-least-32-characters \
ATTUNE_SETUP_ENCRYPTION_KEY=encryption-key-with-at-least-32-characters \
  "$root_dir/scripts/generate-attune-setup.sh" \
    --database-mode external \
    --database-host db.example.com \
    --database-user 'attune@app' \
    --database-sslmode require \
    --rabbitmq-mode external \
    --rabbitmq-host mq.example.com \
    --rabbitmq-user 'attune:agent' \
    --rabbitmq-port 5671 \
    --rabbitmq-scheme amqps \
    --rabbitmq-vhost /attune-prod \
    --namespace verify \
    --release verify \
    --output-dir "$render_dir/setup-external" >/dev/null

helm lint --strict "$root_dir/charts/attune" \
  --values "$render_dir/setup-external/values.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$render_dir/setup-external/values.yaml" > "$render_dir/attune-external.yaml"

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/setup-external/secrets.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-external.yaml"

if grep -Eq 'name: "verify-attune-(postgresql|rabbitmq|provision-postgresql-|provision-rabbitmq-)' \
  "$render_dir/attune-external.yaml"; then
  printf 'external setup rendered bundled data services or provisioners\n' >&2
  exit 1
fi

external_database_url="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data."ATTUNE__DATABASE__URL" | @base64d' - \
    < "$render_dir/setup-external/secrets.yaml"
})"
if [[ "$external_database_url" != 'postgresql://attune%40app:external%40database%3Apassword@db.example.com:5432/attune?sslmode=require' ]]; then
  printf 'external setup has the wrong database URL\n' >&2
  exit 1
fi
external_rabbitmq_url="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data."ATTUNE__MESSAGE_QUEUE__URL" | @base64d' - \
    < "$render_dir/setup-external/secrets.yaml"
})"
if [[ "$external_rabbitmq_url" != 'amqps://attune%3Aagent:external%40rabbitmq%3Apassword@mq.example.com:5671/%2Fattune-prod' ]]; then
  printf 'external setup has the wrong RabbitMQ URL\n' >&2
  exit 1
fi

bundled_database_size="$({
  docker run --rm -i mikefarah/yq:4.47.2 '.database.postgresql.persistence.size' - \
    < "$render_dir/setup-bundled/values.yaml"
})"
if [[ "$bundled_database_size" != 20Gi ]]; then
  printf 'bundled setup did not pass database size to the chart\n' >&2
  exit 1
fi

if ! grep -q 'secretName: "attune.example.com-tls"' "$render_dir/setup/values.yaml"; then
  printf 'generated ingress did not reference its required TLS Secret\n' >&2
  exit 1
fi
if ! grep -qx 'secrets.yaml' "$render_dir/setup/.gitignore"; then
  printf 'generated output does not protect secrets.yaml from Git\n' >&2
  exit 1
fi
if ! grep -qx 'credentials.state' "$render_dir/setup/.gitignore"; then
  printf 'generated output does not protect credentials.state from Git\n' >&2
  exit 1
fi
if ! grep -qx '.credentials.state.\*' "$render_dir/setup/.gitignore"; then
  printf 'generated output does not protect temporary credential state from Git\n' >&2
  exit 1
fi

ATTUNE_SETUP_DATABASE_PASSWORD='  short' \
ATTUNE_SETUP_RABBITMQ_PASSWORD=short \
  "$root_dir/scripts/generate-attune-setup.sh" \
    --database-mode external \
    --database-host db.example.com \
    --rabbitmq-mode external \
    --rabbitmq-host mq.example.com \
    --output-dir "$render_dir/setup-round-trip" >/dev/null

round_trip_password="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "attune-runtime") | .data.DB_PASSWORD | @base64d' - \
    < "$render_dir/setup-round-trip/secrets.yaml"
})"
if [[ "$round_trip_password" != '  short' ]]; then
  printf 'generated Secret did not preserve leading password whitespace\n' >&2
  exit 1
fi

"$root_dir/scripts/generate-attune-setup.sh" \
  --database-mode external \
  --database-host db.example.com \
  --rabbitmq-mode external \
  --rabbitmq-host mq.example.com \
  --output-dir "$render_dir/setup-round-trip" \
  --force >/dev/null
preserved_external_password="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "attune-runtime") | .data.DB_PASSWORD | @base64d' - \
    < "$render_dir/setup-round-trip/secrets.yaml"
})"
if [[ "$preserved_external_password" != '  short' ]]; then
  printf 'external regeneration did not preserve its saved password\n' >&2
  exit 1
fi

for corrupt_state in empty truncated empty-value malformed duplicate; do
  corrupt_dir="$render_dir/setup-state-$corrupt_state"
  cp -a "$render_dir/setup-round-trip" "$corrupt_dir"
  case "$corrupt_state" in
    empty)
      : > "$corrupt_dir/credentials.state"
      ;;
    truncated)
      printf 'DATABASE_MODE\texternal\n' > "$corrupt_dir/credentials.state"
      ;;
    empty-value)
      empty_value_tmp="$corrupt_dir/credentials.state.tmp"
      while IFS=$'\t' read -r state_key state_value; do
        if [[ "$state_key" == DATABASE_PASSWORD_B64 ]]; then
          state_value=""
        fi
        printf '%s\t%s\n' "$state_key" "$state_value"
      done < "$corrupt_dir/credentials.state" > "$empty_value_tmp"
      mv "$empty_value_tmp" "$corrupt_dir/credentials.state"
      ;;
    malformed)
      malformed_tmp="$corrupt_dir/credentials.state.tmp"
      while IFS=$'\t' read -r state_key state_value; do
        if [[ "$state_key" == JWT_SECRET_B64 ]]; then
          state_value='%%%'
        fi
        printf '%s\t%s\n' "$state_key" "$state_value"
      done < "$corrupt_dir/credentials.state" > "$malformed_tmp"
      mv "$malformed_tmp" "$corrupt_dir/credentials.state"
      ;;
    duplicate)
      printf 'DATABASE_MODE\texternal\n' >> "$corrupt_dir/credentials.state"
      ;;
  esac
  corrupt_checksum="$(sha256sum "$corrupt_dir/credentials.state")"
  if "$root_dir/scripts/generate-attune-setup.sh" \
    --database-mode external \
    --database-host db.example.com \
    --rabbitmq-mode external \
    --rabbitmq-host mq.example.com \
    --output-dir "$corrupt_dir" \
    --force >/dev/null 2>&1; then
    printf 'setup generator accepted %s credential state\n' "$corrupt_state" >&2
    exit 1
  fi
  if [[ "$(sha256sum "$corrupt_dir/credentials.state")" != "$corrupt_checksum" ]]; then
    printf 'failed regeneration modified %s credential state\n' "$corrupt_state" >&2
    exit 1
  fi
done

cp -a "$render_dir/setup" "$render_dir/setup-rotate"
old_encryption_key="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data."ATTUNE__SECURITY__ENCRYPTION_KEY"' - \
    < "$render_dir/setup-rotate/secrets.yaml"
})"
"$root_dir/scripts/generate-attune-setup.sh" \
  --output-dir "$render_dir/setup-rotate" \
  --rotate-secrets >/dev/null
new_encryption_key="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.metadata.name == "attune-runtime") | .data."ATTUNE__SECURITY__ENCRYPTION_KEY"' - \
    < "$render_dir/setup-rotate/secrets.yaml"
})"
if [[ -z "$new_encryption_key" || "$old_encryption_key" == "$new_encryption_key" ]]; then
  printf 'explicit secret rotation did not replace generated credentials\n' >&2
  exit 1
fi

: > "$render_dir/attune-mode-matrix.yaml"
for mode_pair in \
  'cnpg bundled' \
  'cnpg external' \
  'bundled bundled' \
  'bundled external' \
  'external bundled' \
  'external external'; do
  read -r database_mode rabbitmq_mode <<< "$mode_pair"
  mode_name="${database_mode}-${rabbitmq_mode}"
  mode_args=(
    --database-mode "$database_mode"
    --rabbitmq-mode "$rabbitmq_mode"
    --namespace verify
    --release verify
    --output-dir "$render_dir/setup-$mode_name"
  )
  if [[ "$database_mode" == external ]]; then
    mode_args+=(--database-host db.example.com)
  fi
  if [[ "$rabbitmq_mode" == external ]]; then
    mode_args+=(--rabbitmq-host mq.example.com)
  fi

  "${setup_generator[@]}" "${mode_args[@]}" >/dev/null

  helm template verify "$root_dir/charts/attune" \
    --namespace verify \
    --values "$render_dir/setup-$mode_name/values.yaml" > "$render_dir/attune-$mode_name.yaml"
  printf '%s\n' '---' >> "$render_dir/attune-mode-matrix.yaml"
  cat "$render_dir/attune-$mode_name.yaml" >> "$render_dir/attune-mode-matrix.yaml"

  postgresql_rendered=false
  rabbitmq_rendered=false
  grep -q 'name: "verify-attune-postgresql"' "$render_dir/attune-$mode_name.yaml" && postgresql_rendered=true
  grep -q 'name: "verify-attune-rabbitmq"' "$render_dir/attune-$mode_name.yaml" && rabbitmq_rendered=true
  if [[ "$postgresql_rendered" != "$([[ "$database_mode" == bundled ]] && printf true || printf false)" ]]; then
    printf 'database mode %s rendered the wrong PostgreSQL resources\n' "$database_mode" >&2
    exit 1
  fi
  if [[ "$rabbitmq_rendered" != "$([[ "$rabbitmq_mode" == bundled ]] && printf true || printf false)" ]]; then
    printf 'RabbitMQ mode %s rendered the wrong resources\n' "$rabbitmq_mode" >&2
    exit 1
  fi
  if [[ "$rabbitmq_mode" == external ]] &&
    [[ "$({
      docker run --rm -i mikefarah/yq:4.47.2 \
        eval-all --no-doc 'select(.metadata.name == "verify-runtime") | .data."ATTUNE__MESSAGE_QUEUE__URL" | @base64d' - \
        < "$render_dir/setup-$mode_name/secrets.yaml"
    })" != 'amqps://attune:rabbitmq-password-123456@mq.example.com:5671/%2F' ]]; then
      printf 'external RabbitMQ mode did not default to AMQPS port 5671\n' >&2
      exit 1
  fi
done

default_shared_modes="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "PersistentVolumeClaim") | [.metadata.name, .spec.accessModes[0]] | @tsv' - \
    < "$render_dir/attune-bundled-bundled.yaml"
})"
expected_default_shared_modes=$'verify-attune-packs\tReadWriteOnce\tverify-attune-runtime-envs\tReadWriteOnce\tverify-attune-artifacts\tReadWriteOnce'
if [[ "$default_shared_modes" != "$expected_default_shared_modes" ]]; then
  printf 'default shared PVC access mode changed from ReadWriteOnce\n' >&2
  exit 1
fi

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-mode-matrix.yaml"

if "$root_dir/scripts/generate-attune-setup.sh" \
  --ingress-host exposed.example.com \
  --ingress-tls-secret exposed-example-com-tls \
  --output-dir "$render_dir/setup-known-password" >/dev/null 2>&1; then
  printf 'setup generator exposed the known bootstrap password without explicit consent\n' >&2
  exit 1
fi

if ATTUNE_SETUP_DATABASE_PASSWORD=external-password \
  "$root_dir/scripts/generate-attune-setup.sh" \
    --database-mode external \
    --database-host 'db..example.com' \
    --output-dir "$render_dir/setup-invalid-external-host" >/dev/null 2>&1; then
  printf 'setup generator accepted an invalid external hostname\n' >&2
  exit 1
fi

if ATTUNE_SETUP_DATABASE_PASSWORD=external-password \
  "$root_dir/scripts/generate-attune-setup.sh" \
    --database-mode external \
    --database-host db.example.com \
    --database-sslmode verify-full \
    --output-dir "$render_dir/setup-unsupported-ca" >/dev/null 2>&1; then
  printf 'setup generator accepted unsupported PostgreSQL CA verification\n' >&2
  exit 1
fi

quoted_output_dir="$render_dir/setup path;literal"
quoted_output="$({
  "${setup_generator[@]}" --output-dir "$quoted_output_dir"
})"
printf -v expected_quoted_values_path '%q' "$quoted_output_dir/values.yaml"
if [[ "$quoted_output" != *"--values $expected_quoted_values_path"* ]]; then
  printf 'setup generator printed an unsafe output path\n' >&2
  exit 1
fi

if "$root_dir/scripts/generate-attune-setup.sh" \
  --ingress-host 'Invalid..example.com' \
  --ingress-tls-secret invalid-host-tls \
  --confirm-bootstrap-password-changed \
  --output-dir "$render_dir/setup-invalid-host" >/dev/null 2>&1; then
  printf 'setup generator accepted an invalid Kubernetes ingress hostname\n' >&2
  exit 1
fi

if "$root_dir/scripts/generate-attune-setup.sh" \
  --database-user postgres \
  --output-dir "$render_dir/setup-cnpg-postgres" >/dev/null 2>&1; then
  printf 'setup generator accepted the CNPG postgres administrator as its application user\n' >&2
  exit 1
fi

if "$root_dir/scripts/generate-attune-setup.sh" \
  --release aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --output-dir "$render_dir/setup-long-release" >/dev/null 2>&1; then
  printf 'setup generator accepted a release name that produces oversized resources\n' >&2
  exit 1
fi

for chart in "$root_dir"/charts/*; do
  chart_name="$(basename "$chart")"
  chart_args=()
  if [[ "$chart_name" == attune ]]; then
    chart_args+=(--set security.existingSecret=verify-attune-secrets)
  fi
  helm lint --strict "$chart" "${chart_args[@]}"
  helm template verify "$chart" --namespace verify "${chart_args[@]}" > "$render_dir/$chart_name.yaml"
  docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
    -strict -summary < "$render_dir/$chart_name.yaml"

  if [[ "${ATTUNE_VERIFY_SKIP_PACKAGE_CHECK:-false}" != true ]]; then
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
  fi
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

helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --set security.existingSecret=attune-service-secrets \
  --set security.identitySecret.existingSecret=attune-identity \
  --set security.oidc.enabled=true \
  --set-string security.oidc.discoveryUrl=https://login.example.com/.well-known/openid-configuration \
  --set-string security.oidc.clientId=attune \
  --set-string security.oidc.redirectUri=https://attune.example.com/auth/callback \
  --set-json 'security.oidc.scopes=["groups"]' \
  --set security.activeDirectory.enabled=true \
  --set-string security.activeDirectory.url=ldaps://ad.example.com:636 \
  --set-string 'security.activeDirectory.userSearchBase=ou=users\,dc=example\,dc=com' \
  --set-string 'security.activeDirectory.searchBindDn=cn=attune\,ou=services\,dc=example\,dc=com' \
  > "$render_dir/attune-identity.yaml"

identity_config="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "ConfigMap") | .data."config.yaml"' - \
    < "$render_dir/attune-identity.yaml"
})"

for expected_setting in \
  'discovery_url: "https://login.example.com/.well-known/openid-configuration"' \
  'scopes: ["groups"]' \
  'url: "ldaps://ad.example.com:636"' \
  'user_filter: "(sAMAccountName={login})"'; do
  if [[ "$identity_config" != *"$expected_setting"* ]]; then
    printf 'identity config is missing %s\n' "$expected_setting" >&2
    exit 1
  fi
done

identity_secret_consumers="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc \
    '[select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.envFrom[]?.secretRef.name == "attune-identity")] | length' - \
    < "$render_dir/attune-identity.yaml"
})"
if [[ "$identity_secret_consumers" -ne 1 ]]; then
  printf 'expected only the API to import the identity Secret, found %s consumers\n' "$identity_secret_consumers" >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=attune-service-secrets \
  --set security.oidc.enabled=true \
  > /dev/null 2>&1; then
  printf 'OIDC rendered without its required provider settings\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=attune-service-secrets \
  --set security.activeDirectory.enabled=true \
  --set-string security.activeDirectory.url=ldaps://ad.example.com:636 \
  > /dev/null 2>&1; then
  printf 'Active Directory rendered without a bind mode\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --set security.existingSecret=attune-service-secrets \
  --set-string security.activeDirectory.searchBindDn=cn=attune \
  > /dev/null 2>&1; then
  printf 'Active Directory rendered with partial search-bind credentials\n' >&2
  exit 1
fi

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
  --set security.existingSecret=attune-service-secrets \
  --set database.postgresql.provisioning.enabled=true \
  > /dev/null 2>&1; then
  printf 'PostgreSQL provisioning rendered without required existing Secrets\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --set security.existingSecret=attune-service-secrets \
  --set rabbitmq.provisioning.enabled=true \
  > /dev/null 2>&1; then
  printf 'RabbitMQ provisioning rendered without required existing Secrets\n' >&2
  exit 1
fi

if helm template verify "$root_dir/charts/attune" > /dev/null 2>&1; then
  printf 'Attune rendered without a runtime Kubernetes Secret\n' >&2
  exit 1
fi

if grep -Eq '^[[:space:]]+(jwtSecret|encryptionKey|clientSecret|searchBindPassword|password):' \
  "$root_dir/charts/attune/values.yaml"; then
  printf 'values.yaml contains a literal secret field\n' >&2
  exit 1
fi

pre_upgrade_hook_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.annotations."helm.sh/hook" == "pre-upgrade")] | length' - \
    < "$render_dir/attune-upgrade.yaml"
})"

if [[ "$pre_upgrade_hook_count" -ne 5 ]]; then
  printf 'expected five pre-upgrade Jobs, found %d\n' "$pre_upgrade_hook_count" >&2
  exit 1
fi

pre_upgrade_hook_names="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.annotations."helm.sh/hook" == "pre-upgrade") | .metadata.name] | sort | join(",")' - \
    < "$render_dir/attune-upgrade.yaml"
})"
expected_hook_names='verify-attune-init-packs,verify-attune-init-user,verify-attune-migrations,verify-attune-postgresql-major-preflight,verify-attune-provision-postgresql'
if [[ "$pre_upgrade_hook_names" != "$expected_hook_names" ]]; then
  printf 'pre-upgrade Jobs do not use stable retry-safe names: %s\n' "$pre_upgrade_hook_names" >&2
  exit 1
fi

complete_preflight_script="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "postgresql-major-preflight") | .spec.template.spec.containers[0].args[0]' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ "$complete_preflight_script" != *'server_major "$MAINTENANCE_DB_HOST"'* ]] || \
   [[ "$complete_preflight_script" != *'PostgreSQL 18 is ready through the maintenance Service'* ]] || \
   [[ "$complete_preflight_script" != *'ordinary_major="$(server_major "$ORDINARY_DB_HOST"'* ]] || \
   [[ "$complete_preflight_script" != *'PostgreSQL 18 is ready through the existing ordinary Service'* ]] || \
   [[ "$complete_preflight_script" != *'"$ordinary_major" = 16'* ]] || \
   [[ "$complete_preflight_script" != *'refusing complete stage: the existing ordinary Service still reaches PostgreSQL 16'* ]] || \
   [[ "$complete_preflight_script" != *'ordinary Service reached unsupported PostgreSQL major'* ]] || \
   [[ "$complete_preflight_script" != *'default_transaction_read_only=on'* ]]; then
  printf 'complete-stage preflight does not distinguish read-only maintenance and ordinary Service detection\n' >&2
  exit 1
fi

mutation_host_override_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and (.metadata.labels."app.kubernetes.io/component" == "provision-postgresql" or .metadata.labels."app.kubernetes.io/component" == "migrations" or .metadata.labels."app.kubernetes.io/component" == "init-user" or .metadata.labels."app.kubernetes.io/component" == "init-packs")) | (.spec.template.spec.initContainers[]?.env[]?, .spec.template.spec.containers[]?.env[]?) | select(.name == "DB_HOST" and .value == "verify-attune-postgresql-maintenance")] | length' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ "$mutation_host_override_count" -ne 5 ]]; then
  printf 'bundled database mutation Jobs do not all use the maintenance Service, found %s overrides\n' "$mutation_host_override_count" >&2
  exit 1
fi
bundled_database_url_suppression_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and (.metadata.labels."app.kubernetes.io/component" == "migrations" or .metadata.labels."app.kubernetes.io/component" == "init-user" or .metadata.labels."app.kubernetes.io/component" == "init-packs")) | .spec.template.spec.containers[] | .env[]? | select(.name == "ATTUNE__DATABASE__URL" and .value == "")] | length' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ "$bundled_database_url_suppression_count" -ne 3 ]]; then
  printf 'bundled mutation Jobs can bypass DB_HOST through ATTUNE__DATABASE__URL\n' >&2
  exit 1
fi
if [[ "$(grep -c 'name: DB_HOST' "$root_dir/charts/attune/templates/jobs.yaml")" -lt 5 ]] || \
   [[ "$(grep -c 'attune.databaseMutationHost' "$root_dir/charts/attune/templates/jobs.yaml")" -lt 5 ]] || \
   [[ "$(grep -c 'name: ATTUNE__DATABASE__URL' "$root_dir/charts/attune/templates/jobs.yaml")" -lt 5 ]]; then
  printf 'database-mutating storage Jobs are missing maintenance Service overrides\n' >&2
  exit 1
fi

bounded_upgrade_bootstrap_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and (.metadata.labels."app.kubernetes.io/component" == "init-user" or .metadata.labels."app.kubernetes.io/component" == "init-packs") and .spec.activeDeadlineSeconds == 300)] | length' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ "$bounded_upgrade_bootstrap_count" -ne 2 ]]; then
  printf 'expected init-user and init-packs Jobs to have a 300-second deadline\n' >&2
  exit 1
fi

init_user_upgrade_hook="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "init-user") | .metadata.annotations."helm.sh/hook" // ""' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ "$init_user_upgrade_hook" != pre-upgrade ]]; then
  printf 'shared-volume init-user upgrade Job is not a pre-upgrade hook\n' >&2
  exit 1
fi

rabbitmq_upgrade_hook="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "provision-rabbitmq") | .metadata.annotations."helm.sh/hook" // ""' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ -n "$rabbitmq_upgrade_hook" ]]; then
  printf 'RabbitMQ provisioning must be a normal upgrade resource, found hook %s\n' "$rabbitmq_upgrade_hook" >&2
  exit 1
fi
