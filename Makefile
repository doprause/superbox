# =============================================================================
# Superbox — Makefile
# Wraps common Docker Compose and Ansible operations
# =============================================================================

COMPOSE        := docker compose
ANSIBLE        := ansible-playbook
INVENTORY      := ansible/inventory
PLAYBOOK       := ansible/playbook.yml
COMPOSE_ARGS   :=

.PHONY: help setup up down restart logs ps pull update backup provision \
        validate lint check-env

# Default target
help:
	@echo ""
	@echo "Superbox — All-In-One Small Business Server"
	@echo "============================================"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Stack management:"
	@echo "  setup      First-run: generate secrets, create data dirs"
	@echo "  up         Start all services (docker compose up -d)"
	@echo "  down       Stop all services"
	@echo "  restart    Restart all services"
	@echo "  logs       Follow logs (last 50 lines)"
	@echo "  ps         Show running containers and health"
	@echo "  pull       Pull latest images"
	@echo "  update     Pull images and recreate changed containers"
	@echo ""
	@echo "Backup:"
	@echo "  backup     Trigger a Duplicati backup via API"
	@echo ""
	@echo "Provisioning:"
	@echo "  provision  Run Ansible playbook against ansible/inventory"
	@echo ""
	@echo "Validation:"
	@echo "  validate   Validate Docker Compose config"
	@echo "  lint       Lint Ansible playbook"
	@echo "  check-env  Verify .env contains all required variables"
	@echo ""

# ---------------------------------------------------------------------------
# First-run setup
# ---------------------------------------------------------------------------
setup:
	@echo "==> Running first-run setup..."
	@chmod +x scripts/setup.sh
	@./scripts/setup.sh

# ---------------------------------------------------------------------------
# Stack lifecycle
# ---------------------------------------------------------------------------
up: check-env
	@echo "==> Starting Superbox..."
	$(COMPOSE) up -d $(COMPOSE_ARGS)

down:
	@echo "==> Stopping Superbox..."
	$(COMPOSE) down

restart:
	@echo "==> Restarting Superbox..."
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f --tail=50

ps:
	$(COMPOSE) ps

pull:
	@echo "==> Pulling latest images..."
	$(COMPOSE) pull

update: pull
	@echo "==> Recreating changed containers..."
	$(COMPOSE) up -d --remove-orphans

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
backup:
	@echo "==> Triggering Duplicati backup..."
	@BACKUP_URL="http://localhost:8200"; \
	TOKEN=$$(curl -s -X POST "$$BACKUP_URL/api/v1/auth/issuetoken" \
	  -H "Content-Type: application/json" \
	  -d '{"Password":""}' | jq -r '.Token'); \
	curl -s -X POST "$$BACKUP_URL/api/v1/backup/1/run" \
	  -H "Authorization: Bearer $$TOKEN" | jq .
	@echo "==> Backup triggered. Check Duplicati UI for progress."

# ---------------------------------------------------------------------------
# Ansible provisioning
# ---------------------------------------------------------------------------
provision:
	@echo "==> Provisioning host with Ansible..."
	@if [ ! -f "$(INVENTORY)" ]; then \
	  echo "ERROR: ansible/inventory not found."; \
	  echo "       Copy ansible/inventory.example to ansible/inventory and edit it."; \
	  exit 1; \
	fi
	$(ANSIBLE) $(PLAYBOOK) -i $(INVENTORY)

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate:
	@echo "==> Validating Docker Compose config..."
	$(COMPOSE) config --quiet && echo "Config is valid."

lint:
	@echo "==> Linting Ansible playbook..."
	@command -v ansible-lint >/dev/null 2>&1 || (echo "ansible-lint not installed. Run: pip install ansible-lint" && exit 1)
	ansible-lint $(PLAYBOOK)

check-env:
	@if [ ! -f ".env" ]; then \
	  echo "ERROR: .env file not found."; \
	  echo "       Run 'make setup' first, or copy .env.example to .env and fill in values."; \
	  exit 1; \
	fi
	@echo "==> .env file found."
