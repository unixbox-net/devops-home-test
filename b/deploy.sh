#!/usr/bin/env bash
# multi-target-deployer.sh
# Unified builder/deployer for Proxmox | AWS | Firecracker with Salt-first bootstrap.
# - Creates a Debian-based ISO that installs + runs a first-boot bootstrap.
# - Bootstrap:
#     * WireGuard (optional)
#     * Salt Minion (required; orchestrates everything via Salt Master)
#     * Log Forwarding (rsyslog) to Salt Master
#     * Kubernetes bring-up is Salt-driven; optional local fallback
#
# Usage examples:
#   # Proxmox: template + clones, control-plane via Salt, workers via Salt later
#   TARGET=proxmox VMNAME=k8s TEMPLATE_ONLY=false NUM_CLONES=3 ./multi-target-deployer.sh
#
#   # Proxmox: ONE-SHOT INSTALL (no template, no clones) — single VM, start and done
#   TARGET=proxmox ONE_SHOT=true VMID=1100 VMNAME=myapp NETWORK_MODE=static STATIC_IP=10.100.10.50 ./multi-target-deployer.sh
#
#   # AWS: single node that will auto-connect to Salt and apply highstate
#   TARGET=aws AWS_INSTANCE_NAME=k8s-cp KUBE_ROLE=control-plane ./multi-target-deployer.sh
#
#   # Firecracker: build rootfs + vmlinux + run script; node joins Salt on first boot
#   TARGET=firecracker KUBE_ROLE=worker KUBE_FC_MODE=ignite ./multi-target-deployer.sh
#
# Notes:
# - This script assumes Salt states exist on the master:
#       roles/kubernetes/control-plane
#       roles/kubernetes/worker
#       profiles/kubernetes/cilium (or calico)
#       profiles/monitoring/kube-prometheus-stack (Helm)
#       apps/gameserver/demo
#   You can trivially rename; grains determine targeting (see below).

set -euo pipefail

LOG_FILE="/root/install.txt"
exec &> >(tee -a "$LOG_FILE")

log()       { echo "[INFO]  $(date '+%F %T') - $*"; }
error_log() { echo "[ERROR] $(date '+%F %T') - $*" >&2; }
die()       { error_log "$*"; exit 1; }

# =============================================================================
# CONFIG (Targets + General)
# =============================================================================

# === Output target: proxmox | aws | firecracker
TARGET="${TARGET:-proxmox}"

# ISO source (Debian 13 DVD suggested for offline-ish package coverage)
ISO_ORIG="${ISO_ORIG:-/root/debian-13.0.0-amd64-DVD-1.iso}"

# Build workspace
BUILD_DIR="${BUILD_DIR:-/root/build}"
CUSTOM_DIR="$BUILD_DIR/custom"
MOUNT_DIR="${MOUNT_DIR:-/mnt/build}"
DARKSITE_DIR="$CUSTOM_DIR/darksite"
PRESEED_FILE="preseed.cfg"
OUTPUT_ISO="$BUILD_DIR/base.iso"
FINAL_ISO="${FINAL_ISO:-/root/clone.iso}"

# Domain + naming
DOMAIN="${DOMAIN:-unixbox.net}"
VMNAME="${VMNAME:-k8s}"         # base name (will be cleaned)

# --- One-shot installer toggle (Proxmox only) ---
# ONE_SHOT=true  -> create one VM, install, start it; NO template or clones; no "-template" suffix.
# BOOT_ONLY=true -> alias for ONE_SHOT.
ONE_SHOT="${ONE_SHOT:-${BOOT_ONLY:-false}}"

# Template-only flag (legacy behavior). Ignored if ONE_SHOT=true.
TEMPLATE_ONLY="${TEMPLATE_ONLY:-false}"

# Salt master (central control + logs + inventory orchestrator)
SALT_ENABLE="${SALT_ENABLE:-true}"
SALT_MASTER="${SALT_MASTER:-salt.unixbox.net}"
SALT_MINION_ID="${SALT_MINION_ID:-}"       # optional; default hostname if empty

# WireGuard (optional)
WG_ENABLE="${WG_ENABLE:-true}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PRIVATE_KEY="${WG_PRIVATE_KEY:-}"         # leave empty to generate
WG_PUBLIC_KEY_PEER="${WG_PUBLIC_KEY_PEER:-}" # optional peer key
WG_PEER_ENDPOINT="${WG_PEER_ENDPOINT:-}"     # host:port
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"
WG_ADDRESS="${WG_ADDRESS:-10.42.0.2/32}"
WG_DNS="${WG_DNS:-1.1.1.1}"

