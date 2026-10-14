#!/bin/sh
# Idempotent OpenBao setup for Siegel (SEC-05). Needs BAO_ADDR and an admin BAO_TOKEN.
# Creates non-exportable transit keys and the least-privilege policy the API server runs with.
set -eu
bao secrets list | grep -q '^transit/' || bao secrets enable transit
bao read transit/keys/siegel-phone >/dev/null 2>&1 || bao write -f transit/keys/siegel-phone type=hmac key_size=32
bao read transit/keys/siegel-as >/dev/null 2>&1 || bao write -f transit/keys/siegel-as type=ed25519
bao policy write siegel-server - <<'POLICY'
path "transit/hmac/siegel-phone/*" { capabilities = ["update"] }
path "transit/sign/siegel-as"      { capabilities = ["update"] }
path "transit/keys/siegel-as"      { capabilities = ["read"] }
POLICY
echo "openbao ready"
