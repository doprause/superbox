# Troubleshooting

Quick reference for diagnosing common problems.

## General Diagnostic Commands

```bash
# Show all container statuses and health
make ps

# Follow all logs
make logs

# Follow logs for a specific service
docker compose logs -f traefik
docker compose logs -f authentik-server
docker compose logs -f crowdsec

# Inspect a container
docker inspect <container-name>

# Execute a shell in a container
docker exec -it <container-name> sh
```

---

## Traefik

### Certificates not issuing (Let's Encrypt)

**Symptoms:** Browser shows "invalid certificate" or "certificate expired"

**Checks:**
1. Verify DNS resolves to your server IP:
   ```bash
   dig +short yourdomain.com
   ```
2. Verify port 80 is reachable from the internet (required for HTTP-01 challenge):
   ```bash
   curl -I http://yourdomain.com
   ```
3. Check `acme.json` permissions:
   ```bash
   stat services/infrastructure/traefik/acme.json
   # Must be 600
   ```
4. Check Traefik logs for ACME errors:
   ```bash
   docker compose logs traefik | grep -i acme
   docker compose logs traefik | grep -i certificate
   ```
5. Let's Encrypt rate limits: 5 certificates per domain per week. If you hit the limit, use the staging resolver temporarily by adding `caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"` to `traefik.yml`.

### Service not accessible via its domain

**Checks:**
1. Confirm the container has `traefik.enable=true` label
2. Confirm the container is on `traefik-net`
3. Check Traefik's router list:
   ```bash
   curl -s http://traefik:8080/api/http/routers | jq '.[].name'
   ```
4. Check that the `Host` rule matches the domain exactly
5. Verify the port in `loadbalancer.server.port` matches the container's listening port

### HTTP redirect loop

Traefik is redirecting HTTP to HTTPS, but something upstream is stripping the HTTPS. Check that `forwardedHeaders.trustedIPs` in `traefik.yml` includes your proxy/load balancer IP.

---

## CrowdSec

### Legitimate IP getting banned

```bash
# View all decisions
docker exec crowdsec cscli decisions list

# Delete a specific ban
docker exec crowdsec cscli decisions delete --ip 1.2.3.4

# Add to whitelist permanently
docker exec crowdsec cscli whitelists add --ip 1.2.3.4 --reason "my server"
```

### Bouncer not connecting to LAPI

```bash
docker compose logs bouncer-traefik | grep -i error
docker compose logs crowdsec | grep -i bouncer
```

Verify the bouncer API key matches between `CROWDSEC_BOUNCER_KEY` in `.env` and the key registered in CrowdSec:

```bash
docker exec crowdsec cscli bouncers list
```

---

## Authentik

### Login redirect loop

**Symptom:** Browser bounces between the application and `auth.yourdomain.com` without logging in

**Checks:**
1. Verify `AUTHENTIK_HOST` in `services/auth/compose.yml` matches your actual domain
2. Confirm the Authentik outpost router is reachable:
   ```bash
   curl -I https://auth.yourdomain.com/outpost.goauthentik.io/auth/traefik
   ```
3. Check browser cookies — clear cookies for `yourdomain.com` and retry

### Blueprints not applying

```bash
docker compose logs authentik-worker | grep -i blueprint
docker exec authentik-worker ak apply_blueprint /blueprints/superbox/groups.yaml
```

### Forgot admin password

```bash
docker exec authentik-server ak set_password --username akadmin --password newpassword123
```

### Database connection error

```bash
docker compose logs authentik-db
docker exec authentik-db pg_isready -U authentik -d authentik
# Should return: authentik:5432 - accepting connections
```

---

## OpenCloud

### Cannot log in (OIDC error)

1. Verify Authentik has the `opencloud` application and provider configured
2. Check `PROXY_OIDC_ISSUER` matches the Authentik application's provider URL
3. Test the OIDC discovery endpoint:
   ```bash
   curl https://auth.yourdomain.com/application/o/opencloud/.well-known/openid-configuration
   ```

### Collabora editor not loading

1. Check Collabora is running: `docker compose ps collabora`
2. Verify the `aliasgroup1` environment variable matches `https://cloud.yourdomain.com:443`
3. Check Collabora logs: `docker compose logs collabora`
4. Test Collabora is reachable: `curl -I https://collabora.yourdomain.com`

---

## Monitoring

### Prometheus not scraping a target

```bash
# Check targets status
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastError: .lastError}'
```

Common causes:
- Target container not on `monitoring-net`
- Wrong port in scrape config
- Target not exposing a `/metrics` endpoint

### Grafana shows "No data"

1. Check the Prometheus datasource is connected: Grafana → Configuration → Data Sources → Prometheus → Test
2. Verify the time range — ensure it covers a period when Prometheus was scraping
3. Check that the metric names in the dashboard query match actual metrics: run the query in Prometheus UI first

---

## NAS / Samba

### Can't connect from Windows

1. Verify Samba is running and ports are open from LAN:
   ```bash
   docker compose ps samba
   nc -zv <server-ip> 445
   ```
2. Check Samba logs: `docker compose logs samba`
3. Try connecting by IP instead of hostname: `\\<server-ip>\public`
4. Ensure the Windows machine is on the same subnet as the Samba firewall rule

### Permission denied on share

1. Check file ownership on the host: `ls -la data/nas/shares/`
2. The Samba container runs as `PUID:PGID` (default 1000:1000) — files must be owned by this UID
3. For authenticated shares, verify the Samba user exists: `docker exec samba pdbedit -L`

---

## Backup (Duplicati)

### Backup job failing

```bash
docker compose logs duplicati
```

Check the Duplicati web UI at `https://backup.yourdomain.com` → select job → **Show log** for detailed error messages.

Common causes:
- Backup target unreachable (S3 credentials, SFTP host key)
- Insufficient disk space at destination
- Source path not mounted

### Can't restore — passphrase lost

The `BACKUP_PASSPHRASE` is stored in `.env`. If `.env` is also lost, encrypted backups cannot be decrypted. **This is why the passphrase must be stored in an offline secure location (e.g. printed and stored physically).**

---

## Passwords (Bitwarden Lite)

### Container fails to start

```bash
docker compose logs bitwarden
```

Most common cause: missing `BITWARDEN_INSTALLATION_ID` or `BITWARDEN_INSTALLATION_KEY` in `.env`.

### Clients can't connect

1. Verify the client is configured with `https://vault.yourdomain.com` (not bitwarden.com)
2. Check TLS: `curl -I https://vault.yourdomain.com`
3. Bitwarden uses TLS 1.3 only (`modern` profile) — ensure the client supports TLS 1.3

---

## Useful One-Liners

```bash
# Check which containers are unhealthy
docker ps --filter health=unhealthy

# Show resource usage of all containers
docker stats --no-stream

# Check disk usage of Docker volumes and images
docker system df

# Prune stopped containers, unused networks, dangling images
docker system prune

# View last 100 lines of all container logs
docker compose logs --tail=100

# Check if a domain resolves correctly
dig +short auth.yourdomain.com

# Test HTTPS reachability and cert validity
curl -vI https://yourdomain.com 2>&1 | grep -E "(SSL|TLS|certificate|subject|issuer|expire)"

# Verify no containers running as root
docker compose ps --format json | jq -r '.[] | "\(.Name): user=\(.User)"'
```