# Kubernetes “intent” (used as Salt grains; Salt should perform the real work)
KUBE_ENABLE="${KUBE_ENABLE:-true}"                # advertise K8s usage to Salt
KUBE_ROLE="${KUBE_ROLE:-worker}"                  # control-plane | worker
KUBE_VERSION="${KUBE_VERSION:-1.30.3-00}"         # used when fallback path is needed
KUBE_CNI="${KUBE_CNI:-cilium}"                    # cilium | calico (grains for Salt)
KUBE_FC_MODE="${KUBE_FC_MODE:-ignite}"            # ignite | kata | none (grains for Salt)
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-k8s.unixbox.net:6443}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SVC_CIDR="${SVC_CIDR:-10.96.0.0/12}"
KUBEADM_TOKEN="${KUBEADM_TOKEN:-}"                # fallback join
KUBEADM_CA_CERT_HASH="${KUBEADM_CA_CERT_HASH:-}"  # fallback join

# Monitoring (Salt will use these grains to decide what to deploy)
KUBE_DEPLOY_MONITORING="${KUBE_DEPLOY_MONITORING:-true}"         # metrics-server + kube-prometheus-stack
KUBE_DEPLOY_DEMO_GAMESERVER="${KUBE_DEPLOY_DEMO_GAMESERVER:-true}" # demo DS for UDP echo

# Installer profile (Debian tasksel)
INSTALL_PROFILE="${INSTALL_PROFILE:-server}"  # server | gnome-min | gnome-full | xfce-min | kde-min

# Optional extra scripts into ISO
SCRIPTS_DIR="${SCRIPTS_DIR:-/root/custom-scripts}"

# =============================================================================
# Proxmox knobs
# =============================================================================
INPUT="${INPUT:-1}"           # 1|fiend, 2|dragon, 3|lion
VMID="${VMID:-1002}"
VM_STORAGE="${VM_STORAGE:-void}"     # ceph rbd id or zfs id
ISO_STORAGE="${ISO_STORAGE:-local}"  # storage ID for ISOs

DISK_SIZE_GB="${DISK_SIZE_GB:-32}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"

NETWORK_MODE="${NETWORK_MODE:-static}"        # static | dhcp
STATIC_IP="${STATIC_IP:-10.100.10.111}"
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-10.100.10.1}"
NAMESERVER="${NAMESERVER:-10.100.10.2 10.100.10.3 1.1.1.1 8.8.8.8}"

USE_CLOUD_INIT="${USE_CLOUD_INIT:-true}"
CLONE_VLAN_ID="${CLONE_VLAN_ID:-}"

NUM_CLONES="${NUM_CLONES:-3}"
BASE_CLONE_VMID="${BASE_CLONE_VMID:-3000}"
BASE_CLONE_IP="${BASE_CLONE_IP:-$STATIC_IP}"
CLONE_MEMORY_MB="${CLONE_MEMORY_MB:-4096}"
CLONE_CORES="${CLONE_CORES:-4}"

EXTRA_DISK_COUNT="${EXTRA_DISK_COUNT:-0}"
EXTRA_DISK_SIZE_GB="${EXTRA_DISK_SIZE_GB:-10}"
EXTRA_DISK_TARGET="${EXTRA_DISK_TARGET:-}"

# =============================================================================
# AWS knobs
# =============================================================================
AWS_REGION="${AWS_REGION:-ca-central-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_INSTANCE_NAME="${AWS_INSTANCE_NAME:-k8s-node}"
AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-t2.micro}"
AWS_ARCH="${AWS_ARCH:-x86_64}"                   # x86_64 | arm64
AWS_OS_IMAGE="${AWS_OS_IMAGE:-al2023}"           # only al2023 here
AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"               # blank => use default VPC subnet
AWS_ASSOC_PUBLIC_IP="${AWS_ASSOC_PUBLIC_IP:-auto}"  # auto|true|false
AWS_SG_NAME="${AWS_SG_NAME:-${AWS_INSTANCE_NAME}-sg}"
AWS_ENABLE_SSH="${AWS_ENABLE_SSH:-true}"
AWS_OPEN_HTTP="${AWS_OPEN_HTTP:-false}"
AWS_OPEN_HTTPS="${AWS_OPEN_HTTPS:-false}"
AWS_SSH_CIDR="${AWS_SSH_CIDR:-}"                 # optional override
AWS_KEY_NAME="${AWS_KEY_NAME:-${AWS_INSTANCE_NAME}-key}"
AWS_PUBLIC_KEY_PATH="${AWS_PUBLIC_KEY_PATH:-}"    # path to .pub to import
AWS_SAVE_PEM="${AWS_SAVE_PEM:-${AWS_KEY_NAME}.pem}"
AWS_SSH_USER="${AWS_SSH_USER:-ec2-user}"
AWS_AUTO_SSH="${AWS_AUTO_SSH:-false}"
AWS_EXTRA_TAGS="${AWS_EXTRA_TAGS:-Owner=ops,Env=dev}"
AWS_KMS_KEY_ID="${AWS_KMS_KEY_ID:-}"

