#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/root/install.txt"
exec &> >(tee -a "$LOG_FILE")

log()       { echo "[INFO]  $(date '+%F %T') - $*"; }
error_log() { echo "[ERROR] $(date '+%F %T') - $*" >&2; }
die()       { error_log "$*"; exit 1; }

# =============================================================================
# CONFIG (Original + New)
# =============================================================================

# === ADDED: Output target (which platform to build/deploy to) ==================
#   proxmox     -> build ISO, install template on Proxmox, then clone N VMs
#   aws         -> launch an EC2 instance (Amazon Linux 2023) with bootstrap
#   firecracker -> build a Debian rootfs + Firecracker config/run script
TARGET="${TARGET:-proxmox}"

# ------------------------------------------------------------------------------
# Base installer/ISO inputs (used by Proxmox target)
# ------------------------------------------------------------------------------
# Path to the Debian installer ISO to customize. Netinst or DVD both OK.
# You can override via env: ISO_ORIG=/path/to/iso.iso
# Example: /root/debian-13.0.0-amd64-DVD-1.iso
ISO_ORIG="${ISO_ORIG:-/root/debian-13.0.0-amd64-DVD-1.iso}"

# Working directories for ISO customization and darksite payload.
BUILD_DIR="/root/build"                 # scratch workspace (will be wiped each run)
CUSTOM_DIR="$BUILD_DIR/custom"          # ISO files copied here for edits
MOUNT_DIR="/mnt/build"                  # temporary mount point for original ISO
DARKSITE_DIR="$CUSTOM_DIR/darksite"     # payload injected into ISO or rootfs
PRESEED_FILE="preseed.cfg"              # Debian preseed filename inside ISO
OUTPUT_ISO="$BUILD_DIR/base.iso"        # intermediate ISO path
FINAL_ISO="/root/clone.iso"             # final ISO uploaded to Proxmox

# ------------------------------------------------------------------------------
# Cluster target (Proxmox-only identifiers)
# ------------------------------------------------------------------------------
# Which Proxmox host to target by a simple selector:
#   1|fiend, 2|dragon, 3|lion  (maps to fixed IPs below)
INPUT="${INPUT:-1}"

# Proxmox VMID for the base template VM to create from the ISO.
VMID="${VMID:-1002}"

# Short base name for the VM/template (domain appended to form FQDN).
# Must be DNS-safe (letters/digits/dashes) — script normalizes it.
VMNAME="${VMNAME:-test}"

# ------------------------------------------------------------------------------
# Domain and naming
# ------------------------------------------------------------------------------
# DNS domain appended to VMNAME (e.g., "test.unixbox.net").
DOMAIN="${DOMAIN:-unixbox.net}"

# ------------------------------------------------------------------------------
# Storage choices (Proxmox)
# ------------------------------------------------------------------------------
# VM_STORAGE: Proxmox storage backend for VM disks.
#   Examples: "void" (Ceph RBD), "local-zfs" (ZFS), "fireball" (custom).
VM_STORAGE="${VM_STORAGE:-void}"

# ISO_STORAGE: Proxmox directory-like storage for ISOs.
#   Typically "local" on the Proxmox node.
ISO_STORAGE="${ISO_STORAGE:-local}"

# ------------------------------------------------------------------------------
# Base VM resources (Proxmox template) — used to install the template
# ------------------------------------------------------------------------------
DISK_SIZE_GB="${DISK_SIZE_GB:-32}"      # Disk size (GB) for template root disk
MEMORY_MB="${MEMORY_MB:-4096}"          # RAM for template install (MB)
CORES="${CORES:-4}"                     # vCPU count for template install

# ------------------------------------------------------------------------------
# Installer networking for the template (Proxmox base VM)
# ------------------------------------------------------------------------------
# NETWORK_MODE: "static" or "dhcp" for the installer environment.
NETWORK_MODE="${NETWORK_MODE:-static}"
STATIC_IP="${STATIC_IP:-10.100.10.111}" # Used if NETWORK_MODE=static
NETMASK="${NETMASK:-255.255.255.0}"     # Netmask for static config
GATEWAY="${GATEWAY:-10.100.10.1}"       # Default gateway for static config
# Space-separated list of DNS resolvers for the installer
NAMESERVER="${NAMESERVER:-10.100.10.2 10.100.10.3 1.1.1.1 8.8.8.8}"

# ------------------------------------------------------------------------------
# Cloud-Init and VLAN for clones (Proxmox)
# ------------------------------------------------------------------------------
# USE_CLOUD_INIT: if true, clones get a cloud-init disk and ipconfig set.
USE_CLOUD_INIT="${USE_CLOUD_INIT:-true}"

# Optional VLAN tag for the clone NIC (empty = no VLAN tag).
CLONE_VLAN_ID="${CLONE_VLAN_ID:-}"

# ------------------------------------------------------------------------------
# Clone fanout plan (Proxmox) — how many clones and their base IDs/IPs
# ------------------------------------------------------------------------------
NUM_CLONES="${NUM_CLONES:-3}"           # Number of clones to create from template
BASE_CLONE_VMID="${BASE_CLONE_VMID:-3000}" # First VMID to use for clones (increments)
BASE_CLONE_IP="${BASE_CLONE_IP:-$STATIC_IP}" # Starting IP for clones (last octet increments)
CLONE_MEMORY_MB="${CLONE_MEMORY_MB:-4096}"   # RAM per clone (MB)
CLONE_CORES="${CLONE_CORES:-4}"              # vCPU per clone

# ------------------------------------------------------------------------------
# Optional extra data disks per clone (Proxmox)
# ------------------------------------------------------------------------------
EXTRA_DISK_COUNT="${EXTRA_DISK_COUNT:-0}"     # Number of extra disks to attach to each clone
EXTRA_DISK_SIZE_GB="${EXTRA_DISK_SIZE_GB:-10}"# Size per extra disk (GB)
EXTRA_DISK_TARGET="${EXTRA_DISK_TARGET:-}"    # Storage (e.g., "local-zfs"); empty = skip

# ------------------------------------------------------------------------------
# Desktop selection (for Debian install) — only if not "server"
# ------------------------------------------------------------------------------
# Valid: server | gnome-min | gnome-full | xfce-min | kde-min
INSTALL_PROFILE="${INSTALL_PROFILE:-server}"

# ------------------------------------------------------------------------------
# Extra scripts to include in darksite payload (copied to /usr/local/bin)
# ------------------------------------------------------------------------------
SCRIPTS_DIR="${SCRIPTS_DIR:-/root/custom-scripts}"

# === ADDED: Darksite bootstrap (WireGuard + Salt) — used by all targets =======
# Enable/disable WireGuard bootstrap in guest (if variables are provided).
WG_ENABLE="${WG_ENABLE:-true}"

# WireGuard interface name inside guest (usually wg0).
WG_INTERFACE="${WG_INTERFACE:-wg0}"

# Private key for the guest peer. If empty, it will be generated in-place.
WG_PRIVATE_KEY="${WG_PRIVATE_KEY:-}"

# The *remote* peer’s public key (e.g., your hub/exit peer). Optional but
# needed if you want the guest to connect on first boot.
WG_PUBLIC_KEY_PEER="${WG_PUBLIC_KEY_PEER:-}"

# Remote endpoint "host:port" (e.g., vpn.example.com:51820). Required to dial out.
WG_PEER_ENDPOINT="${WG_PEER_ENDPOINT:-}"

