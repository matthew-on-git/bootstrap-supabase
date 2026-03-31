#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────
# bootstrap-supabase — Idempotent installer for self-hosted Supabase
#
# Deploys the full Supabase stack via Docker Compose:
#   PostgreSQL · GoTrue (Auth) · PostgREST · Realtime · Storage
#   Edge Functions · Studio · Kong (API Gateway) · imgproxy
#   Optional: Analytics (Logflare) + Log collection (Vector)
#
# Supports:  Ubuntu 22.04 / 24.04
# TLS modes: off | letsencrypt-http | dns-cloudflare
# Re-run safe: secrets and data volumes are preserved
# ───────────────────────────────────────────────────────────────────
set -euo pipefail

######################################################################
# Constants & Defaults
######################################################################

INSTALL_DIR_DEFAULT="/opt/supabase"
DOMAIN_DEFAULT="localhost"
API_PORT_DEFAULT=8000
TLS_MODE_DEFAULT="off"
BACKUP_RETENTION_DEFAULT=7

# Pinned versions — update as a tested set
VER_POSTGRES_DEFAULT="15.8.1.085"
VER_STUDIO_DEFAULT="2026.03.16-sha-5528817"
VER_GOTRUE_DEFAULT="v2.186.0"
VER_POSTGREST_DEFAULT="v14.6"
VER_REALTIME_DEFAULT="v2.76.5"
VER_STORAGE_DEFAULT="v1.44.2"
VER_META_DEFAULT="v0.95.2"
VER_EDGE_RUNTIME_DEFAULT="v1.71.2"
VER_KONG_DEFAULT="3.9.1"
VER_IMGPROXY_DEFAULT="v3.30.1"
VER_LOGFLARE_DEFAULT="1.31.2"
VER_VECTOR_DEFAULT="0.53.0-alpine"

CONF_FILE=".install.conf"

######################################################################
# Logging
######################################################################

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'

