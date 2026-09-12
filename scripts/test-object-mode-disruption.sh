#!/usr/bin/env bash
set -euo pipefail

namespace=attune-object-test
release=attune
duration_seconds=86400
interval_seconds=30
output=object-mode-disruption.tsv
self_test=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="$2"; shift 2 ;;
    --release) release="$2"; shift 2 ;;
    --duration-seconds) duration_seconds="$2"; shift 2 ;;
    --interval-seconds) interval_seconds="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --self-test) self_test=true; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! [[ "$duration_seconds" =~ ^[1-9][0-9]*$ && "$interval_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'duration and interval must be positive integers\n' >&2
  exit 2
fi

printf 'timestamp\tcycle\taction\tresult\n' > "$output"
started="$(date +%s)"
deadline=$((started + duration_seconds))
cycle=0

if [[ "$self_test" == true ]]; then
  while (( $(date +%s) < deadline )); do
    cycle=$((cycle + 1))
    printf '%s\t%d\tself-test-disruption\tpass\n' "$(date -u +%FT%TZ)" "$cycle" >> "$output"
    sleep "$interval_seconds"
    printf '%s\t%d\tself-test-invariants\tpass\n' "$(date -u +%FT%TZ)" "$cycle" >> "$output"
  done
  (( cycle >= 3 )) || { printf 'self-test completed fewer than three cycles\n' >&2; exit 1; }
  printf 'self-test passed %d disruption cycles in %d seconds\n' "$cycle" "$duration_seconds"
  exit 0
fi

if [[ "${ATTUNE_ALLOW_DISRUPTION:-}" != true ]]; then
  printf 'set ATTUNE_ALLOW_DISRUPTION=true to delete pods in the target release\n' >&2
  exit 2
fi
if [[ -z "${ATTUNE_DISRUPTION_WORKLOAD_COMMAND:-}" || -z "${ATTUNE_DISRUPTION_VERIFY_COMMAND:-}" ]]; then
  printf 'set ATTUNE_DISRUPTION_WORKLOAD_COMMAND and ATTUNE_DISRUPTION_VERIFY_COMMAND\n' >&2
  printf 'the verifier must check mixed releases, artifact digests, log sequences, and pending-upload age\n' >&2
  exit 2
fi

node_count="$(kubectl get nodes --no-headers | awk '$2 == "Ready" { count++ } END { print count + 0 }')"
if (( node_count < 3 )); then
  printf 'the disruption run requires at least three ready nodes, found %s\n' "$node_count" >&2
  exit 1
fi

config_name="${release}-attune-config"
config="$(kubectl --namespace "$namespace" get configmap "$config_name" -o jsonpath='{.data.config\.yaml}')"
if [[ "$config" != *'provider: "s3"'* && "$config" != *'provider: "gcs"'* ]]; then
  printf 'target release is not using object storage\n' >&2
  exit 1
fi
if kubectl --namespace "$namespace" get pvc -o name | grep -Eq '/.*-(packs|runtime-envs|artifacts)$'; then
  printf 'target release still has a shared pack, runtime, or artifact claim\n' >&2
  exit 1
fi

mapfile -t components < <(kubectl --namespace "$namespace" get pods \
  -l "app.kubernetes.io/instance=${release}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/component}{"\n"}{end}' |
  awk -F '\t' '$2 == "api" || $2 == "executor" || $2 == "supervisor" || $2 ~ /^action-worker-/ || $2 ~ /^sensor-worker-/ { print $2 }' |
  sort -u)
if [[ "${#components[@]}" -lt 5 ]]; then
  printf 'expected API, executor, supervisor, action worker, and sensor worker pods\n' >&2
  exit 1
fi

while (( $(date +%s) < deadline )); do
  cycle=$((cycle + 1))
  bash -o pipefail -c "$ATTUNE_DISRUPTION_WORKLOAD_COMMAND"
  component="${components[$(((cycle - 1) % ${#components[@]}))]}"
  victim="$(kubectl --namespace "$namespace" get pods \
    -l "app.kubernetes.io/instance=${release},app.kubernetes.io/component=${component}" \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$victim" ]] || { printf 'no pod found for component %s\n' "$component" >&2; exit 1; }
  kubectl --namespace "$namespace" delete pod "$victim" --wait=false
  kubectl --namespace "$namespace" wait --for=delete "pod/${victim}" --timeout=2m
  printf '%s\t%d\tdelete:%s\tpass\n' "$(date -u +%FT%TZ)" "$cycle" "$victim" >> "$output"
  kubectl --namespace "$namespace" wait \
    --for=condition=Available deployment \
    -l "app.kubernetes.io/instance=${release}" \
    --timeout=10m
  bash -o pipefail -c "$ATTUNE_DISRUPTION_VERIFY_COMMAND"
  printf '%s\t%d\tacceptance-invariants\tpass\n' "$(date -u +%FT%TZ)" "$cycle" >> "$output"
  sleep "$interval_seconds"
done

printf 'completed %d disruption cycles in %d seconds; evidence: %s\n' "$cycle" "$duration_seconds" "$output"