# AllowedIPs for the peer (what to route via WG). Common: "0.0.0.0/0" or site subnets.
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"

# Address assigned to the guest WireGuard interface.
WG_ADDRESS="${WG_ADDRESS:-10.42.0.2/32}"

# DNS resolver(s) to push into WireGuard interface (optional).
WG_DNS="${WG_DNS:-1.1.1.1}"

# Salt Minion bootstrap toggle. If true, salt-minion is installed+enabled.
SALT_ENABLE="${SALT_ENABLE:-true}"

# Salt Master hostname or IP the minion should connect to.
SALT_MASTER="${SALT_MASTER:-salt.unixbox.net}"

# Optional explicit minion ID (defaults to FQDN if empty).
SALT_MINION_ID="${SALT_MINION_ID:-}"

# === ADDED: AWS knobs (only read when TARGET=aws) ==============================
AWS_REGION="${AWS_REGION:-ca-central-1}"         # Region to deploy into
AWS_PROFILE="${AWS_PROFILE:-}"                   # Optional named profile
AWS_INSTANCE_NAME="${AWS_INSTANCE_NAME:-multi-target-micro}"  # EC2 Name tag
AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-t2.micro}"            # Instance type
AWS_ARCH="${AWS_ARCH:-x86_64}"                   # x86_64 | arm64 (affects AMI param path)
AWS_OS_IMAGE="${AWS_OS_IMAGE:-al2023}"           # Amazon Linux 2023 (supported here)
AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"               # Optional; default VPC’s first subnet if empty
AWS_ASSOC_PUBLIC_IP="${AWS_ASSOC_PUBLIC_IP:-auto}" # auto|true|false for public IP association
AWS_SG_NAME="${AWS_SG_NAME:-${AWS_INSTANCE_NAME}-sg}"         # Security group to create/use
AWS_ENABLE_SSH="${AWS_ENABLE_SSH:-true}"         # Open tcp/22 from your /32
AWS_OPEN_HTTP="${AWS_OPEN_HTTP:-false}"          # Also open tcp/80 (from your /32)
AWS_OPEN_HTTPS="${AWS_OPEN_HTTPS:-false}"        # Also open tcp/443 (from your /32)
AWS_SSH_CIDR="${AWS_SSH_CIDR:-}"                 # Override detected /32 (e.g., "203.0.113.7/32")
AWS_KEY_NAME="${AWS_KEY_NAME:-${AWS_INSTANCE_NAME}-key}"      # EC2 key pair name
AWS_PUBLIC_KEY_PATH="${AWS_PUBLIC_KEY_PATH:-}"   # If set, import this public key
AWS_SAVE_PEM="${AWS_SAVE_PEM:-${AWS_KEY_NAME}.pem}" # If creating a new key pair, save PEM here
AWS_SSH_USER="${AWS_SSH_USER:-ec2-user}"         # Default SSH user for AL2023
AWS_AUTO_SSH="${AWS_AUTO_SSH:-false}"            # Auto SSH after boot (if public IP present)
AWS_EXTRA_TAGS="${AWS_EXTRA_TAGS:-Owner=ops,Env=dev}" # Comma list "K=V,K=V" extra tags
AWS_KMS_KEY_ID="${AWS_KMS_KEY_ID:-}"             # Optional CMK for EBS encryption (else default)

# === ADDED: Firecracker knobs (only read when TARGET=firecracker) =============
# Directory used to assemble the rootfs tree before packing (if needed).
FC_ROOTFS_DIR="${FC_ROOTFS_DIR:-$BUILD_DIR/fcroot}"

# Output path for the ext4 root filesystem image.
FC_IMG="${FC_IMG:-$BUILD_DIR/rootfs.ext4}"

# Size of the rootfs image in MB (2048 = 2GB).
FC_IMG_SIZE_MB="${FC_IMG_SIZE_MB:-2048}"

# Kernel package to install into the rootfs (when building a Debian userland).
FC_KERNEL_PKG="${FC_KERNEL_PKG:-linux-image-amd64}"

# Path to a host kernel image compatible with Firecracker (uncompressed vmlinux preferred).
# You can copy/convert your kernel to this path before running, or leave default if valid.
FC_VMLINUX_PATH="${FC_VMLINUX_PATH:-/boot/vmlinux-$(uname -r)}"

# Where to copy/write the kernel image that Firecracker will actually use.
FC_OUTPUT_VMLINUX="${FC_OUTPUT_VMLINUX:-$BUILD_DIR/vmlinux}"

# Generated run helper script to start Firecracker with the produced config.
FC_RUN_SCRIPT="${FC_RUN_SCRIPT:-$BUILD_DIR/run-fc.sh}"

# Generated Firecracker configuration JSON (machine, net, drives, boot).
FC_CONFIG_JSON="${FC_CONFIG_JSON:-$BUILD_DIR/fc.json}"

# Host TAP interface to bridge host<->guest networking for Firecracker.
FC_TAP_IF="${FC_TAP_IF:-fc-tap0}"

# Guest IP (CIDR) configured via kernel boot args or init; same /24 as host gateway.
FC_GUEST_IP="${FC_GUEST_IP:-172.20.0.2/24}"

# Host-side gateway IP on the TAP interface (no CIDR suffix here).
FC_GW_IP="${FC_GW_IP:-172.20.0.1}"

# =============================================================================
# Compute / Validate basics (Original)
# =============================================================================

# Normalize VMNAME to lowercase, dash-only; fail if it contains invalid chars.
VMNAME_CLEAN="${VMNAME//[_\.]/-}"
VMNAME_CLEAN="$(echo "$VMNAME_CLEAN" | sed 's/^-*//;s/-*$//;s/--*/-/g' | tr '[:upper:]' '[:lower:]')"
[[ "$VMNAME_CLEAN" =~ ^[a-z0-9-]+$ ]] || die "Invalid VM name after cleanup: '$VMNAME_CLEAN'"
VMNAME="$VMNAME_CLEAN"

# Map INPUT selector to a specific Proxmox host & address (Proxmox-only).
case "$INPUT" in
  1|fiend)  HOST_NAME="fiend.${DOMAIN}";  PROXMOX_HOST="10.100.10.225" ;;
  2|dragon) HOST_NAME="dragon.${DOMAIN}"; PROXMOX_HOST="10.100.10.226" ;;
  3|lion)   HOST_NAME="lion.${DOMAIN}";   PROXMOX_HOST="10.100.10.227" ;;
  *)        die "Unknown host: $INPUT" ;;
esac

# Canonical FQDN and template name used for the base VM in Proxmox.
BASE_FQDN="${VMNAME}.${DOMAIN}"
BASE_VMNAME="${BASE_FQDN}-template"

log "Target=$TARGET  PMX: $HOST_NAME ($PROXMOX_HOST)  VMID=$VMID  VMNAME=$BASE_VMNAME"
log "Storages: VM_STORAGE=$VM_STORAGE  ISO_STORAGE=$ISO_STORAGE  Disk=${DISK_SIZE_GB}G"
log "Network: $NETWORK_MODE  DOMAIN=$DOMAIN  Cloud-Init: $USE_CLOUD_INIT  Profile: $INSTALL_PROFILE"

# =============================================================================
# Helpers (ADDED)
# =============================================================================
aws_cli() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}