# =============================================================================
# Firecracker knobs
# =============================================================================
FC_ROOTFS_DIR="${FC_ROOTFS_DIR:-$BUILD_DIR/fcroot}"
FC_IMG="${FC_IMG:-$BUILD_DIR/rootfs.ext4}"
FC_IMG_SIZE_MB="${FC_IMG_SIZE_MB:-2048}"
FC_KERNEL_PKG="${FC_KERNEL_PKG:-linux-image-amd64}"
FC_VMLINUX_PATH="${FC_VMLINUX_PATH:-/boot/vmlinux-$(uname -r)}"
FC_OUTPUT_VMLINUX="${FC_OUTPUT_VMLINUX:-$BUILD_DIR/vmlinux}"
FC_RUN_SCRIPT="${FC_RUN_SCRIPT:-$BUILD_DIR/run-fc.sh}"
FC_CONFIG_JSON="${FC_CONFIG_JSON:-$BUILD_DIR/fc.json}"
FC_TAP_IF="${FC_TAP_IF:-fc-tap0}"
FC_GUEST_IP="${FC_GUEST_IP:-172.20.0.2/24}"
FC_GW_IP="${FC_GW_IP:-172.20.0.1}"

# =============================================================================
# Compute / Validate basics
# =============================================================================
VMNAME_CLEAN="${VMNAME//[_\.]/-}"
VMNAME_CLEAN="$(echo "$VMNAME_CLEAN" | sed 's/^-*//;s/-*$//;s/--*/-/g' | tr '[:upper:]' '[:lower:]')"
[[ "$VMNAME_CLEAN" =~ ^[a-z0-9-]+$ ]] || die "Invalid VM name after cleanup: '$VMNAME_CLEAN'"
VMNAME="$VMNAME_CLEAN"

case "$INPUT" in
  1|fiend)  HOST_NAME="fiend.${DOMAIN}";  PROXMOX_HOST="10.100.10.225" ;;
  2|dragon) HOST_NAME="dragon.${DOMAIN}"; PROXMOX_HOST="10.100.10.226" ;;
  3|lion)   HOST_NAME="lion.${DOMAIN}";   PROXMOX_HOST="10.100.10.227" ;;
  *)        HOST_NAME="unknown"; PROXMOX_HOST="";;
esac

BASE_FQDN="${VMNAME}.${DOMAIN}"
if [[ "$ONE_SHOT" == "true" ]]; then
  BASE_VMNAME="${BASE_FQDN}"
else
  BASE_VMNAME="${BASE_FQDN}-template"
fi

log "Target=$TARGET  PMX: $HOST_NAME ($PROXMOX_HOST)  VMID=$VMID  VMNAME=$BASE_VMNAME"
log "Storages: VM_STORAGE=$VM_STORAGE  ISO_STORAGE=$ISO_STORAGE  Disk=${DISK_SIZE_GB}G"
log "Network: $NETWORK_MODE  DOMAIN=$DOMAIN  Cloud-Init: $USE_CLOUD_INIT  Profile: $INSTALL_PROFILE"

# =============================================================================
# Helpers
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
    command -v curl >/dev/null || die "curl missing."
  fi
  if [[ "$TARGET" == "firecracker" ]]; then
    command -v debootstrap >/dev/null || die "debootstrap missing."
    command -v fallocate  >/dev/null || die "fallocate missing."
    command -v mkfs.ext4  >/dev/null || die "mkfs.ext4 missing."
    command -v rsync      >/dev/null || die "rsync missing."
  fi
}

# =============================================================================
# Build ISO payload (darksite + preseed)
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
# darksite: WireGuard, Salt, Logs (rsyslog), K8s fallback, grains
# -----------------------------------------------------------------------------
log "Writing darksite bootstrap scripts..."

# 1) WireGuard
cat > "$DARKSITE_DIR/scripts/setup_wireguard.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[WG] $(date '+%F %T') - $*"; }
[ -f /etc/environment.d/99-provision.conf ] && . /etc/environment.d/99-provision.conf
[[ "${WG_ENABLE:-true}" == "true" ]] || { log "disabled"; exit 0; }

apt-get update -y
apt-get install -y wireguard resolvconf
mkdir -p /etc/wireguard; chmod 700 /etc/wireguard

IF="${WG_INTERFACE:-wg0}"
ADDR="${WG_ADDRESS:-10.42.0.2/32}"
DNS="${WG_DNS:-1.1.1.1}"
PRIV="${WG_PRIVATE_KEY:-}"
PEER_PUB="${WG_PUBLIC_KEY_PEER:-}"
PEER_ENDPOINT="${WG_PEER_ENDPOINT:-}"
ALLOWED="${WG_ALLOWED_IPS:-0.0.0.0/0}"

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
log "WireGuard up: ${IF}"
EOS
chmod +x "$DARKSITE_DIR/scripts/setup_wireguard.sh"

# 2) rsyslog forwarding to Salt master (for central logging)
cat > "$DARKSITE_DIR/scripts/setup_logs.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[LOGFWD] $(date '+%F %T') - $*"; }
[ -f /etc/environment.d/99-provision.conf ] && . /etc/environment.d/99-provision.conf
[[ -n "${SALT_MASTER:-}" ]] || { log "No SALT_MASTER; skip syslog fwd"; exit 0; }

