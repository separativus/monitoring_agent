# monitoring_agent

## Overview

This repo is the **agent half** of a two-repo homelab observability split:

- **`monitoring_agent`** (this repo) — runs on every host, exposes host + container metrics over HTTP for pull-based scraping.
- **`monitoring`** (sibling at `/home/runner/monitoring`) — runs only on `hydra`, hosts Prometheus + Grafana, scrapes every agent across the homelab.

The agent stack is intentionally minimal: two upstream containers (`node-exporter` and `cAdvisor`) wired up with sane resource limits and healthchecks. No custom code, no secrets, no remote-write — just two `/metrics` endpoints waiting to be scraped.

## Architecture

```
              host kernel / cgroups / docker.sock
                          |
              +-----------v-----------+
              |   monitoring_agent    |
              |   (this repo)         |
              |                       |
              |  node-exporter :9100  |  <-- /proc, /sys, /rootfs
              |  cadvisor      :8080  |  <-- /var/run, /var/lib/docker
              +-----------+-----------+
                          |
                          | HTTP pull (Prometheus scrape, 15s)
                          |
              +-----------v-----------+
              |  monitoring (hydra)   |
              |  prometheus :9090     |
              |  grafana    :3000     |
              +-----------------------+

Hosts running monitoring_agent:
  hydra  10.0.50.10   (also runs the `monitoring` server stack)
  lab    10.0.50.11
  live   10.10.10.10  (offsite, reachable via WireGuard)
```

`monitoring/prometheus/prometheus.yml.tmpl` defines six scrape jobs that point at this agent on each host: `node-exporter-{hydra,lab,live}` and `cadvisor-{hydra,lab,live}`, with the `host` label baked in by the server side.

## Tech Stack

- **Runtime:** Docker / Docker Compose v2
- **Images (pinned):**
  - `prom/node-exporter:v1.11.0`
  - `gcr.io/cadvisor/cadvisor:v0.55.1`
- No application code, no language toolchain.

## Repository Layout

```
monitoring_agent/
├── docker-compose.yml   # the entire agent: 2 services, host bind-mounts, limits, healthchecks
└── CLAUDE.md            # this file
```

That's it. Single-file deployment by design.

## Development

### Prerequisites
- Docker Engine with Compose v2 (`docker compose ...`)
- Read access to `/proc`, `/sys`, `/`, `/var/run`, `/var/lib/docker`, `/dev/disk` on the host
- Inbound TCP `9100` and `8080` reachable from `hydra` (10.0.50.10) on the management network

### Build & Run
Pure compose, no build step:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

### Testing
Smoke-test from the host:

```bash
curl -s http://localhost:9100/metrics | head
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/metrics | head
```