require_tools() {
  command -v xorriso >/dev/null || die "xorriso missing."
  if [[ "$TARGET" == "aws" ]]; then
    command -v aws >/dev/null || die "aws CLI missing."
  fi
  if [[ "$TARGET" == "firecracker" ]]; then
    command -v debootstrap >/dev/null || die "debootstrap missing."
    command -v fallocate >/dev/null  || die "fallocate missing."
    command -v mkfs.ext4 >/dev/null  || die "mkfs.ext4 missing."
  fi
}

# =============================================================================
# Build ISO payload (Original, with darksite bootstrap additions)
# =============================================================================

log "Cleaning build dir..."
umount "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$CUSTOM_DIR" "$MOUNT_DIR" "$DARKSITE_DIR"

log "Mount ISO..."
mount -o loop "$ISO_ORIG" "$MOUNT_DIR"

log "Copy ISO contents..."
cp -a "$MOUNT_DIR/"* "$CUSTOM_DIR/"
cp -a "$MOUNT_DIR/.disk" "$CUSTOM_DIR/"
umount "$MOUNT_DIR"

log "Stage custom scripts..."
mkdir -p "$DARKSITE_DIR/scripts"
if [[ -d "$SCRIPTS_DIR" ]] && compgen -G "$SCRIPTS_DIR/*" >/dev/null; then
  rsync -a "$SCRIPTS_DIR"/ "$DARKSITE_DIR/scripts"/
  log "Added scripts from $SCRIPTS_DIR"
else
  log "No scripts at $SCRIPTS_DIR; skipping."
fi

# -----------------------------------------------------------------------------
# === ADDED: Darksite bootstrap: WireGuard + Salt reusable scripts
# -----------------------------------------------------------------------------
log "Writing darksite bootstrap scripts (wireguard & salt)..."
cat > "$DARKSITE_DIR/scripts/setup_wireguard.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[WG] $(date '+%F %T') - $*"; }

WG_IF="${WG_INTERFACE:-wg0}"
WG_ADDR="${WG_ADDRESS:-10.42.0.2/32}"
WG_DNS="${WG_DNS:-1.1.1.1}"
WG_PRIV="${WG_PRIVATE_KEY:-}"
WG_PEER_PUB="${WG_PUBLIC_KEY_PEER:-}"
WG_PEER_ENDPOINT="${WG_PEER_ENDPOINT:-}"
WG_ALLOWED="${WG_ALLOWED_IPS:-0.0.0.0/0}"

apt-get update -y
apt-get install -y wireguard resolvconf

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

if [[ -z "$WG_PRIV" ]]; then
  wg genkey | tee /etc/wireguard/${WG_IF}.key | wg pubkey > /etc/wireguard/${WG_IF}.pub
  chmod 600 /etc/wireguard/${WG_IF}.key
  WG_PRIV="$(cat /etc/wireguard/${WG_IF}.key)"
fi

cat >/etc/wireguard/${WG_IF}.conf <<EOF
[Interface]
Address = ${WG_ADDR}
PrivateKey = ${WG_PRIV}
ListenPort = 51820
DNS = ${WG_DNS}

EOF

if [[ -n "$WG_PEER_PUB" ]]; then
cat >>/etc/wireguard/${WG_IF}.conf <<EOF
[Peer]
PublicKey = ${WG_PEER_PUB}
Endpoint = ${WG_PEER_ENDPOINT}
AllowedIPs = ${WG_ALLOWED}
PersistentKeepalive = 25
EOF
fi

systemctl enable wg-quick@${WG_IF}
systemctl restart wg-quick@${WG_IF} || true
log "WireGuard configured on ${WG_IF}."
EOS
chmod +x "$DARKSITE_DIR/scripts/setup_wireguard.sh"

cat > "$DARKSITE_DIR/scripts/setup_salt.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[SALT] $(date '+%F %T') - $*"; }

SALT_MASTER="${SALT_MASTER:-salt}"
SALT_MINION_ID="${SALT_MINION_ID:-}"

apt-get update -y
apt-get install -y curl gnupg lsb-release
curl -fsSL https://repo.saltproject.io/py3/debian/latest/salt-archive-keyring.gpg -o /usr/share/keyrings/salt-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] http://repo.saltproject.io/py3/debian/$(. /etc/os-release; echo $VERSION_CODENAME)/amd64/latest $(. /etc/os-release; echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/salt.list
apt-get update -y
apt-get install -y salt-minion

mkdir -p /etc/salt
{
  echo "master: ${SALT_MASTER}"
  [[ -n "$SALT_MINION_ID" ]] && echo "id: ${SALT_MINION_ID}"
} > /etc/salt/minion

systemctl enable salt-minion
systemctl restart salt-minion || true
log "Salt minion configured (master=${SALT_MASTER})."
EOS
chmod +x "$DARKSITE_DIR/scripts/setup_salt.sh"

# -----------------------------------------------------------------------------
# postinstall.sh (Original, extended to call wireguard/salt)
# -----------------------------------------------------------------------------
log "Writing postinstall.sh..."
cat > "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/postinstall.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR
log(){ echo "[INFO] $(date '+%F %T') - $*"; }

# Load runtime vars (baked during ISO build)
if [ -f /etc/environment.d/99-provision.conf ]; then
  . /etc/environment.d/99-provision.conf
fi

: "${DOMAIN:?}"
: "${USE_CLOUD_INIT:=false}"
INSTALL_PROFILE="${INSTALL_PROFILE:-server}"
WG_ENABLE="${WG_ENABLE:-true}"
SALT_ENABLE="${SALT_ENABLE:-true}"

# Users & SSH keys
USERS=(
  "todd:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV51Eelt8PwYreHhJJ4JJP3OMwrXswUShblYY10J+A/ todd@onyx"
)

# Build AllowUsers
ALLOW_USERS=""
for e in "${USERS[@]}"; do u="${e%%:*}"; ALLOW_USERS+="$u "; done
ALLOW_USERS="${ALLOW_USERS%% }"

wait_for_network() {
  log "Waiting for basic network..."
  for i in {1..60}; do
    ip route show default &>/dev/null && ping -c1 -W1 1.1.1.1 &>/dev/null && return 0
    sleep 2
  done
  log "No network after wait; continuing."
}

update_and_upgrade() {
  log "APT sources -> trixie"
  cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt -y upgrade
}

install_base_packages() {
  log "Installing base packages..."
  apt install -y --no-install-recommends \
    dbus polkitd pkexec \
    curl wget ca-certificates gnupg lsb-release unzip \
    net-tools traceroute tcpdump sysstat strace lsof ltrace \
    rsync rsyslog cron chrony sudo git ethtool jq \
    qemu-guest-agent openssh-server \
    ngrep nmap \
    bpfcc-tools bpftrace libbpf-dev python3-bpfcc python3 python3-pip \
    uuid-runtime tmux htop python3.13-venv \
    linux-image-amd64 linux-headers-amd64
}

