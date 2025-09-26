#!/usr/bin/env bash
# demo_install.sh — One‑shot installer for the ca-central-1 demo
# Ubuntu/Debian aware + Terraform auto-fix + safe conditionals (no `&&` with `set -e`).
#
set -Eeuo pipefail

REGION="ca-central-1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$SCRIPT_DIR"
APP_DIR="$ROOT_DIR/app"
DOCKER_DIR="$ROOT_DIR/docker"
K8S_DIR="$ROOT_DIR/k8s/$REGION"
TF_DIR="$ROOT_DIR/infra/terraform/$REGION"

DO_INSTALL=0
DO_TERRAFORM=0
DO_PUSH=0
DO_K8S=0
DO_CLEAN=0
RUN_ALL=0
AUTO_YES=0

IMAGE_LOCAL="demo/app:latest"
ECR_IMAGE=""
ECR_URL=""
S3_BUCKET=""

log() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }
trap 'err "An error occurred on line $LINENO. Exiting." ' ERR

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency '$1'"; }

sudo_if_needed() { if [[ $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi; }

confirm() {
  local prompt="$1"
  if [[ $AUTO_YES -eq 1 ]]; then return 0; fi
  read -rp "$prompt [y/N]: " ans || true
  [[ "${ans:-n}" =~ ^[Yy](es)?$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-prereqs) DO_INSTALL=1 ;;
      --terraform) DO_TERRAFORM=1 ;;
      --push) DO_PUSH=1 ;;
      --k8s) DO_K8S=1 ;;
      --region) REGION="${2:-$REGION}"; shift ;;
      --all) RUN_ALL=1 ;;
      --clean) DO_CLEAN=1 ;;
      -y|--yes) AUTO_YES=1 ;;
      -h|--help) sed -n '1,160p' "$0"; exit 0;;
      *) warn "Unknown arg: $1" ;;
    esac; shift
  done
  if [[ $RUN_ALL -eq 1 ]]; then DO_INSTALL=1; DO_TERRAFORM=1; DO_PUSH=1; DO_K8S=1; fi
}

ensure_layout() {
  [[ -d "$APP_DIR" ]] || die "App dir not found: $APP_DIR"
  [[ -d "$DOCKER_DIR" ]] || die "Docker dir not found: $DOCKER_DIR"
  [[ -d "$TF_DIR" ]] || warn "Terraform dir not found: $TF_DIR (skip --terraform)"
  [[ -d "$K8S_DIR" ]] || warn "K8s dir not found: $K8S_DIR (skip --k8s)"
}

detect_distro() {
  if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
  DIST_ID="${ID:-ubuntu}"; DIST_CODENAME="${VERSION_CODENAME:-noble}"
  echo "$DIST_ID" "$DIST_CODENAME"
}

install_terraform_direct() {
  ver="$(curl -fsSL https://releases.hashicorp.com/terraform/ | grep -oP 'terraform/\K[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [[ -n "$ver" ]] || ver="1.9.5"
  log "Installing Terraform $ver (direct binary)"
  tmpdir="$(mktemp -d)"; pushd "$tmpdir" >/dev/null
  url="https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_amd64.zip"
  curl -fsSLO "$url"
  unzip -q "terraform_${ver}_linux_amd64.zip"
  sudo_if_needed install -m 0755 terraform /usr/local/bin/terraform
  popd >/dev/null; rm -rf "$tmpdir"
  terraform -version || true
}

