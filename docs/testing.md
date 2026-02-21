# Testing

A step-by-step guide to validating the Superbox implementation from a clean state.

## Step 0 — Prerequisites

```bash
# Confirm Docker Compose v2.20+
docker compose version

# Confirm all files are present
git log --oneline -3

# Dry-run the full compose config
make validate
```

---

## Step 1 — Local setup without a real domain

Test locally first using `/etc/hosts` to fake DNS — no public domain or port-forwarding required.

```bash
# Add to /etc/hosts (use 127.0.0.1 or your LAN IP)
echo "127.0.0.1 superbox.local auth.superbox.local portainer.superbox.local grafana.superbox.local cloud.superbox.local files.superbox.local vault.superbox.local backup.superbox.local" | sudo tee -a /etc/hosts
```

Set these values in `.env`:

```env
DOMAIN=superbox.local
USE_LETSENCRYPT=false
ACME_EMAIL=admin@superbox.local
```

With `USE_LETSENCRYPT=false`, Traefik skips ACME entirely — no port 80 reachability or DNS propagation required.

---

## Step 2 — Start with required modules only

Comment out all optional modules in `docker-compose.yml`:

```yaml
include:
  - ./services/infrastructure/compose.yml   # keep
  - ./services/management/compose.yml        # keep
  # - ./services/auth/compose.yml
  # - ./services/opencloud/compose.yml
  # - ./services/monitoring/compose.yml
  # - ./services/nas/compose.yml
  # - ./services/backup/compose.yml
  # - ./services/passwords/compose.yml
```

Then run:

```bash
make setup
make up
make ps
```

Expected containers and status:

| Container | Expected status |
|-----------|----------------|
| `socket-proxy` | running |
| `traefik` | running |
| `crowdsec` | running |
| `bouncer-traefik` | running |
| `portainer` | running |
| `homepage` | running |
| `watchtower` | running |

---

## Step 3 — Smoke test the infrastructure layer

```bash
# Traefik is alive and redirecting HTTP → HTTPS
curl -I http://localhost
# Expect: HTTP/1.1 301 Moved Permanently

# CrowdSec is running
docker exec crowdsec cscli version
docker exec crowdsec cscli bouncers list

# Socket proxy is blocking restricted endpoints
docker exec traefik wget -qO- http://socket-proxy:2375/v1.41/auth || echo "blocked — correct"

# Homepage dashboard is reachable (self-signed TLS warning is expected)
curl -sk https://superbox.local | grep -i superbox

# Portainer is routed
curl -sk https://portainer.superbox.local | grep -i portainer
```

---

## Step 4 — Add the Auth module

Uncomment `services/auth/compose.yml` in `docker-compose.yml`, then:

```bash
make up
docker compose logs -f authentik-server authentik-worker
# Wait for: "Starting server" in authentik-server logs (~30–60s)
```

Verify Authentik is up:

```bash
curl -sk https://auth.superbox.local/-/health/live/
# Expect: {"status": "ok"}

# Check blueprints were applied by the worker
docker compose logs authentik-worker | grep -i blueprint
```

Complete first-time setup:

1. Navigate to `https://auth.superbox.local/if/flow/initial-setup/`
2. Set the admin password (or use `AUTHENTIK_BOOTSTRAP_PASSWORD` from `.env`)
3. Log in at `https://auth.superbox.local`
4. Go to **System → Blueprints** — all Superbox blueprints should show **Successful**

---

## Step 5 — Add remaining modules one at a time

Enable each module, run `make up`, then verify:

### Monitoring

```bash
# Uncomment services/monitoring/compose.yml, then:
make up
curl -sk https://grafana.superbox.local/api/health
# Expect: {"database":"ok","version":"..."}

# Prometheus targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[].labels.job'
```

### OpenCloud

```bash
# Uncomment services/opencloud/compose.yml, then:
make up
curl -sk https://cloud.superbox.local/status.php
# Expect: JSON with version and installed: true
```

### NAS

```bash
# Uncomment services/nas/compose.yml, then:
make up
docker compose ps filebrowser samba
curl -sk https://files.superbox.local | grep -i filebrowser
```

### Backup

```bash
# Uncomment services/backup/compose.yml, then:
make up
curl -sk https://backup.superbox.local | grep -i duplicati
```

### Passwords

```bash
# Uncomment services/passwords/compose.yml, then:
make up
curl -sk https://vault.superbox.local | grep -i bitwarden
```

---

## Step 6 — Full verification checklist

Once all modules are running, work through this checklist:

```bash
# All containers are healthy
make ps

# No containers running as root
docker compose ps --format json | jq -r '.[] | "\(.Name): \(.User)"'

# acme.json has correct permissions
stat services/infrastructure/traefik/acme.json | grep '0600'

# CrowdSec bouncer is registered
docker exec crowdsec cscli bouncers list

# Manually ban and unban a test IP (end-to-end CrowdSec test)
docker exec crowdsec cscli decisions add --ip 10.255.255.1 --reason "test"
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli decisions delete --ip 10.255.255.1
```

Functional checks:

| Test | Expected result |
|------|----------------|
| `https://superbox.local` | Homepage dashboard loads |
| `https://auth.superbox.local` | Authentik login page loads |
| `https://cloud.superbox.local` | OpenCloud loads, SSO login via Authentik |
| Open a `.docx` in OpenCloud | Collabora editor launches |
| `https://grafana.superbox.local` | Grafana loads, Prometheus datasource working |
| `\\superbox\public` (Windows) or `smb://superbox/public` (macOS) | Samba share accessible |
| `https://files.superbox.local` | FileBrowser shows NAS shares |
| `https://backup.superbox.local` | Duplicati UI loads |
| `https://vault.superbox.local` | Bitwarden vault loads |
| `https://portainer.superbox.local` | Portainer (requires Authentik session) |

---

## Step 7 — IaC round-trip test

Validates that the stack is fully reproducible from config alone — no manual state:

```bash
make down
docker volume prune -f
make setup && make up
make ps
# All services should restore to healthy with no manual re-configuration
```

---

## Common First-Run Issues

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `crowdsec` exits immediately | Missing or unreadable `acme.json` | Check file exists and is chmod 600 |
| `bouncer-traefik` can't connect to LAPI | CrowdSec still starting | Wait 10s, it retries automatically |
| `authentik-server` won't start | `authentik-db` not ready | Check `docker compose ps authentik-db` health |
| Traefik returns 404 on all routes | Container not on `traefik-net` or missing `traefik.enable=true` label | Check labels and networks in compose.yml |
| Self-signed certificate browser warning | Expected with `USE_LETSENCRYPT=false` | Add a browser exception, or install [mkcert](https://github.com/FiloSottile/mkcert) CA |
| `make validate` fails | Syntax error in a compose file | Run `docker compose config 2>&1` for the specific error |
| Authentik blueprints not applying | Worker not started or path mismatch | Check `docker compose logs authentik-worker` |