maybe_install_desktop() {
  case "$INSTALL_PROFILE" in
    gnome-min)
      log "Installing minimal GNOME + NetworkManager..."
      apt install -y --no-install-recommends gnome-core gdm3 gnome-terminal network-manager
      systemctl enable --now NetworkManager gdm3 || true
      ;;
    gnome-full)
      log "Installing full GNOME (task-gnome-desktop)..."
      apt install -y task-gnome-desktop
      ;;
    xfce-min)
      log "Installing minimal XFCE..."
      apt install -y --no-install-recommends xfce4 xfce4-terminal lightdm xorg network-manager
      systemctl enable --now NetworkManager lightdm || true
      ;;
    kde-min)
      log "Installing minimal KDE Plasma..."
      apt install -y --no-install-recommends plasma-desktop sddm plasma-workspace-wayland kwin-wayland konsole network-manager
      systemctl enable --now NetworkManager sddm || true
      ;;
    server) log "Server profile selected. Skipping desktop." ;;
    *)      log "Unknown INSTALL_PROFILE='$INSTALL_PROFILE'. Skipping desktop." ;;
  esac
}

enforce_wayland_defaults() {
  if systemctl list-unit-files | grep -q '^gdm3\.service'; then
    mkdir -p /etc/gdm3
    if [ -f /etc/gdm3/daemon.conf ]; then
      if grep -q '^[# ]*WaylandEnable=' /etc/gdm3/daemon.conf; then
        sed -i 's/^[# ]*WaylandEnable=.*/WaylandEnable=true/' /etc/gdm3/daemon.conf
      else
        printf '\n[daemon]\nWaylandEnable=true\n' >> /etc/gdm3/daemon.conf
      fi
    else
      cat > /etc/gdm3/daemon.conf <<'EOF'
[daemon]
WaylandEnable=true
EOF
    fi
  fi
  if systemctl list-unit-files | grep -q '^sddm\.service'; then
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
Session=plasmawayland.desktop
[Wayland]
EnableHiDPI=true
EOF
  fi
}

maybe_install_cloud_init() {
  if [[ "$USE_CLOUD_INIT" == "true" ]]; then
    log "Installing cloud-init..."
    apt install -y cloud-init cloud-guest-utils
    systemctl enable cloud-init cloud-init-local cloud-config cloud-final || true
  else
    log "Cloud-Init disabled."
  fi
}

disable_ipv6() {
  log "Disabling IPv6..."
  cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf || true
}

write_bashrc() {
  log "Writing /etc/skel/.bashrc"
  cat >/etc/skel/.bashrc <<'EOF'
# ~/.bashrc
[ -z "$PS1" ] && return
PS1='\[\e[0;32m\]\u@\h\[\e[m\]:\[\e[0;34m\]\w\[\e[m\]\$ '
HISTSIZE=10000; HISTFILESIZE=20000; HISTTIMEFORMAT='%F %T '; HISTCONTROL=ignoredups:erasedups
shopt -s histappend checkwinsize cdspell
alias grep='grep --color=auto'
alias ll='ls -alF'; alias la='ls -A'; alias l='ls -CF'
alias ports='ss -tuln'; alias df='df -h'; alias du='du -h'
[ -f /etc/bash_completion ] && . /etc/bash_completion
VENV_DIR="/root/bccenv"; [ -d "$VENV_DIR" ] && [ -n "$PS1" ] && . "$VENV_DIR/bin/activate"
echo "$USER connected to $(hostname) on $(date)"
EOF
  for u in root ansible debian; do
    h=$(eval echo "~$u") || true
    [ -d "$h" ] || continue
    cp /etc/skel/.bashrc "$h/.bashrc"; chown "$u:$u" "$h/.bashrc" || true
  done
}

configure_ufw_firewall() {
  log "Configuring UFW..."
  apt-get install -y ufw
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw --force enable
}

write_tmux_conf() {
  log "Writing tmux config..."
  cat >/etc/skel/.tmux.conf <<'EOF'
set -g mouse on
setw -g mode-keys vi
set -g history-limit 10000
set -g default-terminal "screen-256color"
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
EOF
  cp /etc/skel/.tmux.conf /root/.tmux.conf
}

