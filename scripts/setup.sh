#!/usr/bin/env bash
# =============================================================================
# Superbox — First-Run Setup Script
# Generates secrets, creates data directories, and prepares the environment.
# Run once before `make up`. Safe to re-run (existing secrets are preserved).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN] ${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section(){ echo -e "\n${BOLD}${CYAN}$*${NC}"; }

# ---------------------------------------------------------------------------
# 1. Pre-flight checks — detect missing tools and offer to install them
# ---------------------------------------------------------------------------
section "=== Pre-flight checks ==="

# Detect OS and package manager
detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  elif command -v uname >/dev/null 2>&1; then
    OS_ID="$(uname -s | tr '[:upper:]' '[:lower:]')"
    OS_LIKE=""
  else
    OS_ID="unknown"
    OS_LIKE=""
  fi
}

# Prompt the user yes/no; return 0 for yes, 1 for no
prompt_yes_no() {
  local prompt="$1"
  local reply
  while true; do
    read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]:${NC} ")" reply
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) echo "  Please enter y or n." ;;
    esac
  done
}

# Install Docker CE via the official convenience script
install_docker() {
  log "Installing Docker CE..."
  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to install Docker but was not found. Install curl first."
  fi
  curl -fsSL https://get.docker.com | sh
  # Add current user to docker group so we don't need sudo for docker commands
  if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER"
    log "Added $SUDO_USER to the docker group (re-login required to take effect)"
  elif [ "$(id -u)" -ne 0 ]; then
    warn "Run 'sudo usermod -aG docker $USER' and re-login to use Docker without sudo."
  fi
}

# Upgrade the docker-compose-plugin to a version that supports 'include'
install_compose_plugin() {
  log "Installing/upgrading docker-compose-plugin..."
  case "${OS_ID}" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y docker-compose-plugin
      ;;
    fedora|rhel|centos|rocky|almalinux)
      dnf install -y docker-compose-plugin 2>/dev/null || \
        yum install -y docker-compose-plugin
      ;;
    *)
      warn "Cannot auto-install docker-compose-plugin on '${OS_ID}'."
      warn "Install it manually: https://docs.docker.com/compose/install/"
      return 1
      ;;
  esac
}

# Install openssl via the system package manager
install_openssl() {
  log "Installing openssl..."
  case "${OS_ID}" in
    ubuntu|debian)
      apt-get update -qq && apt-get install -y openssl
      ;;
    fedora|rhel|centos|rocky|almalinux)
      dnf install -y openssl 2>/dev/null || yum install -y openssl
      ;;
    arch|manjaro)
      pacman -Sy --noconfirm openssl
      ;;
    alpine)
      apk add --no-cache openssl
      ;;
    *)
      warn "Cannot auto-install openssl on '${OS_ID}'. Install it manually."
      return 1
      ;;
  esac
}

detect_os

# --- Check: Docker ---
if ! command -v docker >/dev/null 2>&1; then
  warn "Docker is not installed."
  if prompt_yes_no "Install Docker CE now?"; then
    install_docker
    # Verify install succeeded
    command -v docker >/dev/null 2>&1 || error "Docker installation failed. Install manually: https://docs.docker.com/engine/install/"
    log "Docker installed — OK"
  else
    error "Docker is required. Install it from https://docs.docker.com/engine/install/ and re-run setup."
  fi
else
  log "Docker $(docker --version | awk '{print $3}' | tr -d ',') found — OK"
fi

# --- Check: Docker daemon is running ---
if ! docker info >/dev/null 2>&1; then
  warn "Docker daemon is not running."
  if prompt_yes_no "Start Docker now?"; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start docker
      sleep 2
      docker info >/dev/null 2>&1 || error "Failed to start Docker daemon."
      log "Docker daemon started — OK"
    else
      error "Cannot start Docker automatically. Start the Docker daemon and re-run setup."
    fi
  else
    error "Docker daemon must be running. Start it and re-run setup."
  fi
fi

# --- Check: Docker Compose v2 plugin ---
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "")
if [ -z "$COMPOSE_VERSION" ]; then
  warn "Docker Compose v2 plugin is not installed."
  if prompt_yes_no "Install docker-compose-plugin now?"; then
    install_compose_plugin
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "")
    [ -n "$COMPOSE_VERSION" ] || error "docker-compose-plugin installation failed. Install manually: https://docs.docker.com/compose/install/"
    log "Docker Compose v$COMPOSE_VERSION installed — OK"
  else
    error "Docker Compose v2.20+ is required. Install it and re-run setup."
  fi
fi