log_info() { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die() {
  log_error "$*"
  exit 1
}
banner() { printf "\n${BOLD}═══ %s ═══${NC}\n\n" "$*"; }

######################################################################
# Helpers
######################################################################

prompt() {
  local var="$1" msg="$2" default="$3"
  if [[ "$AUTO_YES" == "true" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local input
  read -rp "$(printf "${BLUE}>>>${NC} %s [%s]: " "$msg" "$default")" input
  printf -v "$var" '%s' "${input:-$default}"
}

prompt_secret() {
  local var="$1" msg="$2" default="$3"
  if [[ "$AUTO_YES" == "true" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local input
  read -srp "$(printf "${BLUE}>>>${NC} %s [%s]: " "$msg" "${default:+********}")" input
  echo
  printf -v "$var" '%s' "${input:-$default}"
}

prompt_yesno() {
  local var="$1" msg="$2" default="$3"
  if [[ "$AUTO_YES" == "true" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local input
  read -rp "$(printf "${BLUE}>>>${NC} %s [%s]: " "$msg" "$default")" input
  input="${input:-$default}"
  case "${input,,}" in
  y | yes) printf -v "$var" 'y' ;;
  *) printf -v "$var" 'n' ;;
  esac
}

# Generate an HS256 JWT. Tokens expire in ~5 years.
generate_jwt() {
  local secret="$1" role="$2"
  local iat exp header payload h_b64 p_b64 sig
  iat=$(date +%s)
  exp=$((iat + 157680000))
  header='{"alg":"HS256","typ":"JWT"}'
  payload="{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}"
  h_b64=$(printf '%s' "$header" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  p_b64=$(printf '%s' "$payload" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  sig=$(printf '%s.%s' "$h_b64" "$p_b64" |
    openssl dgst -sha256 -hmac "$secret" -binary |
    openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  printf '%s.%s.%s' "$h_b64" "$p_b64" "$sig"
}

######################################################################
# Argument Parsing
######################################################################

AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  -y | --yes)
    AUTO_YES=true
    shift
    ;;
  -h | --help)
    cat <<'USAGE'
Usage: install.sh [OPTIONS]

Idempotent installer for self-hosted Supabase (free tier).

Options:
  -y, --yes    Non-interactive mode (accept all defaults / saved config)
  -h, --help   Show this help message

Environment:
  Requires root on Ubuntu 22.04 / 24.04.
  Installs Docker if not present.
  Safe to re-run — secrets, data volumes, and config are preserved.

TLS Modes:
  off                No TLS — binds directly. Use behind an external LB.
  letsencrypt-http   nginx + certbot with HTTP-01. Requires port 80/443.
  dns-cloudflare     nginx + certbot with DNS-01 via Cloudflare API.
USAGE
    exit 0
    ;;
  *) die "Unknown option: $1" ;;
  esac
done

######################################################################
# Pre-flight Checks
######################################################################

banner "Pre-flight Checks"

[[ $EUID -eq 0 ]] || die "This script must be run as root"

if command -v lsb_release &>/dev/null; then
  [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]] ||
    die "This script requires Ubuntu (detected: $(lsb_release -is))"
else
  die "lsb_release not found — is this Ubuntu?"
fi

log_info "Checking internet connectivity..."
curl -sf --max-time 10 https://hub.docker.com >/dev/null 2>&1 ||
  die "Cannot reach Docker Hub — check internet connectivity"

log_info "Pre-flight checks passed"

######################################################################
# Load Saved Config
######################################################################

INSTALL_DIR="$INSTALL_DIR_DEFAULT"
DOMAIN="$DOMAIN_DEFAULT"
API_PORT="$API_PORT_DEFAULT"
TLS_MODE="$TLS_MODE_DEFAULT"
CERTBOT_EMAIL=""
CF_API_TOKEN=""
BACKUP_RETENTION="$BACKUP_RETENTION_DEFAULT"
ENABLE_ANALYTICS="y"
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
SMTP_SENDER=""

VER_POSTGRES="$VER_POSTGRES_DEFAULT"
VER_STUDIO="$VER_STUDIO_DEFAULT"
VER_GOTRUE="$VER_GOTRUE_DEFAULT"
VER_POSTGREST="$VER_POSTGREST_DEFAULT"
VER_REALTIME="$VER_REALTIME_DEFAULT"
VER_STORAGE="$VER_STORAGE_DEFAULT"
VER_META="$VER_META_DEFAULT"
VER_EDGE_RUNTIME="$VER_EDGE_RUNTIME_DEFAULT"
VER_KONG="$VER_KONG_DEFAULT"
VER_IMGPROXY="$VER_IMGPROXY_DEFAULT"
VER_LOGFLARE="$VER_LOGFLARE_DEFAULT"
VER_VECTOR="$VER_VECTOR_DEFAULT"

for candidate in "${INSTALL_DIR}/${CONF_FILE}" "${INSTALL_DIR_DEFAULT}/${CONF_FILE}"; do
  if [[ -f "$candidate" ]]; then
    log_info "Loading saved configuration from ${candidate}"
    # shellcheck source=/dev/null
    source "$candidate"
    break
  fi
done

######################################################################
# Interactive Configuration
######################################################################

banner "Configuration"

prompt DOMAIN "Domain name" "$DOMAIN"
prompt INSTALL_DIR "Install directory" "$INSTALL_DIR"
prompt API_PORT "API gateway port (Kong)" "$API_PORT"

printf "\n  TLS modes:\n"
printf "    off               — No TLS. Use behind an external load balancer.\n"
printf "    letsencrypt-http  — nginx + certbot (HTTP-01). Requires port 80/443.\n"
printf "    dns-cloudflare    — nginx + certbot (DNS-01). No inbound port 80 needed.\n\n"
prompt TLS_MODE "TLS mode" "$TLS_MODE"

case "$TLS_MODE" in
off | letsencrypt-http | dns-cloudflare) ;;
*) die "Invalid TLS mode: $TLS_MODE" ;;
esac

if [[ "$TLS_MODE" != "off" ]]; then
  prompt CERTBOT_EMAIL "Certbot email for Let's Encrypt" "$CERTBOT_EMAIL"
  [[ -n "$CERTBOT_EMAIL" ]] || die "Certbot email is required for TLS"
fi

if [[ "$TLS_MODE" == "dns-cloudflare" ]]; then
  prompt_secret CF_API_TOKEN "Cloudflare API token" "$CF_API_TOKEN"
  [[ -n "$CF_API_TOKEN" ]] || die "Cloudflare API token is required for dns-cloudflare mode"
fi

printf "\n"
prompt_yesno CONFIGURE_SMTP "Configure SMTP for auth emails?" "${SMTP_HOST:+y}"
CONFIGURE_SMTP="${CONFIGURE_SMTP:-n}"
if [[ "$CONFIGURE_SMTP" == "y" ]]; then
  prompt SMTP_HOST "SMTP host" "$SMTP_HOST"
  prompt SMTP_PORT "SMTP port" "$SMTP_PORT"
  prompt SMTP_USER "SMTP username" "$SMTP_USER"
  prompt_secret SMTP_PASS "SMTP password" "$SMTP_PASS"
  prompt SMTP_SENDER "Sender email address" "$SMTP_SENDER"
fi

prompt_yesno ENABLE_ANALYTICS "Enable analytics (Logflare + Vector)?" "$ENABLE_ANALYTICS"
prompt BACKUP_RETENTION "Backup retention (days)" "$BACKUP_RETENTION"

######################################################################
# Save Configuration
######################################################################

mkdir -p "$INSTALL_DIR"

cat >"${INSTALL_DIR}/${CONF_FILE}" <<CONF
# bootstrap-supabase saved configuration — $(date -Iseconds)
DOMAIN="${DOMAIN}"
INSTALL_DIR="${INSTALL_DIR}"
API_PORT="${API_PORT}"
TLS_MODE="${TLS_MODE}"
CERTBOT_EMAIL="${CERTBOT_EMAIL}"
CF_API_TOKEN="${CF_API_TOKEN}"
BACKUP_RETENTION="${BACKUP_RETENTION}"
ENABLE_ANALYTICS="${ENABLE_ANALYTICS}"
SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_USER="${SMTP_USER}"
SMTP_PASS="${SMTP_PASS}"
SMTP_SENDER="${SMTP_SENDER}"
VER_POSTGRES="${VER_POSTGRES}"
VER_STUDIO="${VER_STUDIO}"
VER_GOTRUE="${VER_GOTRUE}"
VER_POSTGREST="${VER_POSTGREST}"
VER_REALTIME="${VER_REALTIME}"
VER_STORAGE="${VER_STORAGE}"
VER_META="${VER_META}"
VER_EDGE_RUNTIME="${VER_EDGE_RUNTIME}"
VER_KONG="${VER_KONG}"
VER_IMGPROXY="${VER_IMGPROXY}"
VER_LOGFLARE="${VER_LOGFLARE}"
VER_VECTOR="${VER_VECTOR}"
CONF
chmod 600 "${INSTALL_DIR}/${CONF_FILE}"
log_info "Configuration saved"

######################################################################
# Install Packages
######################################################################

banner "Installing Packages"

export DEBIAN_FRONTEND=noninteractive

apt_packages=(ca-certificates curl gnupg openssl postgresql-client)

if ! command -v docker &>/dev/null; then
  log_info "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC2027,SC2046
  echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu "$(lsb_release -cs)" stable" \
    >/etc/apt/sources.list.d/docker.list
  apt_packages+=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
fi

if [[ "$TLS_MODE" != "off" ]]; then
  apt_packages+=(nginx certbot)
  case "$TLS_MODE" in
  letsencrypt-http) apt_packages+=(python3-certbot-nginx) ;;
  dns-cloudflare) apt_packages+=(python3-certbot-dns-cloudflare) ;;
  esac