install_custom_scripts() {
  log "Installing custom scripts (if any)..."
  if [[ -d /root/darksite/scripts ]] && compgen -G "/root/darksite/scripts/*" >/dev/null; then
    cp -a /root/darksite/scripts/* /usr/local/bin/
    chmod +x /usr/local/bin/* || true
  fi
}

setup_vim_config() {
  log "Setting up Vim..."
  apt-get install -y vim vim-airline vim-airline-themes vim-ctrlp vim-fugitive vim-gitgutter vim-tabular
  mkdir -p /etc/skel/.vim/autoload/airline/themes
  cat >/etc/skel/.vimrc <<'EOF'
syntax on
filetype plugin indent on
set number
set relativenumber
set tabstop=2 shiftwidth=2 expandtab
EOF
}

setup_python_env() {
  log "Python env for BCC..."
  apt-get install -y python3-psutil python3-bpfcc
  local VENV_DIR="/root/bccenv"
  python3 -m venv --system-site-packages "$VENV_DIR"
  . "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools
  pip install cryptography pyOpenSSL numba pytest
  deactivate
  for f in /root/.bashrc /etc/skel/.bashrc; do
    grep -q "$VENV_DIR" "$f" 2>/dev/null || echo -e "\n# Auto-activate BCC venv\n[ -d \"$VENV_DIR\" ] && . \"$VENV_DIR/bin/activate\"" >> "$f"
  done
}

setup_users_and_ssh() {
  log "Creating users and hardening sshd..."
  for entry in "${USERS[@]}"; do
    u="${entry%%:*}"; key="${entry#*:}"
    id -u "$u" &>/dev/null || useradd --create-home --shell /bin/bash "$u"
    h="/home/$u"; mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
    echo "$key" >"$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
    chown -R "$u:$u" "$h"
    echo "$u ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-$u"; chmod 440 "/etc/sudoers.d/90-$u"
  done
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-custom.conf <<EOF
Port 22
Protocol 2
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 2
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers ${ALLOW_USERS}
EOF
  chmod 600 /etc/ssh/sshd_config.d/99-custom.conf
  systemctl restart ssh
}

configure_dns_hosts() {
  log "Hostname and /etc/hosts..."
  VMNAME="$(hostname --short)"
  FQDN="${VMNAME}.${DOMAIN}"
  hostnamectl set-hostname "$FQDN"
  echo "$VMNAME" >/etc/hostname
  cat >/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 ${FQDN} ${VMNAME}
EOF
}

sync_skel_to_existing_users() {
  for u in root ansible debian; do
    h=$(eval echo "~$u") || true
    [ -d "$h" ] || continue
    cp /etc/skel/.bashrc "$h/.bashrc" || true
    cp /etc/skel/.tmux.conf "$h/.tmux.conf" || true
    cp /etc/skel/.vimrc "$h/.vimrc" || true
    chown -R "$u:$u" "$h" || true
  done
}

enable_services() {
  systemctl enable qemu-guest-agent ssh rsyslog chrony || true
  if [[ "$USE_CLOUD_INIT" == "true" ]]; then
    systemctl enable cloud-init cloud-init-local cloud-config cloud-final || true
  fi
}

# === ADDED: hook in darksite bootstrap
run_darksite_bootstrap() {
  if [[ "${WG_ENABLE:-true}" == "true" ]]; then
    /usr/local/bin/setup_wireguard.sh || true
  fi
  if [[ "${SALT_ENABLE:-true}" == "true" ]]; then
    /usr/local/bin/setup_salt.sh || true
  fi
}

cleanup_identity() {
  log "Cleaning identity for template safety..."
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -s /etc/machine-id /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_* || true
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server
}

final_cleanup() {
  apt autoremove -y || true
  apt clean || true
  rm -rf /tmp/* /var/tmp/* || true
  find /var/log -type f -exec truncate -s 0 {} \; || true
}

log "BEGIN postinstall"
wait_for_network
update_and_upgrade
install_base_packages
maybe_install_desktop
enforce_wayland_defaults
maybe_install_cloud_init
disable_ipv6
setup_vim_config
write_bashrc
configure_ufw_firewall
write_tmux_conf
sync_skel_to_existing_users
setup_users_and_ssh
setup_python_env
configure_dns_hosts
install_custom_scripts
enable_services
run_darksite_bootstrap
cleanup_identity
final_cleanup

log "Disabling bootstrap service..."
systemctl disable bootstrap.service || true
rm -f /etc/systemd/system/bootstrap.service
rm -f /etc/systemd/system/multi-user.target.wants/bootstrap.service

log "Postinstall complete. Forcing poweroff..."
/sbin/poweroff -f
EOSCRIPT
chmod +x "$DARKSITE_DIR/postinstall.sh"

# -----------------------------------------------------------------------------
# bootstrap.service (Original)
# -----------------------------------------------------------------------------
log "Writing bootstrap.service..."
cat > "$DARKSITE_DIR/bootstrap.service" <<'EOF'
[Unit]
Description=Initial Bootstrap Script (One-time)
After=network.target
Wants=network.target
ConditionPathExists=/root/darksite/postinstall.sh

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/root/darksite/postinstall.sh'
TimeoutStartSec=0
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Bake 99-provision.conf (Original + darksite toggles)
# -----------------------------------------------------------------------------
cat > "$DARKSITE_DIR/99-provision.conf" <<EOF
DOMAIN=$DOMAIN
USE_CLOUD_INIT=$USE_CLOUD_INIT
INSTALL_PROFILE=$INSTALL_PROFILE
WG_ENABLE=$WG_ENABLE
SALT_ENABLE=$SALT_ENABLE
WG_INTERFACE=${WG_INTERFACE:-$WG_INTERFACE}
WG_ADDRESS=${WG_ADDRESS:-$WG_ADDRESS}
WG_DNS=${WG_DNS:-$WG_DNS}
WG_PRIVATE_KEY=${WG_PRIVATE_KEY:-$WG_PRIVATE_KEY}
WG_PUBLIC_KEY_PEER=${WG_PUBLIC_KEY_PEER:-$WG_PUBLIC_KEY_PEER}
WG_PEER_ENDPOINT=${WG_PEER_ENDPOINT:-$WG_PEER_ENDPOINT}
WG_ALLOWED_IPS=${WG_ALLOWED_IPS:-$WG_ALLOWED_IPS}
SALT_MASTER=${SALT_MASTER}
SALT_MINION_ID=${SALT_MINION_ID}
EOF

# -----------------------------------------------------------------------------
# finalize-template.sh (Original)
# -----------------------------------------------------------------------------
log "Writing finalize-template.sh..."
cat > "$DARKSITE_DIR/finalize-template.sh" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

: "${PROXMOX_HOST:?Missing PROXMOX_HOST}"
: "${TEMPLATE_VMID:?Missing TEMPLATE_VMID}"
: "${NUM_CLONES:?Missing NUM_CLONES}"
: "${BASE_CLONE_VMID:?Missing BASE_CLONE_VMID}"
: "${BASE_CLONE_IP:?Missing BASE_CLONE_IP}"
: "${CLONE_MEMORY_MB:=4096}"
: "${CLONE_CORES:=4}"
: "${CLONE_VLAN_ID:=}"
: "${CLONE_GATEWAY:=}"
: "${CLONE_NAMESERVER:=}"
: "${VMNAME_CLEAN:?Missing VMNAME_CLEAN}"
: "${VM_STORAGE:?Missing VM_STORAGE}"
: "${USE_CLOUD_INIT:=false}"
: "${DOMAIN:=localdomain}"
: "${EXTRA_DISK_COUNT:=0}"
: "${EXTRA_DISK_SIZE_GB:=100}"
: "${EXTRA_DISK_TARGET:=}"

echo "[*] Waiting for VM $TEMPLATE_VMID on $PROXMOX_HOST to shut down..."
SECONDS=0; TIMEOUT=900
while ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@"$PROXMOX_HOST" "qm status $TEMPLATE_VMID" | grep -q running; do
  (( SECONDS > TIMEOUT )) && { echo "[!] Timeout waiting for shutdown"; exit 1; }
  sleep 15
done

echo "[*] Converting $TEMPLATE_VMID to template..."
ssh root@"$PROXMOX_HOST" "qm template $TEMPLATE_VMID"

check_storage() {
  local stor="$1"
  ssh root@"$PROXMOX_HOST" "pvesm status --storage $stor 2>/dev/null | awk 'NR>1 {print \$6}'" | grep -qx active
}

IP_PREFIX=$(echo "$BASE_CLONE_IP" | cut -d. -f1-3)
IP_START=$(echo "$BASE_CLONE_IP" | cut -d. -f4)

if [[ "$EXTRA_DISK_COUNT" -gt 0 ]]; then
  if [[ -z "$EXTRA_DISK_TARGET" || ! $(check_storage "$EXTRA_DISK_TARGET" && echo ok) == ok ]]; then
    echo "[!] Extra disk target invalid or inactive; skipping extra disks."
    EXTRA_DISK_COUNT=0
  else
    echo "[*] Extra disks: ${EXTRA_DISK_COUNT} x ${EXTRA_DISK_SIZE_GB}G on $EXTRA_DISK_TARGET."
  fi
fi

for ((i=0; i<NUM_CLONES; i++)); do
  CLONE_VMID=$((BASE_CLONE_VMID + i))
  CLONE_IP="${IP_PREFIX}.$((IP_START + i))"

  INDEX=$((i+1))
  CLONE_NAME="${VMNAME_CLEAN}.${DOMAIN}-${INDEX}-${CLONE_IP}"
  FQDN="${VMNAME_CLEAN}.${DOMAIN}"
  DESC="${FQDN} - ${CLONE_IP}"

  echo "[*] Cloning $CLONE_NAME (VMID $CLONE_VMID, IP $CLONE_IP)..."

  ssh root@"$PROXMOX_HOST" "qm clone $TEMPLATE_VMID $CLONE_VMID --name '$CLONE_NAME' --full 1 --storage $VM_STORAGE"
  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --delete ide3 || true"

  NET_OPTS="virtio,bridge=vmbr0"
  [[ -n "$CLONE_VLAN_ID" ]] && NET_OPTS="$NET_OPTS,tag=$CLONE_VLAN_ID"

  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --memory $CLONE_MEMORY_MB --cores $CLONE_CORES --net0 $NET_OPTS --agent enabled=1 --boot order=scsi0"

  if [[ "$USE_CLOUD_INIT" == "true" ]]; then
    ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --ide3 ${VM_STORAGE}:cloudinit"
    ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --ipconfig0 ip=${CLONE_IP}/24${CLONE_GATEWAY:+,gw=${CLONE_GATEWAY}}"
    [[ -n "$CLONE_NAMESERVER" ]] && ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --nameserver '$CLONE_NAMESERVER'"
  fi

  if [[ "$EXTRA_DISK_COUNT" -gt 0 ]]; then
    echo "[*] Adding $EXTRA_DISK_COUNT extra disk(s) to VM $CLONE_VMID..."
    for ((d=1; d<=EXTRA_DISK_COUNT; d++)); do
      DISK_BUS="scsi$((d))"
      ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --${DISK_BUS} ${EXTRA_DISK_TARGET}:${EXTRA_DISK_SIZE_GB}"
    done
  fi

  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --description '$DESC'"
  ssh root@"$PROXMOX_HOST" "qm start $CLONE_VMID"
  echo "[+] Clone $CLONE_NAME started."
done

echo "[OK] All clones created."
EOSCRIPT
chmod +x "$DARKSITE_DIR/finalize-template.sh"

# =============================================================================
# Preseed (Original)
# =============================================================================
log "Creating preseed.cfg..."

if [[ "$NETWORK_MODE" == "dhcp" ]]; then
  NETBLOCK=$(cat <<EOF
# Networking (DHCP)
d-i netcfg/choose_interface select auto
d-i netcfg/disable_dhcp boolean false
d-i netcfg/get_hostname string $VMNAME
d-i netcfg/get_domain string $DOMAIN
EOF
)
else
  NETBLOCK=$(cat <<EOF
# Networking (Static)
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $VMNAME
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string $STATIC_IP
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $NAMESERVER
EOF
)
fi

case "$INSTALL_PROFILE" in
  server)
    PROFILEBLOCK=$(cat <<'EOF'
# Server profile (no desktop)
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  gnome-min)
    PROFILEBLOCK=$(cat <<'EOF'
# Minimal GNOME (Wayland via gdm3)
tasksel tasksel/first multiselect standard
d-i pkgsel/include string gnome-core gdm3 gnome-terminal network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  gnome-full)
    PROFILEBLOCK=$(cat <<'EOF'
# Full GNOME
tasksel tasksel/first multiselect standard, desktop, gnome-desktop, ssh-server
d-i pkgsel/ignore-recommends boolean false
d-i pkgsel/upgrade select none
EOF
)
    ;;
  xfce-min)
    PROFILEBLOCK=$(cat <<'EOF'
# Minimal XFCE (X11)
tasksel tasksel/first multiselect standard
d-i pkgsel/include string xfce4 xfce4-terminal lightdm xorg network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  kde-min)
    PROFILEBLOCK=$(cat <<'EOF'
# Minimal KDE Plasma (Wayland)
tasksel tasksel/first multiselect standard
d-i pkgsel/include string plasma-desktop sddm plasma-workspace-wayland kwin-wayland konsole network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  *) error_log "Unknown INSTALL_PROFILE: $INSTALL_PROFILE"; exit 1 ;;
esac

cat > "$CUSTOM_DIR/$PRESEED_FILE" <<EOF
# Locale & keyboard
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us

$NETBLOCK

# Mirrors (we will re-point in postinstall)
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i apt-setup/use_mirror boolean false
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

# Temporary user (postinstall creates real users)
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/username string debian
d-i passwd/user-fullname string Debian User
d-i passwd/user-password password debian
d-i passwd/user-password-again password debian

# Timezone
d-i time/zone string America/Toronto
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

# Disk (guided LVM on whole disk)
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-lvm/confirm_write_new_label boolean true
d-i partman-auto-lvm/guided_size string max

$PROFILEBLOCK

d-i grub-installer/bootdev string /dev/sda
d-i grub-installer/only_debian boolean true

d-i finish-install/keep-consoles boolean false
d-i finish-install/exit-installer boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i cdrom-detect/eject boolean true

tasksel tasksel/first multiselect standard, ssh-server
d-i finish-install/reboot_in_progress note
# Late command: copy darksite payload and enable bootstrap
d-i preseed/late_command string \
  mkdir -p /target/root/darksite ; \
  cp -a /cdrom/darksite/* /target/root/darksite/ ; \
  in-target chmod +x /root/darksite/postinstall.sh ; \
  in-target cp /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service ; \
  in-target mkdir -p /etc/environment.d ; \
  in-target cp /root/darksite/99-provision.conf /etc/environment.d/99-provision.conf ; \
  in-target chmod 0644 /etc/environment.d/99-provision.conf ; \
  in-target systemctl daemon-reload ; \
  in-target systemctl enable bootstrap.service ;

# Power off the installer VM (no reboot)
d-i debian-installer/exit/poweroff boolean true
EOF

# =============================================================================
# Boot menu & ISO rebuild (Original)
# =============================================================================
log "Updating isolinux/txt.cfg..."
TXT_CFG="$CUSTOM_DIR/isolinux/txt.cfg"
ISOLINUX_CFG="$CUSTOM_DIR/isolinux/isolinux.cfg"
cat >> "$TXT_CFG" <<EOF
label auto
  menu label ^base
  kernel /install.amd/vmlinuz
  append auto=true priority=critical vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/$PRESEED_FILE ---
EOF
sed -i 's/^default .*/default auto/' "$ISOLINUX_CFG"

log "Rebuilding ISO..."
xorriso -as mkisofs \
  -o "$OUTPUT_ISO" \
  -r -J -joliet-long -l \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$CUSTOM_DIR"

mv "$OUTPUT_ISO" "$FINAL_ISO"
log "ISO ready: $FINAL_ISO"

# =============================================================================
# Branch by TARGET
# =============================================================================

require_tools

if [[ "$TARGET" == "proxmox" ]]; then
  # ======================== Proxmox path (Original) ==========================
  log "Uploading ISO to $PROXMOX_HOST..."
  scp -q "$FINAL_ISO" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/"
  FINAL_ISO_BASENAME="$(basename "$FINAL_ISO")"

  log "Creating VM $VMID on $PROXMOX_HOST..."
  ssh root@"$PROXMOX_HOST" \
    VMID="$VMID" VMNAME="$BASE_VMNAME" FINAL_ISO="$FINAL_ISO_BASENAME" \
    VM_STORAGE="${VM_STORAGE:-void}" ISO_STORAGE="${ISO_STORAGE:-local}" \
    DISK_SIZE_GB="${DISK_SIZE_GB:-32}" MEMORY_MB="${MEMORY_MB:-4096}" \
    CORES="${CORES:-4}" USE_CLOUD_INIT="${USE_CLOUD_INIT:-false}" \
    'bash -s' <<'EOSSH'
set -euo pipefail
: "${VMID:?}"; : "${VMNAME:?}"; : "${FINAL_ISO:?}"
: "${VM_STORAGE:?}"; : "${ISO_STORAGE:?}"
: "${DISK_SIZE_GB:?}"; : "${MEMORY_MB:?}"; : "${CORES:?}"

qm destroy "$VMID" --purge || true

qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --ide2 ${ISO_STORAGE}:iso/${FINAL_ISO},media=cdrom \
  --scsihw virtio-scsi-single \
  --scsi0 ${VM_STORAGE}:${DISK_SIZE_GB} \
  --serial0 socket \
  --ostype l26 \
  --agent enabled=1

qm set "$VMID" --efidisk0 ${VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=0
qm set "$VMID" --boot order=ide2
qm start "$VMID"
EOSSH

  log "Waiting for VM $VMID to power off after installer..."
  SECONDS=0; TIMEOUT=1800
  while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
    (( SECONDS > TIMEOUT )) && { error_log "Timeout waiting for installer shutdown"; exit 1; }
    sleep 20
  done

  if [[ "$NETWORK_MODE" == "static" ]]; then
    BASE_DESC="${BASE_FQDN}-template - ${STATIC_IP}"
  else
    BASE_DESC="${BASE_FQDN}-template - DHCP"
  fi

  log "Detach ISO, set boot=scsi0, optionally add cloudinit, set description..."
  ssh root@"$PROXMOX_HOST" 'bash -s --' "$VMID" "$VM_STORAGE" "$USE_CLOUD_INIT" "$BASE_DESC" <<'EOSSH'
set -euo pipefail
VMID="$1"; VM_STORAGE="$2"; USE_CLOUD_INIT="$3"; VM_DESC="$4"

qm set "$VMID" --delete ide2
qm set "$VMID" --boot order=scsi0
if [ "$USE_CLOUD_INIT" = "true" ]; then
  qm set "$VMID" --ide3 ${VM_STORAGE}:cloudinit
fi
qm set "$VMID" --description "$VM_DESC"
qm start "$VMID"
EOSSH

  log "Waiting for VM $VMID to power off after postinstall..."
  SECONDS=0; TIMEOUT=1800
  while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
    (( SECONDS > TIMEOUT )) && { error_log "Timeout waiting for postinstall shutdown"; exit 1; }
    sleep 20
  done

  log "Template + clone loop..."
  IP_PREFIX="$(echo "$BASE_CLONE_IP" | cut -d. -f1-3)"
  IP_START="$(echo "$BASE_CLONE_IP" | cut -d. -f4)"

  export PROXMOX_HOST TEMPLATE_VMID="$VMID" VM_STORAGE USE_CLOUD_INIT DOMAIN
  export NUM_CLONES BASE_CLONE_VMID BASE_CLONE_IP CLONE_MEMORY_MB CLONE_CORES
  export CLONE_VLAN_ID CLONE_GATEWAY="$GATEWAY" CLONE_NAMESERVER="$NAMESERVER"
  export VMNAME_CLEAN="$VMNAME" EXTRA_DISK_COUNT EXTRA_DISK_SIZE_GB EXTRA_DISK_TARGET

  bash "$DARKSITE_DIR/finalize-template.sh"

  log "All done (Proxmox)."

elif [[ "$TARGET" == "aws" ]]; then
  # =============================== AWS path ==================================
  log "Launching AWS instance (AL2023) with darksite bootstrap..."
  # Ensure we can call STS
  aws_cli sts get-caller-identity >/dev/null || die "AWS identity failure (check credentials)."

  # Find default VPC & pick subnet if not provided
  vpc_id="$(aws_cli ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [[ -n "$AWS_SUBNET_ID" ]] || AWS_SUBNET_ID="$(aws_cli ec2 describe-subnets --filters Name=vpc-id,Values="$vpc_id" --query 'Subnets[0].SubnetId' --output text)"

  # Security group (create or reuse)
  sg_id="$(aws_cli ec2 describe-security-groups --filters Name=group-name,Values="$AWS_SG_NAME" Name=vpc-id,Values="$vpc_id" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(aws_cli ec2 create-security-group --vpc-id "$vpc_id" --group-name "$AWS_SG_NAME" --description "Minimal SG for $AWS_INSTANCE_NAME" --query 'GroupId' --output text)"
    aws_cli ec2 create-tags --resources "$sg_id" --tags Key=Name,Value="$AWS_SG_NAME"
    CREATED_SG=1
  else
    CREATED_SG=0
  fi

  # Ingress (from your /32)
  myip="$(curl -fsSL https://checkip.amazonaws.com || true)"; myip="${myip//$'\n'/}"
  if [[ "$AWS_ENABLE_SSH" == "true" ]]; then
    cidr="${AWS_SSH_CIDR:-${myip}/32}"
    aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" \
      --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=\"${cidr}\"}]" \
      >/dev/null 2>&1 || true
  fi
  if [[ "$AWS_OPEN_HTTP" == "true" && -n "$myip" ]]; then
    aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" \
      --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=\"${myip}/32\"}]" \
      >/dev/null 2>&1 || true
  fi
  if [[ "$AWS_OPEN_HTTPS" == "true" && -n "$myip" ]]; then
    aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" \
      --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=\"${myip}/32\"}]" \
      >/dev/null 2>&1 || true
  fi

  # Key pair (import or create)
  if [[ -n "$AWS_PUBLIC_KEY_PATH" && -r "$AWS_PUBLIC_KEY_PATH" ]]; then
    exists="$(aws_cli ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")"
    if [[ "$exists" != "$AWS_KEY_NAME" ]]; then
      aws_cli ec2 import-key-pair --key-name "$AWS_KEY_NAME" --public-key-material "fileb://$AWS_PUBLIC_KEY_PATH" >/dev/null
    fi
    PEM_PATH=""
  else
    exists="$(aws_cli ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")"
    if [[ "$exists" != "$AWS_KEY_NAME" ]]; then
      aws_cli ec2 create-key-pair --key-name "$AWS_KEY_NAME" --key-type rsa --key-format pem \
        --query 'KeyMaterial' --output text > "$AWS_SAVE_PEM"
      chmod 600 "$AWS_SAVE_PEM"
      PEM_PATH="$AWS_SAVE_PEM"
    else
      PEM_PATH=""
    fi
  fi

  # Resolve AMI (AL2023)
  if [[ "$AWS_ARCH" == "arm64" ]]; then
    ami_param="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
  else
    ami_param="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
  fi
  ami_id="$(aws_cli ssm get-parameter --name "$ami_param" --query 'Parameter.Value' --output text)"

  # Build User-Data: WireGuard + Salt + fetch optional darksite over scp or http (customize here)
  read -r -d '' USERDATA <<'EOCLOUD'
