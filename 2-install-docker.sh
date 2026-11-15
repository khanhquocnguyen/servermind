#!/usr/bin/env bash
# 2-install-docker.sh — Run ONCE after 1-harden.sh. Installs Docker Engine + Compose from Docker's official repo.
#
# What it does, in order:
#   1. Add Docker's official apt repository (removes distro packages like docker.io if present)
#   2. Install Docker Engine, CLI, containerd, buildx and the compose plugin
#   3. Configure the daemon: published ports bind to localhost by default, log rotation, live-restore
#   4. Let your user run docker without sudo + create the shared "traefik-proxy-network" for Traefik
#
# Usage — as your normal user (NOT root), so that user is added to the docker group:
#   sudo bash 2-install-docker.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PROXY_NET=traefik-proxy-network

info() { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash 2-install-docker.sh"
command -v apt-get >/dev/null || die "Only Debian/Ubuntu are supported."

TARGET_USER=${SUDO_USER:-}
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] \
  || die "Run as your normal user via sudo (sudo bash 2-install-docker.sh), not as root, so that user gets docker access."

. /etc/os-release
case "$ID" in
  debian|ubuntu) ;;
  *) die "Unsupported distro: $ID (only debian/ubuntu)." ;;
esac
[[ -n "${VERSION_CODENAME:-}" ]] || die "Cannot detect the release codename from /etc/os-release."

# ---------------------------------------------------------------------------
info "Step 1/4: Add Docker's official apt repository"
# Distro-packaged Docker is old and conflicts with docker-ce; remove it if present.
apt-get remove -y -q docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
apt-get update -q
apt-get install -y -q ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
ok "Repository added."

# ---------------------------------------------------------------------------
info "Step 2/4: Install Docker Engine + Compose plugin"
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
ok "Installed: $(docker --version)"

# ---------------------------------------------------------------------------
info "Step 3/4: Configure the daemon"
# "ip": "127.0.0.1"
#   Docker writes its own iptables rules and BYPASSES ufw, so a plain `-p 5432:5432` would expose the
#   container to the whole internet. With this setting, published ports bind to localhost unless you
#   say otherwise. To expose on purpose, be explicit in compose:
#     - "0.0.0.0:80:80"            # public (Traefik)
#     - "100.x.y.z:5432:5432"      # Tailscale-only (use the server's Tailscale IP)
# log-opts: rotate container logs so a chatty container cannot fill the disk.
# live-restore: containers keep running while dockerd restarts (e.g. during updates).
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  warn "Existing daemon.json backed up and replaced."
fi
cat > /etc/docker/daemon.json <<'EOF'
{
  "ip": "127.0.0.1",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl enable --now docker >/dev/null
systemctl restart docker
ok "Daemon configured and running."

# ---------------------------------------------------------------------------
info "Step 4/4: Give $TARGET_USER docker access + create the shared network"
usermod -aG docker "$TARGET_USER"
# Each `docker compose up` gets its own private network, so Traefik cannot see containers from other
# projects by default. This one network is created outside compose; Traefik and every app join it,
# so Traefik can reach them by container name (http://myapp:3000).
docker network inspect "$PROXY_NET" >/dev/null 2>&1 || docker network create "$PROXY_NET" >/dev/null
ok "User $TARGET_USER added to the docker group; network '$PROXY_NET' ready."

# ---------------------------------------------------------------------------
info "Verify"
docker run --rm hello-world >/dev/null && ok "docker run works"
docker compose version

echo
ok "DONE."
echo "  Log out and back in once so '$TARGET_USER' can run docker without sudo (group change needs a new login)."
echo "  Then test:          docker ps"
echo "  Publishing ports:   default binds to 127.0.0.1 only. Traefik must use \"0.0.0.0:80:80\" and \"0.0.0.0:443:443\"."
echo "  Tailscale-only:     \"$(tailscale ip -4 2>/dev/null | head -n1 || echo '<TAILSCALE_IP>'):5432:5432\""
echo
echo "  Shared network '$PROXY_NET' — add this to Traefik AND to every app's compose file:"
echo
echo "    services:"
echo "      myapp:"
echo "        networks: [$PROXY_NET]"
echo "    networks:"
echo "      $PROXY_NET:"
echo "        external: true"