fi

log_info "Updating package index..."
apt-get update -qq

log_info "Installing: ${apt_packages[*]}"
apt-get install -y -qq "${apt_packages[@]}"

systemctl enable --now docker
log_info "Docker is running"

######################################################################
# Generate / Preserve Secrets
######################################################################

banner "Secrets"

ENV_FILE="${INSTALL_DIR}/.env"

preserve_or_generate() {
  local var_name="$1" generator="$2"
  if [[ -f "$ENV_FILE" ]]; then
    local existing
    existing=$(grep -oP "^${var_name}=\K.*" "$ENV_FILE" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      printf -v "$var_name" '%s' "$existing"
      log_info "Preserved existing ${var_name}"
      return
    fi
  fi
  local value
  value=$(eval "$generator")
  printf -v "$var_name" '%s' "$value"
  log_info "Generated new ${var_name}"
}

preserve_or_generate POSTGRES_PASSWORD "openssl rand -hex 32"
preserve_or_generate JWT_SECRET "openssl rand -hex 32"
preserve_or_generate DASHBOARD_PASSWORD "openssl rand -hex 16"
preserve_or_generate SECRET_KEY_BASE "openssl rand -base64 48 | tr -d '\n'"
preserve_or_generate VAULT_ENC_KEY "openssl rand -hex 16"
preserve_or_generate LOGFLARE_API_KEY "openssl rand -hex 16"

# JWT tokens are derived from JWT_SECRET — only regenerate when it changes
EXISTING_JWT=""
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_JWT=$(grep -oP "^JWT_SECRET=\K.*" "$ENV_FILE" 2>/dev/null || true)
fi

if [[ "$EXISTING_JWT" == "$JWT_SECRET" && -f "$ENV_FILE" ]]; then
  ANON_KEY=$(grep -oP "^ANON_KEY=\K.*" "$ENV_FILE" 2>/dev/null || true)
  SERVICE_ROLE_KEY=$(grep -oP "^SERVICE_ROLE_KEY=\K.*" "$ENV_FILE" 2>/dev/null || true)
  if [[ -n "$ANON_KEY" && -n "$SERVICE_ROLE_KEY" ]]; then
    log_info "Preserved existing ANON_KEY and SERVICE_ROLE_KEY"
  else
    ANON_KEY=$(generate_jwt "$JWT_SECRET" "anon")
    SERVICE_ROLE_KEY=$(generate_jwt "$JWT_SECRET" "service_role")
    log_info "Generated new ANON_KEY and SERVICE_ROLE_KEY"
  fi
else
  ANON_KEY=$(generate_jwt "$JWT_SECRET" "anon")
  SERVICE_ROLE_KEY=$(generate_jwt "$JWT_SECRET" "service_role")
  log_info "Generated new ANON_KEY and SERVICE_ROLE_KEY"
fi

######################################################################
# Derived Values
######################################################################

if [[ "$TLS_MODE" == "off" ]]; then
  API_EXTERNAL_URL="http://${DOMAIN}:${API_PORT}"
  SUPABASE_PUBLIC_URL="${API_EXTERNAL_URL}"
  SITE_URL="${API_EXTERNAL_URL}"
  KONG_BIND="0.0.0.0"
else
  API_EXTERNAL_URL="https://${DOMAIN}"
  SUPABASE_PUBLIC_URL="${API_EXTERNAL_URL}"
  SITE_URL="${API_EXTERNAL_URL}"
  KONG_BIND="127.0.0.1"
fi

MAILER_AUTOCONFIRM="true"
[[ -n "$SMTP_HOST" ]] && MAILER_AUTOCONFIRM="false"

######################################################################
# Directory Structure
######################################################################

banner "Setting Up Directories"

mkdir -p "${INSTALL_DIR}"/{volumes/api,volumes/db/init,volumes/storage,volumes/functions/hello,volumes/logs,backups}
log_info "Directory structure created under ${INSTALL_DIR}"

######################################################################
# DB Init Script
######################################################################

cat >"${INSTALL_DIR}/volumes/db/init/99-bootstrap.sh" <<'INITDB'
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username supabase_admin --dbname postgres <<-'EOSQL'
  -- Realtime schema
  CREATE SCHEMA IF NOT EXISTS _realtime;
  ALTER SCHEMA _realtime OWNER TO supabase_admin;

  -- Realtime publication
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
      CREATE PUBLICATION supabase_realtime;
    END IF;
  END$$;

  -- API role grants on public schema
  GRANT USAGE ON SCHEMA public TO anon, service_role;
  GRANT ALL ON ALL TABLES    IN SCHEMA public TO anon, service_role;
  GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, service_role;
  GRANT ALL ON ALL ROUTINES  IN SCHEMA public TO anon, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON ROUTINES  TO anon, service_role;

  -- Analytics database (harmless if analytics not enabled)
  SELECT 'CREATE DATABASE _supabase'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '_supabase')\gexec