#!/bin/bash
set -euo pipefail

# System update
dnf -y update || true

# Install WireGuard & Salt (Amazon Linux 2023)
dnf -y install iproute wireguard-tools wget curl python3 || true
# Salt via pip (simple bootstrap); replace with official repo if desired
python3 -m pip install --upgrade pip
python3 -m pip install salt==3007.* || true

# Write Salt minion config
mkdir -p /etc/salt
echo "master: ${SALT_MASTER:-salt}" > /etc/salt/minion
[ -n "${SALT_MINION_ID:-}" ] && echo "id: ${SALT_MINION_ID}" >> /etc/salt/minion
systemctl enable --now salt-minion || true

# WireGuard quick setup
IF="${WG_INTERFACE:-wg0}"
ADDR="${WG_ADDRESS:-10.42.0.2/32}"
DNS="${WG_DNS:-1.1.1.1}"
PRIV="${WG_PRIVATE_KEY:-}"
PEER_PUB="${WG_PUBLIC_KEY_PEER:-}"
PEER_ENDPOINT="${WG_PEER_ENDPOINT:-}"
ALLOWED="${WG_ALLOWED_IPS:-0.0.0.0/0}"

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

if [[ -z "$PRIV" ]]; then
  umask 077
  wg genkey | tee /etc/wireguard/${IF}.key | wg pubkey > /etc/wireguard/${IF}.pub
  PRIV="$(cat /etc/wireguard/${IF}.key)"