From `hydra`, verify Prometheus is actually scraping:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health:.health}'
```

### Configuration
There is no config file. Everything lives inline in `docker-compose.yml`:

- `node-exporter` runs with `--path.procfs=/host/proc`, `--path.sysfs=/host/sys`, `--path.rootfs=/rootfs`, and excludes pseudo-filesystems via `--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)`.
- `cadvisor` is `privileged: true` and bind-mounts the docker socket area read-only.
- No secrets. No env file. Nothing to vault.

## Deployment

### Hosts
Deployed identically on all three hosts: `hydra`, `lab`, `live`.

### Method
Docker Compose, run from a checkout of this repo. Containers are `restart: unless-stopped` so they survive reboots.

### Restart procedure

```bash
cd /path/to/monitoring_agent
docker compose pull
docker compose up -d         # recreate only changed services
docker compose logs -f --tail=50
```

### Resource budget per host
- `node-exporter`: `mem_limit: 128m`, `cpus: 0.5`
- `cadvisor`:      `mem_limit: 512m`, `cpus: 1.0`

## Signals Collected

| Source        | Port | Endpoint    | What                                                                        |
|---------------|------|-------------|-----------------------------------------------------------------------------|
| node-exporter | 9100 | `/metrics`  | CPU, load, memory, disk usage/IO, network, filesystem, time, uname, hwmon   |
| cAdvisor      | 8080 | `/metrics`  | Per-container CPU, memory, network, blkio, fs (via cgroups + docker.sock)   |
| cAdvisor      | 8080 | `/healthz`  | Liveness probe                                                              |

Scrape cadence is set on the **server** side (`monitoring` repo): `scrape_interval: 15s`, `evaluation_interval: 15s`. Retention is 90 days in Prometheus.

## Integration Points

- **Sibling `monitoring` repo at `/home/runner/monitoring`** — this is the only consumer.
  - Server config: `monitoring/prometheus/prometheus.yml.tmpl`
  - Targets it expects: `${HYDRA_IP}:9100`, `${HYDRA_IP}:8080`, `${LAB_IP}:9100`, `${LAB_IP}:8080`, `${LIVE_IP}:9100`, `${LIVE_IP}:8080` (template variables interpolated at container start from `.env`).
  - Server-side relabeling drops `id` and `container_label_.*` labels from cAdvisor to control cardinality — keep that in mind before adding scrape labels here.
- **Grafana** on hydra (`monitoring` repo, port `3000`) consumes Prometheus as its only datasource.
- No alerting, no remote-write, no push gateway.

## Conventions

- **Pinned image tags only.** No `:latest` anywhere — both images are tagged to specific versions (`v1.11.0`, `v0.55.1`).
- **Read-only bind mounts** wherever the container only needs to observe (`/proc`, `/sys`, `/`, `/var/run`, `/var/lib/docker`, `/dev/disk`).
- **Resource limits on every service.** Required to prevent cAdvisor runaway.
- **Healthchecks on every service.** 30s interval, 5s timeout, 3 retries.
- **Stable container names** (`node-exporter`, `cadvisor`) for predictable `docker ps` output across hosts.

## Current Best Practices (2026)

These are 2026-current notes worth knowing before making changes:

1. **Grafana Agent went EOL on 2025-11-01.** Its replacement, **Grafana Alloy**, is now the recommended unified collector. Alloy ships `prometheus.exporter.unix` (drop-in for node-exporter — same metric names, dashboards keep working) and `prometheus.exporter.cadvisor` in a single binary, so a future migration could collapse this whole compose file into one Alloy container per host. Worth considering if logs/traces are ever added — Alloy handles all three signals from one config.
2. **Cardinality control on cAdvisor.** cAdvisor is the #1 cardinality offender in a Prometheus stack. The server side already drops `id` and `container_label_.*` via `metric_relabel_configs`; if more drops are needed, they belong on the **server** so the network payload still benefits — but `--docker_only`, `--store_container_labels=false`, and `--disable_metrics=` flags on cAdvisor itself are the cleanest approach. Currently none of these are set, so every metric ships.
3. **cAdvisor `housekeeping_interval`** defaults to 1s in older versions and 10s in 0.55.x — leave it alone unless CPU pressure shows up. Setting it lower causes the well-known cAdvisor CPU runaway.
4. **node-exporter v1.11.0 (released 2026-04-04)** ships a distroless image variant. Only default collectors are enabled here; if textfile or systemd collectors are added later, enable one at a time and watch `scrape_duration_seconds`.
5. **OpenTelemetry Collector Docker Stats receiver** is a viable cAdvisor alternative for pure-Docker (non-Kubernetes) hosts and is simpler than cAdvisor for this exact topology. The Kubernetes Node SIG has a roadmap to phase cAdvisor out of its current role; for a homelab the migration isn't urgent, but it's the direction the ecosystem is moving.
6. **TLS / auth on `:9100` and `:8080`.** Currently both ports are wide open on the host. Acceptable inside the lab VLAN, but if these endpoints ever need to traverse the WireGuard link from `live` without WG, use `--web.config.file` on node-exporter for TLS + basic auth. Same goes for cAdvisor (`--http_auth_file`).

## Gotchas & Known Issues

- **`live` host symlink quirk.** This agent runs on `live` (10.10.10.10). On `live`, restarting `dockerd` will destroy data unless `/home/ameyze/ameyze-live` symlink → `ameyze_live` is intact. Verify the symlink **before** running `docker compose down` or restarting Docker on that host. (See `~/.claude/projects/-home-runner/memory/ameyze_live_path_quirk.md`.)
- **`live` is offsite over WireGuard.** Prometheus on `hydra` scrapes `live:9100` and `live:8080` through the WG tunnel. If WG is down, you'll see scrape failures for both `node-exporter-live` and `cadvisor-live`, not an agent problem.
- **cAdvisor needs `privileged: true`.** This is upstream-required, not a config mistake. It needs raw access to cgroups + the docker socket area.
- **Filesystem mount excludes use `$$` in compose YAML.** The regex `^/(sys|proc|dev|host|etc)($$|/)` uses double-dollar to escape compose's variable interpolation — single `$` would break the regex. Don't "fix" it.
- **Port collisions.** `:8080` is a popular port; check `ss -tlnp | grep 8080` before deploying on a new host. Harbor on `hydra` uses different ports, but other services may not.
- **Image registry.** Images come from Docker Hub and `gcr.io`, **not** from `hydra.registry.com` (the homelab Harbor). If outbound DNS/egress is restricted, mirror them into Harbor first.
- **No dashboards or alert rules in this repo.** Those live in the `monitoring` sibling under `monitoring/grafana/dashboards` and (if/when added) Prometheus rule files.

## External Resources

- node-exporter upstream: https://github.com/prometheus/node_exporter
- cAdvisor upstream: https://github.com/google/cadvisor
- Prometheus cAdvisor guide: https://prometheus.io/docs/guides/cadvisor/
- Grafana Alloy (successor unified agent): https://grafana.com/docs/alloy/latest/
- Sibling repo: `/home/runner/monitoring` (Prometheus + Grafana server)
- Server-side scrape config: `/home/runner/monitoring/prometheus/prometheus.yml.tmpl`