EOSQL
INITDB
chmod +x "${INSTALL_DIR}/volumes/db/init/99-bootstrap.sh"
log_info "Database init script written"

######################################################################
# Kong Declarative Config
######################################################################

cat >"${INSTALL_DIR}/volumes/api/kong.yml" <<KONG
_format_version: "2.1"
_transform: true

###
### Consumers / Credentials
###
consumers:
  - username: ANON
    keyauth_credentials:
      - key: ${ANON_KEY}
  - username: SERVICE_ROLE
    keyauth_credentials:
      - key: ${SERVICE_ROLE_KEY}

acls:
  - consumer: ANON
    group: anon
  - consumer: SERVICE_ROLE
    group: admin

###
### API Routes
###
services:
  ## ── Auth (open — no key required) ────────────────────────────
  - name: auth-v1-open
    url: http://auth:9999/verify
    routes:
      - name: auth-v1-open
        strip_path: true
        paths: [/auth/v1/verify]
    plugins:
      - name: cors

  - name: auth-v1-open-callback
    url: http://auth:9999/callback
    routes:
      - name: auth-v1-open-callback
        strip_path: true
        paths: [/auth/v1/callback]
    plugins:
      - name: cors

  - name: auth-v1-open-authorize
    url: http://auth:9999/authorize
    routes:
      - name: auth-v1-open-authorize
        strip_path: true
        paths: [/auth/v1/authorize]
    plugins:
      - name: cors

  ## ── Auth (key-auth gated) ────────────────────────────────────
  - name: auth-v1
    url: http://auth:9999/
    routes:
      - name: auth-v1
        strip_path: true
        paths: [/auth/v1/]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin, anon]}

  ## ── REST (PostgREST) ─────────────────────────────────────────
  - name: rest-v1
    url: http://rest:3000/
    routes:
      - name: rest-v1
        strip_path: true
        paths: [/rest/v1/]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin, anon]}

  ## ── GraphQL ──────────────────────────────────────────────────
  - name: graphql-v1
    url: http://rest:3000/rpc/graphql
    routes:
      - name: graphql-v1
        strip_path: true
        paths: [/graphql/v1]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin, anon]}

  ## ── Realtime ─────────────────────────────────────────────────
  - name: realtime-v1-ws
    url: http://realtime:4000/socket/
    routes:
      - name: realtime-v1-ws
        strip_path: true
        paths: [/realtime/v1/]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin, anon]}

  ## ── Storage ──────────────────────────────────────────────────
  - name: storage-v1
    url: http://storage:5000/
    routes:
      - name: storage-v1
        strip_path: true
        paths: [/storage/v1/]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin, anon]}

  ## ── Postgres Meta (service_role only) ────────────────────────
  - name: meta
    url: http://meta:8080/
    routes:
      - name: meta
        strip_path: true
        paths: [/pg/]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin]}

  ## ── Edge Functions ───────────────────────────────────────────
  - name: functions-v1
    url: http://functions:9000/
    routes:
      - name: functions-v1
        strip_path: true
        paths: [/functions/v1/]
    plugins:
      - name: cors
      - name: key-auth
        config: {hide_credentials: false}
      - name: acl
        config: {hide_groups_header: true, allow: [admin, anon]}