install_prereqs() {
  read DIST_ID DIST_CODENAME < <(detect_distro)
  log "Installing prerequisites for ${DIST_ID^} (${DIST_CODENAME})"
  sudo_if_needed apt-get update -y
  sudo_if_needed apt-get install -y ca-certificates curl gnupg lsb-release unzip jq git wget software-properties-common

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker via get.docker.com"
    curl -fsSL https://get.docker.com | sudo_if_needed sh
  else
    log "Docker already installed"
  fi
  sudo_if_needed systemctl enable docker || true
  sudo_if_needed systemctl start docker || true

  # Terraform: try apt for supported, else direct
  SUPPORTED_CODENAMES="bookworm bullseye jammy focal noble"
  if ! command -v terraform >/dev/null 2>&1; then
    if echo "$SUPPORTED_CODENAMES" | grep -qw "$DIST_CODENAME"; then
      log "Trying HashiCorp apt for ${DIST_ID}/${DIST_CODENAME}"
      set +e
      curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo_if_needed gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${DIST_ID} ${DIST_CODENAME} main" | sudo_if_needed tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
      sudo_if_needed apt-get update -y
      sudo_if_needed apt-get install -y terraform
      rc=$?
      set -e
      if [[ $rc -ne 0 ]]; then
        warn "HashiCorp apt failed; removing and installing direct binary."
        sudo_if_needed rm -f /etc/apt/sources.list.d/hashicorp.list || true
        install_terraform_direct
      else
        log "Terraform installed via apt."
      fi
    else
      warn "Codename ${DIST_CODENAME} not supported by HashiCorp apt; installing direct binary."
      install_terraform_direct
    fi
  else
    log "Terraform already installed"
  fi

  # AWS CLI v2
  if ! command -v aws >/dev/null 2>&1; then
    log "Installing AWS CLI v2"
    tmpdir="$(mktemp -d)"; pushd "$tmpdir" >/dev/null
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo_if_needed ./aws/install
    popd >/dev/null; rm -rf "$tmpdir"
  else
    log "AWS CLI already installed"
  fi

  # kubectl
  if ! command -v kubectl >/dev/null 2>&1; then
    log "Installing kubectl (stable)"
    KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt || echo v1.30.0)"
    curl -fsSLo kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
    sudo_if_needed install -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
  else
    log "kubectl already installed"
  fi

  # Add current user to docker group if not root
  if [[ $EUID -ne 0 ]] && ! groups "$USER" | grep -q docker; then
    warn "Adding $USER to docker group (re-login may be required)"
    sudo_if_needed usermod -aG docker "$USER" || true
  fi

  log "Prerequisites installed."
}

tf_autofix_required_providers() {
  if [[ ! -d "$TF_DIR" ]]; then return 0; fi
  local versions="$TF_DIR/versions.tf"
  local providers="$TF_DIR/providers.tf"
  if [[ -f "$versions" && -f "$providers" ]]; then
    log "Auto-fixing Terraform required_providers (if needed)"
    [[ -f "$versions.bak" ]] || cp -a "$versions" "$versions.bak" || true
    [[ -f "$providers.bak" ]] || cp -a "$providers" "$providers.bak" || true
    cat >"$versions" <<'EOF'
terraform {
  required_version = ">= 1.5.0"
}
EOF
    cat >"$providers" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}
EOF
    log "Terraform files rewritten (versions.tf/providers.tf)."
  fi
}

docker_stack_recreate() {
  need docker
  log "Building local app image: $IMAGE_LOCAL"
  docker build -t "$IMAGE_LOCAL" "$APP_DIR"

  log "Bringing stack down (remove orphans & volumes)"
  (cd "$DOCKER_DIR" && docker compose down -v --remove-orphans || true)

  log "Starting stack with --force-recreate and --build"
  (cd "$DOCKER_DIR" && docker compose up -d --build --force-recreate)

  log "Compose services:"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  log "Endpoints:"
  log "  App:        http://localhost:8000"
  log "  Prometheus: http://localhost:9090"
  log "  Grafana:    http://localhost:3000 (admin/admin)"
}