fi

cat >/etc/wireguard/${IF}.conf <<EOF
[Interface]
Address = ${ADDR}
PrivateKey = ${PRIV}
ListenPort = 51820
DNS = ${DNS}
EOF

if [[ -n "$PEER_PUB" ]]; then
cat >>/etc/wireguard/${IF}.conf <<EOF
[Peer]
PublicKey = ${PEER_PUB}
Endpoint = ${PEER_ENDPOINT}
AllowedIPs = ${ALLOWED}
PersistentKeepalive = 25
EOF
fi

systemctl enable wg-quick@${IF}
systemctl restart wg-quick@${IF} || true

# (Optional) Pull darksite payload if you host it; placeholder:
# curl -fsSL http://YOUR_DARKSITE_URL/darksite.tgz | tar -xz -C /root/
# /root/darksite/postinstall.sh || true

EOCLOUD

  # EBS encryption JSON
  if [[ -n "$AWS_KMS_KEY_ID" ]]; then
    kms_json="\"Encrypted\":true,\"KmsKeyId\":\"${AWS_KMS_KEY_ID}\""
  else
    kms_json="\"Encrypted\":true"
  fi
  bdm="[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",${kms_json}}}]"

  # Network interface JSON
  if [[ "$AWS_ASSOC_PUBLIC_IP" == "true" ]]; then
    ni="[{\"DeviceIndex\":0,\"SubnetId\":\"${AWS_SUBNET_ID}\",\"Groups\":[\"${sg_id}\"],\"AssociatePublicIpAddress\":true}]"
  elif [[ "$AWS_ASSOC_PUBLIC_IP" == "false" ]]; then
    ni="[{\"DeviceIndex\":0,\"SubnetId\":\"${AWS_SUBNET_ID}\",\"Groups\":[\"${sg_id}\"],\"AssociatePublicIpAddress\":false}]"
  else
    ni="[{\"DeviceIndex\":0,\"SubnetId\":\"${AWS_SUBNET_ID}\",\"Groups\":[\"${sg_id}\"]}]"
  fi

  tags="ResourceType=instance,Tags=[{Key=Name,Value=${AWS_INSTANCE_NAME}},{Key=Owner,Value=ops},{Key=Env,Value=dev}]"

  iid="$(aws_cli ec2 run-instances \
    --image-id "$ami_id" \
    --instance-type "$AWS_INSTANCE_TYPE" \
    --key-name "$AWS_KEY_NAME" \
    --block-device-mappings "$bdm" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "$tags" \
    --network-interfaces "$ni" \
    --user-data "$USERDATA" \
    --query 'Instances[0].InstanceId' --output text)"

  [[ -n "$iid" && "$iid" != "None" ]] || die "run-instances did not return an InstanceId."
  log "Instance ID: $iid"
  aws_cli ec2 wait instance-running --instance-ids "$iid"

  pub_ip="$(aws_cli ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  log "Launched: $iid  PublicIP=$pub_ip"

  if [[ "$AWS_AUTO_SSH" == "true" && -n "$pub_ip" && "$pub_ip" != "None" ]]; then
    keyarg=()
    if [[ -n "${PEM_PATH:-}" && -r "${PEM_PATH:-}" ]]; then keyarg=(-i "$PEM_PATH"); fi
    log "Attempting SSH (${AWS_SSH_USER}@${pub_ip}) ..."
    exec ssh -o StrictHostKeyChecking=accept-new "${keyarg[@]}" "${AWS_SSH_USER}@${pub_ip}"
  fi

  log "All done (AWS)."