KONG

log_info "Kong API gateway config written"

######################################################################
# Vector Config (log collection)
######################################################################

if [[ "$ENABLE_ANALYTICS" == "y" ]]; then
  cat >"${INSTALL_DIR}/volumes/logs/vector.yml" <<VECTOR
api:
  enabled: true
  address: 0.0.0.0:9001

sources:
  docker_host:
    type: docker_logs
    docker_host: unix:///var/run/docker.sock

transforms:
  project_logs:
    type: remap
    inputs: [docker_host]
    source: |-
      .project = "default"
      .event_message = del(.message)
      .appname = del(.container_name)
      del(.container_created_at)
      del(.container_id)
      del(.source_type)
      del(.stream)
      del(.label)
      del(.image)
      del(.host)
      del(.timestamp)

sinks:
  logflare:
    type: http
    method: post
    batch:
      max_bytes: 524288
    inputs: [project_logs]
    uri: "http://analytics:4000/api/logs?source_name=docker_host"
    encoding:
      codec: json
    headers:
      x-api-key: "${LOGFLARE_API_KEY}"
VECTOR
  log_info "Vector config written"
fi

######################################################################
# Example Edge Function
######################################################################

cat >"${INSTALL_DIR}/volumes/functions/hello/index.ts" <<'EDGEFN'
Deno.serve(async (_req: Request) => {
  return new Response(
    JSON.stringify({ message: "Hello from Supabase Edge Functions!" }),
    { headers: { "Content-Type": "application/json" } },
  );
});
EDGEFN
log_info "Example edge function written"

######################################################################
# .env (secrets)
######################################################################

cat >"$ENV_FILE" <<DOTENV
# bootstrap-supabase — generated $(date -Iseconds)
# Contains secrets — do not commit to version control.

POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
LOGFLARE_API_KEY=${LOGFLARE_API_KEY}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SENDER=${SMTP_SENDER}
DOTENV
chmod 600 "$ENV_FILE"
log_info ".env written (chmod 600)"

######################################################################
# docker-compose.yml
######################################################################

banner "Writing Docker Compose"

# Build the optional analytics block
ANALYTICS_BLOCK=""
if [[ "$ENABLE_ANALYTICS" == "y" ]]; then
  # NOTE: \${VAR} refs are expanded by Docker Compose from .env at runtime.
  # Bash does not re-expand variables inside an already-expanded string,
  # so the \$ in this assignment produces a literal $ in the variable value,
  # which then passes through the outer heredoc untouched.
  ANALYTICS_BLOCK=$(
    cat <<ANALYTICS_EOF

  # ── Analytics (Logflare) ───────────────────────────────────────
  analytics:
    image: supabase/logflare:${VER_LOGFLARE}
    container_name: supabase-analytics
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      LOGFLARE_NODE_HOST: "127.0.0.1"
      DB_USERNAME: supabase_admin
      DB_DATABASE: _supabase
      DB_HOSTNAME: db
      DB_PORT: "5432"
      DB_PASSWORD: \${POSTGRES_PASSWORD}
      DB_SCHEMA: _analytics
      LOGFLARE_API_KEY: \${LOGFLARE_API_KEY}
      LOGFLARE_SINGLE_TENANT: "true"
      LOGFLARE_SUPABASE_MODE: "true"
      LOGFLARE_MIN_CLUSTER_SIZE: "1"
      RELEASE_COOKIE: cookie
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 10

  # ── Log Collection (Vector) ────────────────────────────────────
  vector:
    image: timberio/vector:${VER_VECTOR}
    container_name: supabase-vector
    restart: unless-stopped
    volumes:
      - ./volumes/logs/vector.yml:/etc/vector/vector.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      LOGFLARE_API_KEY: \${LOGFLARE_API_KEY}
    depends_on:
      analytics:
        condition: service_healthy
ANALYTICS_EOF
  )
fi

cat >"${INSTALL_DIR}/docker-compose.yml" <<COMPOSE
# bootstrap-supabase — generated $(date -Iseconds)
# Re-run install.sh to regenerate. Data volumes are preserved.

