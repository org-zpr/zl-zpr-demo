#!/usr/bin/env bash
# Regenerate every key and cert in ../zpr-conf/include/ from scratch.
#
#   ZPR_ROOT=/path/to/repos [ZPR_REPO_PREFIX=zl-] tools/regen-pki.sh
#
# X25519 link (noise) material comes from zpr-visaservice's tools/zpr-pki
# (RFC 8410 X.509). The admin TLS cert is deliberately NOT zpr-pki: it must
# carry subjectAltName = DNS:vs.zpr, IP:fd5a:5052::1 (Go's verifier ignores CN,
# and the I1 CoreDNS plugin pins this CA with no insecure fallback), and
# zpr-pki gensignedcert cannot emit a SAN — so it is a plain openssl
# self-signed RSA cert.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INC_DIR="$(cd "$SCRIPT_DIR/../zpr-conf" && pwd)/include"

: "${ZPR_ROOT:?ZPR_ROOT must point to the directory containing the ZPR repositories}"
ZPR_REPO_PREFIX="${ZPR_REPO_PREFIX:-}"
PKI="$ZPR_ROOT/${ZPR_REPO_PREFIX}zpr-visaservice/tools/zpr-pki"
[ -x "$PKI" ] || { echo "ERROR: zpr-pki not found/executable at $PKI" >&2; exit 1; }

DAYS=3650
mkdir -p "$INC_DIR"
cd "$INC_DIR"

# --- micro-CA ---
"$PKI" gencakey > auth-ca.key
"$PKI" gencacert /CN=auth.demo "$DAYS" < auth-ca.key > auth-ca.crt

# authpair NAME -- RSA-2048 identity keypair (bootstrap/auth key). Deliberately
# NOT zpr-pki genkey: zplc loads bootstrap keys with load_rsa_public_key
# (zpr-compiler src/crypto.rs), so these must be RSA, exactly like
# multinode-demo's. zpr-pki stays the tool for everything X25519 (noise).
authpair() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$1-private-key.pem" 2>/dev/null
  openssl pkey -in "$1-private-key.pem" -pubout -out "$1-public-key.pem"
}

# noisepair NAME CN -- a Zode's X25519 link keypair + its CA-signed cert
# (`ph zode --private-key-file` / `--certificate-file`). The cert's CN is the
# Zode's name: the policy's [nodes.*] provider and [bootstrap] key.
noisepair() {
  "$PKI" genkey > "$1-noise.key"
  "$PKI" pubkey < "$1-noise.key" \
    | "$PKI" gensignedcert auth-ca.crt auth-ca.key "/CN=$2" "$DAYS" > "$1-noise.crt"
}

# One auth keypair and one link keypair per Zode. The visa service needs
# neither: it runs on the relay's TUN and authenticates by construction
# (zl-zpr-dev-context docs/ZODE_LINKS.md, "The relay hosts the visa service").
authpair node  # node.demo, the relay
authpair web   # web.demo
authpair dns   # dns.demo
authpair alice # alice, the client

noisepair node node.demo
noisepair web web.demo
noisepair dns dns.demo
noisepair alice alice

# --- admin TLS cert (RSA, self-signed, SAN required — see header) ---
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
  -subj "/C=US/ST=KY/L=Louisville/O=ZPR/OU=ZPRnet/CN=vs.zpr" \
  -addext "subjectAltName=DNS:vs.zpr,IP:fd5a:5052::1" \
  -keyout admin-tls-key.pem -out admin-tls-cert.pem 2>/dev/null

echo "regenerated PKI in $INC_DIR:"
ls -1 "$INC_DIR"
