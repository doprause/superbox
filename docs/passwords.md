# Passwords — Bitwarden Lite

The passwords module provides a self-hosted Bitwarden-compatible password manager using the official Bitwarden Lite single-container deployment (GA December 2025).

**Location:** `services/passwords/`

## Components

| Container | Image | Role |
|-----------|-------|------|
| `bitwarden` | `ghcr.io/bitwarden/self-host:2025.12` | All-in-one Bitwarden server (SQLite backend) |

## URLs

| URL | Purpose | Access |
|-----|---------|--------|
| `https://vault.${DOMAIN}` | Bitwarden web vault | `chain-public` |
| `https://vault.${DOMAIN}/admin` | Admin portal | `chain-internal` (Authentik forward auth) |

---

## Prerequisites

Before starting, obtain a Bitwarden installation ID and key:

1. Go to [bitwarden.com/host](https://bitwarden.com/host)
2. Enter your email address
3. Copy the **Installation ID** and **Installation Key**
4. Add them to `.env`:

```env
BITWARDEN_INSTALLATION_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
BITWARDEN_INSTALLATION_KEY=xxxxxxxxxxxxxxxxxxxx
```

These values are required for Bitwarden Lite to start. Without them, the container will fail to initialize.

---

## First-Time Setup

1. Start the module: `docker compose up -d bitwarden`
2. Navigate to `https://vault.${DOMAIN}`
3. Click **Create Account**
4. Register with your email address and a strong master password
5. (Optional) Set up two-factor authentication in account settings

The master password is the encryption key for your vault — it is never sent to the server. If you lose it, your vault data cannot be recovered.

---

## Admin Portal

The admin portal at `https://vault.${DOMAIN}/admin` is protected by Authentik forward auth (accessible only to authenticated users, i.e. LAN/VPN access). It allows:

- Viewing registered users
- Deleting accounts
- Configuring organization settings
- Sending invitation emails
- Viewing server diagnostics

Configure admin email in `.env`:

```env
BITWARDEN_ADMIN_EMAIL=admin@yourdomain.com
```

---

## Client Setup

### Browser extension

Install the Bitwarden browser extension for Chrome, Firefox, Safari, or Edge. In the extension settings:

1. Click the region selector (default: bitwarden.com)
2. Select **Self-hosted**
3. Enter your server URL: `https://vault.${DOMAIN}`
4. Log in with your account credentials

### Desktop app

Download the Bitwarden desktop app. In the Settings menu:

1. Click **Self-hosted environment**
2. Enter: `https://vault.${DOMAIN}`
3. Save and log in

### Mobile apps (iOS / Android)

1. Open the Bitwarden app
2. Tap the region selector on the login screen
3. Select **Self-hosted**
4. Enter: `https://vault.${DOMAIN}`
5. Log in

### CLI

```bash
bw config server https://vault.${DOMAIN}
bw login your@email.com
bw sync
bw list items
```

---

## Organizations and Teams

Bitwarden supports shared vaults via Organizations:

1. Log into the web vault → **New Organization**
2. Invite team members by email
3. Create **Collections** for different teams (e.g. "DevOps", "Finance")
4. Share items into collections

Members must have accounts on your Bitwarden instance. Send invitations from the admin portal or from the organization management page.

---

## Backup

Bitwarden Lite's SQLite database is stored in `data/passwords/`. It is included in the Duplicati backup job under `/source/passwords`.

The database contains encrypted vault data (encrypted by each user's master password key) — even with database access, individual vault items cannot be read without the user's master password.

### Manual export

Users can export their own vault from the web vault: **Tools → Export Vault** (encrypted JSON or CSV).

---

## TLS Configuration

Bitwarden uses Traefik for TLS termination. The `modern` TLS profile (TLS 1.3 only) is applied to the vault router:

```yaml
- "traefik.http.routers.bitwarden.tls.options=modern@file"
```

This is the strictest TLS profile, appropriate for a password manager.

---

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `BITWARDEN_INSTALLATION_ID` | bitwarden.com/host | Licence and update checks |
| `BITWARDEN_INSTALLATION_KEY` | bitwarden.com/host | Licence validation |
| `BW_DOMAIN` | `.env` | Sets the server's public domain |
| `BITWARDEN_ADMIN_EMAIL` | `.env` | Admin portal access |
| `BITWARDEN_MASTER_PASSWORD` | `setup.sh` | Generated reference password (stored in `.env`) |

---

## Troubleshooting

**Container fails to start:**
- Verify `BITWARDEN_INSTALLATION_ID` and `BITWARDEN_INSTALLATION_KEY` are set in `.env`
- Check logs: `docker compose logs bitwarden`

**Can't reach the vault:**
- Confirm Traefik is routing `vault.${DOMAIN}` to port 8080
- Check TLS cert: `curl -I https://vault.${DOMAIN}`

**Admin portal not accessible:**
- The `/admin` path uses a separate Traefik router with higher priority and `chain-internal` middleware
- Ensure you are accessing from a network where Authentik forward auth succeeds (LAN or VPN)