services:
  # ── Database ───────────────────────────────────────────────────
  db:
    image: supabase/postgres:${VER_POSTGRES}
    container_name: supabase-db
    restart: unless-stopped
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - db-data:/var/lib/postgresql/data
      - ./volumes/db/init/99-bootstrap.sh:/docker-entrypoint-initdb.d/99-bootstrap.sh:ro
    environment:
      POSTGRES_HOST: /var/run/postgresql
      PGPORT: "5432"
      POSTGRES_PORT: "5432"
      PGPASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      PGDATABASE: postgres
      POSTGRES_DB: postgres
      JWT_SECRET: \${JWT_SECRET}
      JWT_EXP: "3600"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U supabase_admin -h localhost"]
      interval: 5s
      timeout: 5s
      retries: 10
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
      - -c
      - log_min_messages=fatal

  # ── API Gateway (Kong) ────────────────────────────────────────
  kong:
    image: kong/kong:${VER_KONG}
    container_name: supabase-kong
    restart: unless-stopped
    ports:
      - "${KONG_BIND}:${API_PORT}:8000"
      - "${KONG_BIND}:8443:8443"
    volumes:
      - ./volumes/api/kong.yml:/var/lib/kong/kong.yml:ro
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /var/lib/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
      KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
    depends_on:
      auth:
        condition: service_healthy
      rest:
        condition: service_started

  # ── Auth (GoTrue) ─────────────────────────────────────────────
  auth:
    image: supabase/gotrue:${VER_GOTRUE}
    container_name: supabase-auth
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: "9999"
      API_EXTERNAL_URL: ${API_EXTERNAL_URL}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:\${POSTGRES_PASSWORD}@db:5432/postgres
      GOTRUE_SITE_URL: ${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: ""
      GOTRUE_DISABLE_SIGNUP: "false"
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: "3600"
      GOTRUE_JWT_SECRET: \${JWT_SECRET}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: "true"
      GOTRUE_MAILER_AUTOCONFIRM: "${MAILER_AUTOCONFIRM}"
      GOTRUE_SMTP_HOST: \${SMTP_HOST}
      GOTRUE_SMTP_PORT: \${SMTP_PORT}
      GOTRUE_SMTP_USER: \${SMTP_USER}
      GOTRUE_SMTP_PASS: \${SMTP_PASS}
      GOTRUE_SMTP_ADMIN_EMAIL: \${SMTP_SENDER}
      GOTRUE_MAILER_URLPATHS_INVITE: /auth/v1/verify
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: /auth/v1/verify
      GOTRUE_MAILER_URLPATHS_RECOVERY: /auth/v1/verify
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: /auth/v1/verify
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9999/health"]
      interval: 5s
      timeout: 5s
      retries: 5

  # ── REST API (PostgREST) ──────────────────────────────────────
  rest:
    image: postgrest/postgrest:${VER_POSTGREST}
    container_name: supabase-rest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGRST_DB_URI: postgres://authenticator:\${POSTGRES_PASSWORD}@db:5432/postgres
      PGRST_DB_SCHEMAS: public,storage,graphql_public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: \${JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: \${JWT_SECRET}
      PGRST_APP_SETTINGS_JWT_EXP: "3600"
      PGRST_DB_MAX_ROWS: "1000"

  # ── Realtime ───────────────────────────────────────────────────
  realtime:
    image: supabase/realtime:${VER_REALTIME}
    container_name: supabase-realtime
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      PORT: "4000"
      DB_HOST: db
      DB_PORT: "5432"
      DB_USER: supabase_admin
      DB_PASSWORD: \${POSTGRES_PASSWORD}
      DB_NAME: postgres
      DB_AFTER_CONNECT_QUERY: "SET search_path TO _realtime"
      DB_ENC_KEY: supabaserealtime
      API_JWT_SECRET: \${JWT_SECRET}
      SECRET_KEY_BASE: \${SECRET_KEY_BASE}
      FLY_ALLOC_ID: fly123
      FLY_APP_NAME: realtime
      ERL_AFLAGS: -proto_dist inet_tcp
      ENABLE_TAILSCALE: "false"
      DNS_NODES: "''"
    healthcheck:
      test: ["CMD", "bash", "-c", "printf '\\\\0' > /dev/tcp/localhost/4000"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ── Storage API ────────────────────────────────────────────────
  storage:
    image: supabase/storage-api:${VER_STORAGE}
    container_name: supabase-storage
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started
      imgproxy:
        condition: service_started
    volumes:
      - storage-data:/var/lib/storage
    environment:
      ANON_KEY: \${ANON_KEY}
      SERVICE_KEY: \${SERVICE_ROLE_KEY}
      POSTGREST_URL: http://rest:3000
      PGRST_JWT_SECRET: \${JWT_SECRET}
      DATABASE_URL: postgres://supabase_storage_admin:\${POSTGRES_PASSWORD}@db:5432/postgres
      FILE_SIZE_LIMIT: "52428800"
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: stub
      REGION: stub
      GLOBAL_S3_BUCKET: stub
      ENABLE_IMAGE_TRANSFORMATION: "true"
      IMGPROXY_URL: http://imgproxy:5001
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:5000/status"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ── Image Transformations ──────────────────────────────────────
  imgproxy:
    image: darthsim/imgproxy:${VER_IMGPROXY}
    container_name: supabase-imgproxy
    restart: unless-stopped
    volumes:
      - storage-data:/var/lib/storage:ro
    environment:
      IMGPROXY_BIND: ":5001"
      IMGPROXY_LOCAL_FILESYSTEM_ROOT: /
      IMGPROXY_USE_ETAG: "true"
      IMGPROXY_ENABLE_WEBP_DETECTION: "true"
    healthcheck:
      test: ["CMD", "imgproxy", "health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ── Postgres Meta ──────────────────────────────────────────────
  meta:
    image: supabase/postgres-meta:${VER_META}
    container_name: supabase-meta
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      PG_META_PORT: "8080"
      PG_META_DB_HOST: db
      PG_META_DB_PORT: "5432"
      PG_META_DB_NAME: postgres
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: \${POSTGRES_PASSWORD}

  # ── Edge Functions ─────────────────────────────────────────────
  functions:
    image: supabase/edge-runtime:${VER_EDGE_RUNTIME}
    container_name: supabase-edge-functions
    restart: unless-stopped
    depends_on:
      kong:
        condition: service_started
    volumes:
      - ./volumes/functions:/home/deno/functions:ro
    environment:
      JWT_SECRET: \${JWT_SECRET}
      SUPABASE_URL: http://kong:8000
      SUPABASE_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: \${SERVICE_ROLE_KEY}
      SUPABASE_DB_URL: postgresql://postgres:\${POSTGRES_PASSWORD}@db:5432/postgres
      VERIFY_JWT: "true"

  # ── Studio Dashboard ──────────────────────────────────────────
  studio:
    image: supabase/studio:${VER_STUDIO}
    container_name: supabase-studio
    restart: unless-stopped
    depends_on:
      kong:
        condition: service_started
    ports:
      - "${KONG_BIND}:3000:3000"
    environment:
      STUDIO_DEFAULT_ORGANIZATION: Default Organization
      STUDIO_DEFAULT_PROJECT: Default Project
      SUPABASE_URL: http://kong:8000
      SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL}
      SUPABASE_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_KEY: \${SERVICE_ROLE_KEY}
      AUTH_JWT_SECRET: \${JWT_SECRET}
      SUPABASE_DASHBOARD_USERNAME: supabase
      SUPABASE_DASHBOARD_PASSWORD: \${DASHBOARD_PASSWORD}
      LOGFLARE_API_KEY: \${LOGFLARE_API_KEY}
      LOGFLARE_URL: http://analytics:4000
      NEXT_PUBLIC_ENABLE_LOGS: "true"
      NEXT_ANALYTICS_BACKEND_PROVIDER: postgres
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://localhost:3000/api/platform/health').then(r=>{if(r.status!==200)throw r.status})"]
      interval: 10s
      timeout: 5s
      retries: 5
${ANALYTICS_BLOCK}

volumes:
  db-data:
  storage-data:
COMPOSE

log_info "docker-compose.yml written ($(grep -c 'image:' "${INSTALL_DIR}/docker-compose.yml") services)"

######################################################################
# nginx / TLS
######################################################################

if [[ "$TLS_MODE" != "off" ]]; then
  banner "TLS Setup"

  if [[ "$TLS_MODE" == "dns-cloudflare" ]]; then
    mkdir -p /etc/letsencrypt
    cat >/etc/letsencrypt/.cloudflare-credentials <<CFCRED
dns_cloudflare_api_token = ${CF_API_TOKEN}
CFCRED
    chmod 600 /etc/letsencrypt/.cloudflare-credentials
    log_info "Cloudflare credentials written"
  fi

  # Obtain certificate (skip if already exists)
  if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log_info "Obtaining TLS certificate for ${DOMAIN}..."
    case "$TLS_MODE" in
    letsencrypt-http)
      cat >/etc/nginx/sites-available/supabase <<TMPNGINX
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 444; }
}
TMPNGINX
      ln -sf /etc/nginx/sites-available/supabase /etc/nginx/sites-enabled/supabase
      rm -f /etc/nginx/sites-enabled/default
      systemctl reload nginx
      certbot certonly --nginx -d "$DOMAIN" \
        --non-interactive --agree-tos -m "$CERTBOT_EMAIL"
      ;;
    dns-cloudflare)
      certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/.cloudflare-credentials \
        -d "$DOMAIN" \
        --non-interactive --agree-tos -m "$CERTBOT_EMAIL"
      ;;
    esac
    log_info "TLS certificate obtained"
  else
    log_info "TLS certificate already exists — skipping certbot"
  fi

  # Production nginx config
  cat >/etc/nginx/sites-available/supabase <<NGINX