terraform_apply() {
  if [[ ! -d "$TF_DIR" ]]; then warn "TF dir not found; skipping terraform"; return; fi
  need terraform; need aws
  tf_autofix_required_providers
  log "Terraform apply in $TF_DIR (region=$REGION)"
  pushd "$TF_DIR" >/dev/null
  terraform init -upgrade
  terraform apply -auto-approve -var="region=$REGION"
  ECR_URL="$(terraform output -raw ecr_repository_url 2>/dev/null || true)"
  S3_BUCKET="$(terraform output -raw artifacts_bucket 2>/dev/null || true)"
  popd >/dev/null
  if [[ -n "$ECR_URL" ]]; then log "ECR repo: $ECR_URL"; else warn "ECR output not found"; fi
  if [[ -n "$S3_BUCKET" ]]; then log "Artifacts bucket: $S3_BUCKET"; else warn "S3 output not found"; fi
}

ecr_push() {
  if [[ -z "$ECR_URL" ]]; then warn "No ECR repo URL from terraform outputs; skipping push"; return; fi
  need aws; need docker
  local registry="${ECR_URL%/*}"
  local repo="${ECR_URL##*/}"
  local tag="$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
  local full="${registry}/${repo}:${tag}"
  log "Login to ECR: $registry"
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry"
  log "Tag & push $full"
  docker tag "$IMAGE_LOCAL" "$full"
  docker push "$full"
  ECR_IMAGE="$full"
  log "Pushed image: $ECR_IMAGE"
}

k8s_apply() {
  if [[ ! -d "$K8S_DIR" ]]; then warn "K8s manifests missing; skipping --k8s"; return; fi
  need kubectl
  log "Applying Kubernetes namespace/deployment/service"
  kubectl apply -f "$K8S_DIR/namespace.yaml"
  local manifest="$K8S_DIR/deployment.yaml"
  if [[ -n "$ECR_IMAGE" ]]; then
    log "Rendering deployment with ECR image: $ECR_IMAGE"
    tmp="$(mktemp)"
    sed "s|image: demo/app:latest|image: ${ECR_IMAGE}|g" "$manifest" > "$tmp"
    kubectl apply -f "$tmp"; rm -f "$tmp"
  else
    kubectl apply -f "$manifest"
  fi
  kubectl apply -f "$K8S_DIR/service.yaml"
  log "Try: kubectl -n demo port-forward svc/demo-app 8000:8000"
}

terraform_destroy() {
  if [[ ! -d "$TF_DIR" ]]; then warn "TF dir not found; skipping destroy"; return; fi
  need terraform; need aws
  if confirm "Terraform destroy all infra in $REGION?"; then
    log "Destroying terraform stack"
    pushd "$TF_DIR" >/dev/null
    terraform destroy -auto-approve -var="region=$REGION"
    popd >/dev/null
  else
    warn "Skipped terraform destroy"
  fi
}

cleanup_all() {
  warn "Cleanup requested"
  if [[ -d "$DOCKER_DIR" ]]; then
    log "Compose down -v (remove volumes)"
    (cd "$DOCKER_DIR" && docker compose down -v --remove-orphans || true)
  fi
  if [[ -d "$TF_DIR" ]]; then
    terraform_destroy
  fi
  log "Cleanup completed."
}

main() {
  parse_args "$@"
  ensure_layout

  if [[ $DO_CLEAN -eq 1 ]]; then cleanup_all; exit 0; fi
  if [[ $DO_INSTALL -eq 1 ]]; then install_prereqs; fi

  docker_stack_recreate

  if [[ $DO_TERRAFORM -eq 1 ]]; then
    terraform_apply
    if [[ $DO_PUSH -eq 1 ]]; then ecr_push; fi
  fi

  if [[ $DO_K8S -eq 1 ]]; then k8s_apply; fi

  log "All done."
  if [[ -n "$ECR_URL" || -n "$S3_BUCKET" ]]; then
    printf "Outputs:\n"
    if [[ -n "$ECR_URL" ]]; then printf "  - ECR: %s\n" "$ECR_URL"; fi
    if [[ -n "$S3_BUCKET" ]]; then printf "  - S3 : %s\n" "$S3_BUCKET"; fi
  fi
  if [[ -n "$ECR_IMAGE" ]]; then log "Deployed image: $ECR_IMAGE"; fi
}

main "$@"
