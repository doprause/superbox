# Management

The management module provides the container management UI, the service dashboard, and automated image updates.

**Location:** `services/management/`

## Components

| Container | Image | Role |
|-----------|-------|------|
| `portainer` | `portainer/portainer-ce:2.21` | Docker container management UI |
| `homepage` | `ghcr.io/gethomepage/homepage:v0.10` | Service dashboard with system widgets |
| `watchtower` | `containrrr/watchtower:1.7` | Nightly automated image updates |

---

## Portainer

Portainer provides a web UI for managing all Docker containers, images, volumes, and networks without needing shell access.

**URL:** `https://portainer.${DOMAIN}` (protected by `chain-internal` — Authentik forward auth)

### First login

On first access, create an admin password. In subsequent logins, Authentik handles authentication via forward auth — Portainer's own auth screen is bypassed once the Authentik session is established.

### Docker API access

Portainer connects to the Docker daemon via Socket Proxy (`tcp://socket-proxy:2375`) rather than mounting the raw Docker socket. This limits Portainer to permitted API calls only.

### Common operations

| Task | Location in UI |
|------|---------------|
| View container logs | Containers → select container → Logs |
| Restart a container | Containers → select container → Restart |
| Pull a new image | Images → Pull image |
| Inspect a network | Networks → select network |
| View volume contents | Volumes → select volume → Browse |

---

## Homepage

Homepage is the entry-point dashboard for the stack, served at the root domain (`https://${DOMAIN}`).

**URL:** `https://${DOMAIN}` (protected by `chain-secure`)

### Configuration files

All configuration is in `services/management/homepage/config/` and mounted read-only into the container.

#### `services.yaml`

Defines service links grouped into categories. Each entry can include:

- `icon` — icon name from [dashboard-icons](https://github.com/walkxcode/dashboard-icons)
- `href` — the URL to open
- `description` — shown below the service name
- `ping` — URL to check for up/down status dot
- `siteMonitor` — URL for HTTP status check

To add a new service:

```yaml
- My Category:
    - My App:
        icon: myapp.png
        href: "https://myapp.${HOMEPAGE_VAR_DOMAIN}"
        description: What this app does
        ping: "https://myapp.${HOMEPAGE_VAR_DOMAIN}"
```

#### `widgets.yaml`

Configures the header widgets (system stats, weather, search bar, clock). Current widgets:

| Widget | Data |
|--------|------|
| `resources` | CPU, RAM, disk usage, CPU temperature, uptime |
| `datetime` | Clock in 24-hour format |
| `search` | DuckDuckGo search bar |
| `openmeteo` | Local weather (configure latitude/longitude) |

To change the weather location, edit `widgets.yaml`:

```yaml
- openmeteo:
    latitude: 51.50  # London
    longitude: -0.12
    timezone: Europe/London
```

#### `settings.yaml`

Controls the overall look and feel: title, theme (dark/light), color scheme, layout column counts, and language.

---

## Watchtower

Watchtower checks for updated Docker images nightly (03:00) and automatically recreates containers when a newer image is available.

### Opt-in model

Watchtower only updates containers with the label:

```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=true"
```

Containers without this label are never touched by Watchtower. This prevents unintended updates to services where you want explicit version control.

### Schedule

Configured via `WATCHTOWER_SCHEDULE=0 0 3 * * *` (cron format: second minute hour day month weekday). To change, edit the environment variable in `compose.yml`.

### Manual update

To trigger an immediate update check:

```bash
docker exec watchtower watchtower --run-once
```

Or use the Makefile:

```bash
make update   # pull + recreate changed containers
```

### Notifications

Watchtower supports notifications via [Shoutrrr](https://containrrr.dev/shoutrrr/) (Slack, Discord, email, Telegram, etc.). Configure by setting `WATCHTOWER_NOTIFICATION_URL` in `.env`:

```env
# Slack example
WATCHTOWER_NOTIFICATION_URL=slack://token@channel

# Email example
WATCHTOWER_NOTIFICATION_URL=smtp://user:pass@host:587/?from=from@example.com&to=to@example.com
```
