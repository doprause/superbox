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
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
section "=== Pre-flight checks ==="

command -v docker >/dev/null 2>&1 || error "Docker is not installed. Install Docker CE first."

COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "")
if [ -z "$COMPOSE_VERSION" ]; then
  error "Docker Compose v2 plugin is not installed. Install docker-compose-plugin."
fi

COMPOSE_MAJOR=$(echo "$COMPOSE_VERSION" | cut -d. -f1)
COMPOSE_MINOR=$(echo "$COMPOSE_VERSION" | cut -d. -f2)
if [ "$COMPOSE_MAJOR" -lt 2 ] || { [ "$COMPOSE_MAJOR" -eq 2 ] && [ "$COMPOSE_MINOR" -lt 20 ]; }; then
  error "Docker Compose v2.20+ is required (for 'include' support). Found: $COMPOSE_VERSION"
fi

log "Docker Compose v$COMPOSE_VERSION found — OK"

command -v openssl >/dev/null 2>&1 || error "openssl is not installed."
log "openssl found — OK"

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
  "data/traefik"
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
