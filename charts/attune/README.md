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
    enabled: true
    className: traefik
    hosts:
      - host: attune.example.com
        paths:
          - path: /
            pathType: Prefix
```

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
the credential provisioners and initialization Jobs as ordered `pre-upgrade`
hooks before rolling the Deployments.

The PostgreSQL provisioner creates a restricted login, transfers ownership of
the Attune database and schema to it, and pre-creates extensions that require
administrator privileges. The RabbitMQ provisioner creates a user without
administrator tags and grants it access to the `/` vhost. Both provisioners
update passwords and permissions when they run again.

Attune `0.4.0` creates the bootstrap identity with the development password
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

## Use pre-created Kubernetes Secrets

Create these Secrets in the release namespace before installing the chart:

- A PostgreSQL administrator Secret with `username` and `password` keys.
- A RabbitMQ administrator Secret with `username` and `password` keys.
- An Attune runtime Secret containing the application environment variables.
- An optional identity Secret for OIDC and Active Directory credentials.

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

The provisioners create missing accounts and reconcile privileges, but do not
change passwords on existing accounts. To rotate a password, change it in the
backing service first, update the Kubernetes Secret, and then upgrade the Helm
release. The release revision annotation rolls all credential-consuming Pods.
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
