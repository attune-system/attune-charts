# Attune chart

This chart installs the Attune platform, including these components:

- API, executor, notifier, supervisor, and web Deployments
- Action-worker and sensor-worker pools
- Optional bundled TimescaleDB and RabbitMQ StatefulSets
- Migration, bootstrap-user, and pack-initialization Jobs
- Shared claims or RWX-free object storage for packs, runtime environments, and artifacts

The chart defaults target a small single-node k3s cluster. All platform
Deployments use one replica, and shared claims use `ReadWriteOnce`.

## Install on k3s

Create the runtime Secret before installing the chart. Keep this Secret out of
the Helm values stored by Rancher. The required keys are listed under
[Use pre-created Kubernetes Secrets](#use-pre-created-kubernetes-secrets).

Set only Secret names and non-secret settings in your values file:

```yaml
security:
  existingSecret: attune-runtime

web:
  config:
    apiUrl: ""
    wsUrl: ""
  ingress:
    enabled: false
```

Attune `0.6.0` starts with the known bootstrap password `TestPass123!`. Keep
ingress disabled for the first login.

When upgrading from chart `0.5.4` or older, copy the chart-managed
`<release>-attune-secrets` Secret to a separately named Secret before the
upgrade, then set `security.existingSecret` to the new name. Chart `0.6.0` no
longer renders the old Secret, so Helm removes that managed resource during the
upgrade.

Keep `apiUrl` and `wsUrl` empty when one public host fronts the chart. The web
client derives `wss://<current-host>/ws`, and the web nginx forwards `/ws` to
the internal notifier Service on port `8081`. Set `web.config.wsUrl` only when
the notifier is deliberately exposed through another public origin.

The CLI uses the same public origin for watched commands. Override it with
`--notifier-url` or `ATTUNE_NOTIFIER_WS_URL`; both values are WebSocket base
URLs, so use `wss://attune.example.com` rather than appending `/ws`.

The web nginx and nginx-ingress defaults disable proxy buffering and allow one
hour of inactivity for API streams. Preserve the
`nginx.ingress.kubernetes.io/proxy-*` annotations when adding custom ingress
annotations. PostgreSQL leases limit execution-log streams to 100 across all
API Pods and 5 per signed identity by default. Each API Pod renews its leases
every 10 seconds. PostgreSQL recovers leases from a crashed Pod after 45
seconds. `leaseSeconds` must exceed twice `heartbeatSeconds`, which gives a
scheduled renewal a full heartbeat interval before the API's conservative
local lease-loss deadline. Configure these values with
`api.executionLogStreams`.

Install the release:

```bash
helm upgrade --install attune attune/attune \
  --namespace attune \
  --create-namespace \
  --values values.yaml \
  --wait \
  --wait-for-jobs \
  --timeout 20m
```

Forward the web Service locally, sign in at `http://127.0.0.1:8080`, and change
the bootstrap password:

```bash
kubectl --namespace attune port-forward service/attune-attune-web 8080:80
```

Then enable ingress in `values.yaml`, configure `hosts` and `tls`, and run the
Helm upgrade command again. The TLS Secret must exist in the release namespace
before the upgrade. Do not expose Attune before changing the bootstrap
password.

```yaml
web:
  ingress:
    enabled: true
    className: traefik
    hosts:
      - host: attune.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: attune-example-com-tls
        hosts:
          - attune.example.com
```

Fresh installations run initialization Jobs as normal release resources, so
application init containers and Helm can wait for them together. Upgrades run
the PostgreSQL provisioner, migrations, and user initialization as ordered
`pre-upgrade` hooks. Pack initialization is a `pre-upgrade` hook for shared
volumes and a `post-upgrade` hook for object storage. The RabbitMQ provisioner
remains a normal release Job. New application Pods wait for it to reconcile the
password while the rolling update retains old ready replicas.

The PostgreSQL provisioner creates a restricted login, transfers ownership of
the Attune database and schema to it, and pre-creates extensions that require
administrator privileges. The RabbitMQ provisioner creates a user without
administrator tags and grants it access to the `/` vhost. Both provisioners
reconcile ownership and permissions when they run again. The RabbitMQ
provisioner also reconciles the service password from the runtime Secret.

Attune `0.6.0` creates the bootstrap identity with the development password
`TestPass123!`. Change that password after the first login. The current
`init-user` image does not honor a custom `bootstrap.testUser.password` value.

## Configure OIDC and Active Directory

Rancher exposes both identity providers in the generated chart form under
`security`. OIDC uses browser redirects with PKCE. Active Directory uses
Attune's LDAP login support and accepts either direct-bind or search-and-bind
configuration.

Configure OIDC with the public callback URL registered at your provider:

```yaml
security:
  oidc:
    enabled: true
    discoveryUrl: https://sso.example.com/.well-known/openid-configuration
    clientId: attune
    providerName: sso
    providerLabel: Company SSO
    redirectUri: https://attune.example.com/auth/callback
    postLogoutRedirectUri: https://attune.example.com/login
    scopes:
      - groups
  identitySecret:
    existingSecret: attune-identity
```

For Active Directory search-and-bind, use a read-only directory account:

```yaml
security:
  activeDirectory:
    enabled: true
    url: ldaps://ad.example.com:636
    userSearchBase: "ou=users,dc=example,dc=com"
    userFilter: "(sAMAccountName={login})"
    searchBindDn: "cn=attune-readonly,ou=service-accounts,dc=example,dc=com"
    providerName: ad
    providerLabel: Active Directory
  identitySecret:
    existingSecret: attune-identity
```

For direct bind, set `activeDirectory.bindDnTemplate` and leave
`userSearchBase` and `searchBindDn` empty. Use
`startTls: true` with an `ldap://` URL only when the directory requires
STARTTLS. Keep `dangerSkipTlsVerify` disabled outside local testing.

The API imports the Secret selected by `security.identitySecret.existingSecret`.
It can contain
`ATTUNE__SECURITY__OIDC__CLIENT_SECRET`,
`ATTUNE__SECURITY__LDAP__SEARCH_BIND_PASSWORD`, or both. Omit the identity
Secret for public OIDC clients and Active Directory direct bind. The chart
writes non-secret identity settings to the mounted ConfigMap.

## Choose data backends

The database and RabbitMQ choices are independent. Use any combination from
these tables.

| Database mode | Chart settings | Prerequisite |
| --- | --- | --- |
| CloudNativePG | `database.postgresql.enabled: false` and `database.host: <cluster>-rw` | A ready CNPG `Cluster` with the required extensions |
| Bundled | `database.postgresql.enabled: true` and `database.postgresql.provisioning.enabled: true` | A PostgreSQL administrator Secret |
| External | `database.postgresql.enabled: false` and an external `database.host` | A provisioned database, role, schema, and extensions |

Every long-running database client has an explicit pool budget under its
service values. The API and executor default to 10 connections per Pod. The
supervisor, notifier, action-worker Pods, sensor-worker Pods, and storage
migration Jobs default to 5.

Calculate the steady-state ceiling as
`api replicas * api budget + executor replicas * executor budget + supervisor replicas * supervisor budget + notifier replicas * notifier budget + sum(action worker replicas * pool budget) + sum(sensor worker replicas * pool budget)`.
The default deployment is therefore `10 + 10 + 5 + 5 + 5 + 5 = 40` pooled
connections. Kubernetes' default 25% rolling surge rounds each one-replica
Deployment up by one Pod, so simultaneous rollouts can temporarily double that
ceiling to 80. `database.connectionReserve` keeps another 20 connections for
migration hooks, provisioning, monitoring, and operator access. The bundled
PostgreSQL instance sets `max_connections` from
`database.postgresql.maxConnections`, which defaults to 100. The chart rejects
a bundled database capacity below its calculated rolling ceiling plus reserve.
It cannot validate an external database's actual `max_connections`; provision
at least 100 connections for the unmodified defaults and recalculate after
changing replicas, worker pools, rollout strategy, or pool budgets.

| RabbitMQ mode | Chart settings | Prerequisite |
| --- | --- | --- |
| Bundled | `rabbitmq.enabled: true` and `rabbitmq.provisioning.enabled: true` | A RabbitMQ administrator Secret |
| External | `rabbitmq.enabled: false` and an external `rabbitmq.host` | A provisioned user with access to the selected vhost |

Attune requires PostgreSQL 16 or later with TimescaleDB 2.17 or later. RabbitMQ
must be version 3.12 or later.

The repository includes `scripts/generate-attune-setup.sh`. Clone the chart
repository before running it. The script generates `values.yaml`, Kubernetes
Secrets, and an optional CloudNativePG manifest:

```bash
# CloudNativePG TimescaleDB and bundled RabbitMQ
./scripts/generate-attune-setup.sh

# Standalone TimescaleDB/PostgreSQL and bundled RabbitMQ
./scripts/generate-attune-setup.sh --database-mode bundled
```

CloudNativePG mode uses three instances by default. It pins
`timescale/timescaledb-ha:pg16.15-ts2.29.2` through an `ImageCatalog`, loads
TimescaleDB, and creates the `timescaledb`, `pgcrypto`, and `uuid-ossp`
extensions. Install the CloudNativePG operator before applying the generated
`timescaledb.yaml`.

The generator places the CloudNativePG `Cluster`, `ImageCatalog`, and bootstrap
Secret in the Attune release namespace. Its generated `<cluster>-rw` hostname
works in that layout. To separate the database manually, place all three CNPG
resources in the database namespace. Keep the runtime Secret in the Attune
release namespace, and set `database.host`, `DB_HOST`, and the host in
`ATTUNE__DATABASE__URL` to `<cluster>-rw.<database-namespace>.svc`. Keep
`DB_USER`, `DB_PASSWORD`, `DB_NAME`, and `DB_SCHEMA` consistent with the CNPG
bootstrap configuration.

For external services, provide existing passwords through the environment:

```bash
ATTUNE_SETUP_DATABASE_PASSWORD='database-password' \
ATTUNE_SETUP_RABBITMQ_PASSWORD='rabbitmq-password' \
  ./scripts/generate-attune-setup.sh \
    --database-mode external \
    --database-host db.example.com \
    --rabbitmq-mode external \
    --rabbitmq-host mq.example.com \
    --rabbitmq-vhost /attune
```

Run `./scripts/generate-attune-setup.sh --help` for all options. The generator
stores credentials in an ignored `credentials.state` file. `--force` preserves
those credentials while regenerating manifests. Use `--rotate-secrets` only for
a coordinated credential rotation. The state file does not store generator
options. Repeat every original option on a `--force` run. For example:

```bash
./scripts/generate-attune-setup.sh \
  --database-mode bundled \
  --namespace production \
  --release attune-prod \
  --storage-class longhorn \
  --output-dir production-setup \
  --force
```

For generated ingress values, change the bootstrap password through a local
port-forward first. Then rerun the generator with the original options plus
`--ingress-host`, `--ingress-tls-secret`,
`--confirm-bootstrap-password-changed`, and `--force`.

## Use pre-created Kubernetes Secrets

Create the Secrets required by the selected backend modes before installing the
chart:

- An Attune runtime Secret in the release namespace containing the application
  environment variables.
- An optional identity Secret in the release namespace for OIDC and Active
  Directory credentials.
- For bundled PostgreSQL, an administrator Secret in the release namespace
  with `username` and `password` keys.
- For bundled RabbitMQ, an administrator Secret in the release namespace with
  `username` and `password` keys.
- For CloudNativePG, a `kubernetes.io/basic-auth` bootstrap Secret matching
  `bootstrap.initdb.owner` in the same namespace as the CNPG `Cluster`.

External PostgreSQL and RabbitMQ modes do not use administrator Secrets in this
chart.

The provisioners currently support the PostgreSQL and RabbitMQ StatefulSets
bundled with this chart. Provision accounts in external services before
installing and leave the corresponding `provisioning.enabled` value `false`.

Configure their names and key mappings:

```yaml
security:
  existingSecret: attune-service-secrets

database:
  postgresql:
    admin:
      existingSecret: attune-postgresql-admin
      usernameKey: username
      passwordKey: password
    provisioning:
      enabled: true

rabbitmq:
  admin:
    existingSecret: attune-rabbitmq-admin
    usernameKey: username
    passwordKey: password
  provisioning:
    enabled: true
```

The runtime Secret must contain these keys:

```text
ATTUNE__SECURITY__JWT_SECRET
ATTUNE__SECURITY__ENCRYPTION_KEY
ATTUNE__DATABASE__URL
ATTUNE__MESSAGE_QUEUE__URL
ATTUNE_MQ_URL
DB_HOST
DB_PORT
DB_USER
DB_PASSWORD
DB_NAME
DB_SCHEMA
RABBITMQ_USER
RABBITMQ_PASSWORD
TEST_LOGIN
TEST_DISPLAY_NAME
TEST_PASSWORD
DEFAULT_ADMIN_LOGIN
DEFAULT_ADMIN_PERMISSION_SET_REF
SOURCE_PACKS_DIR
TARGET_PACKS_DIR
RUNTIME_ENVS_DIR
ARTIFACTS_DIR
LOADER_SCRIPT
```

For PostgreSQL TLS, add `PGSSLMODE` to the runtime Secret and use the same
`sslmode` in `ATTUNE__DATABASE__URL`. The generator supports `disable`, `allow`,
`prefer`, and `require`. Mode `require` encrypts traffic but does not verify the
server certificate. The chart cannot mount the CA file that libpq needs for
`verify-ca` or `verify-full`, so those modes are not currently supported.

For RabbitMQ TLS, use an `amqps://` URL in both message-queue keys. Encode the
vhost as the URL path. For example, vhost `/attune` becomes `/%2Fattune`. The
RabbitMQ CA must also exist in each consuming container's trust store.

Set `security.existingSecret` to the runtime Secret name. The chart never copies
these values into the Helm release. When the bundled PostgreSQL or RabbitMQ
instance uses a different administrator account, set its `admin.existingSecret`
and key names separately.

When MCP is enabled with `mcp.auth.useBootstrapTestUser: false`, set
`mcp.auth.existingSecret` to a Secret containing the keys selected by
`mcp.auth.loginKey` and `mcp.auth.passwordKey`.

`DB_USER` and `RABBITMQ_USER` must differ from their administrator usernames.
The connection URLs must use the same service credentials. URL-encode passwords
when placing them in a URL. Keep both service usernames stable after the first
installation. The PostgreSQL provisioner refuses to take ownership from a
different role once schema objects exist.

The provisioners create missing accounts and reconcile privileges. PostgreSQL
does not change passwords on existing accounts, so change that password in the
database before updating the Kubernetes Secret. RabbitMQ reconciles the service
password from the runtime Secret on each install or upgrade. The release
revision annotation rolls all credential-consuming Pods.
Do not rotate an administrator Secret by changing only its Kubernetes value:
PostgreSQL and RabbitMQ use those values only when initializing empty data
volumes.

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

The API, executor, supervisor, workers, and initialization Jobs share the three
`sharedStorage` claims. Configure all three as RWX when those workloads can run
on different nodes. Bundled PostgreSQL and RabbitMQ remain RWO:

```yaml
database:
  postgresql:
    persistence:
      accessModes: [ReadWriteOnce]
      storageClassName: longhorn

rabbitmq:
  persistence:
    accessModes: [ReadWriteOnce]
    storageClassName: longhorn

sharedStorage:
  packs:
    accessModes: [ReadWriteMany]
    storageClassName: longhorn
  runtimeEnvs:
    accessModes: [ReadWriteMany]
    storageClassName: longhorn
  artifacts:
    accessModes: [ReadWriteMany]
    storageClassName: longhorn
```

Longhorn RWX also requires the NFS client package on every schedulable node.
Kubernetes cannot change a bound PVC from RWO to RWX. Back up and copy each
shared volume into a new RWX claim, verify the copy, and retain the old volume
until the migrated workload has been tested. Deleting a PVC can delete its
backing volume when the reclaim policy is `Delete`.

## Use RWX-free object storage

Set one storage mode for the release. The chart configures Attune to use an
existing S3 bucket or GCS bucket. It does not create buckets, KMS keys, IAM
roles, workload-identity bindings, or other cloud resources.

```yaml
storage:
  mode: object
  object:
    provider: s3
    bucket: company-attune
    prefix: production
    region: us-east-1
    kmsKey: arn:aws:kms:us-east-1:123456789012:key/example

serviceAccounts:
  api:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/attune-api
  supervisor:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/attune-supervisor
```

GCS does not use `region` or `kmsKey`. Put its Workload Identity annotation on
the same two service accounts. Workers authenticate to the Attune API and do
not receive bucket identity. Object mode creates no shared pack, runtime, or
artifact claims. It uses size-limited `emptyDir` volumes for local pack and
runtime caches and artifact staging. Runtime log buffering is in memory, not in
an `emptyDir`.

When `kmsKey` selects an AWS customer-managed KMS key, grant each service
account that accesses encrypted objects, including the API and supervisor,
`kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, and `kms:DescribeKey` on
that key. The IAM policy and the KMS key policy must both allow the roles, and
the key must be in the S3 bucket's region.

Object-mode Pods set only `fsGroup: 1000` and `fsGroupChangePolicy:
OnRootMismatch` by default. Kubernetes gives that group write access to local
volumes and adds it as a supplementary group without changing the UID supplied
by an action-worker or sensor-worker image. Override these fields under
`storage.local.podSecurityContext` if UID 1000 is not the installation's shared
write group.

For caches that should survive container restarts within the same Pod, opt into
Kubernetes generic ephemeral volumes:

```yaml
storage:
  mode: object
  local:
    mode: genericEphemeralVolume
    packs:
      sizeLimit: 2Gi
      storageClassName: fast-rwo
    runtimeEnvs:
      sizeLimit: 10Gi
      storageClassName: fast-rwo
```

The chart puts an inline `volumeClaimTemplate` on each action-worker and
sensor-worker Pod for both caches. Kubernetes dynamically provisions each claim
as `ReadWriteOnce`, schedules the Pod with its claims, and deletes them with the
Pod. Claims are never shared between Pods. A replacement Pod gets empty caches
and rebuilds them from object storage. The API and artifact staging continue to
use bounded `emptyDir` volumes. This mode requires a storage class that supports
dynamic provisioning and Kubernetes 1.23 or newer.

Set the per-stream loss window under `artifacts`:

```yaml
artifacts:
  logSegmentMaxBytes: 65536
  flushIntervalMs: 500
```

Each action stdout stream, action stderr stream, and managed-sensor stream can
hold at most `logSegmentMaxBytes` accepted but uncommitted bytes. Reaching the
byte limit applies backpressure until the commit finishes. Partial segments
start committing within `flushIntervalMs` under normal runtime scheduling. The
storage request has no finite duration bound, so data remains uncommitted until
that request completes or fails. A forced Pod termination can lose the accepted
bytes whose commit has not completed. A graceful action shutdown waits for both
streams to flush and seal.

The chart leaves application `resources` empty, so include this buffer in your
own memory requests. Add
`4 * max_concurrent_tasks * logSegmentMaxBytes` to each action-worker Pod's
normal request. The factor of four covers stdout and stderr plus a peak
segment-sized handoff allocation beside each stream buffer. The default worker
concurrency of 10 and default segment size need 2.5 MiB. Add twice the segment
size per concurrently active managed-sensor stream. Leave headroom for request
bodies and allocator overhead. The executor's workflow logger commits each
entry directly and does not hold this in-memory segment buffer.

The API checks object storage before it starts listening for traffic. For S3,
enable bucket versioning and grant the API service account
`s3:GetBucketVersioning`, `s3:PutObject`, `s3:GetObject`,
`s3:GetObjectVersion`, `s3:DeleteObject`, `s3:DeleteObjectVersion`, and
`s3:AbortMultipartUpload` for the configured bucket and prefix. A disabled or
suspended bucket is rejected. For GCS, grant `storage.objects.create`,
`storage.objects.get`, and `storage.objects.delete`; reads must accept a
specific generation and deletes must accept a generation-match precondition.
The configured prefix must allow temporary `.attune-preflight/` and
`.attune-upload/` objects. Startup fails with the provider and bucket name when
any required operation is unavailable.

### Migrate from shared volumes

The chart treats `sharedVolume` to `object` as an explicit one-time cutover. On
an actual Helm upgrade, it checks the live release ConfigMap and the three
legacy PVC names. If the previous release was not using object storage and any
legacy claim exists, rendering fails unless
`storage.object.migrateFromSharedVolume` is `true`. A fresh object-mode install
creates no shared claims and does not run this migration.

Use this operator flow:

1. Back up the Attune database, all three shared PVCs, and the target object
   bucket. Test that the backups can be restored.
2. Block ingress and other API clients. Stop producers, then scale the Attune
   Deployments to zero with `kubectl --namespace attune scale deployment
   --selector app.kubernetes.io/instance=attune --replicas=0`. Wait until no
   Attune application or worker Pods remain. Keep PostgreSQL and RabbitMQ up.
3. Put the complete object storage and workload-identity configuration in the
   values file. Leave `migrateFromSharedVolume: false` in that file.
4. Run the cutover once by adding
   `--set storage.object.migrateFromSharedVolume=true` to the normal `helm
   upgrade` command. Use `--wait --wait-for-jobs`; do not use automatic
   rollback. The pre-upgrade hooks use the target API and supervisor images,
   target config, runtime Secret, and separate service accounts with the target
   workload-identity annotations. Helm
   first runs `attune-api --upgrade-pack-releases`, then runs
   `attune-supervisor migrate-storage`. Both mount the legacy packs and
   artifacts claims. Either command failing stops the upgrade.

   ```bash
   helm upgrade attune attune/attune \
     --namespace attune \
     --values object-values.yaml \
     --set storage.object.migrateFromSharedVolume=true \
     --wait \
     --wait-for-jobs \
     --timeout 60m
   ```
5. If a hook fails, keep writes stopped, inspect the failed Job, correct the
   cause, and retry the same Helm command. Both application commands must be
   idempotent. The deployed ConfigMap remains in shared-volume mode until the
   pre-upgrade migration succeeds.
6. After Helm succeeds, verify pack releases, object digests, artifacts, and
   runtime logs before restoring clients and producers. Future upgrades must
   use `migrateFromSharedVolume: false`. The chart also reads the deployed
   object-storage config, so retained PVCs do not trigger or replay the
   migration on later object-mode upgrades.

The chart leaves the three shared PVCs unmounted and annotates them with
`helm.sh/resource-policy: keep`. Helm also keeps them on uninstall. Delete the
retained claims manually only after the migration and restore procedure have
been tested and the retention period has passed.

Rollback has a hard data boundary. Shared volumes cannot represent writes that
Attune accepts into object storage after cutover. Do not claim or attempt an
automatic rollback to `sharedVolume`. Stop writes first, then use a tested
reverse migration or restore the pre-cutover database and PVC backups as one
consistent set.

On an object-mode upgrade, the core pack bootstrap is a `post-upgrade` hook. It
waits for `/health` through a Service that selects only API Pods carrying the
target Helm release revision, then publishes the bundled pack through the
authenticated upload API. It uses a temporary integration identity rather than
the initial administrator password. Old API Pods cannot satisfy this gate.
Shared-volume upgrades keep the bootstrap as a `pre-upgrade` hook. Executor and
worker init containers then wait for the active core pack through the API.
Per-service storage modes are rejected by the values schema.

Run a disruption test against a dedicated three-node test release. The command
hooks must generate pack, runtime, artifact, and log activity and verify mixed
releases, object digests, log segment sequences, and pending-upload age.

```bash
ATTUNE_ALLOW_DISRUPTION=true \
ATTUNE_DISRUPTION_WORKLOAD_COMMAND='./test/generate-object-load.sh' \
ATTUNE_DISRUPTION_VERIFY_COMMAND='./test/verify-object-invariants.sh' \
  ./scripts/test-object-mode-disruption.sh \
    --namespace attune-object-test \
    --release attune \
    --duration-seconds 86400 \
    --output object-mode-disruption.tsv
```

## Use external infrastructure

When you disable the bundled database or RabbitMQ, put its connection URL in the
runtime Secret and set the host field in Helm values. Init containers and
bootstrap Jobs use the host fields for readiness checks.

```yaml
database:
  host: postgres.example.com
  postgresql:
    enabled: false

rabbitmq:
  host: rabbitmq.example.com
  port: 5671
  enabled: false
```

Set both `database.postgresql.provisioning.enabled` and
`rabbitmq.provisioning.enabled` to `false` for external services. The chart does
not create users, schemas, extensions, or vhosts in external systems. The
database user must own the selected database and have an owner-writable schema.
Install `timescaledb`, `pgcrypto`, and `uuid-ossp` before installing Attune. The
RabbitMQ user needs configure, write, and read access to its vhost. External
services must meet the minimum versions listed under
[Choose data backends](#choose-data-backends).

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