apt-get update -y
apt-get install -y rsyslog
cat >/etc/rsyslog.d/60-saltmaster-forward.conf <<EOF
# Forward all logs to Salt master (UDP 514)
*.*  @${SALT_MASTER}:514
EOF
systemctl enable rsyslog
systemctl restart rsyslog
log "Forwarding logs to ${SALT_MASTER}:514"
EOS
chmod +x "$DARKSITE_DIR/scripts/setup_logs.sh"

# 3) Salt Minion
cat > "$DARKSITE_DIR/scripts/setup_salt.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[SALT] $(date '+%F %T') - $*"; }
[ -f /etc/environment.d/99-provision.conf ] && . /etc/environment.d/99-provision.conf
[[ "${SALT_ENABLE:-true}" == "true" ]] || { log "disabled"; exit 0; }

apt-get update -y
apt-get install -y curl gnupg lsb-release
curl -fsSL https://repo.saltproject.io/py3/debian/latest/salt-archive-keyring.gpg -o /usr/share/keyrings/salt-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/salt-archive-keyring.gpg] http://repo.saltproject.io/py3/debian/$(. /etc/os-release; echo $VERSION_CODENAME)/amd64/latest $(. /etc/os-release; echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/salt.list
apt-get update -y
apt-get install -y salt-minion

mkdir -p /etc/salt
: "${SALT_MASTER:=salt}"
: "${SALT_MINION_ID:=}"
{
  echo "master: ${SALT_MASTER}"
  [[ -n "$SALT_MINION_ID" ]] && echo "id: ${SALT_MINION_ID}"
  echo "log_level: info"
  echo "enable_fqdns_grains: True"
} > /etc/salt/minion

# Useful grains for targeting on the master side
mkdir -p /etc/salt/grains
cat >/etc/salt/grains <<EOF
role: kubernetes
kube_role: ${KUBE_ROLE:-worker}
kube_cni: ${KUBE_CNI:-cilium}
kube_fc_mode: ${KUBE_FC_MODE:-ignite}
deploy_monitoring: ${KUBE_DEPLOY_MONITORING:-true}
deploy_demo_gameserver: ${KUBE_DEPLOY_DEMO_GAMESERVER:-true}
domain: ${DOMAIN:-localdomain}
EOF

systemctl enable salt-minion
systemctl restart salt-minion || true

# Optionally ask for immediate highstate (non-blocking)
(sleep 10; salt-call state.apply --local test=False >/var/log/salt_first_apply.log 2>&1 || true) &

log "Salt minion installed and started."
EOS
chmod +x "$DARKSITE_DIR/scripts/setup_salt.sh"

# 4) K8s fallback (runs only if Salt is unreachable or you want day-0 cluster w/o Salt)
cat > "$DARKSITE_DIR/scripts/setup_kubernetes_fallback.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[K8S-FB] $(date '+%F %T') - $*"; }
[ -f /etc/environment.d/99-provision.conf ] && . /etc/environment.d/99-provision.conf

[[ "${KUBE_ENABLE:-true}" == "true" ]] || { log "K8s disabled; exit."; exit 0; }
[[ -x /usr/bin/salt-call ]] && { log "Salt present; Salt should handle K8s. Skipping fallback."; exit 0; }

# Fallback installs containerd + kubeadm/kubelet/kubectl and performs init/join
swapoff -a || true
sed -ri 's/^\s*([^#].*\sswap\s)/# \1/' /etc/fstab || true

cat >/etc/modules-load.d/k8s.conf <<EOF
br_netfilter
overlay
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-kubernetes.conf <<EOF
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system || true

apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# containerd
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
> /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y containerd.io
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# kubeadm/kubelet/kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
> /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y "kubelet=${KUBE_VERSION:-1.30.3-00}" "kubeadm=${KUBE_VERSION:-1.30.3-00}" "kubectl=${KUBE_VERSION:-1.30.3-00}"
apt-mark hold kubelet kubeadm kubectl

if [[ "${KUBE_ROLE:-worker}" == "control-plane" ]]; then
  cat >/var/tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${KUBE_VERSION%%-*}
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT:-k8s.unixbox.net:6443}"
networking:
  podSubnet: "${POD_CIDR:-10.244.0.0/16}"
  serviceSubnet: "${SVC_CIDR:-10.96.0.0/12}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    container-runtime-endpoint: "unix:///run/containerd/containerd.sock"
EOF
  kubeadm init --config /var/tmp/kubeadm-config.yaml
  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config

  # Simple CNI: Cilium by default
  curl -fsSL https://raw.githubusercontent.com/cilium/cilium/v1.15.7/install/kubernetes/quick-install.yaml \
    | kubectl apply -f -

  # Minimal metrics-server (so HPA/dashboards work)
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml || true

else
  if [[ -n "${KUBEADM_TOKEN:-}" && -n "${KUBEADM_CA_CERT_HASH:-}" ]]; then
    kubeadm reset -f || true
    kubeadm join "${CONTROL_PLANE_ENDPOINT}" \
      --token "${KUBEADM_TOKEN}" \
      --discovery-token-ca-cert-hash "${KUBEADM_CA_CERT_HASH}" \
      --cri-socket "unix:///run/containerd/containerd.sock"
  else
    log "Join token/hash missing; skipping kubeadm join."
  fi
