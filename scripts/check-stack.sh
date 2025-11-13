#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# check-stack.sh
# -----------------------------------------------------------------------------
# Convenience script to verify the Galera + Passbolt stack:
#   * loads the same environment variables as start-lab.sh
#   * checks cluster size and wsrep state
#   * runs the Passbolt CLI healthcheck
# -----------------------------------------------------------------------------

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

ENV_FILE="${PROJECT_ROOT}/.env"
GLOBAL_ENV="/etc/environment"
if [[ -f "${GLOBAL_ENV}" ]]; then
  set -a
  # shellcheck disable=SC1091 -- intentional: load system-level environment if present
  source "${GLOBAL_ENV}"
  set +a
fi
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090 -- intentional: load user-provided .env at runtime
  source "${ENV_FILE}"
  set +a
fi

log() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

require_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "Environment variable ${name} is required but not set." >&2
    exit 1
  fi
}

require_env DATASOURCES_DEFAULT_USERNAME
require_env DATASOURCES_DEFAULT_PASSWORD
require_env DATASOURCES_DEFAULT_DATABASE
require_env MARIADB_ROOT_PASSWORD

log "Checking Galera cluster size"
docker compose exec -T galera1 mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"

log "Checking Galera replication health"
docker compose exec -T galera1 mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" \
  -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

log "Running Passbolt healthcheck"
docker compose exec -T passbolt su -s /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt healthcheck" www-data

