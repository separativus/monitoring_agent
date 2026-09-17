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
  hydra     10.0.50.10    (also runs the `monitoring` server stack)
  lab       10.0.50.11
  live      10.0.200.6    (offsite VPS, reachable via WireGuard)
  tibiafun  10.0.200.10   (offsite VPS, reachable via WireGuard)
  pi        192.168.100.2 (Raspberry Pi 3 B+, arm64, stretched service VLAN 100)
```

The server side generates two scrape jobs per host (`node-exporter-<name>` and `cadvisor-<name>`, with the `host` label baked in) from the `MONITOR_HOSTS` variable in `monitoring/.env` — see `monitoring/prometheus/generate-config.sh`.

Not every monitored host runs this agent: `syno` (Synology NAS, 10.0.50.5) has no Docker on ARM DSM and runs a native node_exporter instead (`:node` entry in `MONITOR_HOSTS`, managed per the gotchas in `monitoring/CLAUDE.md`). Don't point `deploy.sh` at it.

## Tech Stack

- **Runtime:** Docker / Docker Compose v2
- **Images (pinned):**
  - `prom/node-exporter:v1.12.1`
  - `gcr.io/cadvisor/cadvisor:v0.55.1`
- No application code, no language toolchain.

## Repository Layout

```
monitoring_agent/
├── docker-compose.yml   # the entire agent: 2 services, host bind-mounts, limits, healthchecks
├── .env.example         # template for the per-host .env (BIND_IP, optional cAdvisor limits)
├── deploy.sh            # ./deploy.sh <user@host> [bind_ip] — copies the compose file to ~/monitoring_agent, seeds .env, runs `docker compose up -d`
└── CLAUDE.md            # this file
```

The compose file is identical on every host. The only per-host input is `.env` next to it (gitignored, seeded by `deploy.sh`).

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
. ./.env   # exporters bind to BIND_IP only, localhost does not answer
curl -s http://$BIND_IP:9100/metrics | head
curl -s http://$BIND_IP:8080/healthz
curl -s -o /dev/null -w '%{time_total}s\n' http://$BIND_IP:8080/metrics   # must stay well under the 10 s scrape timeout
```