fi
log "Fallback K8s bring-up complete."
EOS
chmod +x "$DARKSITE_DIR/scripts/setup_kubernetes_fallback.sh"

# 5) postinstall (one-time) — runs WG, Salt, logs, K8s fallback
log "Writing postinstall.sh..."
cat > "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/postinstall.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR
log(){ echo "[POST] $(date '+%F %T') - $*"; }

# Load baked vars
[ -f /etc/environment.d/99-provision.conf ] && . /etc/environment.d/99-provision.conf

# 0) Base OS prep
export DEBIAN_FRONTEND=noninteractive
log "Switching APT to trixie channels..."
cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF
apt update
apt -y upgrade

log "Installing base packages..."
apt install -y --no-install-recommends \
  dbus polkitd pkexec curl wget ca-certificates gnupg lsb-release unzip \
  net-tools traceroute tcpdump sysstat strace lsof ltrace \
  rsync rsyslog cron chrony sudo git ethtool jq \
  qemu-guest-agent openssh-server ngrep nmap tmux htop

# 1) SSH hardening + users
USERS=("todd:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV51Eelt8PwYreHhJJ4JJP3OMwrXswUShblYY10J+A/ todd@onyx")
ALLOW_USERS=""
for e in "${USERS[@]}"; do u="${e%%:*}"; ALLOW_USERS+="$u "; done
ALLOW_USERS="${ALLOW_USERS%% }"

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

# 2) Hostname
VMNAME="$(hostname --short)"
FQDN="${VMNAME}.${DOMAIN:-localdomain}"
hostnamectl set-hostname "$FQDN"
cat >/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 ${FQDN} ${VMNAME}
EOF

# 3) Optional: WireGuard + Log forwarding + Salt
/usr/local/bin/setup_wireguard.sh || true
/usr/local/bin/setup_logs.sh || true
/usr/local/bin/setup_salt.sh || true

# 4) Kubernetes fallback (only if Salt is unavailable)
/usr/local/bin/setup_kubernetes_fallback.sh || true

# 5) Clean identity for templating reuse
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_* || true
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server

# 6) Housekeeping
apt autoremove -y || true
apt clean || true
find /var/log -type f -exec truncate -s 0 {} \; || true

log "Disabling bootstrap service..."
systemctl disable bootstrap.service || true
rm -f /etc/systemd/system/bootstrap.service
rm -f /etc/systemd/system/multi-user.target.wants/bootstrap.service

log "Postinstall complete. Powering off..."
/sbin/poweroff -f
EOSCRIPT
chmod +x "$DARKSITE_DIR/postinstall.sh"

# 6) bootstrap.service (one-time)
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

# 7) Bake env for bootstrap (all knobs Salt needs + target info as grains seeds)
cat > "$DARKSITE_DIR/99-provision.conf" <<EOF
DOMAIN=$DOMAIN
USE_CLOUD_INIT=$USE_CLOUD_INIT
INSTALL_PROFILE=$INSTALL_PROFILE
WG_ENABLE=$WG_ENABLE
SALT_ENABLE=$SALT_ENABLE
SALT_MASTER=$SALT_MASTER
SALT_MINION_ID=$SALT_MINION_ID
WG_INTERFACE=$WG_INTERFACE
WG_ADDRESS=$WG_ADDRESS
WG_DNS=$WG_DNS
WG_PRIVATE_KEY=$WG_PRIVATE_KEY
WG_PUBLIC_KEY_PEER=$WG_PUBLIC_KEY_PEER
WG_PEER_ENDPOINT=$WG_PEER_ENDPOINT
WG_ALLOWED_IPS=$WG_ALLOWED_IPS

# K8s intent (grains)
KUBE_ENABLE=$KUBE_ENABLE
KUBE_ROLE=$KUBE_ROLE
KUBE_VERSION=$KUBE_VERSION
KUBE_CNI=$KUBE_CNI
KUBE_FC_MODE=$KUBE_FC_MODE
CONTROL_PLANE_ENDPOINT=$CONTROL_PLANE_ENDPOINT
POD_CIDR=$POD_CIDR
SVC_CIDR=$SVC_CIDR
KUBEADM_TOKEN=$KUBEADM_TOKEN
KUBEADM_CA_CERT_HASH=$KUBEADM_CA_CERT_HASH
KUBE_DEPLOY_MONITORING=$KUBE_DEPLOY_MONITORING
KUBE_DEPLOY_DEMO_GAMESERVER=$KUBE_DEPLOY_DEMO_GAMESERVER
EOF

# 8) finalize-template.sh (Proxmox clone fanout)
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

