# Getting Started

## Prerequisites

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| OS | Ubuntu 24.04 LTS | Bare-metal or VM |
| RAM | 4 GB | 8 GB recommended with all modules enabled |
| Disk | 40 GB | More for NAS shares and backups |
| Docker CE | Latest | See [docs.docker.com](https://docs.docker.com/engine/install/ubuntu/) |
| Docker Compose | v2.20+ | Required for `include` directive support |
| Domain | Any | Public domain required for Let's Encrypt; local domain for self-signed |

Check your Docker Compose version:

```bash
docker compose version
# Docker Compose version v2.24.5
```

## Adding Your SSH Key to the Server

Before running the Ansible playbook or connecting remotely, add your client's public SSH key to the server so you can authenticate without a password.

**On your local machine**, generate a key pair if you don't have one:

```bash
ssh-keygen -t ed25519 -C "your@email.com"
# Key saved to ~/.ssh/id_ed25519 (private) and ~/.ssh/id_ed25519.pub (public)
```

**Copy the public key to the server** using `ssh-copy-id`:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@<server-ip>
# Enter the password once — subsequent logins will use the key
```

If `ssh-copy-id` is not available, copy the key manually:

```bash
cat ~/.ssh/id_ed25519.pub | ssh ubuntu@<server-ip> \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

**Verify key-based login works** before disabling password auth:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<server-ip>
```

**Optionally disable password authentication** on the server for hardened access (`/etc/ssh/sshd_config`):

```
PasswordAuthentication no
PubkeyAuthentication yes
```

Then restart SSH: `sudo systemctl restart ssh`

## Adding Your User to the Docker Group

If your server user is not in the `docker` group, the setup script will fail with "Docker daemon is not running" even when the daemon is active — because the user lacks permission to reach the Docker socket.

Add the user to the `docker` group:

```bash
sudo usermod -aG docker $USER
```

Then apply the change to your current session without logging out:

```bash
newgrp docker
```

Verify access:

```bash
docker info >/dev/null && echo "Docker access OK"
```

> **Note:** A full logout and login is required for the group change to persist across all new sessions.

---

Once the key is in place, update `ansible/inventory` to reference it:

```ini
[superbox]
<server-ip> ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

## Installation

### Option A — Automated (Ansible)

For a completely fresh Ubuntu 24.04 machine:

```bash
git clone https://github.com/doprause/superbox.git
cd superbox
cp ansible/inventory.example ansible/inventory
# Edit ansible/inventory with your server IP and SSH key path
make provision
```

The Ansible playbook installs Docker, configures UFW, hardens the host, and starts the stack. See [Provisioning](provisioning.md) for full details.

### Option B — Manual

On a machine that already has Docker installed:

```bash
git clone https://github.com/doprause/superbox.git
cd superbox
make setup
```

## Configuration

### 1. Edit `.env`

`make setup` creates `.env` from `.env.example` and generates all secrets automatically. You must still set:

```env
DOMAIN=yourdomain.com
ACME_EMAIL=admin@yourdomain.com
USE_LETSENCRYPT=true
```

For **local/private networks** without a public domain:

```env
USE_LETSENCRYPT=false
DOMAIN=superbox.local
```

In this case, configure a self-signed certificate or [mkcert](https://github.com/FiloSottile/mkcert) CA and mount it into Traefik.

### 2. Configure DNS

Create A records for each enabled module pointing to your server's public IP:

```
yourdomain.com          → <server IP>
auth.yourdomain.com     → <server IP>
cloud.yourdomain.com    → <server IP>
collabora.yourdomain.com → <server IP>
grafana.yourdomain.com  → <server IP>
portainer.yourdomain.com → <server IP>
files.yourdomain.com    → <server IP>
vault.yourdomain.com    → <server IP>
backup.yourdomain.com   → <server IP>
traefik.yourdomain.com  → <server IP>
```

DNS must resolve before Let's Encrypt can issue certificates.

### 3. Open firewall ports

| Port | Protocol | Service |
|------|----------|---------|
| 80 | TCP | Traefik (ACME HTTP-01 challenge + redirect) |
| 443 | TCP | Traefik (HTTPS) |
| 445 | TCP | Samba (LAN only) |
| 139 | TCP | Samba NetBIOS (LAN only) |
| 137–138 | UDP | Samba discovery (LAN only) |

If using the Ansible `firewall` role, these are configured automatically.

### 4. Select modules

Edit `docker-compose.yml` and comment out any modules you don't need:

```yaml
include:
  - ./services/infrastructure/compose.yml   # REQUIRED
  - ./services/management/compose.yml        # REQUIRED
  - ./services/auth/compose.yml
  # - ./services/opencloud/compose.yml       # disabled
  - ./services/monitoring/compose.yml
  # - ./services/nas/compose.yml             # disabled
  - ./services/backup/compose.yml
  - ./services/passwords/compose.yml
```

### 5. Bitwarden Lite (if enabled)

Obtain an installation ID and key from [bitwarden.com/host](https://bitwarden.com/host) and add them to `.env`:

```env
BITWARDEN_INSTALLATION_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
BITWARDEN_INSTALLATION_KEY=xxxxxxxxxxxxxxxxxxxx
```

## Starting the Stack

```bash
make up
```

Monitor startup:

```bash
make logs
# or watch individual services:
docker compose logs -f traefik
docker compose logs -f authentik-server
```

Check all containers are healthy:

```bash
make ps
```

## First-Boot Steps

### 1. Authentik initial setup

Navigate to `https://auth.yourdomain.com/if/flow/initial-setup/` and set the admin password (or use the one generated by `setup.sh` — printed to the terminal and stored in `.env` as `AUTHENTIK_BOOTSTRAP_PASSWORD`).

### 2. Complete Authentik blueprint application

Blueprints in `services/auth/authentik/blueprints/` are applied automatically on worker startup. Verify they were applied:

1. Log into Authentik as admin
2. Go to **System → Blueprints**
3. Confirm all Superbox blueprints show status **Successful**

### 3. Create your user account

In Authentik, create a regular user account and add it to the `superbox-users` group. Add admin accounts to `superbox-admins` (MFA will be enforced).

### 4. Verify services

| URL | Expected |
|-----|---------|
| `https://yourdomain.com` | Homepage dashboard |
| `https://auth.yourdomain.com` | Authentik login page |
| `https://cloud.yourdomain.com` | OpenCloud login |
| `https://grafana.yourdomain.com` | Grafana (login via Authentik) |
| `https://portainer.yourdomain.com` | Portainer (behind forward auth) |

## Upgrading

```bash
make update
```

This pulls new images and recreates any containers whose image has changed. Watchtower also does this automatically each night for containers with the `com.centurylinklabs.watchtower.enable=true` label.

Before major upgrades, check the upstream changelogs — especially for Authentik, which occasionally has database migration steps.

## Stopping and Restoring

```bash
make down          # stop all containers (data is preserved in data/)
make up            # restart from existing data
```

To perform a full IaC round-trip (destroy and restore from config):

```bash
make down
docker volume prune -f
make setup && make up
```

Services restore from their config files and mounted volumes. No manual re-configuration is needed.
