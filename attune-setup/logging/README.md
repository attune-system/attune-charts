# Attune log analytics

VictoriaLogs stores structured logs from the `attune` namespace for 14 days. The web UI at `https://logs.rdrx.app/select/vmui/` requires an Authelia session with two-factor authentication.

## Deploy

```bash
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update vm
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install victoria-logs vm/victoria-logs-single \
  --version 0.13.9 \
  --namespace logging \
  --values attune-setup/logging/server-values.yaml \
  --wait
helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
  --version 0.3.7 \
  --namespace logging \
  --values attune-setup/logging/collector-values.yaml \
  --wait
kubectl apply -f attune-setup/logging/auth-gateway.yaml
```

## Access

```bash
kubectl --namespace logging port-forward service/victoria-logs-vls-server 9428:9428
```

Open `http://localhost:9428/select/vmui/`. This port-forward bypasses Authelia and should only be used for local administration.

Useful LogsQL queries:

```text
*
event:="attune.runtime_log"
level:="ERROR"
kubernetes.container_name:="worker"
```
