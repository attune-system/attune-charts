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

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-cnpg.yaml"

notifier_port="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "ConfigMap") | .data."config.yaml" | from_yaml | .notifier.port' - \
    < "$render_dir/attune-cnpg.yaml"
})"
if [[ "$notifier_port" != 8081 ]]; then
  printf 'rendered application config is missing the notifier listener\n' >&2
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

helm lint --strict "$root_dir/charts/attune" \
  --values "$root_dir/charts/attune/ci/object-ephemeral-values.yaml"
helm template verify "$root_dir/charts/attune" \
  --namespace verify \
  --values "$root_dir/charts/attune/ci/object-ephemeral-values.yaml" \
  > "$render_dir/attune-object-ephemeral.yaml"

docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-shared-volume.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-object.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-object-upgrade.yaml"
docker run --rm -i ghcr.io/yannh/kubeconform:v0.7.0 \
  -strict -summary < "$render_dir/attune-object-ephemeral.yaml"

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
    eval-all --no-doc '[select(.kind == "Deployment" or .kind == "Job") | select(.spec.template.spec.securityContext.fsGroup != null)] | length' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$shared_local_security_count" -ne 0 ]]; then
  printf 'local-volume group ownership escaped object mode\n' >&2
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
if ! grep -Fq '.attune-bootstrap-r{{ .Release.Revision }}' "$root_dir/charts/attune/templates/jobs.yaml" || \
   ! grep -Fq '.attune-bootstrap-r{{ .Release.Revision }}' "$root_dir/charts/attune/templates/applications.yaml"; then
  printf 'shared-volume bootstrap marker is not tied to the Helm release revision\n' >&2
  exit 1
fi

shared_api_wait="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "api") | .spec.template.spec.initContainers[] | select(.name == "wait-for-packs") | .args[0]' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$shared_api_wait" != *"$shared_bootstrap_marker"* ]]; then
  printf 'shared-volume API does not wait for the current bootstrap marker\n' >&2
  exit 1
fi

if grep -q 'name: wait-for-packs' "$render_dir/attune-shared-volume.yaml" && \
   [[ "$(grep -c 'name: wait-for-packs' "$render_dir/attune-shared-volume.yaml")" -ne 1 ]]; then
  printf 'shared-volume consumers still use filesystem-only pack readiness\n' >&2
  exit 1
fi

shared_core_wait_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "wait-for-core-pack")] | length' - \
    < "$render_dir/attune-shared-volume.yaml"
})"
if [[ "$shared_core_wait_count" -ne 3 ]]; then
  printf 'shared-volume consumers do not wait for API pack readiness\n' >&2
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

object_init_packs_script="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "init-packs") | .spec.template.spec.containers[] | select(.name == "init-packs") | .args[0]' - \
    < "$render_dir/attune-object-upgrade.yaml"
})"
if [[ "$object_init_packs_script" != *'ATTUNE_API_URL'*/health* || "$object_init_packs_script" == *'/health/ready'* || "$object_init_packs_script" != *'waiting for api'* ]]; then
  printf 'object-mode init-packs does not wait for basic API health before bootstrap\n' >&2
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
  'command: \["attune-api"\]' \
  'args: \["--upgrade-pack-releases"\]' \
  'command: \["attune-supervisor"\]' \
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

object_core_wait_count="$(grep -c 'name: wait-for-core-pack' "$render_dir/attune-object.yaml")"
if [[ "$object_core_wait_count" -ne 3 ]]; then
  printf 'object mode expected executor and both worker pools to wait for the core pack, found %s\n' "$object_core_wait_count" >&2
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

if ! grep -q 'image: docker.io/timescale/timescaledb-ha:pg16.15-ts2.29.2@sha256:903669a95321e439a181e2b350d6242a0af2e0ed2629196489780d1e58c46816' \
  "$render_dir/setup/timescaledb.yaml"; then
  printf 'generated setup does not pin the expected TimescaleDB image\n' >&2
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

if [[ "$pre_upgrade_hook_count" -ne 4 ]]; then
  printf 'expected four pre-upgrade Jobs, found %d\n' "$pre_upgrade_hook_count" >&2
  exit 1
fi

pre_upgrade_hook_names="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.annotations."helm.sh/hook" == "pre-upgrade") | .metadata.name] | sort | join(",")' - \
    < "$render_dir/attune-upgrade.yaml"
})"
expected_hook_names='verify-attune-init-packs,verify-attune-init-user,verify-attune-migrations,verify-attune-provision-postgresql'
if [[ "$pre_upgrade_hook_names" != "$expected_hook_names" ]]; then
  printf 'pre-upgrade Jobs do not use stable retry-safe names: %s\n' "$pre_upgrade_hook_names" >&2
  exit 1
fi

bounded_pre_upgrade_hook_count="$({
  docker run --rm -i mikefarah/yq:4.47.2 \
    eval-all --no-doc '[select(.kind == "Job" and .metadata.annotations."helm.sh/hook" == "pre-upgrade" and .spec.activeDeadlineSeconds == 600)] | length' - \
    < "$render_dir/attune-upgrade.yaml"
})"
if [[ "$bounded_pre_upgrade_hook_count" -ne 4 ]]; then
  printf 'expected every pre-upgrade Job to have a 600-second deadline\n' >&2
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