elif [[ "$TARGET" == "firecracker" ]]; then
  # ============================ Firecracker path ==============================
  log "Building Firecracker rootfs via debootstrap (Debian minimal)..."
  rm -rf "$FC_ROOTFS_DIR"
  mkdir -p "$FC_ROOTFS_DIR"

  # Create rootfs
  debootstrap --variant=minbase trixie "$FC_ROOTFS_DIR" http://deb.debian.org/debian
  chroot "$FC_ROOTFS_DIR" bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends systemd-sysv ca-certificates curl wget iproute2 iputils-ping \
      openssh-server net-tools resolvconf gnupg lsb-release nano vim \
      wireguard wireguard-tools salt-minion
    echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
    systemctl enable ssh
    # Salt minion config
    mkdir -p /etc/salt
    echo 'master: ${SALT_MASTER}' > /etc/salt/minion
    [ -n '${SALT_MINION_ID}' ] && echo 'id: ${SALT_MINION_ID}' >> /etc/salt/minion
    systemctl enable salt-minion || true
    # WireGuard: leave conf to first boot or pack minimal conf
  "

  # Create ext4 rootfs image
  log "Assembling ext4 image..."
  fallocate -l "${FC_IMG_SIZE_MB}M" "$FC_IMG"
  mkfs.ext4 -F "$FC_IMG"
  mkdir -p "$BUILD_DIR/mntimg"
  mount -o loop "$FC_IMG" "$BUILD_DIR/mntimg"
  rsync -aHAX --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp --exclude=/run "$FC_ROOTFS_DIR"/ "$BUILD_DIR/mntimg"/
  mkdir -p "$BUILD_DIR/mntimg"/{proc,sys,dev,run,tmp}
  chmod 1777 "$BUILD_DIR/mntimg/tmp"
  umount "$BUILD_DIR/mntimg"

  # Kernel (copy host vmlinux or from package path if present)
  if [[ -f "$FC_VMLINUX_PATH" ]]; then
    cp -f "$FC_VMLINUX_PATH" "$FC_OUTPUT_VMLINUX"
  else
    # best-effort search
    vmlin="$(find /boot -maxdepth 1 -type f -name 'vmlinux-*' | head -n1 || true)"
    [[ -n "$vmlin" ]] && cp -f "$vmlin" "$FC_OUTPUT_VMLINUX" || die "No vmlinux found. Set FC_VMLINUX_PATH."
  fi

  # Firecracker config JSON & run script
  cat > "$FC_CONFIG_JSON" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$(realpath "$FC_OUTPUT_VMLINUX")",
    "boot_args": "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules random.trust_cpu=on ip=${FC_GUEST_IP}::${FC_GW_IP%/*}:255.255.255.0::eth0:off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$(realpath "$FC_IMG")",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "02:FC:00:00:00:01",
      "host_dev_name": "${FC_TAP_IF}"
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 2048,
    "smt": false
  }
}
EOF

  cat > "$FC_RUN_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
FC_BIN="${FC_BIN:-/usr/local/bin/firecracker}"  # or /usr/bin/firecracker
CFG="${CFG:-'"$FC_CONFIG_JSON"' }"

# Create TAP if needed
if ! ip link show '"$FC_TAP_IF"' >/dev/null 2>&1; then
  sudo ip tuntap add dev '"$FC_TAP_IF"' mode tap
  sudo ip addr add '"$FC_GW_IP"' dev '"$FC_TAP_IF"'
  sudo ip link set '"$FC_TAP_IF"' up
fi

# Launch Firecracker
$FC_BIN --no-api --config-file "$CFG" --seccomp-level=0
EOS
  chmod +x "$FC_RUN_SCRIPT"

  log "Firecracker outputs:"
  log " - Kernel:  $FC_OUTPUT_VMLINUX"
  log " - Rootfs:  $FC_IMG"
  log " - Config:  $FC_CONFIG_JSON"
  log " - Runner:  $FC_RUN_SCRIPT"
  log "All done (Firecracker)."

else
  die "Unknown TARGET='$TARGET' (use proxmox|aws|firecracker)"
fi

