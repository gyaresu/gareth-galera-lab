#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# generate-demo-gpg.sh
# -----------------------------------------------------------------------------
# Convenience helper to create a GPG key pair for the demo admin user.
# - Loads /etc/environment and .env so it can reuse PASSBOLT_ADMIN_* values
# - Defaults to using the admin email as the passphrase (unless overridden via
#   PASSBOLT_ADMIN_GPG_PASSPHRASE or explicit CLI arguments)
# - Writes key material to keys/gpg/
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/keys/gpg"
ENV_FILE="${PROJECT_ROOT}/.env"

mkdir -p "${OUTPUT_DIR}"

if ! command -v gpg >/dev/null 2>&1; then
  echo "Error: gpg is not installed or not in PATH." >&2
  exit 1
fi

declare -A DEFAULT_USER=()

load_env() {
  local file="$1"
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
  fi
}

if [[ -f /etc/environment ]]; then
  load_env /etc/environment
fi

if [[ -f "$ENV_FILE" ]]; then
  load_env "$ENV_FILE"
fi

if [[ -n "${PASSBOLT_ADMIN_EMAIL:-}" ]]; then
  DEFAULT_USER[email]="${PASSBOLT_ADMIN_EMAIL}"
  DEFAULT_USER[name]="${PASSBOLT_ADMIN_FIRSTNAME:-Admin} ${PASSBOLT_ADMIN_LASTNAME:-User}"
  DEFAULT_USER[passphrase]="${PASSBOLT_ADMIN_GPG_PASSPHRASE:-${PASSBOLT_ADMIN_EMAIL}}"
fi

USERS=("$@")

if [ "${#USERS[@]}" -eq 0 ]; then
  if [[ ${#DEFAULT_USER[@]} -gt 0 ]]; then
    USERS=("${DEFAULT_USER[email]}:${DEFAULT_USER[name]}:${DEFAULT_USER[passphrase]}")
  else
    USERS=("ada@passbolt.com:Ada passbolt:ada@passbolt.com")
  fi
fi

generate_key() {
  local entry="$1"
  IFS=':' read -r email name passphrase <<< "$entry"

  if [[ -z "${email}" || -z "${name}" ]]; then
    echo "Skipping invalid entry: ${entry}" >&2
    return
  fi

  if [[ -z "${passphrase}" ]]; then
    passphrase="${email}"
  fi

  local safe_email="${email//[@.]/_}"
  local key_file="${OUTPUT_DIR}/${email}.key"
  local pub_file="${OUTPUT_DIR}/${email}.pub"

  if [ -f "${key_file}" ] || [ -f "${pub_file}" ]; then
    echo "GPG material already exists for ${email}, skipping."
    return
  fi

  echo "Generating GPG key for ${name} (${email})"

  local batch_file
  batch_file="$(mktemp "/tmp/gpg_batch_${safe_email}.XXXXXX")"
  cat > "${batch_file}" <<EOF
%echo Generating ECC key for ${name}
Key-Type: EDDSA
Key-Curve: Ed25519
Subkey-Type: ECDH
Subkey-Curve: Curve25519
Name-Real: ${name}
Name-Email: ${email}
Expire-Date: 0
Passphrase: ${passphrase}
%commit
%echo Created key for ${name}
EOF

  local temp_home
  temp_home="$(mktemp -d "/tmp/gpg_${safe_email}.XXXXXX")"
  chmod 700 "${temp_home}"

  GNUPGHOME="${temp_home}" gpg --batch --generate-key "${batch_file}"
  GNUPGHOME="${temp_home}" gpg --batch --yes --pinentry-mode loopback --passphrase "${passphrase}" \
    --armor --export-secret-keys "${email}" > "${key_file}"
  GNUPGHOME="${temp_home}" gpg --batch --yes --armor --export "${email}" > "${pub_file}"

  rm -rf "${temp_home}" "${batch_file}"

  echo "  Private key: ${key_file}"
  echo "  Public key : ${pub_file}"
  echo "  Passphrase : ${passphrase}"
  echo ""
}

for user in "${USERS[@]}"; do
  generate_key "${user}"
done

echo "Key generation complete. Keys stored in ${OUTPUT_DIR}"

