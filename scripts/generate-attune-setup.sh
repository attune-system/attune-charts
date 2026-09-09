#!/usr/bin/env bash
set -euo pipefail

readonly TIMESCALE_IMAGE="docker.io/timescale/timescaledb-ha:pg16.15-ts2.29.2@sha256:903669a95321e439a181e2b350d6242a0af2e0ed2629196489780d1e58c46816"

namespace="attune"
release="attune"
database_mode="cnpg"
cluster_name="attune-timescaledb"
instances="3"
database_size="20Gi"
database_host=""
database_port="5432"
database_name="attune"
database_schema="attune"
database_user="attune"
database_sslmode=""
rabbitmq_mode="bundled"
rabbitmq_host=""
rabbitmq_port="5672"
rabbitmq_port_set=false
rabbitmq_user="attune"
rabbitmq_scheme=""
rabbitmq_vhost="/"
storage_class=""
shared_storage_rwx_class=""
admin_email="admin@attune.local"
ingress_host=""
ingress_class="nginx"
ingress_tls_secret=""
output_dir="attune-setup"
force=false
rotate_secrets=false
bootstrap_password_changed=false
credentials_tmp=""

cleanup() {
  [[ -z "$credentials_tmp" ]] || rm -f -- "$credentials_tmp"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Generate Attune Helm values and Kubernetes Secrets for bundled, CloudNativePG,
or externally managed data services.

Usage:
  ./scripts/generate-attune-setup.sh [options]

Options:
  --namespace NAME       Kubernetes namespace (default: attune)
  --release NAME         Helm release name (default: attune)
  --database-mode MODE   cnpg, bundled, or external (default: cnpg)
  --cluster-name NAME    CloudNativePG Cluster name (default: attune-timescaledb)
  --instances COUNT      PostgreSQL instances (default: 3)
  --database-size SIZE   Storage per PostgreSQL instance (default: 20Gi)
  --database-host HOST   Required for external database mode
  --database-port PORT   PostgreSQL port (default: 5432)
  --database-name NAME   PostgreSQL database (default: attune)
  --database-schema NAME PostgreSQL schema (default: attune)
  --database-user USER   PostgreSQL service user (default: attune)
  --database-sslmode MODE disable, allow, prefer, or require (default: require externally)
  --rabbitmq-mode MODE   bundled or external (default: bundled)
  --rabbitmq-host HOST   Required for external RabbitMQ mode
  --rabbitmq-port PORT   AMQP port (default: 5672, or 5671 for external AMQPS)
  --rabbitmq-user USER   RabbitMQ service user (default: attune)
  --rabbitmq-scheme NAME amqp or amqps (default: amqps externally)
  --rabbitmq-vhost NAME  RabbitMQ virtual host (default: /)
  --storage-class NAME   StorageClass for database, RabbitMQ, and shared PVCs
  --shared-storage-rwx-class NAME
                         RWX StorageClass for all three shared PVCs
  --admin-email EMAIL    Initial Attune administrator login
  --ingress-host HOST    Enable ingress with this hostname
  --ingress-class NAME   IngressClass name (default: nginx)
  --ingress-tls-secret NAME
                         Existing TLS Secret for the ingress hostname
  --output-dir PATH      Destination directory (default: attune-setup)
  --force                Regenerate files while preserving saved credentials
  --rotate-secrets       Replace secrets.yaml with newly generated credentials
  --confirm-bootstrap-password-changed
                         Confirm the fixed bootstrap password was changed
  -h, --help             Show this help

Secret overrides:
  Set ATTUNE_SETUP_DATABASE_PASSWORD, ATTUNE_SETUP_DATABASE_ADMIN_PASSWORD,
  ATTUNE_SETUP_RABBITMQ_PASSWORD, ATTUNE_SETUP_RABBITMQ_ADMIN_PASSWORD,
  ATTUNE_SETUP_JWT_SECRET, or ATTUNE_SETUP_ENCRYPTION_KEY. Missing values are
  generated with OpenSSL. External services require their service password.

Regeneration:
  The generator stores credentials in an ignored credentials.state file.
  --force reuses that file. --rotate-secrets replaces every credential.

Examples:
  ./scripts/generate-attune-setup.sh
  ./scripts/generate-attune-setup.sh --namespace production --release attune-prod \
    --storage-class longhorn --database-size 100Gi
  ./scripts/generate-attune-setup.sh --database-mode bundled \
    --storage-class longhorn --shared-storage-rwx-class longhorn
  # After installation and changing the bootstrap password through port-forwarding:
  ./scripts/generate-attune-setup.sh --namespace production --release attune-prod \
    --storage-class longhorn --database-size 100Gi \
    --ingress-host attune.example.com \
    --ingress-tls-secret attune-example-com-tls \
    --confirm-bootstrap-password-changed --force
  ./scripts/generate-attune-setup.sh --database-mode bundled
  ATTUNE_SETUP_DATABASE_PASSWORD=... ATTUNE_SETUP_RABBITMQ_PASSWORD=... \
    ./scripts/generate-attune-setup.sh --database-mode external \
      --database-host db.example.com --rabbitmq-mode external \
      --rabbitmq-host mq.example.com --rabbitmq-scheme amqps
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

take_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

validate_dns_label() {
  local label="$1" value="$2" max_length="${3:-63}"
  [[ ${#value} -le $max_length && "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    die "$label must be a lowercase Kubernetes name no longer than $max_length characters"
}

validate_dns_subdomain() {
  local label="$1" value="$2" segment
  local -a segments
  [[ ${#value} -le 253 ]] || die "$label must not exceed 253 characters"
  [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]] ||
    die "$label must be a lowercase DNS subdomain"
  IFS='.' read -ra segments <<< "$value"
  for segment in "${segments[@]}"; do
    [[ ${#segment} -le 63 ]] || die "$label contains a DNS label longer than 63 characters"
  done
}

validate_dns_hostname() {
  validate_dns_subdomain "$1" "$2"
  [[ ! "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$1 must not be an IP address"
}

urlencode() {
  local LC_ALL=C value="$1" encoded="" character hex index
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      [A-Za-z0-9.~_-]) encoded+="$character" ;;
      *)
        printf -v hex '%%%02X' "'$character"
        encoded+="$hex"
        ;;
    esac
  done
  printf '%s' "$encoded"
}

base64_value() {
  printf '%s' "$1" | openssl base64 -A
}

base64_decode() {
  printf '%s' "$1" | openssl base64 -d -A
}

decode_saved_credential() {
  local encoded="$1" decoded
  decoded="$(base64_decode "$encoded")" || die "invalid base64 value in $credentials_file"
  [[ "$(base64_value "$decoded")" == "$encoded" ]] || die "invalid base64 value in $credentials_file"
  printf '%s' "$decoded"
}

load_credentials() {
  local key value
  local database_mode_seen=0 rabbitmq_mode_seen=0
  local database_password_seen=0 database_admin_password_seen=0
  local rabbitmq_password_seen=0 rabbitmq_admin_password_seen=0
  local jwt_secret_seen=0 encryption_key_seen=0
  while IFS=$'\t' read -r key value; do
    case "$key" in
      DATABASE_MODE)
        ((database_mode_seen += 1))
        [[ $database_mode_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        previous_database_mode="$value"
        ;;
      RABBITMQ_MODE)
        ((rabbitmq_mode_seen += 1))
        [[ $rabbitmq_mode_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        previous_rabbitmq_mode="$value"
        ;;
      DATABASE_PASSWORD_B64)
        ((database_password_seen += 1))
        [[ $database_password_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        saved_database_password="$(decode_saved_credential "$value")"
        ;;
      DATABASE_ADMIN_PASSWORD_B64)
        ((database_admin_password_seen += 1))
        [[ $database_admin_password_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        saved_database_admin_password="$(decode_saved_credential "$value")"
        ;;
      RABBITMQ_PASSWORD_B64)
        ((rabbitmq_password_seen += 1))
        [[ $rabbitmq_password_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        saved_rabbitmq_password="$(decode_saved_credential "$value")"
        ;;
      RABBITMQ_ADMIN_PASSWORD_B64)
        ((rabbitmq_admin_password_seen += 1))
        [[ $rabbitmq_admin_password_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        saved_rabbitmq_admin_password="$(decode_saved_credential "$value")"
        ;;
      JWT_SECRET_B64)
        ((jwt_secret_seen += 1))
        [[ $jwt_secret_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        saved_jwt_secret="$(decode_saved_credential "$value")"
        ;;
      ENCRYPTION_KEY_B64)
        ((encryption_key_seen += 1))
        [[ $encryption_key_seen -eq 1 ]] || die "duplicate key in $credentials_file: $key"
        saved_encryption_key="$(decode_saved_credential "$value")"
        ;;
      *) die "invalid key in $credentials_file: $key" ;;
    esac
  done < "$credentials_file"

  [[ $database_mode_seen -eq 1 && $rabbitmq_mode_seen -eq 1 &&
    $database_password_seen -eq 1 && $database_admin_password_seen -eq 1 &&
    $rabbitmq_password_seen -eq 1 && $rabbitmq_admin_password_seen -eq 1 &&
    $jwt_secret_seen -eq 1 && $encryption_key_seen -eq 1 ]] ||
    die "$credentials_file is incomplete"
  [[ "$previous_database_mode" =~ ^(cnpg|bundled|external)$ ]] || die "$credentials_file has an invalid database mode"
  [[ "$previous_rabbitmq_mode" =~ ^(bundled|external)$ ]] || die "$credentials_file has an invalid RabbitMQ mode"
  [[ -n "$saved_database_password" && -n "$saved_rabbitmq_password" &&
    -n "$saved_jwt_secret" && -n "$saved_encryption_key" ]] ||
    die "$credentials_file contains an empty required credential"
  [[ "$previous_database_mode" != bundled || -n "$saved_database_admin_password" ]] ||
    die "$credentials_file contains an empty bundled database administrator password"
  [[ "$previous_rabbitmq_mode" != bundled || -n "$saved_rabbitmq_admin_password" ]] ||
    die "$credentials_file contains an empty bundled RabbitMQ administrator password"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      take_value "$1" "${2:-}"
      namespace="$2"
      shift 2
      ;;
    --release)
      take_value "$1" "${2:-}"
      release="$2"
      shift 2
      ;;
    --database-mode)
      take_value "$1" "${2:-}"
      database_mode="$2"
      shift 2
      ;;
    --cluster-name)
      take_value "$1" "${2:-}"
      cluster_name="$2"
      shift 2
      ;;
    --instances)
      take_value "$1" "${2:-}"
      instances="$2"
      shift 2
      ;;
    --database-size)
      take_value "$1" "${2:-}"
      database_size="$2"
      shift 2
      ;;
    --database-host)
      take_value "$1" "${2:-}"
      database_host="$2"
      shift 2
      ;;
    --database-port)
      take_value "$1" "${2:-}"
      database_port="$2"
      shift 2
      ;;
    --database-name)
      take_value "$1" "${2:-}"
      database_name="$2"
      shift 2
      ;;
    --database-schema)
      take_value "$1" "${2:-}"
      database_schema="$2"
      shift 2
      ;;
    --database-user)
      take_value "$1" "${2:-}"
      database_user="$2"
      shift 2
      ;;
    --database-sslmode)
      take_value "$1" "${2:-}"
      database_sslmode="$2"
      shift 2
      ;;
    --rabbitmq-mode)
      take_value "$1" "${2:-}"
      rabbitmq_mode="$2"
      shift 2
      ;;
    --rabbitmq-host)
      take_value "$1" "${2:-}"
      rabbitmq_host="$2"
      shift 2
      ;;
    --rabbitmq-port)
      take_value "$1" "${2:-}"
      rabbitmq_port="$2"
      rabbitmq_port_set=true
      shift 2
      ;;
    --rabbitmq-user)
      take_value "$1" "${2:-}"
      rabbitmq_user="$2"
      shift 2
      ;;
    --rabbitmq-scheme)
      take_value "$1" "${2:-}"
      rabbitmq_scheme="$2"
      shift 2
      ;;
    --rabbitmq-vhost)
      take_value "$1" "${2:-}"
      rabbitmq_vhost="$2"
      shift 2
      ;;
    --storage-class)
      take_value "$1" "${2:-}"
      storage_class="$2"
      shift 2
      ;;
    --shared-storage-rwx-class)
      take_value "$1" "${2:-}"
      shared_storage_rwx_class="$2"
      shift 2
      ;;
    --admin-email)
      take_value "$1" "${2:-}"
      admin_email="$2"
      shift 2
      ;;
    --ingress-host)
      take_value "$1" "${2:-}"
      ingress_host="$2"
      shift 2
      ;;
    --ingress-class)
      take_value "$1" "${2:-}"
      ingress_class="$2"
      shift 2
      ;;
    --ingress-tls-secret)
      take_value "$1" "${2:-}"
      ingress_tls_secret="$2"
      shift 2
      ;;
    --output-dir)
      take_value "$1" "${2:-}"
      output_dir="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --rotate-secrets)
      force=true
      rotate_secrets=true
      shift
      ;;
    --confirm-bootstrap-password-changed)
      bootstrap_password_changed=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1. Run with --help for usage."
      ;;
  esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is required to generate credentials"
