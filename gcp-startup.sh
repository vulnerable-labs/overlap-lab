#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/overlap-startup.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

export DEBIAN_FRONTEND=noninteractive

# Override these with instance metadata if needed.
REPO_URL="${REPO_URL:-https://github.com/vulnerable-labs/overlap-lab.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/overlap-lab}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-overlap-prod}"

# Helper to read instance metadata attributes (returns empty string on failure)
get_metadata() {
  local key="$1"
  curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" || true
}

# Apply metadata overrides if present (metadata keys: REPO_URL, REPO_BRANCH, APP_DIR, HOSTNAME_VALUE, LAB_MODE, DEV_PORTAL_TOKEN, SECRET_KEY, IMAGE_BUILD)
meta_val=""
meta_val="$(get_metadata "REPO_URL")" && [[ -n "${meta_val}" ]] && REPO_URL="${meta_val}"
meta_val="$(get_metadata "REPO_BRANCH")" && [[ -n "${meta_val}" ]] && REPO_BRANCH="${meta_val}"
meta_val="$(get_metadata "APP_DIR")" && [[ -n "${meta_val}" ]] && APP_DIR="${meta_val}"
meta_val="$(get_metadata "HOSTNAME_VALUE")" && [[ -n "${meta_val}" ]] && HOSTNAME_VALUE="${meta_val}"
meta_val="$(get_metadata "LAB_MODE")" && [[ -n "${meta_val}" ]] && export LAB_MODE="${meta_val}"
meta_val="$(get_metadata "DEV_PORTAL_TOKEN")" && [[ -n "${meta_val}" ]] && export DEV_PORTAL_TOKEN="${meta_val}"
meta_val="$(get_metadata "SECRET_KEY")" && [[ -n "${meta_val}" ]] && export SECRET_KEY="${meta_val}"
meta_val="$(get_metadata "IMAGE_BUILD")" && [[ -n "${meta_val}" ]] && export IMAGE_BUILD="${meta_val}"

log() {
  echo "[$(date -Is)] $*"
}

retry() {
  local attempts="$1"
  shift
  local delay=3
  local count=1

  until "$@"; do
    if [[ "${count}" -ge "${attempts}" ]]; then
      return 1
    fi
    log "Retry ${count}/${attempts} failed: $*"
    count=$((count + 1))
    sleep "${delay}"
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "This script must run as root."
    exit 1
  fi
}

wait_for_docker() {
  for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  docker info >/dev/null 2>&1
}

require_root

log "Updating package indexes..."
retry 5 apt-get update -y

log "Installing base dependencies..."
apt-get install -y ca-certificates curl gnupg lsb-release git python3

log "Adding Docker's official apt repository..."
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo \"${VERSION_CODENAME}\") stable" \
  > /etc/apt/sources.list.d/docker.list

retry 5 apt-get update -y

log "Installing Docker Engine and Compose plugin..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Enabling and starting Docker..."
systemctl enable --now docker
wait_for_docker

log "Setting hostname to ${HOSTNAME_VALUE}..."
hostnamectl set-hostname "${HOSTNAME_VALUE}" || true

log "Preparing application directory at ${APP_DIR}..."
mkdir -p "$(dirname "${APP_DIR}")"

if [[ -d "${APP_DIR}/.git" ]]; then
  log "Existing repository detected, refreshing origin..."
  git -C "${APP_DIR}" remote set-url origin "${REPO_URL}" || true
  retry 3 git -C "${APP_DIR}" fetch --prune origin
  git -C "${APP_DIR}" checkout -B "${REPO_BRANCH}" "origin/${REPO_BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${REPO_BRANCH}"
else
  log "Cloning repository from ${REPO_URL}..."
  rm -rf "${APP_DIR}"
  retry 3 git clone --branch "${REPO_BRANCH}" --single-branch "${REPO_URL}" "${APP_DIR}"
fi

# If building a golden image, prepare a first-boot service that will generate
# runtime-unique secrets on first boot. This avoids baking secrets into the image.
if [[ "${IMAGE_BUILD:-0}" == "1" ]]; then
  log "Preparing image-firstboot service for first-boot initialization..."

  cat > /usr/local/bin/overlap-firstboot.sh <<'EOF'