From `hydra`, verify Prometheus is actually scraping:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health:.health}'
```

### Configuration
Per-host values come from `.env` next to the compose file (template: `.env.example`):

- `BIND_IP` (required, `${BIND_IP:?}` in compose) — the host address both exporters bind to, i.e. the address Prometheus scrapes for that host (`MONITOR_HOSTS`). Nothing listens on other interfaces (IoT VLANs on hydra, public IPv4/IPv6 on live/tibiafun).
- `CADVISOR_MEM_LIMIT` / `CADVISOR_CPUS` (optional, default `1g` / `2.0`) — only `pi` overrides them (`512m` / `1.0`).

Everything else lives inline in `docker-compose.yml`:

- The compose project name is pinned via top-level `name: monitoring_agent` — this becomes the `stack` label on the server side and must be identical on every host (it used to drift to `monitoring-agent` on lab/live via directory-name derivation; fixed 2026-07-16).
- `node-exporter` runs with `--path.procfs=/host/proc`, `--path.sysfs=/host/sys`, `--path.rootfs=/rootfs`, and excludes pseudo-filesystems via `--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)`.
- `cadvisor` is `privileged: true` and bind-mounts the docker socket area read-only.
- `cadvisor` runs with `--disable_metrics=disk,<v0.55.1 default set>`: under the containerd snapshotter the per-container fs-usage walk covers the whole merged rootfs and starves/OOMs the container (see Gotchas). Dashboards only use the diskIO counters.
- The `node-exporter` healthcheck probes `/`, not `/metrics` (see Gotchas).
- The `cadvisor` healthcheck doubles as a dockerd-restart watchdog: it remembers dockerd's PID (`/var/run/docker.pid`) in a tmpfs `/tmp` and terminates cAdvisor when the PID changes, so the restart policy brings it back re-attached (see Gotchas).
- Both services log via `json-file` with `max-size: 10m`, `max-file: 3`.
- No secrets, nothing to vault. `.env` holds only an IP and limits.

## Deployment

### Hosts
Deployed identically on all four hosts: `hydra`, `lab`, `live`, `pi`. Both pinned images are multi-arch (amd64 + arm64 verified), so x86 boxes and the Raspberry Pi run the same compose file.

### Method
One command from this repo on hydra:

```bash
./deploy.sh <user@host>    # e.g. ./deploy.sh runner@192.168.100.2
```

It copies `docker-compose.yml` to `~/monitoring_agent` on the target, appends `BIND_IP=<host part of the argument>` to `~/monitoring_agent/.env` if that key is missing (pass a second argument to bind elsewhere), and runs `docker compose pull && docker compose up -d` there (no-op if nothing changed). Existing `.env` lines are never touched, so `pi`'s limit overrides survive redeploys. Requires SSH key auth and a docker-group user on the target. Containers are `restart: unless-stopped` so they survive reboots.

`hydra` and `lab` are git checkouts of this repo, so there `git pull && docker compose up -d` in the checkout is equivalent.

For a **new** host, afterwards register it once on the server side: add `<name>:<ip>` to `MONITOR_HOSTS` in `monitoring/.env` on hydra, `docker compose up -d prometheus`, run the verify gate (see `monitoring/CLAUDE.md`).

### Restart procedure

```bash
cd /path/to/monitoring_agent
docker compose pull
docker compose up -d         # recreate only changed services
docker compose logs -f --tail=50
```

### Resource budget per host
- `node-exporter`: `mem_limit: 128m`, `cpus: 0.5`
- `cadvisor`:      `mem_limit: 1g`, `cpus: 2.0` (defaults; `pi` pins `512m` / `1.0` in its `.env`)

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
  - Targets it expects: `<ip>:9100` and `<ip>:8080` for every `name:ip` entry in `MONITOR_HOSTS` (in `monitoring/.env`; jobs generated at Prometheus container start).
  - Server-side relabeling on cAdvisor jobs: drops GitHub-Actions job containers (`name=~"[0-9a-f]{32}_.*"`), promotes the compose project label into a `stack` label, then drops `id` and `container_label_.*` to control cardinality — keep that in mind before adding scrape labels here.
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
2. **Cardinality control on cAdvisor.** cAdvisor is the #1 cardinality offender in a Prometheus stack. The server side already drops `id` and `container_label_.*` via `metric_relabel_configs`; if more drops are needed, they belong on the **server** so the network payload still benefits — but `--docker_only`, `--store_container_labels=false`, and `--disable_metrics=` flags on cAdvisor itself are the cleanest approach. `--disable_metrics=disk,…` is set (see Configuration); the other two are not.
3. **cAdvisor `housekeeping_interval`** defaults to 1s in older versions and 10s in 0.55.x — leave it alone unless CPU pressure shows up. Setting it lower causes the well-known cAdvisor CPU runaway.
4. **node-exporter v1.11.0 (released 2026-04-04)** ships a distroless image variant. Only default collectors are enabled here; if textfile or systemd collectors are added later, enable one at a time and watch `scrape_duration_seconds`.
5. **OpenTelemetry Collector Docker Stats receiver** is a viable cAdvisor alternative for pure-Docker (non-Kubernetes) hosts and is simpler than cAdvisor for this exact topology. The Kubernetes Node SIG has a roadmap to phase cAdvisor out of its current role; for a homelab the migration isn't urgent, but it's the direction the ecosystem is moving.
6. **TLS / auth on `:9100` and `:8080`.** Both ports bind to `BIND_IP` only, i.e. the management/WireGuard address Prometheus scrapes, and are unauthenticated there. Acceptable inside the lab VLAN and the WG tunnel, but if these endpoints ever need to traverse the WireGuard link from `live` without WG, use `--web.config.file` on node-exporter for TLS + basic auth. Same goes for cAdvisor (`--http_auth_file`).

## Gotchas & Known Issues

- **`live` host symlink quirk — resolved.** The Django stack on `live` used to depend on a `/home/ameyze/ameyze-live` → `ameyze_live` symlink; restarting Docker without it destroyed data once. Verified 2026-07-16: all bind mounts now point at the real `/home/ameyze/ameyze_live/...` path, the symlink is gone and no longer needed. (History: `~/.claude/projects/-home-runner/memory/ameyze_live_path_quirk.md`.)
- **`live` is offsite over WireGuard.** Prometheus on `hydra` scrapes `live:9100` and `live:8080` through the WG tunnel. If WG is down, you'll see scrape failures for both `node-exporter-live` and `cadvisor-live`, not an agent problem.
- **cAdvisor needs `privileged: true`.** This is upstream-required, not a config mistake. It needs raw access to cgroups + the docker socket area.
- **Filesystem mount excludes use `$$` in compose YAML.** The regex `^/(sys|proc|dev|host|etc)($$|/)` uses double-dollar to escape compose's variable interpolation — single `$` would break the regex. Don't "fix" it.
- **Port collisions.** `:8080` is a popular port; check `ss -tlnp | grep 8080` before deploying on a new host. Harbor on `hydra` uses different ports, but other services may not.
- **`pi` is a Raspberry Pi 3 B+ with 1 GB RAM** already running AdGuard, step-ca and sync containers. The agent's actual footprint there is ~95 MiB (node-exporter ~23 MiB, cAdvisor ~70 MiB at ~7 % CPU) — fine, but don't raise the cAdvisor limits or lower its `housekeeping_interval` on that host. Its `.env` therefore pins `CADVISOR_MEM_LIMIT=512m` / `CADVISOR_CPUS=1.0`; `pi` also still runs `overlay2`, so the fs-usage walk was never a problem there.
- **cAdvisor goes blind after a dockerd restart.** With `live-restore` the app containers keep running through `systemctl restart docker`, but cAdvisor keeps the dead Docker connection from its start: the target stays `up` and "healthy", yet `count(container_last_seen{name!=""})` for that instance drops to 0 and every container panel goes blank (hydra 2026-07-03). Manual fix was `docker restart cadvisor`; since 2026-09-17 the healthcheck does it automatically (dockerd-PID marker in tmpfs `/tmp`, `kill 1` on change, restart policy restarts it within ~30 s). Diagnosis if it ever recurs: `docker inspect cadvisor --format '{{json .State.Health.Log}}'` shows the "dockerd restarted (old -> new)" line; `count by(instance)(container_last_seen{name!=""})` in Prometheus.
- **cAdvisor + containerd snapshotter = fs-usage walk over the full rootfs.** hydra, lab, live and tibiafun run Docker with `Driver=overlayfs` (`io.containerd.snapshotter.v1`). There cAdvisor's fsHandler walks `/var/lib/docker/rootfs/overlayfs/<cid>` (the merged view, GBs per container) instead of just the upperdir. With many or crash-looping containers (lab 2026-09-11) or simply after a reboot that starts all containers at once (hydra 2026-09-16, 31 containers) the walks take minutes, pin the CPU limit, push the container into its memcg OOM every ~15 min and `/metrics` stops answering within the 10 s scrape timeout → `TargetDown`. Symptoms: `docker stats cadvisor` at ~100 % CPU / at the memory limit, `docker logs cadvisor | grep fsHandler` full of "took 1m…", `dmesg | grep oom` naming cadvisor. That is why `disk` is in `--disable_metrics`; don't remove it.
- **node-exporter healthcheck must not hit `/metrics`.** `wget --spider` closes the socket after the response headers; node-exporter then logs `error encoding and sending metric family … broken pipe` once per metric family, ~560 lines/min, which grew a 4 GB json log on hydra. The check probes the landing page `/` instead (the `/-/healthy` endpoint does not exist in v1.12.1), and both services now rotate their logs.
- **Image registry.** Images come from Docker Hub and `gcr.io`, **not** from `hydra.registry.com` (the homelab Harbor). If outbound DNS/egress is restricted, mirror them into Harbor first.
- **No dashboards or alert rules in this repo.** Those live in the `monitoring` sibling under `monitoring/grafana/dashboards` and (if/when added) Prometheus rule files.

## External Resources

- node-exporter upstream: https://github.com/prometheus/node_exporter
- cAdvisor upstream: https://github.com/google/cadvisor
- Prometheus cAdvisor guide: https://prometheus.io/docs/guides/cadvisor/
- Grafana Alloy (successor unified agent): https://grafana.com/docs/alloy/latest/
- Sibling repo: `/home/runner/monitoring` (Prometheus + Grafana server)
- Server-side scrape config: `/home/runner/monitoring/prometheus/prometheus.yml.tmpl`