# -----------------------------------------------------------------------------
# Preseed (network + profile + darksite late_command)
# -----------------------------------------------------------------------------
log "Creating preseed.cfg..."
if [[ "$NETWORK_MODE" == "dhcp" ]]; then
  NETBLOCK=$(cat <<EOF
# DHCP
d-i netcfg/choose_interface select auto
d-i netcfg/disable_dhcp boolean false
d-i netcfg/get_hostname string $VMNAME
d-i netcfg/get_domain string $DOMAIN
EOF
)
else
  NETBLOCK=$(cat <<EOF
# Static
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
  server)     PROFILEBLOCK=$(cat <<'EOF'
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
) ;;
  gnome-min)  PROFILEBLOCK=$(cat <<'EOF'
tasksel tasksel/first multiselect standard
d-i pkgsel/include string gnome-core gdm3 gnome-terminal network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
) ;;
  gnome-full) PROFILEBLOCK=$(cat <<'EOF'
tasksel tasksel/first multiselect standard, desktop, gnome-desktop, ssh-server
d-i pkgsel/ignore-recommends boolean false
d-i pkgsel/upgrade select none
EOF
) ;;
  xfce-min)   PROFILEBLOCK=$(cat <<'EOF'
tasksel tasksel/first multiselect standard
d-i pkgsel/include string xfce4 xfce4-terminal lightdm xorg network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
) ;;
  kde-min)    PROFILEBLOCK=$(cat <<'EOF'
tasksel tasksel/first multiselect standard
d-i pkgsel/include string plasma-desktop sddm plasma-workspace-wayland kwin-wayland konsole network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
) ;;
  *) die "Unknown INSTALL_PROFILE: $INSTALL_PROFILE" ;;
esac

cat > "$CUSTOM_DIR/$PRESEED_FILE" <<EOF
# Locale & keyboard
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us

$NETBLOCK

# Mirrors
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i apt-setup/use_mirror boolean false
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

# Temporary user
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

# Disk (guided LVM)
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

# Late command: copy darksite and enable bootstrap
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

d-i finish-install/exit-installer boolean true
d-i debian-installer/exit/poweroff boolean true
EOF

# -----------------------------------------------------------------------------
# Boot menu & ISO rebuild
# -----------------------------------------------------------------------------
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
  # ======================== Proxmox path ==========================
  [[ -n "$PROXMOX_HOST" ]] || die "No PROXMOX_HOST defined."
  [[ "$ONE_SHOT" == "true" ]] && log "Proxmox ONE_SHOT mode enabled (no template/clone)."

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

  # Description text depends on ONE_SHOT and IP mode
  if [[ "$NETWORK_MODE" == "static" ]]; then
    DESC_SUFFIX="${STATIC_IP}"
  else
    DESC_SUFFIX="DHCP"
  fi
  if [[ "$ONE_SHOT" == "true" ]]; then
    BASE_DESC="${BASE_FQDN} - ${DESC_SUFFIX}"
  else
    BASE_DESC="${BASE_FQDN}-template - ${DESC_SUFFIX}"
  fi

  log "Detach ISO; set boot=scsi0; cloudinit if enabled..."
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

  # ONE_SHOT -> start the installed VM and exit; no template or clones
  if [[ "$ONE_SHOT" == "true" ]]; then
    log "ONE_SHOT=true -> starting single VM and finishing (no template/clone)."
    ssh root@"$PROXMOX_HOST" "qm start $VMID"
    log "One-shot VM started: $BASE_FQDN (VMID $VMID)."
    log "All done (Proxmox one-shot)."
  else
    # Convert to template & optionally clone
    if [[ "${TEMPLATE_ONLY}" == "true" ]]; then
      log "Converting to template only (no clones)..."
      ssh root@"$PROXMOX_HOST" "qm template $VMID"
    else
      log "Template + clone loop..."
      export PROXMOX_HOST TEMPLATE_VMID="$VMID" VM_STORAGE USE_CLOUD_INIT DOMAIN
      export NUM_CLONES BASE_CLONE_VMID BASE_CLONE_IP CLONE_MEMORY_MB CLONE_CORES
      export CLONE_VLAN_ID CLONE_GATEWAY="$GATEWAY" CLONE_NAMESERVER="$NAMESERVER"
      export VMNAME_CLEAN="$VMNAME" EXTRA_DISK_COUNT EXTRA_DISK_SIZE_GB EXTRA_DISK_TARGET
      bash "$DARKSITE_DIR/finalize-template.sh"
    fi
    log "All done (Proxmox)."
  fi