# --- Check: Compose version is ≥ 2.20 (required for 'include' support) ---
COMPOSE_MAJOR=$(echo "$COMPOSE_VERSION" | cut -d. -f1)
COMPOSE_MINOR=$(echo "$COMPOSE_VERSION" | cut -d. -f2)
if [ "$COMPOSE_MAJOR" -lt 2 ] || { [ "$COMPOSE_MAJOR" -eq 2 ] && [ "$COMPOSE_MINOR" -lt 20 ]; }; then
  warn "Docker Compose v$COMPOSE_VERSION is too old (v2.20+ required for 'include' support)."
  if prompt_yes_no "Upgrade docker-compose-plugin now?"; then
    install_compose_plugin
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "")
    COMPOSE_MAJOR=$(echo "$COMPOSE_VERSION" | cut -d. -f1)
    COMPOSE_MINOR=$(echo "$COMPOSE_VERSION" | cut -d. -f2)
    if [ "$COMPOSE_MAJOR" -lt 2 ] || { [ "$COMPOSE_MAJOR" -eq 2 ] && [ "$COMPOSE_MINOR" -lt 20 ]; }; then
      error "Upgrade failed. Found v$COMPOSE_VERSION. Install manually: https://docs.docker.com/compose/install/"
    fi
    log "Docker Compose upgraded to v$COMPOSE_VERSION — OK"
  else
    error "Docker Compose v2.20+ is required. Upgrade it and re-run setup."
  fi
fi

log "Docker Compose v$COMPOSE_VERSION — OK"

# --- Check: openssl (required for secret generation) ---
if ! command -v openssl >/dev/null 2>&1; then
  warn "openssl is not installed (required for secret generation)."
  if prompt_yes_no "Install openssl now?"; then
    install_openssl
    command -v openssl >/dev/null 2>&1 || error "openssl installation failed. Install it manually and re-run setup."
    log "openssl installed — OK"
  else
    error "openssl is required. Install it and re-run setup."
  fi
else
  log "openssl $(openssl version | awk '{print $2}') — OK"
fi

# ---------------------------------------------------------------------------
# 2. Create .env from template (if not exists)
# ---------------------------------------------------------------------------
section "=== Environment file ==="

if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  log "Created .env from .env.example"
else
  log ".env already exists — preserving existing values"
fi

# Helper: get current value of a key from .env
env_get() {
  local key="$1"
  grep -E "^${key}=" "$ENV_FILE" | cut -d= -f2- | tr -d '"'
}

# Helper: set a key in .env (only if currently empty)
env_set_if_empty() {
  local key="$1"
  local value="$2"
  local current
  current=$(env_get "$key")
  if [ -z "$current" ]; then
    if grep -qE "^${key}=" "$ENV_FILE"; then
      # Key exists but is empty — replace the line
      sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
      # Key doesn't exist — append
      echo "${key}=${value}" >> "$ENV_FILE"
    fi
    log "Generated ${key}"
  else
    log "${key} already set — skipping"
  fi
}

# ---------------------------------------------------------------------------
# 3. Generate secrets
# ---------------------------------------------------------------------------
section "=== Generating secrets ==="

gen_secret() {
  openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64
}

gen_password() {
  openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 32
}

env_set_if_empty "AUTHENTIK_SECRET_KEY"      "$(gen_secret)"
env_set_if_empty "AUTHENTIK_BOOTSTRAP_PASSWORD" "$(gen_password)"
env_set_if_empty "POSTGRES_PASSWORD"         "$(gen_secret)"
env_set_if_empty "OC_ADMIN_PASSWORD"         "$(gen_password)"
env_set_if_empty "BITWARDEN_MASTER_PASSWORD" "$(gen_password)"
env_set_if_empty "CROWDSEC_BOUNCER_KEY"      "$(gen_secret)"
env_set_if_empty "GRAFANA_ADMIN_PASSWORD"    "$(gen_password)"
env_set_if_empty "FILEBROWSER_ADMIN_PASSWORD" "$(gen_password)"
env_set_if_empty "BACKUP_PASSPHRASE"         "$(gen_secret)"

# ---------------------------------------------------------------------------
# 4. Create data directory tree
# ---------------------------------------------------------------------------
section "=== Creating data directories ==="

DATA_DIRS=(
  "data/traefik/logs"
  "data/traefik/certs"
  "data/crowdsec/config"
  "data/crowdsec/data"
  "data/portainer"
  "data/homepage"
  "data/authentik/media"
  "data/authentik/templates"
  "data/authentik/certs"
  "data/authentik-db"
  "data/authentik-redis"
  "data/opencloud"
  "data/collabora"
  "data/monitoring/prometheus"
  "data/monitoring/grafana"
  "data/monitoring/alertmanager"
  "data/nas/shares"
  "data/backup/config"
  "data/backup/restore"
  "data/passwords"
)

