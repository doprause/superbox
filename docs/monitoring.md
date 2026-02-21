# Monitoring

The monitoring module provides full-stack observability: host and container metrics, service dashboards, and alert routing.

**Location:** `services/monitoring/`

## Components

| Container | Image | Role |
|-----------|-------|------|
| `prometheus` | `prom/prometheus:v3.1` | Metrics collection and time-series storage |
| `grafana` | `grafana/grafana:11.4` | Dashboards, visualization, alerting |
| `node-exporter` | `prom/node-exporter:v1.8` | Host CPU, RAM, disk, network metrics |
| `cadvisor` | `gcr.io/cadvisor/cadvisor:v0.50` | Per-container resource metrics |
| `alertmanager` | `prom/alertmanager:v0.27` | Alert deduplication and routing |

## URLs

| URL | Service | Access |
|-----|---------|--------|
| `https://grafana.${DOMAIN}` | Grafana dashboards | `chain-public` (Authentik OAuth2) |
| `https://prometheus.${DOMAIN}` | Prometheus UI | `chain-internal` (forward auth) |
| `https://alertmanager.${DOMAIN}` | Alertmanager UI | `chain-internal` (forward auth) |

---

## Prometheus

Prometheus scrapes metrics from all services on a 15-second interval and stores them for 30 days (10 GB retention).

### Scrape configuration

`services/monitoring/prometheus/prometheus.yml` defines all scrape jobs:

| Job | Target | Metrics |
|-----|--------|---------|
| `prometheus` | `prometheus:9090` | Prometheus self-metrics |
| `traefik` | `traefik:8899` | Request rates, latencies, TLS info |
| `node-exporter` | `node-exporter:9100` | Host CPU, RAM, disk, network |
| `cadvisor` | `cadvisor:8080` | Per-container CPU, RAM, I/O |
| `grafana` | `grafana:3000/metrics` | Grafana internals |
| `authentik` | `authentik-server:9300/metrics` | Authentik request/login metrics |

### Adding a new scrape target

Add a job to `prometheus.yml`:

```yaml
- job_name: myservice
  static_configs:
    - targets: [myservice:8080]
  metrics_path: /metrics
```

Then reload Prometheus (no restart needed):

```bash
curl -X POST http://localhost:9090/-/reload
# or via Traefik:
curl -X POST https://prometheus.${DOMAIN}/-/reload
```

### Storage

Metrics are stored in `data/monitoring/prometheus/`. Retention is configured by:

```
--storage.tsdb.retention.time=30d
--storage.tsdb.retention.size=10GB
```

Both limits are enforced — whichever is reached first triggers deletion of the oldest data.

### Useful queries

```promql
# Container CPU usage (%)
rate(container_cpu_usage_seconds_total{name!=""}[5m]) * 100

# Container memory usage
container_memory_usage_bytes{name!=""}

# Host disk usage (%)
(node_filesystem_size_bytes - node_filesystem_free_bytes) / node_filesystem_size_bytes * 100

# Traefik request rate per service
rate(traefik_service_requests_total[5m])

# Traefik 5xx error rate
rate(traefik_service_requests_total{code=~"5.."}[5m])
```

---

## Grafana

Grafana is pre-configured via provisioning files mounted at startup — no manual datasource setup required.

### Authentication

Grafana is configured for Authentik OAuth2 login. Users in `superbox-admins` group get the `Admin` role; all others get `Viewer`.

The local admin account (`admin` / `GRAFANA_ADMIN_PASSWORD`) remains active as a fallback if Authentik is unavailable.

### Provisioning

`services/monitoring/grafana/provisioning/` contains:

| File | Purpose |
|------|---------|
| `datasources/datasource.yml` | Registers Prometheus and Alertmanager datasources |
| `dashboards/dashboards.yml` | Tells Grafana to load JSON dashboards from the same directory |

### Adding dashboards

1. Export a dashboard as JSON from Grafana UI (Dashboard → Share → Export)
2. Save the JSON file to `services/monitoring/grafana/provisioning/dashboards/`
3. Grafana hot-reloads dashboard files — no restart needed

Recommended community dashboards to import:

| Dashboard | Grafana ID | Contents |
|-----------|-----------|---------|
| Node Exporter Full | 1860 | Comprehensive host metrics |
| Docker Container & Host Metrics | 395 | Container overview |
| Traefik 2 | 11462 | Traefik request/latency/error metrics |
| Authentik | (from Authentik docs) | Login events and user activity |

To import by ID: Grafana → Dashboards → Import → enter ID → Load.

---

## Node Exporter

Node Exporter exposes hardware and OS metrics from the host. It runs with `pid: host` and read-only mounts of `/proc`, `/sys`, and `/` to read kernel metrics.

Key metric families:

| Metric | Description |
|--------|-------------|
| `node_cpu_seconds_total` | CPU time per mode (user, system, idle, iowait) |
| `node_memory_MemAvailable_bytes` | Available RAM |
| `node_filesystem_*` | Disk usage per mount point |
| `node_network_*` | Network bytes/packets per interface |
| `node_load1/5/15` | System load averages |
| `node_disk_*` | Disk I/O operations and bytes |

---

## cAdvisor

cAdvisor (Container Advisor) collects per-container resource usage from the Docker cgroup hierarchy. It requires `privileged: true` to access cgroup data.

Key metric families:

| Metric | Description |
|--------|-------------|
| `container_cpu_usage_seconds_total` | Cumulative CPU time |
| `container_memory_usage_bytes` | Current memory usage |
| `container_network_*` | Container network I/O |
| `container_fs_*` | Container filesystem usage |

---

## Alertmanager

Alertmanager handles alerts fired by Prometheus, deduplicates them, groups them, and routes them to configured receivers.

### Configuration

`services/monitoring/alertmanager/alertmanager.yml`:

- **Routing tree** — routes alerts by severity to different receivers
- **Receivers** — notification channels (email, Slack, webhook, PagerDuty, etc.)
- **Inhibition rules** — suppress warning alerts when a critical alert fires for the same service

### Configuring email alerts

Edit `alertmanager.yml`:

```yaml
global:
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: 'alertmanager@yourdomain.com'
  smtp_auth_username: 'your@gmail.com'
  smtp_auth_password: 'your-app-password'

receivers:
  - name: email-admin
    email_configs:
      - to: admin@yourdomain.com
        require_tls: true
```

Then update the route to use `email-admin` instead of `blackhole`.

### Adding alert rules

Create rule files and mount them into Prometheus. Add to `prometheus.yml`:

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml
```

Example rule file:

```yaml
groups:
  - name: superbox
    rules:
      - alert: HighDiskUsage
        expr: (node_filesystem_size_bytes - node_filesystem_free_bytes) / node_filesystem_size_bytes > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk usage above 85%"
          description: "{{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
```