elif [[ "$TARGET" == "aws" ]]; then
  # =============================== AWS path ==============================
  log "Launching AWS instance..."
  aws_cli sts get-caller-identity >/dev/null || die "AWS identity failure."

  vpc_id="$(aws_cli ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  [[ -n "$AWS_SUBNET_ID" ]] || AWS_SUBNET_ID="$(aws_cli ec2 describe-subnets --filters Name=vpc-id,Values="$vpc_id" --query 'Subnets[0].SubnetId' --output text)"

  sg_id="$(aws_cli ec2 describe-security-groups --filters Name=group-name,Values="$AWS_SG_NAME" Name=vpc-id,Values="$vpc_id" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(aws_cli ec2 create-security-group --vpc-id "$vpc_id" --group-name "$AWS_SG_NAME" --description "SG for $AWS_INSTANCE_NAME" --query 'GroupId' --output text)"
    aws_cli ec2 create-tags --resources "$sg_id" --tags Key=Name,Value="$AWS_SG_NAME"
  fi

  myip="$(curl -fsSL https://checkip.amazonaws.com || true)"; myip="${myip//$'\n'/}"
  if [[ "$AWS_ENABLE_SSH" == "true" ]]; then
    cidr="${AWS_SSH_CIDR:-${myip}/32}"
    aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" \
      --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=\"${cidr}\"}]" >/dev/null 2>&1 || true
  fi
  [[ "$AWS_OPEN_HTTP" == "true"  && -n "$myip" ]] && aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=\"${myip}/32\"}]" >/dev/null 2>&1 || true
  [[ "$AWS_OPEN_HTTPS" == "true" && -n "$myip" ]] && aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=\"${myip}/32\"}]" >/dev/null 2>&1 || true

  if [[ -n "$AWS_PUBLIC_KEY_PATH" && -r "$AWS_PUBLIC_KEY_PATH" ]]; then
    exists="$(aws_cli ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")"
    [[ "$exists" == "$AWS_KEY_NAME" ]] || aws_cli ec2 import-key-pair --key-name "$AWS_KEY_NAME" --public-key-material "fileb://$AWS_PUBLIC_KEY_PATH" >/dev/null
    PEM_PATH=""
  else
    exists="$(aws_cli ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")"
    if [[ "$exists" != "$AWS_KEY_NAME" ]]; then
      aws_cli ec2 create-key-pair --key-name "$AWS_KEY_NAME" --key-type rsa --key-format pem --query 'KeyMaterial' --output text > "$AWS_SAVE_PEM"
      chmod 600 "$AWS_SAVE_PEM"
      PEM_PATH="$AWS_SAVE_PEM"
    else
      PEM_PATH=""
    fi
  fi

  # Resolve AMI
  if [[ "$AWS_OS_IMAGE" == "al2023" ]]; then
    if [[ "$AWS_ARCH" == "arm64" ]]; then
      ami_param="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
    else
      ami_param="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
    fi
  else
    die "Unsupported AWS OS_IMAGE '$AWS_OS_IMAGE'"
  fi
  ami_id="$(aws_cli ssm get-parameter --name "$ami_param" --query 'Parameter.Value' --output text)"

  # User data: install salt-minion + grains + (optional) wireguard + rsyslog
  read -r -d '' USERDATA <<'EOCLOUD'
#!/bin/bash
set -euo pipefail
SALT_MASTER="${SALT_MASTER}"
SALT_MINION_ID="${SALT_MINION_ID}"
KUBE_ROLE="${KUBE_ROLE}"
KUBE_CNI="${KUBE_CNI}"
KUBE_FC_MODE="${KUBE_FC_MODE}"
WG_ENABLE="${WG_ENABLE}"
WG_INTERFACE="${WG_INTERFACE}"
WG_ADDRESS="${WG_ADDRESS}"
WG_DNS="${WG_DNS}"
WG_PRIVATE_KEY="${WG_PRIVATE_KEY}"
WG_PUBLIC_KEY_PEER="${WG_PUBLIC_KEY_PEER}"
WG_PEER_ENDPOINT="${WG_PEER_ENDPOINT}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS}"

dnf -y update || true
dnf -y install curl jq rsyslog || true
systemctl enable --now rsyslog || true

# forward logs to salt master if resolvable
if [[ -n "$SALT_MASTER" ]]; then
  echo "*.*  @${SALT_MASTER}:514" >/etc/rsyslog.d/60-saltmaster-forward.conf
  systemctl restart rsyslog || true
fi

# Install salt minion (py3 pip is fine on AL2023)
dnf -y install python3-pip || true
python3 -m pip install --upgrade pip
python3 -m pip install "salt==3007.*" || true

mkdir -p /etc/salt
echo "master: ${SALT_MASTER}" > /etc/salt/minion
[[ -n "$SALT_MINION_ID" ]] && echo "id: ${SALT_MINION_ID}" >> /etc/salt/minion

mkdir -p /etc/salt/grains
cat >/etc/salt/grains <<EOF
role: kubernetes
kube_role: ${KUBE_ROLE}
kube_cni: ${KUBE_CNI}
kube_fc_mode: ${KUBE_FC_MODE}
deploy_monitoring: ${KUBE_DEPLOY_MONITORING}
deploy_demo_gameserver: ${KUBE_DEPLOY_DEMO_GAMESERVER}
EOF

# start salt-minion as a simple service (systemd unit via pip is messy; we spawn)
nohup sh -c 'while true; do salt-minion -l info; sleep 5; done' >/var/log/salt-minion.out 2>&1 &

# Optional WG quick setup
if [[ "$WG_ENABLE" == "true" ]]; then
  dnf -y install wireguard-tools || true
  mkdir -p /etc/wireguard; chmod 700 /etc/wireguard
  IF="$WG_INTERFACE"; ADDR="$WG_ADDRESS"; DNS="$WG_DNS"; PRIV="$WG_PRIVATE_KEY"
  PEER_PUB="$WG_PUBLIC_KEY_PEER"; PEER_ENDPOINT="$WG_PEER_ENDPOINT"; ALLOWED="$WG_ALLOWED_IPS"
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
  systemctl enable wg-quick@${IF}; systemctl restart wg-quick@${IF} || true
