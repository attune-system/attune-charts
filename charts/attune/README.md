# Attune chart

This chart installs the Attune platform, including these components:

- API, executor, notifier, supervisor, and web Deployments
- Action-worker and sensor-worker pools
- TimescaleDB and RabbitMQ StatefulSets
- Migration, bootstrap-user, and pack-initialization Jobs
- Shared claims for packs, runtime environments, and artifacts

The chart defaults target a small single-node k3s cluster. All platform
Deployments use one replica, and shared claims use `ReadWriteOnce`.

## Install on k3s

Set production secrets and the public hostname in a values file:

```yaml
security:
  jwtSecret: REPLACE_WITH_A_RANDOM_SECRET
  encryptionKey: REPLACE_WITH_AT_LEAST_32_RANDOM_BYTES

database:
  password: REPLACE_WITH_A_DATABASE_PASSWORD

rabbitmq:
  password: REPLACE_WITH_A_RABBITMQ_PASSWORD

bootstrap:
  testUser:
    login: admin@example.com
    displayName: Attune Administrator

web:
  config:
    apiUrl: ""
    wsUrl: ""
  ingress:
    enabled: true
    className: traefik
    hosts:
      - host: attune.example.com
        paths:
          - path: /
            pathType: Prefix
```

Install the release:

```bash
helm upgrade --install attune attune/attune \
  --namespace attune \
  --create-namespace \
  --values values.yaml \
  --wait \
  --wait-for-jobs
```

Fresh installations run initialization Jobs as normal release resources, so
application init containers and Helm can wait for them together. Upgrades run
the same Jobs as ordered `pre-upgrade` hooks before rolling the Deployments.

Attune `0.4.0` creates the bootstrap identity with the development password
`TestPass123!`. Change that password after the first login. The current
`init-user` image does not honor a custom `bootstrap.testUser.password` value.

## Use another storage class

Set `storageClassName` for every persistent store when the cluster has no
default storage class:

```yaml
database:
  postgresql:
    persistence:
      storageClassName: local-path

rabbitmq:
  persistence:
    storageClassName: local-path

sharedStorage:
  packs:
    storageClassName: local-path
  runtimeEnvs:
    storageClassName: local-path
  artifacts:
    storageClassName: local-path
```

For a multi-node cluster, use a storage class that supports your chosen access
mode and pod placement. `ReadWriteOnce` volumes can be mounted by several pods
only when those pods run on the same node.

## Use external infrastructure

When you disable the bundled database or RabbitMQ, set both the connection URL
and the host fields. Init containers and bootstrap Jobs use the host fields for
readiness checks.

```yaml
database:
  url: postgresql://attune:password@postgres.example.com:5432/attune
  host: postgres.example.com
  postgresql:
    enabled: false

rabbitmq:
  url: amqps://attune:password@rabbitmq.example.com:5671
  host: rabbitmq.example.com
  port: 5671
  enabled: false
```

## Configure TLS

Add the TLS Secret after your certificate controller creates it:

```yaml
web:
  ingress:
    tls:
      - hosts:
          - attune.example.com
        secretName: attune-example-com-tls
```
