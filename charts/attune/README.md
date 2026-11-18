# Attune chart

This chart installs the Attune platform, including these components:

- API, executor, notifier, supervisor, and web Deployments
- Action-worker and sensor-worker pools
- Optional bundled PostgreSQL and RabbitMQ StatefulSets
- Migration, bootstrap-user, and pack-initialization Jobs
- Shared claims or RWX-free object storage for packs, runtime environments, and artifacts

The chart defaults target a small single-node k3s cluster. All platform
Deployments use one replica, and shared claims use `ReadWriteOnce`.

Chart `0.11.4` targets Attune `0.11.1` metadata only. It extends chart `0.11.3`
for core pack `1.0.8`, using the
independently versioned `core-1.0.8` init-packs image. Defaults pin the published
AMD64/ARM64 image indexes from release commit
`46a80c7edf458c2dfa15461826fa3df269ebc6b2`. Those historical service pins and
`appVersion: 0.11.1` remain provenance, not a claim of compatibility with the
new execution-host contract. The independent MCP configuration and pins from
[PR12](https://github.com/attune-system/attune-charts/pull/12) are preserved. [Published provenance](../../docs/published-images-0.11.1.json)
records index/child/config digests, source labels and the canonical core archive
digest for this release.
Digests override tags;
changing `global.imageTag` alone does not replace pinned binaries. Clear or replace
the corresponding digest for an explicit image override. Keep API and agent code
aligned. See [worker compatibility](#native-core-107-worker-compatibility).

Pack publication requires an existing registrar-authorized deployment token in
the Secret selected by `corePack.deploymentTokenSecret` and
`corePack.deploymentTokenKey`. The chart does not create or grant that token.
Do not enable the separate managed-runtime gate merely to permit publication.

Attune uses native PostgreSQL partitions and cache maintenance, not TimescaleDB.

The bundled services use digest-pinned PostgreSQL `18.6-alpine` and RabbitMQ
`4.3.6-management-alpine` images. Value overrides can replace either pin.
PostgreSQL 16 data requires a logical backup and restore into PostgreSQL 18.
The chart does not run `pg_upgrade` or copy database files.

### Draft execution isolation prerequisite

This companion is stacked on PR12 head
`377d6613df4c0eda51428116c9e575688ad97125`. While PR12 is unmerged, its PR base
is `security/mcp-request-auth-chart`; PR12 must merge before this companion.
PR12 approval does not cover the worker changes or this regenerated package.

This draft requires the canonical v1 remote CP launch/host APIs and an external
colocated Docker Engine/controller pair. The CP and secret-bearing managers must
remain outside the workload host. Kubernetes host Pods hold only per-slot scoped
enrollment/custody; the external Engine supplies private procfs, immutable RO inputs
and private writable stage/scratch. This chart does not implement Kubernetes Jobs,
privileged DinD, Docker-socket Pods, network isolation or live stage disk quotas.

Current published application/agent pins do not implement this contract. No new
published pin is invented here. Set `workloadLaunch.apiUrl` to the real HTTPS CP
origin, provision each enrollment through that CP, and supply an actual compatible
`workloadLaunch.agentImage.digest` after validating the matching API/controller
images. The old published agent digest is rejected. Init runs both actual binaries
with `env -i` and checks exact offline `--workload-host-contract` output before
copying them and their public CA roots. A claimed image tag or operator checkbox
cannot substitute for that probe or the full integration evidence.

Default rendering with only the older runtime Secret intentionally fails these
new prerequisites; workers are not silently disabled or run via a legacy fallback.
The companion PR remains draft/dependency-blocked until the supported installation,
packaged source images, API authority, runtime stages and image selection are
validated together. Synthetic image digests in render tests are fixtures, not
installable or released image claims.

## Upgrading encrypted data to Attune 0.10.1

Existing installations with encrypted data from before `0.10.1` require the
[offline encryption conversion procedure](https://github.com/attune-system/attune/blob/v0.10.1/docs/deployment/encryption-fingerprint-remediation.md#offline-upgrade-procedure).
This is not an unattended rolling upgrade. Back up the database and matching
file/object storage, rehearse conversion on a restored copy, and stop all service
and external writers. Apply the release's forward migration and run the explicit
`attune-encryption-convert` tool before starting the new workloads.

The chart does not stop all writers or run this conversion for you. Keep the
existing master secret unchanged during conversion; changing it is not a
substitute for conversion. Follow the procedure's verification and temporary
database-role requirements. After conversion, reverting only the image tag is
unsafe; recovery requires matching data, storage, and binaries. Fresh installations
do not need conversion.

### TimescaleDB upgrade boundary

This release supports fresh native PostgreSQL installations, not conversion
of populated TimescaleDB installations. A read-only `pre-upgrade` Job rejects
the TimescaleDB extension on bundled, CloudNativePG, and external databases.
It runs before database provisioning, migrations, and workload changes.
Failed connections and PostgreSQL versions older than 16 also stop the upgrade.

Do not use `--no-hooks`, drop the extension to bypass this check, or reuse a
TimescaleDB data PVC with the stock image. Preserve existing databases and
backups until a separate conversion procedure has been designed and tested.
Generate new CNPG manifests in a new output directory. The generator refuses
directories containing `timescaledb.yaml`, even with `--force`.

The only valid PostgreSQL major-upgrade value pairs are `refuse+complete` and
`startFresh+cutover`. Fresh installs use `refuse+complete` and do not render the
major preflight hook. Keep `refuse+complete` for later PostgreSQL 18 upgrades.

### Upgrade bundled PostgreSQL 16 to 18

This procedure applies only to a native PostgreSQL StatefulSet bundled with
this chart. It does not convert a pre-0.8.0 Attune TimescaleDB schema. It requires
downtime for both stages and the restore between them.

Before the cutover:

- Verify that the current database is PostgreSQL 16 and that the old bundled
  StatefulSet runtime uses `PGDATA=/var/lib/postgresql/data/pgdata`. The new
  guard mounts the PVC root at `/var/lib/postgresql`, where it sees the same
  version marker at `/var/lib/postgresql/pgdata/PG_VERSION`.
- Create a logical backup, include the application role needed by restored
  object ownership, and test the complete restore procedure on PostgreSQL 18.
- Take a storage snapshot or equivalent backup of the PostgreSQL PVC.
- Verify the administrator Secret mappings and access to the runtime Secret.
- Confirm that the cluster can pull the pinned PostgreSQL image and has enough
  free PVC capacity for a second database directory.
- Finish any `sharedVolume` to `object` storage cutover first. The chart rejects
  both cutovers in one Helm upgrade.
- Drain RabbitMQ and save any broker definitions you intend to recreate. The
  cutover starts RabbitMQ 4 with a fresh store; queued messages and definitions
  in the RabbitMQ 3 store are discarded.

Use the same complete values file on both commands. Do not use
`--reuse-values`. It can retain `startFresh+cutover` after the first stage and
leave Attune scaled down.

Start the cutover:

```bash
helm upgrade attune attune/attune \
  --namespace attune \
  --values values.yaml \
  --set database.postgresql.majorUpgradePolicy=startFresh \
  --set database.postgresql.majorUpgradeStage=cutover \
  --set rabbitmq.majorUpgradePolicy=startFresh \
  --wait \
  --timeout 20m
```

The pre-upgrade Job accepts the old PostgreSQL 16 server or an already-started
PostgreSQL 18 server. Helm then scales every Attune Deployment to zero, blocks
the ordinary PostgreSQL Service, and starts PostgreSQL 18 in
`/var/lib/postgresql/18/docker`. RabbitMQ starts version 4 against its fresh
`mnesia-v4` directory. The chart suppresses database provisioning, migrations,
bootstrap Jobs, and storage migration Jobs during this stage.

Keep Attune down. Restore the tested logical backup through
`<release>-attune-postgresql-maintenance`. The restore procedure must recreate
or preserve the configured application role and object ownership. Verify the
restored row counts, extensions, schema ownership, and application role access
before continuing.

Complete the cutover:

```bash
helm upgrade attune attune/attune \
  --namespace attune \
  --values values.yaml \
  --set database.postgresql.majorUpgradePolicy=refuse \
  --set database.postgresql.majorUpgradeStage=complete \
  --set rabbitmq.majorUpgradePolicy=refuse \
  --wait \
  --wait-for-jobs \
  --timeout 20m
```

The second preflight proves PostgreSQL 18 through the maintenance Service before
any mutating hook runs. Bundled database provisioning, migrations, `init-user`,
`init-packs`, and storage migration Jobs also use that Service. The ordinary
application Service becomes routable only after Helm applies the complete
stage.

If either stage fails, keep ingress and producers stopped, inspect the failed
Job or PostgreSQL Pod, fix the cause, and retry the same command. Do not switch
stages to bypass a failure. Do not use Helm automatic rollback across this
cutover. After writes reach PostgreSQL 18, rollback requires stopping writes and
restoring the PostgreSQL 16 database and PVC snapshot as one tested operation.
The chart keeps the old PostgreSQL 16 directory, but that directory is not a
rollback guarantee.

RabbitMQ major-version handling is separate. This PostgreSQL procedure does not
migrate RabbitMQ definitions or queued messages. The chart does not install or
generate a RabbitMQ operator.

## Install on k3s

Create the runtime Secret before installing the chart. Keep this Secret out of
the Helm values stored by Rancher. The required keys are listed under
[Use pre-created Kubernetes Secrets](#use-pre-created-kubernetes-secrets).

The runtime Secret alone is insufficient for execution hosts. Supply the real
HTTPS CP origin, actual validated agent digest and distinct pre-provisioned
enrollment Secret names described in the draft prerequisite. The setup generator
requires `--workload-api-url`, `--workload-agent-digest`,
`--action-enrollment-secret` and `--sensor-enrollment-secret`; it never generates
or stores scoped enrollment tokens. Keep the custody PVC mounted at its parent
and let the UID1000 host create its exclusive private `host` subdirectory.

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

### Supply the deployment credential

For an existing database, provide an already issued integration token whose
identity is authorized to publish the core pack. The setup generator accepts it
through `ATTUNE_SETUP_BOOTSTRAP_TOKEN` and puts it in a separate
`<release>-deployment` Secret. It never creates a token or grants permissions.
The token is not included in Helm values or `credentials.state`, and is not
injected into ordinary application Pods. Re-supply it when regenerating manifests
if you want that Secret included in `secrets.yaml` again.

For a fresh database, no valid token exists before the administrator is created.
Keep ingress disabled and use this staged procedure:

1. Apply the generated namespace, Secrets and database manifests. Start the Helm
   installation below in one terminal. The API and web can become ready before
   pack publication; the publication Job waits for the deployment Secret.
2. In another terminal, port-forward `service/attune-attune-web` on port 8080.
   Sign in as the initial administrator, change the bootstrap password, and issue
   an integration token with the registrar authority required to publish core.
   Save the token, without a trailing newline, in a private mode-0600 file outside
   the repository. Do not put the token in a command argument or shell history.
3. Create the credential Secret from that file. With the generator's default
   release name, run:

   ```bash
   kubectl --namespace attune create secret generic attune-deployment \
     --from-file=ATTUNE_BOOTSTRAP_TOKEN=/private/path/deployment-token
   ```

4. If the publication deadline elapsed while provisioning the token, retry with
   `helm upgrade` using the same values and
   `--set corePack.requiredOnUpgrade=true --wait --wait-for-jobs --timeout 20m`.
   This reruns authenticated publication and requires the target core release
   and content readiness. Inspect both Jobs before enabling ingress.

For hand-written values, select this dedicated Secret with
`corePack.deploymentTokenSecret: attune-deployment`. Retain the token for future
reconciliation or revoke it explicitly and supply a replacement before upgrades.

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

Fresh installations run database and user initialization as normal resources.
Core publication is a post-install hook, followed by a content-readiness hook.
Ordinary workloads wait for platform readiness, never for core publication.
Upgrades run
the PostgreSQL provisioner, migrations, and user initialization as ordered
`pre-upgrade` hooks. In both storage modes, required core reconciliation uses a
`post-upgrade` hook followed by content readiness. Optional reconciliation uses
a normal Job with no blocking content hook, so failure leaves the old release
active and is visible in the Job status without failing Helm. The RabbitMQ provisioner
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

## Run in restricted namespaces

Secure workload contexts are enabled by default under `workloadSecurity`. Every
rendered Pod uses `runAsNonRoot: true` and `RuntimeDefault` seccomp. Every
container and init container disables privilege escalation and drops all Linux
capabilities. The chart supplies image-specific non-root identities for Attune,
helper, PostgreSQL, RabbitMQ, web, and default worker images. The web container
adds back only `NET_BIND_SERVICE` and uses ephemeral writable directories for
nginx state and its generated runtime configuration.

These defaults satisfy Kubernetes Pod Security Admission's `restricted`
profile. Keep them enabled for shared, compliant clusters:

```yaml
workloadSecurity:
  enabled: true
```

Execution-only hosts use UID/GID 1000 and a dedicated persistent custody
claim. They reject custom runtime/security overrides, local runtime discovery,
service passthrough, and DB pool settings. Runtime/image/placement selection
belongs to the persisted CP profile, not the Pod's host image. Keep
`workloadSecurity.enabled` enabled; no pack-controlled process runs in these Pods.

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
    deviceClient:
      clientId: attune-native
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
`ATTUNE__SECURITY__OIDC__DEVICE_CLIENT__CLIENT_SECRET`, and
`ATTUNE__SECURITY__LDAP__SEARCH_BIND_PASSWORD`. Omit the identity
Secret for public OIDC clients and Active Directory direct bind. The chart
writes non-secret identity settings to the mounted ConfigMap.

CLI SSO uses RFC 8628 device authorization. Enable the device grant at your
provider. For Okta, create a public Native application with client authentication
set to `none`, and set `security.oidc.deviceClient.clientId` to its client ID.
Keep the existing web client ID and callback URI. Configure the native app's
group claims to match the web app, with the same issuer and subject identifiers.

Leave `deviceClient.clientId` empty to reuse the web registration. An explicit
native client never inherits the web secret. The chart renders its secret as
`null`; a confidential device client's API-only identity Secret can override it.
Attune supports `none` and `client_secret_basic` client authentication.

Requesting the `groups` scope requires a group claim in the ID token or
subject-verified UserInfo response. Set `security.oidc.requireGroups: true` when
your provider supplies groups without that scope. Missing or malformed required
groups reject login before identity or role changes. A verified empty list clears
OIDC-managed roles. The CLI and API must both run application version 0.7.4 or later.

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
supervisor, notifier, and storage migration Jobs default to 5. Execution-only
action/sensor hosts have no database client or connection budget.

Calculate the steady-state ceiling as
`api replicas * api budget + executor replicas * executor budget + supervisor replicas * supervisor budget + notifier replicas * notifier budget`.
The default deployment is therefore `10 + 10 + 5 + 5 = 30` pooled
connections. Kubernetes' default 25% rolling surge rounds each one-replica
Deployment up by one Pod, so simultaneous rollouts can temporarily double that
ceiling to 60. `database.connectionReserve` keeps another 20 connections for
migration hooks, provisioning, monitoring, and operator access. The bundled
PostgreSQL instance sets `max_connections` from
`database.postgresql.maxConnections`, which defaults to 100. The chart rejects
a bundled database capacity below its calculated rolling ceiling plus reserve.
It cannot validate an external database's actual `max_connections`; provision
at least 100 connections for the unmodified defaults and recalculate after
changing CP replicas, rollout strategy, or pool budgets.

| RabbitMQ mode | Chart settings | Prerequisite |
| --- | --- | --- |
| Bundled | `rabbitmq.enabled: true` and `rabbitmq.provisioning.enabled: true` | A RabbitMQ administrator Secret |
| External | `rabbitmq.enabled: false` and an external `rabbitmq.host` | A provisioned user with access to the selected vhost |

Attune requires PostgreSQL 16 or later. TimescaleDB is not required. RabbitMQ
must be version 3.12 or later.

The repository includes `scripts/generate-attune-setup.sh`. Clone the chart
repository before running it. The script generates `values.yaml`, Kubernetes
Secrets, and an optional CloudNativePG manifest:

```bash
# CloudNativePG PostgreSQL and bundled RabbitMQ
./scripts/generate-attune-setup.sh

# Standalone PostgreSQL and bundled RabbitMQ
./scripts/generate-attune-setup.sh --database-mode bundled
```

CloudNativePG mode uses three instances by default. It pins
`ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie` through an `ImageCatalog`
and creates the `pgcrypto` and `uuid-ossp`
extensions. Install the CloudNativePG operator before applying the generated
`postgresql.yaml`. The image's PostgreSQL identity is UID `26`, GID `102`.

CloudNativePG `v1.30.1` is the recommended operator version for the generated
resources. The repository does not install the operator. It also does not
install or generate a RabbitMQ operator; RabbitMQ remains a chart-managed
StatefulSet unless you configure an external service.

The generated PostgreSQL 18 `ImageCatalog` is for new clusters. Do not apply it
as an in-place major-version change to a PostgreSQL 16 CloudNativePG cluster.
Use CloudNativePG's major-upgrade or logical backup-and-restore procedure.

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

Each action/sensor item is one logical host slot with a unique
`enrollmentSecret.name` and private custody PVC. It receives only the HTTPS API
origin, scoped enrollment credential and custody directory, plus public CA and
observability settings. It receives no general Config, database/broker credential,
JWT/master key, cloud identity, shared pack/runtime/artifact volume, or Kubernetes
service-account token. The external controller/Engine credentials stay outside it.

`replicas` must be one. Add separate slots with independently provisioned
enrollment Secrets and PVCs for capacity. Deployment strategy is `Recreate`, so a
normal revision upgrade does not surge against the old slot. The host must acquire
exclusive custody ownership before registration. On shutdown it closes admission,
requests CP withdrawal preserving bounded capture/prepared-log delivery, drains
for at most 90 seconds, then aborts-and-joins remaining local transport tasks within
15 seconds. The chart requires at least 120 seconds termination grace and bounds
rollout progress at 600 seconds. No timeout proves provider absence or stop.
Unexpected replacement/force deletion must still fail closed on custody ownership
and registration-incarnation fences; these render assertions are not a live
rollout/custody test.

Chart-created custody PVCs use `helm.sh/resource-policy: keep`, independent of
Pod or release removal. Do not delete/reset keys or volumes to repair readiness.
Retire them manually only after the host has withdrawn and delivery has completed
or expired. PVC/node loss produces incomplete logs, never manufactured EOF.

`runtimes`, `passthroughEnv`, local cache/storage settings, general security
context overrides and database budgets are removed from worker items. `env`
accepts only literal public certificate/observability settings. CP-frozen selected
input and finite channel grants reach the execution-only consumer; stdin is sent
once after authenticated Running status and fresh input/grant checks.

Run `python3 scripts/test-worker-environments.py` for positive/negative Helm
fixtures covering scope, rollout strategy, replica/Secret/PVC uniqueness, old-image
rejection and prerequisites. Actual image/offline probe, API, withdrawal/custody and
Engine/runtime tests are separate required evidence, currently incomplete.

### HTTP MCP

MCP remains disabled by default. With `mcp.enabled: true`, the pinned Attune
0.11.1 image serves `/mcp` using **each request's** `Authorization: Bearer <token>`.
Clients obtain their own Attune API token; MCP validates it through `/auth/me`
and forwards the same caller token for API operations. No bootstrap identity,
shared login, credential store, login fallback, or token refresh is configured.
`/health` remains unauthenticated for Kubernetes probes.

```yaml
mcp:
  enabled: true
  http:
    hosts: ["mcp.example.com"]
    origins: ["https://console.example.com"]
```

`mcp.http.hosts` lists exact HTTP Host authorities, including the port if the
client sends one. Empty defaults to `<MCP Service name>:<mcp.service.port>`.
Explicit entries replace that default; include every intended authority when
using an ingress or port forwarding (for example `localhost:8090`). Forwarded
headers do not replace Host validation. `mcp.http.origins` lists exact browser
Origins; empty denies any request carrying Origin. Requests without Origin still
require an allowed Host and a caller token. Wildcards are unsupported. Terminate
TLS at the ingress/proxy and preserve the Authorization header.

Chart 0.11.3 removes `mcp.auth` and rejects supplied obsolete settings, including
values retained with `helm upgrade --reuse-values`. Remove that subtree from
your release values before upgrading. The old chart injected startup login
credentials, which the pinned 0.11.1 HTTP binary rejects, and omitted its required
Host configuration. This chart corrects both without changing image digests.
The pinned agent image lacks CA roots. A non-root `prepare-ca-bundle` init
container copies only the public `/etc/ssl/certs/ca-certificates.crt` bundle from
the chart-selected `images.api` into a dedicated 2 MiB EmptyDir; MCP mounts it
read-only. No host paths, credentials, or network download are used. Custom
`images.api` overrides must provide `/bin/sh`, `cp`, `chmod`, and a nonempty public
bundle at that path, readable by the configured Attune UID. Missing bundles stop
Pod initialization. The copy also remains valid when a future MCP image includes
its own roots; the chart-selected API bundle defines the MCP trust roots.
Custom MCP images must support `ATTUNE_MCP_HTTP_HOSTS`,
`ATTUNE_MCP_HTTP_ORIGINS`, and per-request HTTP Bearer authentication; older
shared-login binaries are unsupported.

Run `python3 scripts/test-mcp-http.py` for render contracts and
`python3 scripts/test-mcp-http.py --integration` for controlled startup and HTTP
checks against the exact chart-selected image. The integration uses synthetic
caller tokens and a local API fixture, not a live platform or production data.

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

The CP API, executor, supervisor and initialization Jobs share the three
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
the same two CP service accounts. Execution-only hosts authenticate to the CP
and receive no bucket identity or shared data claims in either storage mode.
Their encrypted custody is persistent. Immutable runtime/pack cache and writable
setup staging belong to the external controller/Engine pair, not these Pods.

When `kmsKey` selects an AWS customer-managed KMS key, grant each service
account that accesses encrypted objects, including the API and supervisor,
`kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, and `kms:DescribeKey` on
that key. The IAM policy and the KMS key policy must both allow the roles, and
the key must be in the S3 bucket's region.

CP local caches and object staging follow `storage.local`; those settings do
not grant execution hosts filesystem access. Per-host encrypted custody always
uses a dedicated retained PVC. It must not use a Pod-owned ephemeral claim or
be shared with another enrollment. The external Engine's named-volume stage has
separate archive/output bounds and cleanup; these are not hard live byte/inode
quotas and can leave residual disk-exhaustion availability risk.

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
    first checks that every pack already has an active object-backed release
    and current unrevoked runtime admission, using a PostgreSQL 18 read-only
    preflight. Readmit legacy packs through the compatible ordinary API before
    cutover; this hook never freezes or activates them. It mounts no legacy PVC.
    The following `attune-supervisor migrate-storage` hook mounts the legacy packs
    and artifacts claims. Either prerequisite or migration failure stops the upgrade.

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

### Native core 1.0.7 worker compatibility

Chart `0.11.4` retains historical Attune `0.11.1` service provenance and core
`1.0.8` pins, while requiring the new matching launch/host API image contract.
Published `0.11.1` agents cannot implement that contract; follow the draft
prerequisite above before claiming any supported worker installation.
The rollout requirements below still apply; the measured `0.11.0` / core `1.0.7`
acceptance results are historical and do not establish live `1.0.8` acceptance.
Chart `0.11.1` retained core `1.0.7` in error; use `0.11.3` for the matching
application and core release.

Attune `0.11.0` includes native directory selection and all coordinated security
fixes through its release commit. Defaults now select the actual published
compatible injected agent, rather than the incompatible stock `0.10.4` agent.
Stock `0.10.4` advertises `native` but cannot execute directory entrypoints;
runtime advertisement is not evidence of directory support. Image metadata and
static payload checks do not replace live acceptance for the selected bytes.

In historical charts, `images.agent` selected the injected worker. Execution-only
slots now select their independently validated `workloadLaunch.agentImage`;
`images.agent` remains unchanged for other consumers, including MCP. A worker
item's `image` contains the trusted host consumer, not the pack runtime. The CP
profile selects the external Engine runtime image. The historical `0.11.1` agent
is not compatible with this new contract. Verify all eligible pools
and any external workers use compatible code, with compatible API contracts and
retained old-core execution behavior. A successful render or health check does not
establish binary compatibility. Fresh installs also require this real image
selection before publication; old-core staging is not a substitute for it.

Upgrade in two stages using the existing configuration, without changing storage,
runtime, sensor or IAM settings:

1. Keep the currently admitted OLD core release: preserve its `corePack.version`,
   `corePack.digest`, `images.initPacks.tag` and `images.initPacks.digest`. Roll out
   the actual validated execution-only agent and matching CP/controller service images
   described in the draft prerequisite above. Published `0.11.1` pins cannot
   satisfy this step for chart `0.11.4`. Wait for all worker rollouts to complete, old Pods
   to terminate, and old/external workers to drain or be removed from dispatch.
   Verify old-core execution on the new code before proceeding.
2. Retain those compatible worker pins, then select core `1.0.8` and its actual
   compatible init-packs artifact, using measured image/archive digests when
   available. Verify native execution and the removal/preservation inventories.

Chart `0.11.0` support validated here covers fresh installations and staged
**forward upgrades** from `0.10.4`/core `1.0.5` to `0.11.0`/core `1.0.7` in both
storage modes. Acceptance includes retirement, retained IDs/history/old archive,
failure preservation and idempotence. This is AMD64 execution evidence; ARM
execution, RWX and proxy/TLS need their own validation.

**Original core `1.0.5` restoration is unsupported.** Released `0.11.0` exposes
no supported retained-release reactivation or rollback operation. Retained
history and archive pins preserve historical bindings; they do not reactivate
an older release. Re-upload through the original `0.10.4` helper is rejected at
`permission_sets/admin.yaml` `/grants`: “System administration requires explicit
external authority.” Stronger registrar privileges or external approvals do not
make the unchanged legacy Pack-scope definition valid.

The failed restoration preserved the new release/policy in both modes;
object-mode new-core execution and forward recovery to the pinned `1.0.7` Helm
configuration succeeded. These are safety and forward-recovery results, not a
successful legacy restore. Keep compatible services/agent and current core pins;
do not remove digest pins, add grants or acknowledgements, or loosen authority
checks to bypass this boundary. Helm rollback does not reverse admitted pack
state. Full backup-based disaster recovery requires separate coordination and
was not validated here; no application/database downgrade is established. See
[acceptance scope](../../docs/acceptance-image-pins.md#measured-acceptance-and-rollback-boundary).

This sequence matters in both storage modes. Optional upgrade publication is an
ordinary Job that can run concurrently with worker rollout; `--wait` or
`--wait-for-jobs` does not make that Job start after workers drain. Required
publication (`corePack.requiredOnUpgrade=true`) runs at post-upgrade hook weight
0, with content readiness at weight 10. Helm `--wait` can wait for ordinary
resource readiness before post hooks, but neither the adapter nor hook ordering
checks worker binary versions, dispatch eligibility or completed drainage. Without
`--wait`, post hooks can also precede worker readiness. Fresh publication uses
post-install weight 0, then content readiness weight 10. The adapter only waits
for the revision-specific API's `/health/ready`; it never waits for workers.
Do not rely on a single combined worker/core upgrade to establish compatibility.

Fresh installs run core pack bootstrap as a blocking `post-install` hook. On an
upgrade in either storage mode, bootstrap is an ordinary Job. A failed admission
is recorded as a failed Job and must keep the prior admitted core release through
the ordinary API's atomic activation. Helm normally does not wait for ordinary
Jobs; `--wait-for-jobs` can surface their failure. Set
`corePack.requiredOnUpgrade=true` only when a platform release cannot run with
the previous core release; that selects a blocking `post-upgrade` hook after the
target API is available. Neither mode uses a pre-upgrade SQL loader or copies
declarations over the active pack volume.

The chart pins the desired immutable release with `corePack.version` and the
optional `corePack.digest`. Bootstrap reads the active release before writing and
skips upload only when runtime admission also matches. Both modes wait for
`/health/ready` through a Service that selects only API Pods carrying the target
Helm release revision. It uses the existing deployment integration credential
from the selected Secret, not a temporary identity or the administrator password.
The chart adapter requires `/health/ready.pack_publication` with integer
`protocol_version: 1`, integer `client_version: 1`,
`revision: authenticated-pack-publication-1`, `authorization: registrar`, and
exactly `immutable_release` and `atomic_deployment` components. The bundled
client must export the API-only `publish_core` helper and matching version,
revision and component constants. The adapter then verifies `/health/bootstrap`
for the required version, release ID, digest and policy revision, including the
optional digest pin.
Old API Pods and old publishers cannot satisfy these gates. Choose coordinated
API/worker/init-packs images; historical default image tags are not asserted
compatible. `BOOTSTRAP_ADMISSION_ENABLED=false` gates the broader managed-runtime
contract, not authenticated publication. No chart flag enables that gate, removes
registrar checks or creates a deployment credential.

`corePack.digest` pins the measured canonical published core archive
`77088ba9bc6dbaaff5dbdb450e32eddcc95b561f6d9b7a2b0bfe8b263f990010`.
It includes both architectures' native action binaries and is separate from the
OCI index digest and the Python publisher's source-upload tarball hash. The
[provenance record](../../docs/published-images-0.11.1.json) binds it to the
published `0.11.1` source. Overrides must use the actual canonical archive for
the selected candidate, not a pre-release local producer checksum.

Before installation, record the source revision and measured OCI manifest digest
for each coordinated platform image, including migrations, init-user and injected
agent. Verify the live publication contract above and the init-packs image's
`/scripts/bootstrap_core_pack.py` exports `BOOTSTRAP_CLIENT_VERSION=1`,
`BOOTSTRAP_REVISION=authenticated-pack-publication-1`, `BOOTSTRAP_COMPONENTS`
equal to the two components, and callable `publish_core`. The image must provide
Python 3 and PyYAML for publication only, core `1.0.8` metadata, and musl-linked
AMD64/ARM64 binaries for exactly four native actions: `core.echo`, `core.sleep`,
`core.noop` and `core.http_request` (eight ELF payloads total). All four must run
directly in native full worker pools without curl, Python or shell action-runtime
prerequisites; the chart adds no action interpreters. Upstream release checks
cover native HTTP; published-source chart acceptance remains separate from
source tests, and ordinary HTTP success does not establish TLS deployment readiness.
Record the canonical release-archive checksum separately from its image digest.
Supply an existing registrar-authorized integration token in the selected Secret.

Core `1.0.8` / timer `0.7.5` are shipped in the published `0.11.1` release.
The selected `init-packs:core-1.0.8` index and both architecture-specific configs
were measured from public GHCR and identify the release commit. No release
publication is required by this chart update. See the
[published-source acceptance contract](../../docs/acceptance-image-pins.md).

Entrypoints are `actions/bin/{echo,sleep,noop,http_request}/{linux-amd64,linux-arm64}`.
Official init-packs must contain all eight executable static musl ELFs, correct
machines and no `PT_INTERP`/`DT_NEEDED`; API-mode validation checks these before
upload with no source fallback. Python publication and files-manifest v1 remain
unchanged. The default `corePack.digest` is the measured canonical archive from
the selected published image; never substitute an OCI digest, source checksum or
an earlier local producer's core checksum.

Historical local `BUILT_NOT_DEPLOYED` acceptance receipts prove their exact source
and bytes only. The earlier b8 and mixed-source fresh results cannot establish
acceptance of these published `0.11.1` images. Likewise, image architecture
metadata is not ARM execution, RWX or proxy/TLS/provider-failure validation.

The chart delegates the deployment payload to the image's `publish_core(base,
pack_dir)` helper; it does not set metadata removal policy itself. The bundled
helper must explicitly send scalar multipart `absent_metadata_policy=remove`
when activating core `1.0.8`. This policy applies across the pack and has no
component selector. The coordinated candidate and publisher must retire core
action callables other than `echo`, `sleep`, `noop` and `http_request` while
preserving unrelated metadata, runtimes, sensors, IAM sets and dashboards.
Use post-PR54 application main `1a83c7cb5a4e855b7cb331e85464337bfd0abd9a`
as the preservation baseline. PR54 deliberately adds `identities:manage` to
`core.admin` and platformadmin (permission catalog 4, epoch 1); this explicit
security-policy change is an exception when comparing with older baselines,
not permission for broader IAM changes. Its admin-only core `1.0.6` source
release does not establish official artifact publication. PR41 integrates that
policy into four-action core `1.0.7` with timer `0.7.5`. All unrelated component
definitions remain byte-identical to the preservation baseline, including
`core.key_creator` despite removal of its SSH action; preserve their projection
IDs, lifecycle and historical release pins. Scalar Remove retires the seven omitted action refs and also
`install_packs`'s own `workflow_definition` child. This owning-workflow retirement
is the explicit exception to preserving non-action projections; it does not
permit broader unrelated metadata removal. Upstream regression evidence must
compare retained unrelated projection IDs/lifecycle, verify retirement of that
owning workflow child, preserve the pinned old release, and reject new
lookup/execution of removed actions. This
preservation does not narrow the scalar policy. Capture the actual API request,
before/after inventories and failure preservation evidence in owned acceptance
tests. The chart's version/digest health checks alone cannot prove this removal
contract. Optional utility actions are deferred to a separate pack.

Use owned acceptance infrastructure to prove fresh publication, idempotent rerun,
denial and failed-upgrade preservation of prior release/policy/configuration in
both storage modes, plus the independent content-readiness wait. Published release images are available; missing deployment authority still
requires a legitimate operator credential. Offline
renders do not satisfy either requirement. See
[central acceptance image inputs](../../docs/acceptance-image-pins.md).

The adapter is supplied by ConfigMap and only uses private temporary storage.
Shared-volume API/workers retain their PVCs; bootstrap no longer mounts or mutates
those active volumes. API activation must use the unified planner, preserve old
configuration before mutation and bind original authored release defaults.
Trigger/schema activation requires exclusive graph admission before owner locks
and distinct incompatible-rollout acknowledgement, never ordinary force.

API, executor, action-worker, and sensor-worker Pods start from platform
readiness through the ordinary internal API Service, so that Service remains
routable while content health is false. API readiness uses `/health/ready`;
liveness uses `/health/live`. Bootstrap Jobs and workload waits have a
300-second readiness deadline. Publication does not wait for worker hosts. A
credential-free content-ready hook at weight 10 runs after publication hooks
at weight 0 and waits for `/health/content`. This preserves platform-before-content
ordering without a filesystem completion marker. Per-service storage modes are
rejected by the values schema.

Run `python3 scripts/test-bootstrap-admission.py` for offline publisher fixtures
and Helm renders covering both modes, install, optional upgrade and required upgrade.

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
Install `pgcrypto` and `uuid-ossp` before installing Attune. The
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