fi
EOCLOUD

  # EBS config
  if [[ -n "$AWS_KMS_KEY_ID" ]]; then
    kms_json="\"Encrypted\":true,\"KmsKeyId\":\"${AWS_KMS_KEY_ID}\""
  else
    kms_json="\"Encrypted\":true"
  fi
  bdm="[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",${kms_json}}}]"

  # NI config
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
    [[ -r "$AWS_SAVE_PEM" ]] && keyarg=(-i "$AWS_SAVE_PEM")
    log "SSH -> ${AWS_SSH_USER}@${pub_ip}"
    exec ssh -o StrictHostKeyChecking=accept-new "${keyarg[@]}" "${AWS_SSH_USER}@${pub_ip}"
  fi

  log "All done (AWS)."

elif [[ "$TARGET" == "firecracker" ]]; then
  # ============================ Firecracker path ==============================
  log "Building Firecracker rootfs (Debian trixie, minimal + salt + rsyslog + wg)..."
  rm -rf "$FC_ROOTFS_DIR"
  mkdir -p "$FC_ROOTFS_DIR"
  debootstrap --variant=minbase trixie "$FC_ROOTFS_DIR" http://deb.debian.org/debian

  # seed 99-provision + scripts into rootfs and enable a firstboot unit that runs salt + fallback
  cp -a "$DARKSITE_DIR" "$FC_ROOTFS_DIR/root/darksite"
  mkdir -p "$FC_ROOTFS_DIR/etc/environment.d"
  cp -a "$DARKSITE_DIR/99-provision.conf" "$FC_ROOTFS_DIR/etc/environment.d/99-provision.conf"

  chroot "$FC_ROOTFS_DIR" bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends systemd-sysv ca-certificates curl wget iproute2 iputils-ping \
      openssh-server net-tools resolvconf gnupg lsb-release nano vim rsyslog
    systemctl enable ssh rsyslog

    # Firstboot service -> executes darksite bootstrap (Salt + WG + logs + fallback K8s)
    cat >/etc/systemd/system/fc-firstboot.service <<EOF
[Unit]
Description=Firecracker first boot bootstrap
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc "/root/darksite/postinstall.sh || true"

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable fc-firstboot.service
  '

  # Assemble ext4 image
  log "Assembling ext4 image..."
  fallocate -l "${FC_IMG_SIZE_MB}M" "$FC_IMG"
  mkfs.ext4 -F "$FC_IMG"
  mkdir -p "$BUILD_DIR/mntimg"
  mount -o loop "$FC_IMG" "$BUILD_DIR/mntimg"
  rsync -aHAX --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp --exclude=/run "$FC_ROOTFS_DIR"/ "$BUILD_DIR/mntimg"/
  mkdir -p "$BUILD_DIR/mntimg"/{proc,sys,dev,run,tmp}
  chmod 1777 "$BUILD_DIR/mntimg/tmp"
  umount "$BUILD_DIR/mntimg"

  # Kernel
  if [[ -f "$FC_VMLINUX_PATH" ]]; then
    cp -f "$FC_VMLINUX_PATH" "$FC_OUTPUT_VMLINUX"
  else
    vmlin="$(find /boot -maxdepth 1 -type f -name "vmlinux-*" | head -n1 || true)"
    [[ -n "$vmlin" ]] && cp -f "$vmlin" "$FC_OUTPUT_VMLINUX" || die "No vmlinux found; set FC_VMLINUX_PATH"
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
FC_BIN="${FC_BIN:-/usr/local/bin/firecracker}"
CFG="${CFG:-__CFG__}"
TAP="__TAP__"
GW="__GW__"

if ! ip link show "$TAP" >/dev/null 2>&1; then
  sudo ip tuntap add dev "$TAP" mode tap
  sudo ip addr add "$GW" dev "$TAP"
  sudo ip link set "$TAP" up
fi

$FC_BIN --no-api --config-file "$CFG" --seccomp-level=0
EOS
  sed -i "s|__CFG__|$(realpath "$FC_CONFIG_JSON")|g" "$FC_RUN_SCRIPT"
  sed -i "s|__TAP__|$FC_TAP_IF|g" "$FC_RUN_SCRIPT"
  sed -i "s|__GW__|$FC_GW_IP|g" "$FC_RUN_SCRIPT"
  chmod +x "$FC_RUN_SCRIPT"

  log "Firecracker outputs:"
  log " - Kernel : $FC_OUTPUT_VMLINUX"
  log " - Rootfs : $FC_IMG"
  log " - Config : $FC_CONFIG_JSON"
  log " - Runner : $FC_RUN_SCRIPT"
  log "All done (Firecracker)."

else
  die "Unknown TARGET='$TARGET' (use proxmox|aws|firecracker)"
fi
