# Provisioning

The Ansible playbook provisions a fresh Ubuntu 24.04 LTS host with everything needed to run the Superbox stack. It implements the host layer of the Infrastructure as Code (IaC) strategy.

**Location:** `ansible/`

## Overview

```
make provision
    └── ansible-playbook ansible/playbook.yml -i ansible/inventory
            ├── role: base       — packages, sysctl, unattended upgrades
            ├── role: docker     — Docker CE, Compose plugin, daemon config
            ├── role: firewall   — UFW rules, DOCKER-USER iptables chain
            ├── role: storage    — ZFS (optional, enable_zfs: true)
            └── role: superbox   — system user, data dirs, systemd service, stack start
```

## Prerequisites

Install Ansible on the machine you run provisioning from (not necessarily the server):

```bash
pip install ansible ansible-lint
# Optional collections (install if not already present)
ansible-galaxy collection install community.general ansible.posix
```

## Setup

```bash
cp ansible/inventory.example ansible/inventory
```

Edit `ansible/inventory`:

```ini
[superbox]
192.168.1.100 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_ed25519

[superbox:vars]
# superbox_user=superbox
# enable_zfs=false
```

For local provisioning (running on the server itself):

```ini
[superbox]
localhost ansible_connection=local
```

## Running the Playbook

```bash
make provision
# or directly:
ansible-playbook ansible/playbook.yml -i ansible/inventory
```

Run specific roles only using tags:

```bash
ansible-playbook ansible/playbook.yml -i ansible/inventory --tags docker
ansible-playbook ansible/playbook.yml -i ansible/inventory --tags firewall
ansible-playbook ansible/playbook.yml -i ansible/inventory --tags base,sysctl
```

---

## Roles

### `base` — OS hardening and packages

**Tasks:**
- `apt upgrade -y` (full dist-upgrade)
- Install packages: `curl`, `wget`, `git`, `make`, `jq`, `openssl`, `ufw`, `fail2ban`, `unattended-upgrades`
- Configure `unattended-upgrades` for security-only updates (no automatic reboot)
- Apply sysctl hardening settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `net.ipv4.tcp_syncookies` | 1 | SYN flood protection |
| `net.ipv4.conf.all.rp_filter` | 1 | Source address verification |
| `net.ipv4.conf.all.accept_redirects` | 0 | No ICMP redirects |
| `net.ipv4.conf.all.send_redirects` | 0 | No routing redirect |
| `net.core.somaxconn` | 65535 | Larger connection backlog |
| `vm.swappiness` | 10 | Prefer RAM over swap |
| `fs.file-max` | 2097152 | High file descriptor limit |

### `docker` — Docker CE installation

**Tasks:**
- Remove legacy Docker packages
- Add Docker's official apt GPG key and repository
- Install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Start and enable the `docker` systemd service
- Add the `superbox` user to the `docker` group
- Configure `/etc/docker/daemon.json`:
  - Log driver: `json-file`, max 10 MB, 3 files
  - `live-restore: true` — containers survive daemon restarts
  - `no-new-privileges: true` — global default

### `firewall` — UFW and Docker bypass prevention

**Tasks:**
- Reset UFW to defaults
- Set default policies: incoming deny, outgoing allow
- Allow: `22/tcp` (SSH), `80/tcp` (HTTP), `443/tcp` (HTTPS)
- Allow Samba ports (`139/tcp`, `445/tcp`, `137-138/udp`) from LAN subnet only
- Enable UFW
- Insert `DOCKER-USER` iptables rules in `/etc/ufw/before.rules`

**The DOCKER-USER chain is critical.** Without it, Docker bypasses UFW and exposes container ports directly to the internet, even if UFW blocks those ports. The `DOCKER-USER` chain inserts rules that are evaluated before Docker's own NAT rules.

### `storage` — Optional ZFS configuration

Only runs when `enable_zfs: true` in the playbook vars.

**Tasks:**
- Install `zfsutils-linux` and `zfs-auto-snapshot`
- Create ZFS pool from `zfs_disk` (e.g. `/dev/sdb`)
- Create ZFS datasets for each service with `lz4` compression and checksums
- Mount datasets to `data/` subdirectories
- Configure `zfs-auto-snapshot` cron jobs:
  - Every 15 minutes (keep 4)
  - Hourly (keep 24)
  - Daily (keep 31)
  - Weekly (keep 8)
  - Monthly (keep 12)

**Playbook variables for ZFS:**

```yaml
enable_zfs: true
zfs_pool_name: tank
zfs_disk: /dev/sdb          # single disk
# zfs_disk: /dev/sdb /dev/sdc   # mirror
# zfs_disk: raidz /dev/sdb /dev/sdc /dev/sdd  # RAID-Z
```

### `superbox` — System user, directories, and stack startup

**Tasks:**
- Create `superbox` system group (GID 1000)
- Create `superbox` system user (UID 1000), home at `/opt/superbox`
- Clone repository if `repo_url` is set
- Run `make setup` to generate secrets and create `data/` tree
- Run `make up` to start the stack
- Install systemd service (`/etc/systemd/system/superbox.service`) for auto-start on boot

**Systemd service:**

```ini
[Unit]
Description=Superbox Docker Compose Stack
After=docker.service network-online.target

[Service]
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
WorkingDirectory=/opt/superbox
User=superbox
```

---

## Playbook Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `superbox_user` | `superbox` | System user name |
| `superbox_uid` | `1000` | User UID |
| `superbox_gid` | `1000` | Group GID |
| `superbox_home` | `/opt/superbox` | Stack home directory |
| `repo_url` | `""` | Git repo to clone (leave empty to manage manually) |
| `enable_zfs` | `false` | Enable ZFS storage role |
| `zfs_pool_name` | `tank` | ZFS pool name |
| `zfs_disk` | `""` | Disk(s) for ZFS pool |
| `lan_subnet` | `192.168.0.0/16` | LAN subnet for Samba firewall rules |

Override these in `ansible/inventory` under `[superbox:vars]` or directly in `playbook.yml`.

---

## Idempotency

All tasks are idempotent — running the playbook multiple times on the same host produces the same result without duplicating work. This makes it safe to re-run after a configuration change or to verify the host state.

```bash
# Dry-run (check mode) — shows what would change without applying
ansible-playbook ansible/playbook.yml -i ansible/inventory --check --diff
```