validate_dns_label "namespace" "$namespace"
validate_dns_label "release" "$release" 43
validate_dns_label "cluster name" "$cluster_name" 47
[[ "$database_mode" =~ ^(cnpg|bundled|external)$ ]] || die "database mode must be cnpg, bundled, or external"
[[ "$rabbitmq_mode" =~ ^(bundled|external)$ ]] || die "RabbitMQ mode must be bundled or external"
if [[ -z "$database_sslmode" ]]; then
  [[ "$database_mode" == external ]] && database_sslmode=require || database_sslmode=prefer
fi
if [[ -z "$rabbitmq_scheme" ]]; then
  [[ "$rabbitmq_mode" == external ]] && rabbitmq_scheme=amqps || rabbitmq_scheme=amqp
fi
if [[ "$rabbitmq_mode" == external && "$rabbitmq_scheme" == amqps && "$rabbitmq_port_set" != true ]]; then
  rabbitmq_port=5671
fi
[[ "$instances" =~ ^[1-9][0-9]*$ ]] || die "instances must be a positive integer"
[[ "$database_size" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]] || die "database size must look like 20Gi"
[[ "$database_port" =~ ^[1-9][0-9]{0,4}$ && "$database_port" -le 65535 ]] || die "database port is invalid"
[[ "$rabbitmq_port" =~ ^[1-9][0-9]{0,4}$ && "$rabbitmq_port" -le 65535 ]] || die "RabbitMQ port is invalid"
[[ "$database_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "database name must be a PostgreSQL identifier"
[[ "$database_schema" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "database schema must be a PostgreSQL identifier"
if [[ "$database_mode" != external ]]; then
  [[ "$database_user" =~ ^[A-Za-z0-9._~-]+$ ]] || die "managed database user contains unsupported characters"
fi
if [[ "$rabbitmq_mode" != external ]]; then
  [[ "$rabbitmq_user" =~ ^[A-Za-z0-9._~-]+$ ]] || die "bundled RabbitMQ user contains unsupported characters"
fi
[[ "$database_user" != *$'\n'* && "$database_user" != *$'\r'* ]] || die "database user must not contain newlines"
[[ "$rabbitmq_user" != *$'\n'* && "$rabbitmq_user" != *$'\r'* ]] || die "RabbitMQ user must not contain newlines"
[[ "$database_sslmode" =~ ^(disable|allow|prefer|require)$ ]] ||
  die "database sslmode must be disable, allow, prefer, or require; verify-ca and verify-full need CA mounting that this chart does not provide"
[[ "$rabbitmq_scheme" =~ ^(amqp|amqps)$ ]] || die "RabbitMQ scheme must be amqp or amqps"
[[ "$rabbitmq_mode" != bundled || "$rabbitmq_scheme" == amqp ]] || die "bundled RabbitMQ supports only the amqp scheme"
[[ "$rabbitmq_mode" != bundled || "$rabbitmq_vhost" == / ]] || die "bundled RabbitMQ supports only vhost /"
[[ "$rabbitmq_vhost" != *$'\n'* && "$rabbitmq_vhost" != *$'\r'* ]] || die "RabbitMQ vhost must not contain newlines"
[[ "$database_mode" != cnpg || "$database_port" == 5432 ]] || die "CNPG mode uses port 5432"
[[ "$database_mode" == external || "$database_user" != postgres ]] || die "$database_mode database service user must differ from administrator postgres"
[[ "$rabbitmq_mode" != bundled || "$rabbitmq_user" != attune-admin ]] || die "bundled RabbitMQ service user must differ from administrator attune-admin"
if [[ "$database_mode" == external ]]; then
  [[ -n "$database_host" ]] || die "--database-host is required for external database mode"
fi
if [[ "$rabbitmq_mode" == external ]]; then
  [[ -n "$rabbitmq_host" ]] || die "--rabbitmq-host is required for external RabbitMQ mode"
fi
for host in "$database_host" "$rabbitmq_host"; do
  [[ -z "$host" ]] || validate_dns_hostname "external host" "$host"
done
[[ -z "$storage_class" || "$storage_class" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
  die "storage class contains unsupported characters"
[[ -z "$shared_storage_rwx_class" || "$shared_storage_rwx_class" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
  die "shared storage RWX class contains unsupported characters"
[[ "$admin_email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$ ]] || die "admin email is invalid"
if [[ -n "$ingress_host" ]]; then
  validate_dns_hostname "ingress host" "$ingress_host"
  [[ -n "$ingress_tls_secret" ]] || die "--ingress-tls-secret is required when ingress is enabled"
  validate_dns_subdomain "ingress TLS Secret" "$ingress_tls_secret"
  if [[ "$bootstrap_password_changed" != true ]]; then
    die "change Attune's fixed bootstrap password before enabling ingress, then pass --confirm-bootstrap-password-changed"
  fi
elif [[ -n "$ingress_tls_secret" ]]; then
  die "--ingress-host is required when --ingress-tls-secret is set"
fi
validate_dns_subdomain "ingress class" "$ingress_class"

credentials_file="$output_dir/credentials.state"
previous_database_mode=""
previous_rabbitmq_mode=""
saved_database_password=""
saved_database_admin_password=""
saved_rabbitmq_password=""
saved_rabbitmq_admin_password=""
saved_jwt_secret=""
saved_encryption_key=""
if [[ "$force" == true && "$rotate_secrets" != true ]]; then
  if [[ -f "$credentials_file" ]]; then
    load_credentials
  elif [[ -e "$output_dir/secrets.yaml" ]]; then
    die "$output_dir/secrets.yaml predates safe regeneration; preserve it and use a new output directory, or use --rotate-secrets for a coordinated rotation"
  fi
fi

if [[ "$database_mode" == external && -z "${ATTUNE_SETUP_DATABASE_PASSWORD:-}" &&
  ! ( "$previous_database_mode" == external && -n "$saved_database_password" ) ]]; then
  die "ATTUNE_SETUP_DATABASE_PASSWORD is required for external database mode"
fi
if [[ "$rabbitmq_mode" == external && -z "${ATTUNE_SETUP_RABBITMQ_PASSWORD:-}" &&
  ! ( "$previous_rabbitmq_mode" == external && -n "$saved_rabbitmq_password" ) ]]; then
  die "ATTUNE_SETUP_RABBITMQ_PASSWORD is required for external RabbitMQ mode"
fi

database_password="${ATTUNE_SETUP_DATABASE_PASSWORD:-${saved_database_password:-$(openssl rand -hex 24)}}"
rabbitmq_password="${ATTUNE_SETUP_RABBITMQ_PASSWORD:-${saved_rabbitmq_password:-$(openssl rand -hex 24)}}"
database_admin_password="${ATTUNE_SETUP_DATABASE_ADMIN_PASSWORD:-$saved_database_admin_password}"
rabbitmq_admin_password="${ATTUNE_SETUP_RABBITMQ_ADMIN_PASSWORD:-$saved_rabbitmq_admin_password}"
[[ "$database_mode" != bundled || -n "$database_admin_password" ]] || database_admin_password="$(openssl rand -hex 24)"
[[ "$rabbitmq_mode" != bundled || -n "$rabbitmq_admin_password" ]] || rabbitmq_admin_password="$(openssl rand -hex 24)"
jwt_secret="${ATTUNE_SETUP_JWT_SECRET:-${saved_jwt_secret:-$(openssl rand -hex 32)}}"
encryption_key="${ATTUNE_SETUP_ENCRYPTION_KEY:-${saved_encryption_key:-$(openssl rand -hex 32)}}"

for secret_value in \
  "$database_password" \
  "$rabbitmq_password" \
  "$database_admin_password" \
  "$rabbitmq_admin_password" \
  "$jwt_secret" \
  "$encryption_key"; do
  [[ "$secret_value" != *$'\n'* && "$secret_value" != *$'\r'* ]] ||
    die "secret values must not contain newlines"
done
[[ ${#encryption_key} -ge 32 ]] || die "ATTUNE_SETUP_ENCRYPTION_KEY must be at least 32 characters"
[[ ${#jwt_secret} -ge 32 ]] || die "ATTUNE_SETUP_JWT_SECRET must be at least 32 characters"
[[ "$database_mode" == external || ${#database_password} -ge 16 ]] || die "generated database password must be at least 16 characters"
[[ "$rabbitmq_mode" == external || ${#rabbitmq_password} -ge 16 ]] || die "generated RabbitMQ password must be at least 16 characters"
[[ "$database_mode" != bundled || ${#database_admin_password} -ge 16 ]] ||
  die "ATTUNE_SETUP_DATABASE_ADMIN_PASSWORD must be at least 16 characters"
[[ "$rabbitmq_mode" != bundled || ${#rabbitmq_admin_password} -ge 16 ]] ||
  die "ATTUNE_SETUP_RABBITMQ_ADMIN_PASSWORD must be at least 16 characters"

runtime_secret="${release}-runtime"
database_admin_secret="${release}-postgresql-admin"
rabbitmq_admin_secret="${release}-rabbitmq-admin"
database_bootstrap_secret="${cluster_name}-bootstrap"
image_catalog="${cluster_name}-images"

case "$database_mode" in
  cnpg)
    database_host="${cluster_name}-rw"
    database_enabled=false
    database_provisioning=false
    ;;
  bundled)
    database_host="${release}-attune-postgresql"
    database_enabled=true
    database_provisioning=true
    ;;
  external)
    database_enabled=false
    database_provisioning=false
    ;;
esac

if [[ "$rabbitmq_mode" == bundled ]]; then
  rabbitmq_host="${release}-attune-rabbitmq"
  rabbitmq_enabled=true
  rabbitmq_provisioning=true
else
  rabbitmq_enabled=false
  rabbitmq_provisioning=false
fi

database_url="postgresql://$(urlencode "$database_user"):$(urlencode "$database_password")@${database_host}:${database_port}/${database_name}"
if [[ "$database_mode" == external ]]; then
  database_url="${database_url}?sslmode=${database_sslmode}"
fi
rabbitmq_url="${rabbitmq_scheme}://$(urlencode "$rabbitmq_user"):$(urlencode "$rabbitmq_password")@${rabbitmq_host}:${rabbitmq_port}/$(urlencode "$rabbitmq_vhost")"
ingress_enabled=false
[[ -n "$ingress_host" ]] && ingress_enabled=true

umask 077
mkdir -p "$output_dir"
output_files=(.gitignore credentials.state namespace.yaml secrets.yaml timescaledb.yaml values.yaml)
for output_file in "${output_files[@]}"; do
  if [[ -e "$output_dir/$output_file" && "$force" != true ]]; then
    die "$output_dir/$output_file already exists; use --force to replace generated files"
  fi
done
if [[ "$force" == true ]]; then
  for output_file in "${output_files[@]}"; do
    [[ "$output_file" == credentials.state ]] && continue
    rm -f "$output_dir/$output_file"
  done
fi

cat > "$output_dir/.gitignore" <<'EOF'
credentials.state
.credentials.state.*
secrets.yaml
EOF

credentials_tmp="$(mktemp "$output_dir/.credentials.state.XXXXXX")"
{
  printf 'DATABASE_MODE\t%s\n' "$database_mode"
  printf 'RABBITMQ_MODE\t%s\n' "$rabbitmq_mode"
  printf 'DATABASE_PASSWORD_B64\t%s\n' "$(base64_value "$database_password")"
  printf 'DATABASE_ADMIN_PASSWORD_B64\t%s\n' "$(base64_value "$database_admin_password")"
  printf 'RABBITMQ_PASSWORD_B64\t%s\n' "$(base64_value "$rabbitmq_password")"
  printf 'RABBITMQ_ADMIN_PASSWORD_B64\t%s\n' "$(base64_value "$rabbitmq_admin_password")"
  printf 'JWT_SECRET_B64\t%s\n' "$(base64_value "$jwt_secret")"
  printf 'ENCRYPTION_KEY_B64\t%s\n' "$(base64_value "$encryption_key")"
} > "$credentials_tmp"
chmod 600 "$credentials_tmp"
mv -f "$credentials_tmp" "$credentials_file"
credentials_tmp=""

cat > "$output_dir/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${namespace}"
EOF

cat > "$output_dir/secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: "${runtime_secret}"
  namespace: "${namespace}"
type: Opaque
data:
  ATTUNE__SECURITY__JWT_SECRET: "$(base64_value "$jwt_secret")"
  ATTUNE__SECURITY__ENCRYPTION_KEY: "$(base64_value "$encryption_key")"
  ATTUNE__DATABASE__URL: "$(base64_value "$database_url")"
  ATTUNE__MESSAGE_QUEUE__URL: "$(base64_value "$rabbitmq_url")"
  ATTUNE_MQ_URL: "$(base64_value "$rabbitmq_url")"
  DB_HOST: "$(base64_value "$database_host")"
  DB_PORT: "$(base64_value "$database_port")"
  DB_USER: "$(base64_value "$database_user")"
  DB_PASSWORD: "$(base64_value "$database_password")"
  DB_NAME: "$(base64_value "$database_name")"
  DB_SCHEMA: "$(base64_value "$database_schema")"
  PGSSLMODE: "$(base64_value "$database_sslmode")"
  RABBITMQ_USER: "$(base64_value "$rabbitmq_user")"
  RABBITMQ_PASSWORD: "$(base64_value "$rabbitmq_password")"
  TEST_LOGIN: "$(base64_value "$admin_email")"
  TEST_DISPLAY_NAME: "$(base64_value "Attune Administrator")"
  TEST_PASSWORD: "$(base64_value "TestPass123!")"
  DEFAULT_ADMIN_LOGIN: "$(base64_value "$admin_email")"
  DEFAULT_ADMIN_PERMISSION_SET_REF: "$(base64_value "core.admin")"
  SOURCE_PACKS_DIR: "$(base64_value "/source/packs")"
  TARGET_PACKS_DIR: "$(base64_value "/opt/attune/packs")"
  RUNTIME_ENVS_DIR: "$(base64_value "/opt/attune/runtime_envs")"
  ARTIFACTS_DIR: "$(base64_value "/opt/attune/artifacts")"
  LOADER_SCRIPT: "$(base64_value "/scripts/load_core_pack.py")"
EOF

if [[ "$database_mode" == cnpg ]]; then
  cat >> "$output_dir/secrets.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: "${database_bootstrap_secret}"
  namespace: "${namespace}"
type: kubernetes.io/basic-auth
data:
  username: "$(base64_value "$database_user")"
  password: "$(base64_value "$database_password")"
EOF
elif [[ "$database_mode" == bundled ]]; then
  cat >> "$output_dir/secrets.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: "${database_admin_secret}"
  namespace: "${namespace}"
type: Opaque
data:
  username: "$(base64_value "postgres")"
  password: "$(base64_value "$database_admin_password")"
EOF
fi

if [[ "$rabbitmq_mode" == bundled ]]; then
  cat >> "$output_dir/secrets.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: "${rabbitmq_admin_secret}"
  namespace: "${namespace}"
type: Opaque
data:
  username: "$(base64_value "attune-admin")"
  password: "$(base64_value "$rabbitmq_admin_password")"
EOF
fi

if [[ "$database_mode" == cnpg ]]; then
  cat > "$output_dir/timescaledb.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: ImageCatalog
metadata:
  name: "${image_catalog}"
  namespace: "${namespace}"
spec:
  images:
    - major: 16
      image: ${TIMESCALE_IMAGE}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: "${cluster_name}"
  namespace: "${namespace}"
spec:
  instances: ${instances}
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ImageCatalog
    name: "${image_catalog}"
    major: 16
  imagePullPolicy: IfNotPresent
  postgresUID: 1000
  postgresGID: 1000
  bootstrap:
    initdb:
      database: "${database_name}"
      owner: "${database_user}"
      secret:
        name: "${database_bootstrap_secret}"
      dataChecksums: true
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA public;
        - CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public;
        - CREATE EXTENSION IF NOT EXISTS timescaledb;
        - CREATE SCHEMA IF NOT EXISTS "${database_schema}" AUTHORIZATION "${database_user}";
  postgresql:
    shared_preload_libraries:
      - timescaledb
  storage:
    size: "${database_size}"
EOF
  if [[ -n "$storage_class" ]]; then
    printf '    storageClass: "%s"\n' "$storage_class" >> "$output_dir/timescaledb.yaml"
  fi
fi

cat > "$output_dir/values.yaml" <<EOF
security:
  existingSecret: "${runtime_secret}"

database:
  host: "${database_host}"
  port: ${database_port}
  database: "${database_name}"
  schema: "${database_schema}"
  postgresql:
    enabled: ${database_enabled}
EOF

if [[ "$database_mode" == bundled ]]; then
  cat >> "$output_dir/values.yaml" <<EOF
    admin:
      existingSecret: "${database_admin_secret}"
      usernameKey: username
      passwordKey: password
EOF
fi

cat >> "$output_dir/values.yaml" <<EOF
    provisioning:
      enabled: ${database_provisioning}
    persistence:
      size: "${database_size}"
      storageClassName: "${storage_class}"

rabbitmq:
  host: "${rabbitmq_host}"
  port: ${rabbitmq_port}
  enabled: ${rabbitmq_enabled}
EOF

if [[ "$rabbitmq_mode" == bundled ]]; then
  cat >> "$output_dir/values.yaml" <<EOF
  admin:
    existingSecret: "${rabbitmq_admin_secret}"
    usernameKey: username
    passwordKey: password
EOF
fi

cat >> "$output_dir/values.yaml" <<EOF
  provisioning:
    enabled: ${rabbitmq_provisioning}
  persistence:
    storageClassName: "${storage_class}"
EOF

shared_storage_class="${shared_storage_rwx_class:-$storage_class}"
printf '\nsharedStorage:\n' >> "$output_dir/values.yaml"
for shared_claim in packs runtimeEnvs artifacts; do
  printf '  %s:\n' "$shared_claim" >> "$output_dir/values.yaml"
  if [[ -n "$shared_storage_rwx_class" ]]; then
    printf '    accessModes:\n      - ReadWriteMany\n' >> "$output_dir/values.yaml"
  fi
  printf '    storageClassName: "%s"\n' "$shared_storage_class" >> "$output_dir/values.yaml"
done

cat >> "$output_dir/values.yaml" <<EOF
web:
  ingress:
    enabled: ${ingress_enabled}
    className: "${ingress_class}"
    hosts:
      - host: "${ingress_host}"
        paths:
          - path: /
            pathType: Prefix
EOF

if [[ "$ingress_enabled" == true ]]; then
  cat >> "$output_dir/values.yaml" <<EOF
    tls:
      - secretName: "${ingress_tls_secret}"
        hosts:
          - "${ingress_host}"
EOF
fi

chmod 600 "$output_dir/secrets.yaml"

printf 'Generated Attune setup in %s\n\n' "$output_dir"
printf 'Apply in this order:\n'
printf '  kubectl apply -f %q\n' "$output_dir/namespace.yaml"
printf '  kubectl apply -f %q\n' "$output_dir/secrets.yaml"
if [[ "$database_mode" == cnpg ]]; then
  printf '  kubectl apply -f %q\n' "$output_dir/timescaledb.yaml"
  printf '  kubectl wait --namespace %s --for=condition=Ready cluster/%s --timeout=10m\n' "$namespace" "$cluster_name"
fi
printf '  helm upgrade --install %s attune/attune --namespace %s --values %q --wait --wait-for-jobs\n' \
  "$release" "$namespace" "$output_dir/values.yaml"
printf '\nDatabase mode: %s\nRabbitMQ mode: %s\n' "$database_mode" "$rabbitmq_mode"
if [[ -n "$shared_storage_rwx_class" ]]; then
  printf 'Shared storage: ReadWriteMany with StorageClass %s. Install its mount client on every schedulable node.\n' "$shared_storage_rwx_class"
  printf 'Do not apply this access-mode change to bound PVCs. Back up and migrate their data to new RWX claims.\n'
fi
if [[ "$database_mode" == cnpg ]]; then
  printf 'The CloudNativePG operator must already be installed.\n'
elif [[ "$database_mode" == external ]]; then
  printf 'The external database must already contain TimescaleDB, pgcrypto, uuid-ossp, and an owner-writable %s schema.\n' "$database_schema"
fi
if [[ "$rabbitmq_mode" == external ]]; then
  printf 'The external RabbitMQ user must already have configure, write, and read access to vhost %s.\n' "$rabbitmq_vhost"
fi
if [[ "$ingress_enabled" == true ]]; then
  printf 'The ingress TLS Secret %s must already exist in namespace %s.\n' "$ingress_tls_secret" "$namespace"
  printf 'Ingress was enabled based on your confirmation that the bootstrap password was changed.\n'
else
  printf 'The initial login is %s with password TestPass123!\n' "$admin_email"
  printf 'Before enabling ingress, run: kubectl --namespace %s port-forward service/%s-attune-web 8080:80\n' "$namespace" "$release"
  printf 'Sign in at http://127.0.0.1:8080 and change the password.\n'
fi
printf 'Keep %s/secrets.yaml private.\n' "$output_dir"