# Supabase reverse proxy — generated by bootstrap-supabase

upstream kong_upstream   { server 127.0.0.1:${API_PORT}; }
upstream studio_upstream { server 127.0.0.1:3000; }

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 100m;

    # API routes → Kong
    location ~ ^/(rest|auth|realtime|storage|pg|graphql|functions|analytics)/v1(/|\$) {
        proxy_pass          http://kong_upstream;
        proxy_set_header    Host \$host;
        proxy_set_header    X-Real-IP \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade \$http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_read_timeout  86400;
    }

    # Dashboard → Studio
    location / {
        proxy_pass          http://studio_upstream;
        proxy_set_header    Host \$host;
        proxy_set_header    X-Real-IP \$remote_addr;
        proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade \$http_upgrade;
        proxy_set_header    Connection "upgrade";
    }
}

server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINX

  ln -sf /etc/nginx/sites-available/supabase /etc/nginx/sites-enabled/supabase
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  log_info "nginx configured as TLS reverse proxy"
fi

######################################################################
# Start Services
######################################################################

banner "Starting Supabase"

cd "$INSTALL_DIR"

log_info "Pulling container images (this may take a few minutes)..."
docker compose pull

log_info "Starting services..."
docker compose up -d

log_info "Waiting for API gateway..."
for attempt in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${API_PORT}/" >/dev/null 2>&1; then
    log_info "API gateway is healthy (attempt ${attempt}/60)"
    break
  fi
  if [[ $attempt -eq 60 ]]; then
    log_warn "API gateway did not respond within 60s"
    log_warn "Check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
  fi
  sleep 1
