#!/usr/bin/env bash
# add-cert.sh — Add (or replace) a Cloudflare Origin Certificate for a domain and wire it into Traefik.
#
# What it does:
#   1. Asks for the domain, the certificate and the private key (paste from the Cloudflare dashboard)
#   2. Validates them with openssl (parseable, key matches cert, SAN covers the domain)
#   3. Writes certs/<domain>.pem (644) and certs/<domain>.key (600)
#   4. Regenerates dynamic/tls.yml from everything in certs/ — Traefik hot-reloads it, no restart
#   5. If Traefik is running: checks the logs and does a real TLS handshake to confirm the new cert is served
#
# Safe to run as many times as you like, for as many domains as you like, while Traefik is running.
# Usage: cd ~/traefik && bash add-cert.sh

set -euo pipefail

info() { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CERTS="$DIR/certs"
TLS_YML="$DIR/dynamic/tls.yml"

[[ -t 0 ]] || die "Run this interactively: bash add-cert.sh"
command -v openssl >/dev/null || die "openssl is required (apt-get install -y openssl)."
mkdir -p "$CERTS" "$DIR/dynamic"

# ---------------------------------------------------------------------------
# Read a PEM block from the terminal: everything from -----BEGIN ...----- to -----END ...-----
read_pem() {
  local what=$1 line started=0 out=""
  echo "Paste the $what (the whole block incl. BEGIN/END lines), then press Enter:" >&2
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ $started -eq 0 ]]; then
      [[ "$line" == -----BEGIN* ]] || continue   # ignore stray lines before the block
      started=1
    fi
    out+="$line"$'\n'
    [[ "$line" == -----END* ]] && break
  done
  [[ $started -eq 1 && "$out" == *-----END* ]] || die "Did not get a complete $what block."
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
info "Domain"
read -rp "Domain (e.g. example.com — the origin cert should cover it and *.it): " DOMAIN
DOMAIN=${DOMAIN,,}
DOMAIN=${DOMAIN#*://}; DOMAIN=${DOMAIN%%/*}
[[ "$DOMAIN" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] || die "That does not look like a domain."

PEM="$CERTS/$DOMAIN.pem"
KEY="$CERTS/$DOMAIN.key"
if [[ -f "$PEM" || -f "$KEY" ]]; then
  warn "A certificate for $DOMAIN already exists."
  read -rp "Replace it? [y/N]: " ans
  [[ "${ans,,}" == "y" ]] || die "Aborted, nothing changed."
fi

# ---------------------------------------------------------------------------
info "Certificate and key"
echo "Cloudflare dashboard → $DOMAIN → SSL/TLS → Origin Server → Create Certificate"
echo "(RSA 2048, hostnames: $DOMAIN and *.$DOMAIN, 15 years)"
echo
CERT_DATA=$(read_pem "Origin Certificate")
echo
KEY_DATA=$(read_pem "Private Key")

# Validate in temp files before touching certs/
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$CERT_DATA" > "$TMP/cert.pem"
printf '%s\n' "$KEY_DATA"  > "$TMP/cert.key"
chmod 600 "$TMP/cert.key"

openssl x509 -in "$TMP/cert.pem" -noout >/dev/null 2>&1 || die "The certificate is not valid PEM."
openssl pkey -in "$TMP/cert.key" -noout >/dev/null 2>&1 || die "The private key is not valid PEM."

CERT_PUB=$(openssl x509 -in "$TMP/cert.pem" -noout -pubkey | openssl sha256)
KEY_PUB=$(openssl pkey -in "$TMP/cert.key" -pubout 2>/dev/null | openssl sha256)
[[ "$CERT_PUB" == "$KEY_PUB" ]] || die "Key does not match the certificate (did you paste the key from a different cert?)."

SANS=$(openssl x509 -in "$TMP/cert.pem" -noout -ext subjectAltName 2>/dev/null | tr -d ' \n' | sed 's/.*subjectAltName://' || true)
if [[ "$SANS" == *"DNS:$DOMAIN"* && "$SANS" == *"DNS:*.$DOMAIN"* ]]; then
  ok "Covers $DOMAIN and *.$DOMAIN"
else
  warn "SANs on this cert: ${SANS:-none}"
  warn "Expected both DNS:$DOMAIN and DNS:*.$DOMAIN — hosts not listed here will get a cert error from Cloudflare (526)."
  read -rp "Continue anyway? [y/N]: " ans
  [[ "${ans,,}" == "y" ]] || die "Aborted, nothing changed."
fi
ISSUER=$(openssl x509 -in "$TMP/cert.pem" -noout -issuer)
[[ "$ISSUER" == *CloudFlare* || "$ISSUER" == *Cloudflare* ]] || warn "Issuer is not Cloudflare ($ISSUER) — fine if intentional."
NOT_AFTER=$(openssl x509 -in "$TMP/cert.pem" -noout -enddate | cut -d= -f2)
ok "Valid until $NOT_AFTER"

# ---------------------------------------------------------------------------
info "Write certs/$DOMAIN.pem and certs/$DOMAIN.key"
install -m 644 "$TMP/cert.pem" "$PEM"
install -m 600 "$TMP/cert.key" "$KEY"
ok "Files written (key is 600)."

# ---------------------------------------------------------------------------
info "Regenerate dynamic/tls.yml"
# Default certificate: keep the current one if it still exists, otherwise use this domain.
DEFAULT=$DOMAIN
if [[ -f "$TLS_YML" ]]; then
  cur=$(grep -A2 'defaultCertificate:' "$TLS_YML" | grep -o 'certs/[^ ]*\.pem' | head -n1 | sed 's#certs/##; s#\.pem$##' || true)
  [[ -n "$cur" && -f "$CERTS/$cur.pem" && -f "$CERTS/$cur.key" ]] && DEFAULT=$cur
fi

DOMAINS=()
for f in "$CERTS"/*.pem; do
  [[ -f "$f" ]] || continue
  d=$(basename "$f" .pem)
  [[ -f "$CERTS/$d.key" ]] || { warn "certs/$d.pem has no matching .key — skipped."; continue; }
  DOMAINS+=("$d")
done

{
  echo "# GENERATED by add-cert.sh from the files in certs/ — do not edit by hand, rerun the script instead."
  echo "# Traefik picks a cert per request by SNI from the list below; defaultCertificate is the fallback."
  echo "# Hot-reloaded by Traefik's file provider; no restart needed."
  echo
  echo "tls:"
  echo "  stores:"
  echo "    default:"
  echo "      defaultCertificate:"
  echo "        certFile: /certs/$DEFAULT.pem"
  echo "        keyFile: /certs/$DEFAULT.key"
  echo
  echo "  certificates:"
  for d in "${DOMAINS[@]}"; do
    echo "    - certFile: /certs/$d.pem   # $d, *.$d"
    echo "      keyFile: /certs/$d.key"
  done
  echo
  echo "  options:"
  echo "    default:"
  echo "      minVersion: VersionTLS12"
} > "$TLS_YML"
ok "tls.yml now lists ${#DOMAINS[@]} domain(s): ${DOMAINS[*]}  (default: $DEFAULT)"

# ---------------------------------------------------------------------------
info "Check Traefik"
if ! command -v docker >/dev/null || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx traefik; then
  warn "Traefik is not running. Start it with:  cd $DIR && docker compose up -d"
  echo "The files are in place; Traefik will load them on start."
  exit 0
fi

sleep 3   # give the file watcher a moment
ERRS=$(docker logs --since 15s traefik 2>&1 | grep -i '"level":"error"' || true)
if [[ -n "$ERRS" ]]; then
  warn "Traefik logged errors after the reload:"
  echo "$ERRS" | tail -n 5
  die "Fix the above (usually a bad cert/key) and rerun."
fi

# Real handshake against the local Traefik with SNI for this domain; compare fingerprints.
WANT=$(openssl x509 -in "$PEM" -noout -fingerprint -sha256 | cut -d= -f2)
GOT=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "check.$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)
if [[ -n "$GOT" && "$GOT" == "$WANT" ]]; then
  ok "Traefik is serving the new certificate for *.$DOMAIN"
else
  warn "Handshake returned a different cert (got: ${GOT:-nothing}). Wait a few seconds and run:"
  echo "    echo | openssl s_client -connect 127.0.0.1:443 -servername check.$DOMAIN 2>/dev/null | openssl x509 -noout -subject -issuer"
  echo "If it is still wrong, the file watcher may have missed it:  docker compose restart traefik"
fi

echo
ok "DONE."
echo "  Cloudflare for $DOMAIN: SSL/TLS → Overview → mode Full (strict); every hostname you route must be Proxied."
echo "  Next: deploy an app with  Host(\`something.$DOMAIN\`)  and a proxied DNS record for it."
