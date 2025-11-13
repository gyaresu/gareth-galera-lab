#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# start-lab.sh
# -----------------------------------------------------------------------------
# Orchestrates the full Passbolt + Galera demo environment:
#   * loads environment variables from /etc/environment and .env
#   * optionally regenerates TLS certificates
#   * (re)creates the Galera, Valkey and Passbolt containers
#   * runs Passbolt health checks and auto-registers the bootstrap admin user
#
# This script mirrors the expectations documented in env.example and the README.
# -----------------------------------------------------------------------------

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Load environment variables in the same order Docker Compose would:
#   1) system-level /etc/environment
#   2) project-specific .env
ENV_FILE="${PROJECT_ROOT}/.env"
GLOBAL_ENV="/etc/environment"
if [[ -f "${GLOBAL_ENV}" ]]; then
  set -a
  # shellcheck disable=SC1091 -- system file may not exist locally
  source "${GLOBAL_ENV}"
  set +a
fi
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090 -- dynamic path is intentional (user-provided .env)
  source "${ENV_FILE}"
  set +a
fi

# Flag defaults (can be overridden via CLI options)
RESET=0
FORCE_CERTS=0
SKIP_TESTS=0

RESET=0
FORCE_CERTS=0
SKIP_TESTS=0

usage() {
  cat <<'EOF'
Usage: scripts/start-lab.sh [options]

Options:
  --reset         Tear down existing containers and volumes before starting.
  --force-certs   Regenerate TLS material even if certs already exist.
  --skip-tests    Skip post-start smoke tests.
  -h, --help      Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) RESET=1 ;;
    --force-certs) FORCE_CERTS=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

log() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

require_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    log "Environment variable ${name} is required but not set."
    exit 1
  fi
}

wait_for_command() {
  local description=$1; shift
  local timeout=${1:-60}; shift
  local interval=${1:-2}; shift
  local start_ts
  start_ts=$(date +%s)
  until "$@"; do
    local now
    now=$(date +%s)
    if (( now - start_ts > timeout )); then
      log "Timed out while waiting for ${description}"
      return 1
    fi
    sleep "${interval}"
  done
}

# Helper: wait until galera1 reports wsrep_cluster_status=Primary
wait_for_galera_primary() {
  docker compose exec -T galera1 mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" \
    -e "SHOW STATUS LIKE 'wsrep_cluster_status';" 2>/dev/null | grep -q Primary
}

# Helper: ensure cluster size reaches the expected number of nodes
wait_for_cluster_size() {
  local expected=${1:-3}
  docker compose exec -T galera1 mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -N \
    -e "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='wsrep_cluster_size';" 2>/dev/null | grep -qx "${expected}"
}

# Helper: poll the Passbolt HTTPS endpoint until it responds
wait_for_passbolt() {
  docker compose exec -T passbolt curl -sk https://127.0.0.1/healthcheck/status.json \
    >/dev/null 2>&1
}

BASH_BIN="$(command -v bash)"
if command -v /opt/homebrew/bin/bash >/dev/null 2>&1; then
  BASH_BIN="/opt/homebrew/bin/bash"
fi

# Wrapper around generate-certs.sh so we can call it conditionally
generate_certs() {
  log "Generating TLS certificates"
  yes | "${BASH_BIN}" ./scripts/generate-certs.sh
}

# Run Passbolt health check and bootstrap admin account
run_smoke_tests() {
  if [[ "${SKIP_TESTS}" -eq 1 ]]; then
    log "Skipping smoke tests (--skip-tests)"
    return 0
  fi

  log "Running Passbolt healthcheck"
  docker compose exec -T passbolt su -s /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt healthcheck" www-data

  ADMIN_EMAIL="${PASSBOLT_ADMIN_EMAIL}"
  ADMIN_FIRST="${PASSBOLT_ADMIN_FIRSTNAME}"
  ADMIN_LAST="${PASSBOLT_ADMIN_LASTNAME}"
  ADMIN_ROLE="${PASSBOLT_ADMIN_ROLE}"

  log "Registering initial Passbolt admin (${ADMIN_EMAIL})"
  docker compose exec -T passbolt su -s /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt register_user -u '${ADMIN_EMAIL}' -f '${ADMIN_FIRST}' -l '${ADMIN_LAST}' -r '${ADMIN_ROLE}'" www-data
  cat <<EOF

┌──────────────────────────────────────────────────────────────┐
│ Passbolt admin bootstrap complete                            │
│                                                              │
│  User:      ${ADMIN_EMAIL}                                   │
│  Name:      ${ADMIN_FIRST} ${ADMIN_LAST}                     │
│  Role:      ${ADMIN_ROLE}                                    │
│  Next step: Check your terminal output for the registration  │
│             message containing the setup link.               │
└──────────────────────────────────────────────────────────────┘

EOF
}

# Ensure the core environment variables exist.
# (If any are missing we fail fast so the operator doesn’t get a half-built stack)
require_env MARIADB_ROOT_PASSWORD
require_env MARIADB_DATABASE
require_env MARIADB_USER
require_env MARIADB_PASSWORD
require_env DATASOURCES_DEFAULT_HOST
require_env DATASOURCES_DEFAULT_USERNAME
require_env DATASOURCES_DEFAULT_PASSWORD
require_env DATASOURCES_DEFAULT_DATABASE
require_env PASSBOLT_BASE_URL
require_env PASSBOLT_ADMIN_EMAIL
require_env PASSBOLT_ADMIN_FIRSTNAME
require_env PASSBOLT_ADMIN_LASTNAME
require_env PASSBOLT_ADMIN_ROLE

if [[ "${RESET}" -eq 1 ]]; then
  log "Reset requested: tearing down existing containers and volumes"
  docker compose down -v --remove-orphans || true
fi

if [[ "${FORCE_CERTS}" -eq 1 || ! -f certs/rootCA.crt ]]; then
  generate_certs
fi

log "Starting Galera node 1"
docker compose up -d galera1
wait_for_command "Galera node 1 to reach Primary state" 120 3 wait_for_galera_primary

log "Starting remaining Galera nodes"
docker compose up -d galera2 galera3
wait_for_command "Galera cluster size to reach 3" 180 3 wait_for_cluster_size 3

log "Starting Valkey and Passbolt"
log "Passbolt DB host: ${DATASOURCES_DEFAULT_HOST}"
docker compose up -d valkey passbolt
wait_for_command "Passbolt health endpoint" 120 5 wait_for_passbolt

run_smoke_tests

log "Lab environment is ready."