done

######################################################################
# Backup Cron
######################################################################

banner "Configuring Backups"

cat >/etc/cron.d/supabase-backup <<CRON
# Daily Supabase database backup at 02:00
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root PGPASSWORD='${POSTGRES_PASSWORD}' pg_dump -h 127.0.0.1 -U supabase_admin -d postgres 2>/dev/null | gzip > ${INSTALL_DIR}/backups/supabase-\$(date +\%Y\%m\%d-\%H\%M\%S).sql.gz && find ${INSTALL_DIR}/backups -name '*.sql.gz' -mtime +${BACKUP_RETENTION} -delete
CRON
chmod 644 /etc/cron.d/supabase-backup
log_info "Daily backup cron installed (retention: ${BACKUP_RETENTION} days)"

######################################################################
# Summary
######################################################################

banner "Installation Complete"

printf '%s\n' "${BOLD}Container Status:${NC}"
docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps \
  --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null ||
  docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps

printf '\n%s\n' "${BOLD}Access URLs:${NC}"
if [[ "$TLS_MODE" == "off" ]]; then
  printf "  Studio:     http://%s:3000\n" "$DOMAIN"
  printf "  API:        http://%s:%s\n" "$DOMAIN" "$API_PORT"
else
  printf "  Studio:     https://%s\n" "$DOMAIN"
  printf "  API:        https://%s\n" "$DOMAIN"
fi

printf '\n%s\n' "${BOLD}API Keys:${NC}"
printf "  anon (public):     %s\n" "$ANON_KEY"
printf "  service_role:      %s\n" "$SERVICE_ROLE_KEY"

printf '\n%s\n' "${BOLD}Dashboard Login:${NC}"
printf "  Username:  supabase\n"
printf "  Password:  %s\n" "$DASHBOARD_PASSWORD"

printf '\n%s\n' "${BOLD}Database:${NC}"
printf "  Host:      127.0.0.1:5432\n"
printf "  User:      supabase_admin\n"
printf "  Password:  %s\n" "$POSTGRES_PASSWORD"

printf '\n%s\n' "${BOLD}Files:${NC}"
printf "  Install dir:     %s\n" "$INSTALL_DIR"
printf "  Docker Compose:  %s/docker-compose.yml\n" "$INSTALL_DIR"
printf "  Environment:     %s/.env\n" "$INSTALL_DIR"
printf "  Kong config:     %s/volumes/api/kong.yml\n" "$INSTALL_DIR"
printf "  Edge functions:  %s/volumes/functions/\n" "$INSTALL_DIR"
printf "  Backups:         %s/backups/\n" "$INSTALL_DIR"

printf '\n'
printf '%s\n' "${RED}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
printf '%s\n' "${RED}${BOLD}║  BACK UP YOUR JWT_SECRET — IT CANNOT BE RECOVERED             ║${NC}"
printf "${RED}${BOLD}║  %-60s  ║${NC}\n" "$JWT_SECRET"
printf '%s\n' "${RED}${BOLD}║                                                                ║${NC}"
printf '%s\n' "${RED}${BOLD}║  Losing this key invalidates ALL API keys and user sessions.   ║${NC}"
printf '%s\n' "${RED}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
printf '\n'

log_info "Supabase self-hosted is ready."
