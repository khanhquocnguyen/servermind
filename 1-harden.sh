#!/usr/bin/env bash
# 1-harden.sh — Run ONCE on a freshly installed server (Debian/Ubuntu).
#
# What it does, in order:
#   1. Update the OS + enable automatic security updates
#   2. Create a sudo user + add an SSH key
#   3. Install Tailscale
#   4. Lock down SSH: no root, no passwords, key-only, only the new user
#   5. Firewall: from the internet only 80/443 (Traefik); everything else via Tailscale only
#   6. Lock the root account
#
# Docker is installed afterwards by 2-install-docker.sh.
#
# Usage (must be an interactive SSH session, do NOT pipe via stdin):
#   apt-get install -y tmux && tmux new -s harden    # optional but recommended: survives a dropped connection
#   bash 1-harden.sh
#
# The script pauses 3 times ("CHECK 1/2/3") and asks you to test from your OWN machine
# in a NEW terminal. Keep this root session open until the script prints DONE.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

info() { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
ok()   { echo -e "\033[1;32m[✓] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

confirm_ok() {
  local ans
  while true; do
    read -rp "$1 Type OK to continue (Ctrl+C to abort): " ans
    [[ "$ans" == "OK" ]] && return 0
  done
}

# ---------------------------------------------------------------------------
# Pre-flight checks
[[ $EUID -eq 0 ]] || die "Run as root: bash 1-harden.sh"
[[ -t 0 ]] || die "This script needs an interactive session. Run it directly: bash 1-harden.sh"
command -v apt-get >/dev/null || die "Only Debian/Ubuntu are supported."

read -rp "New username [khanh]: " NEW_USER
NEW_USER=${NEW_USER:-khanh}
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."

echo
echo "Which SSH key on YOUR machine will you use? List them with: ls ~/.ssh/*.pub"
echo "Enter the PRIVATE key filename (without .pub). Press Enter if it is the default id_ed25519."
read -rp "Private key filename [id_ed25519]: " KEY_NAME
KEY_NAME=${KEY_NAME:-id_ed25519}
KEY_NAME=${KEY_NAME%.pub}   # strip .pub if typed by mistake
KEY_NAME=${KEY_NAME##*/}    # strip any path
[[ "$KEY_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid key filename."

# Every check below prints this exact ssh command so you can copy-paste it.
SSH="ssh -i ~/.ssh/$KEY_NAME"

# ---------------------------------------------------------------------------
info "Step 1/6: Update the OS and enable automatic security updates"
apt-get update -q
apt-get upgrade -y -q
apt-get install -y -q curl ufw unattended-upgrades
# Writes /etc/apt/apt.conf.d/20auto-upgrades (by default only installs packages from the security channel)
dpkg-reconfigure -f noninteractive unattended-upgrades
ok "OS updated, unattended-upgrades enabled."

# ---------------------------------------------------------------------------
info "Step 2/6: Create user $NEW_USER, grant sudo, add SSH key"
if id "$NEW_USER" &>/dev/null; then
  warn "User already exists, skipping creation."
else
  echo "This password is your rescue path via the VPS provider's console if networking breaks — make it strong."
  adduser --gecos "" "$NEW_USER"
fi
usermod -aG sudo "$NEW_USER"

echo
echo "On your machine run:   cat ~/.ssh/$KEY_NAME.pub"
echo "Paste the whole line here (it starts with ssh-ed25519 / ssh-rsa / ...):"
read -r PUBKEY
[[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/=]+ ]] \
  || die "Invalid key. Paste the contents of the .pub file, not the private key."

HOME_DIR=$(getent passwd "$NEW_USER" | cut -d: -f6)
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$HOME_DIR/.ssh"
AK="$HOME_DIR/.ssh/authorized_keys"
touch "$AK"
grep -qxF "$PUBKEY" "$AK" || echo "$PUBKEY" >> "$AK"
chown "$NEW_USER:$NEW_USER" "$AK"
chmod 600 "$AK"
ok "User and key are ready."

# ---------------------------------------------------------------------------
info "Step 3/6: Install Tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
tailscale status &>/dev/null || tailscale up
TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
[[ -n "$TS_IP" ]] || die "Could not get a Tailscale IP."
ok "Tailscale IP: $TS_IP"

echo
warn "CHECK 1 — can you log in with your KEY and use sudo?"
echo "  Keep this session open. On YOUR machine, open a NEW terminal and run:"
echo
echo "    $SSH -o StrictHostKeyChecking=accept-new -o BatchMode=yes $NEW_USER@$TS_IP"
echo "    sudo whoami        # asks for the password you set above, must print: root"
echo "    exit"
echo
echo "  (BatchMode makes ssh fail instead of falling back to a password, so a wrong key shows up now, not later.)"
echo "  If you get 'Permission denied': compare  cat ~/.ssh/$KEY_NAME.pub  on your machine"
echo "  with  cat $AK  here. Fix the file here if they differ, then retry — no need to restart the script."
confirm_ok "Logged in with the key AND 'sudo whoami' printed root?"

# ---------------------------------------------------------------------------
info "Step 4/6: Lock down SSH"
SSHD_MAIN=/etc/ssh/sshd_config
SSHD_BAK="$SSHD_MAIN.bak.$(date +%Y%m%d%H%M%S)"
CONF=/etc/ssh/sshd_config.d/00-hardening.conf   # 00- so cloud-init's file cannot override it
cp -a "$SSHD_MAIN" "$SSHD_BAK"

rollback_ssh() { rm -f "$CONF"; cp -a "$SSHD_BAK" "$SSHD_MAIN"; }

mkdir -p /etc/ssh/sshd_config.d /run/sshd
if ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_MAIN"
  sshd -t || { rollback_ssh; die "OpenSSH is too old (no Include support). Rolled back."; }
fi

cat > "$CONF" <<EOF
# Generated by 1-harden.sh — to allow another SSH user, edit the AllowUsers line
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $NEW_USER
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
# (AllowTcpForwarding is left at its default so `ssh -L` tunnels to DB/services over Tailscale still work)

# Older OpenSSH uses the name ChallengeResponseAuthentication
sshd -t 2>/dev/null || sed -i 's/^KbdInteractiveAuthentication/ChallengeResponseAuthentication/' "$CONF"
sshd -t || { rollback_ssh; die "SSH config is invalid. Rolled back."; }

systemctl reload ssh 2>/dev/null || systemctl reload sshd

EFFECTIVE=$(sshd -T 2>/dev/null)
for pair in "permitrootlogin no" "passwordauthentication no" "authenticationmethods publickey" "allowusers $NEW_USER"; do
  grep -qi "^$pair$" <<<"$EFFECTIVE" || die "'$pair' is not in effect. Inspect with: sshd -T"
done
ok "SSH locked down (previous config backed up to $SSHD_BAK)."

echo
warn "CHECK 2 — does login still work after locking SSH?"
echo "  On YOUR machine, in a NEW terminal:"
echo
echo "    $SSH $NEW_USER@$TS_IP"
echo "    exit"
echo
confirm_ok "Still able to log in?"

# ---------------------------------------------------------------------------
info "Step 5/6: Firewall — internet reaches only 80/443, everything else via Tailscale only"
# The current SSH session is not cut: ufw always allows ESTABLISHED connections.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'everything over Tailscale'
ufw allow 41641/udp comment 'Tailscale direct connections (WireGuard)'
ufw allow 80/tcp  comment 'web (Traefik)'
ufw allow 443/tcp comment 'web (Traefik)'
ufw --force enable
ufw status verbose

PUB_IP=$(curl -fsS -4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "<PUBLIC_IP_OF_VPS>")
echo
warn "CHECK 3 — Tailscale must work, the public IP must be blocked."
echo "  Run both tests from YOUR machine, one after the other. Test 1 logs you in — type 'exit' to"
echo "  get back to your machine BEFORE running test 2 (running it from inside the server is not a real test)."
echo
echo "  Test 1 — must SUCCEED:"
echo "    $SSH $NEW_USER@$TS_IP"
echo "    exit"
echo
echo "  Test 2 — must FAIL after ~5s with 'Operation timed out' or 'Connection refused':"
echo "    $SSH -o ConnectTimeout=5 $NEW_USER@$PUB_IP"
echo
confirm_ok "Test 1 logged in AND test 2 timed out / was refused?"

# ---------------------------------------------------------------------------
info "Step 6/6: Lock the root account"
passwd -l root
[[ -f /root/.ssh/authorized_keys ]] && mv /root/.ssh/authorized_keys /root/.ssh/authorized_keys.disabled

# ---------------------------------------------------------------------------
echo
ok "DONE."
echo
warn "DO THIS NOW: Tailscale admin console -> Machines -> $(hostname) -> Disable key expiry."
echo "  Node keys expire after 180 days by default. SSH is reachable ONLY over Tailscale, so an expired"
echo "  key means no SSH until you log in through the VPS provider's console and run 'tailscale up' again."
echo
echo "  Log in:            $SSH $NEW_USER@$TS_IP"
echo "  Become root:       sudo -i"
echo "  Public ports:      80/443 open for Traefik; everything else is Tailscale-only"
echo "  Add an SSH user:   edit AllowUsers in $CONF, then: sudo systemctl reload ssh"
echo
echo "  To log in with just 'ssh $NEW_USER@$TS_IP', add this to ~/.ssh/config on your machine:"
echo
echo "    Host $TS_IP"
echo "        User $NEW_USER"
echo "        IdentityFile ~/.ssh/$KEY_NAME"
echo "        IdentitiesOnly yes"
echo
if [[ -f /var/run/reboot-required ]]; then
  warn "The kernel was updated — reboot recommended: sudo reboot — then ssh back in over Tailscale to confirm everything comes up."
fi