#!/bin/bash
set -euo pipefail

LOG_FILE=/var/log/overlap-firstboot.log
exec > >(tee -a "${LOG_FILE}") 2>&1

# If already initialized, exit (idempotent across reboots)
if [[ -f /var/lib/overlap/initialized ]]; then
  exit 0
fi

# Wait for docker to be ready
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

APP_DIR="${APP_DIR}"
DEV_TOKEN="S3cur3_Dev_$(head -c6 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c6)"
PHASE1_FLAG="VulnOS_$(uuidgen | tr -d '-')"
PHASE2_FLAG="VulnOS_$(uuidgen | tr -d '-')"
SECRET_KEY="$(head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

mkdir -p "${APP_DIR}/app/static"
mkdir -p "${APP_DIR}/app/flags"

cat > "${APP_DIR}/app/static/.env.bak" <<EO2
# auto-generated at first boot
DEV_PORTAL_TOKEN=${DEV_TOKEN}
PHASE1_FLAG=${PHASE1_FLAG}
EO2

printf "%s\n" "${PHASE2_FLAG}" > "${APP_DIR}/app/flags/phase2.txt"

export DEV_PORTAL_TOKEN="${DEV_TOKEN}"
export SECRET_KEY="${SECRET_KEY}"
export LAB_MODE="${LAB_MODE:-secure}"

cd "${APP_DIR}"
docker compose up -d --build

# mark as initialized so this script only runs once
mkdir -p /var/lib/overlap
touch /var/lib/overlap/initialized
EOF

  chmod +x /usr/local/bin/overlap-firstboot.sh
  # Replace the literal ${APP_DIR} placeholder in the first-boot script with the real path
  sed -i "s|\${APP_DIR}|${APP_DIR}|g" /usr/local/bin/overlap-firstboot.sh

  cat > /etc/systemd/system/overlap-firstboot.service <<'EOF'
[Unit]
Description=Overlap first-boot initialization
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/overlap-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable overlap-firstboot.service

  # Remove any runtime artifacts created during image build to avoid leaking secrets
  rm -f "${APP_DIR}/app/static/.env.bak" || true
  rm -f "${APP_DIR}/app/flags/phase2.txt" || true

  # Reduce image size
  apt-get clean
  rm -rf /var/lib/apt/lists/*

  log "Image build prep complete. The image will initialize on first boot."
  exit 0
fi

# --- Seed runtime secrets and flags (do not commit secrets to VCS) ---
log "Generating runtime secrets and flags..."
DEV_TOKEN="S3cur3_Dev_$(head -c6 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c6)"
PHASE1_FLAG="VulnOS_$(uuidgen | tr -d '-')"
PHASE2_FLAG="VulnOS_$(uuidgen | tr -d '-')"
SECRET_KEY="$(head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

mkdir -p "${APP_DIR}/app/static"
mkdir -p "${APP_DIR}/app/flags"

cat > "${APP_DIR}/app/static/.env.bak" <<EOF
# auto-generated at startup — do not store real secrets in VCS
DEV_PORTAL_TOKEN=${DEV_TOKEN}
PHASE1_FLAG=${PHASE1_FLAG}
EOF

printf "%s\n" "${PHASE2_FLAG}" > "${APP_DIR}/app/flags/phase2.txt"

# Export values so docker compose picks them up from the environment
export DEV_PORTAL_TOKEN="${DEV_TOKEN}"
export SECRET_KEY="${SECRET_KEY}"
# default to secure mode; set LAB_MODE=vulnerable in instance metadata only in isolated labs
export LAB_MODE="${LAB_MODE:-secure}"

log "Wrote runtime artifacts: .env.bak and phase2 flag."

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  log "Docker Compose is not available after installation."
  exit 1
fi

log "Starting the lab stack..."
cd "${APP_DIR}"
"${COMPOSE[@]}" up -d --build

log "Startup complete."