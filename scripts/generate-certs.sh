#!/bin/bash

# -----------------------------------------------------------------------------
# generate-certs.sh
# -----------------------------------------------------------------------------
# Issues a simple test CA and service certificates used by:
#   * Galera nodes (server cert + key + CA)
#   * Passbolt database client certificate
#
# Each certificate includes Subject Alternative Names (SANs) to support multiple
# hostname formats. Galera node certificates include both the short hostname
# (e.g., galera1) and the .local alias (e.g., galera1.local) in the SANs, allowing
# connections to validate using either format.
#
# Certificates are regenerated on demand by start-lab.sh (--force-certs) or can
# be invoked manually. This script is destructive: it wipes the existing certs
# directory before generating new material.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CERTS_DIR="$PROJECT_ROOT/certs"
TMP_DIR="$CERTS_DIR/tmp"

mkdir -p "$CERTS_DIR" "$TMP_DIR"

ROOT_KEY="$CERTS_DIR/rootCA.key"
ROOT_CERT="$CERTS_DIR/rootCA.crt"

if [[ -f "$ROOT_KEY" || -f "$ROOT_CERT" ]]; then
  echo "Root CA material already exists in $CERTS_DIR" >&2
  read -r -p "Regenerate and overwrite? (y/N) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborting." >&2
    exit 1
  fi
fi

rm -f "$CERTS_DIR"/*.key "$CERTS_DIR"/*.crt "$CERTS_DIR"/*.csr "$CERTS_DIR"/*.pem "$CERTS_DIR"/*.srl

echo "Generating root CA"
ROOT_CONFIG="$TMP_DIR/root_openssl.cnf"
cat > "$ROOT_CONFIG" <<'EOF'
[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca
prompt              = no

[ req_distinguished_name ]
C  = AU
ST = Tasmania
L  = Hobart
O  = Passbolt Asia Pacific
OU = Galera Test
CN = Passbolt Galera Root CA

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF

openssl req \
  -x509 -sha256 -days 3650 -nodes \
  -newkey rsa:4096 \
  -keyout "$ROOT_KEY" \
  -out "$ROOT_CERT" \
  -config "$ROOT_CONFIG" \
  -extensions v3_ca

declare -A NODES=(
  [galera1]="galera1.local"
  [galera2]="galera2.local"
  [galera3]="galera3.local"
)

create_cert() {
  local name="$1"
  local cn="$2"
  local key="$CERTS_DIR/${name}.key"
  local csr="$TMP_DIR/${name}.csr"
  local cert="$CERTS_DIR/${name}.crt"
  local config="$TMP_DIR/${name}_openssl.cnf"

  cat > "$config" <<EOF
[ req ]
default_bits        = 4096
distinguished_name  = req_distinguished_name
req_extensions      = v3_req
prompt              = no

[ req_distinguished_name ]
CN = ${cn}
O  = Passbolt Asia Pacific
OU = Galera Test Lab
L  = Hobart
ST = Tasmania
C  = AU

[ alt_names ]
DNS.1 = ${name}
DNS.2 = ${cn}

[ v3_req ]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth, clientAuth
keyUsage = digitalSignature, keyEncipherment
EOF

  echo "Generating private key for ${name}"
  openssl genrsa -out "$key" 4096

  echo "Generating CSR for ${name}"
  openssl req -new -key "$key" -out "$csr" -config "$config"

  echo "Signing certificate for ${name}"
  openssl x509 -req -in "$csr" -CA "$ROOT_CERT" -CAkey "$ROOT_KEY" -CAcreateserial \
    -out "$cert" -days 825 -sha256 -extensions v3_req -extfile "$config"

  cat "$cert" "$ROOT_CERT" > "$CERTS_DIR/${name}-bundle.pem"
}

for node in "${!NODES[@]}"; do
  create_cert "$node" "${NODES[$node]}"
done

echo "Generating Passbolt client certificate"
create_cert "passbolt-db-client" "passbolt-db-client.local"

echo "Cleaning up temporary files"
rm -rf "$TMP_DIR"

echo "All certificates generated in $CERTS_DIR"

