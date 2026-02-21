# NAS — Network Attached Storage

The NAS module provides SMB/CIFS network file shares (accessible from Windows, macOS, and Linux) and a web-based file manager.

**Location:** `services/nas/`

## Components

| Container | Image | Role |
|-----------|-------|------|
| `samba` | `dperson/samba:latest` | SMB/CIFS network shares |
| `filebrowser` | `filebrowser/filebrowser:v2.32` | Web-based file manager |

Both services share `data/nas/shares/` as their root. Files written via Samba are immediately accessible in FileBrowser and vice versa.

## URLs

| URL | Service | Access |
|-----|---------|--------|
| `\\SUPERBOX\sharename` | Samba (Windows) | SMB credentials |
| `smb://superbox/sharename` | Samba (macOS/Linux) | SMB credentials |
| `https://files.${DOMAIN}` | FileBrowser | `chain-secure` (Authentik forward auth) |

---

## Samba

Samba runs with `network_mode: host` for proper NetBIOS/SMB broadcast discovery on the local network. This means it binds directly to the host's network interfaces.

### Share structure

Shares are defined in `services/nas/samba/smb.conf` and map to subdirectories under `data/nas/shares/`:

| Share | Path | Access |
|-------|------|--------|
| `public` | `data/nas/shares/public/` | Open to all LAN clients (no password) |
| `private` | `data/nas/shares/private/` | Authenticated users (`@users` group) |
| `backups` | `data/nas/shares/backups/` | Read: `@users`; Write: `@admins` |

### Adding a new share

1. Create the directory: `mkdir -p data/nas/shares/myshare`
2. Add a section to `smb.conf`:

```ini
[myshare]
   comment = My New Share
   path = /shares/myshare
   browseable = yes
   writable = yes
   guest ok = no
   valid users = @users
   create mask = 0660
   directory mask = 0770
```

3. Restart Samba: `docker compose restart samba`

### Adding Samba users

Samba maintains its own user database separate from the OS. Users must exist in both:

```bash
# Add OS user (inside the container)
docker exec samba adduser --no-create-home --disabled-password --gecos "" myuser

# Add Samba password
docker exec -it samba smbpasswd -a myuser
```

For group-based access, add the user to the appropriate OS group inside the container:

```bash
docker exec samba addgroup users
docker exec samba adduser myuser users
```

### Connecting from clients

**Windows:**
```
\\SUPERBOX\public
\\<server-IP>\public
```
Open File Explorer → address bar → type the path above.

**macOS:**
`Finder → Go → Connect to Server → smb://superbox/public`

**Linux:**
```bash
# Nautilus (GNOME)
smb://superbox/public

# Mount via CLI
sudo mount -t cifs //superbox/private /mnt/private -o username=myuser,password=mypass,uid=1000,gid=1000
```

### Security notes

- SMBv1 is disabled (`server min protocol = SMB2`)
- Samba ports (445, 139, 137-138) should only be open to the LAN subnet — the Ansible `firewall` role enforces this
- The `public` share has no password — ensure it is only accessible from trusted network segments

---

## FileBrowser

FileBrowser provides a clean web UI for browsing, uploading, downloading, editing, and managing files in the NAS shares directory.

**URL:** `https://files.${DOMAIN}` (protected by Authentik forward auth via `chain-secure`)

### Initial setup

On first start, FileBrowser initializes a SQLite database at `data/filebrowser/database.db`. The initial admin credentials are:

- Username: `admin`
- Password: `admin`

**Change the admin password immediately** via Settings → Profile, or set `FILEBROWSER_ADMIN_PASSWORD` in `.env` and the password will be applied on first start.

### Configuration

FileBrowser reads its base settings from `data/filebrowser/settings.json`:

```json
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database.db",
  "root": "/srv"
}
```

`/srv` maps to `data/nas/shares/` — users can browse the entire shares directory tree.

### User management

FileBrowser has its own user system, separate from Authentik. Since FileBrowser is behind Authentik forward auth, users are already authenticated before reaching it. FileBrowser's own user accounts can be used to further restrict which directories each user can see.

Create additional users via Settings → User Management in the FileBrowser UI.

### Features

- File upload (drag-and-drop, multi-file)
- File download (single file or zip archive)
- Inline text editor
- Image preview
- Video playback
- Search
- Share links (password-optional)
- User permissions (read, write, create, rename, delete, share)