for dir in "${DATA_DIRS[@]}"; do
  mkdir -p "$ROOT_DIR/$dir"
  log "Created $dir"
done

# Set ownership
chown -R "${PUID}:${PGID}" "$ROOT_DIR/data" 2>/dev/null || \
  warn "Could not set ownership on data/ (run as root or adjust PUID/PGID)"

# ---------------------------------------------------------------------------
# 5. Create and secure acme.json
# ---------------------------------------------------------------------------
section "=== Traefik TLS setup ==="

ACME_FILE="$ROOT_DIR/services/infrastructure/traefik/acme.json"
if [ ! -f "$ACME_FILE" ]; then
  touch "$ACME_FILE"
  log "Created acme.json"
fi
chmod 600 "$ACME_FILE"
log "Set acme.json permissions to 600 — OK"

# Generate a self-signed fallback certificate (used when ACME is unavailable,
# e.g. local domains, or as a fallback before the first ACME cert is issued).
CERT_FILE="$ROOT_DIR/data/traefik/certs/cert.pem"
KEY_FILE="$ROOT_DIR/data/traefik/certs/key.pem"
DOMAIN=$(env_get "DOMAIN")
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  log "Generating self-signed fallback TLS certificate for ${DOMAIN:-localhost}..."
  openssl req -x509 -newkey rsa:4096 -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 3650 -nodes \
    -subj "/CN=*.${DOMAIN:-localhost}" \
    -addext "subjectAltName=DNS:*.${DOMAIN:-localhost},DNS:${DOMAIN:-localhost}" \
    2>/dev/null
  log "Self-signed cert generated — OK"
else
  log "TLS fallback certificate already exists — skipping"
fi

# ---------------------------------------------------------------------------
# 6. Post-install checklist
# ---------------------------------------------------------------------------
section "=== Setup complete! ==="

# Read domain from .env
DOMAIN=$(env_get "DOMAIN")
ACME_EMAIL=$(env_get "ACME_EMAIL")

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo -e "  1. ${YELLOW}Edit .env${NC} and set required values:"
echo "       DOMAIN        → your public domain (e.g. example.com)"
echo "       ACME_EMAIL    → Let's Encrypt notification email"
echo "       USE_LETSENCRYPT → true for public domains, false for local"
echo "       BITWARDEN_INSTALLATION_ID / KEY → from https://bitwarden.com/host/"
echo ""
if [ "$DOMAIN" = "yourdomain.com" ] || [ -z "$DOMAIN" ]; then
  echo -e "  ${RED}WARNING: DOMAIN is still set to '${DOMAIN}'. Update it before starting!${NC}"
  echo ""
fi
echo "  2. Configure DNS:"
echo "       Point these A records to your server IP:"
echo "       ${DOMAIN:-yourdomain.com}"
echo "       auth.${DOMAIN:-yourdomain.com}"
echo "       cloud.${DOMAIN:-yourdomain.com}"
echo "       grafana.${DOMAIN:-yourdomain.com}"
echo "       portainer.${DOMAIN:-yourdomain.com}"
echo "       files.${DOMAIN:-yourdomain.com}"
echo "       vault.${DOMAIN:-yourdomain.com}"
echo "       backup.${DOMAIN:-yourdomain.com}"
echo ""
echo "  3. Open firewall ports:"
echo "       80/tcp, 443/tcp (HTTP/HTTPS)"
echo "       445/tcp, 137-139/udp (Samba — LAN only)"
echo ""
echo "  4. Start the stack:"
echo "       make up"
echo ""
echo -e "  ${GREEN}Your secrets are stored in .env — keep this file safe!${NC}"
echo -e "  ${GREEN}NEVER commit .env to version control.${NC}"
echo ""

# Print generated passwords (once, at setup time)
echo -e "${BOLD}Generated credentials (also in .env):${NC}"
printf "  %-35s %s\n" "Authentik admin password:"    "$(env_get AUTHENTIK_BOOTSTRAP_PASSWORD)"
printf "  %-35s %s\n" "OpenCloud admin password:"    "$(env_get OC_ADMIN_PASSWORD)"
printf "  %-35s %s\n" "Grafana admin password:"       "$(env_get GRAFANA_ADMIN_PASSWORD)"
printf "  %-35s %s\n" "FileBrowser admin password:"  "$(env_get FILEBROWSER_ADMIN_PASSWORD)"
printf "  %-35s %s\n" "Bitwarden master password:"   "$(env_get BITWARDEN_MASTER_PASSWORD)"
echo ""
echo -e "${YELLOW}Save these credentials somewhere safe before closing this terminal!${NC}"
echo ""
