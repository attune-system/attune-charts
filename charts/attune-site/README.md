# Attune site chart

This chart installs the public site and its SMTP-backed inquiry form.

## Install with a pre-created SMTP Secret

Create the SMTP Secret in the release namespace:

```bash
kubectl -n attune-sites create secret generic attune-site-smtp \
  --from-literal=host=smtp.example.com \
  --from-literal=from=site@attunedev.org \
  --from-literal=username=SMTP_USERNAME \
  --from-literal=password=SMTP_PASSWORD
```

Install the chart:

```bash
helm upgrade --install attune-site attune/attune-site \
  --namespace attune-sites \
  --create-namespace
```

The chart defaults to the public
`ghcr.io/attune-system/attune-site:0.1.4` image. Set `image.repository`,
`image.tag`, and `imagePullSecrets` to use a private image instead.

## Store campaign data

The chart creates a 1 GiB `ReadWriteOnce` PersistentVolumeClaim and mounts it at
`/data`. The site stores campaign tracking and report state in
`/data/campaigns.db`. To use a claim you already manage:

```yaml
persistence:
  enabled: true
  existingClaim: attune-site-data
```

Keep `replicaCount` at `1`. SQLite and a `ReadWriteOnce` claim do not support
multiple site replicas writing this database. The chart uses the `Recreate`
deployment strategy while persistence is enabled so an upgrade does not run two
writers at once. The chart rejects disabled persistence and replica counts other
than one.

Helm retains chart-created claims when the release is removed or changed to use
`existingClaim`. Delete an abandoned claim manually only after backing up or
discarding its database. A claim's storage class and access modes cannot be
changed after creation, and its requested size cannot be reduced.

## Configure TLS

Add a TLS entry after your certificate controller creates the Secret:

```yaml
ingress:
  tls:
    - hosts:
        - attunedev.org
      secretName: attunedev-org-tls
```
