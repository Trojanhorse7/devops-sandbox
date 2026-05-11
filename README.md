# Devops-sandbox

A **single-VM**, Docker-first “mini Heroku” for **short-lived environments**: create an isolated stack behind Nginx, ship workload logs to disk, poll `/health`, simulate outages, and let TTL-driven cleanup tear everything down automatically.

## Architecture

### System Overview

![System Overview](docs/System%20Overview.png)

### Environment Lifecycle

![Environment Lifecycle](docs/Environment%20Lifecycle.png)

### TTL Auto-Cleanup

![TTL Auto-Cleanup](docs/TTL%20Auto-Cleanup.png)

### Outage Simulation State Machine

![Outage Simulation](docs/Outage%20Simulation.png)

**Nginx + networking model (what reviewers should know):**

1. Each environment gets its own bridge network `sandbox-net-<ENV_ID>`.
2. The workload runs on that **only** (plus labels `sandbox.env` / `sandbox.role=workload`).
3. After each create, the edge Nginx container is `docker network connect`-ed into that network so it can `proxy_pass http://sandbox-app-<ENV_ID>:8080/;` using Docker’s embedded DNS.
4. A path-prefix route (`/env/<ENV_ID>/…`) keeps every environment on **one published host port** (`NGINX_HTTP_PORT`, default `80`).

## Log shipping (chosen approach)

**Approach A (simple, implemented):** during create, the platform runs `docker logs -f <workload> >> logs/<ENV_ID>/app.log &` and stores the shipper **PID** in `envs/<ENV_ID>.json`. `destroy_env.sh` **kills that PID first** to avoid background “zombie” log tasks.

## Prerequisites

- Linux x86_64/amd64 VM (this is the primary target; macOS may work with Docker Desktop but it is not CI-guaranteed).
- Docker Engine + Docker Compose v2 (`docker compose …`).
- Python **3.10+** (for the control API container build + host-side poller utilities).
- `bash`, `openssl`, standard GNU userland (`make`, `nohup`, `curl` recommended for demos).

Secrets live in **`.env`** (never commit). Start from `.env.example`.

## One-command bring-up (after clone)

From the repo root:

```bash
make quickstart
```

What this does:

1. Copies `.env.example` → `.env` on first run (if missing) and patches `SANDBOX_ROOT` to your current directory.
2. Builds and starts **Nginx + API** via Compose.
3. Starts the **TTL cleanup daemon** and **health poller** under `nohup` (PIDs in `.cleanup.pid` / `.health_poller.pid`).

### From zero to first healthy env (≤ 5 commands)

```bash
git clone <your-fork-or-repo-url> devops-sandbox
cd devops-sandbox
make quickstart
SANDBOX_ROOT="$PWD" bash platform/create_env.sh demo 3600
curl -fsS "http://127.0.0.1:80/env/<paste-env-id-here>/health"
```

API explorer (when `make quickstart` succeeds): `http://127.0.0.1:9090/docs`

## Makefile targets

| Target | Purpose |
|--------|---------|
| `make quickstart` | `init` + `up` |
| `make init` | Ensure `.env` exists + patch `SANDBOX_ROOT` |
| `make up` | Compose up + background daemon + poller |
| `make down` | Stop pollers, destroy all envs, `docker compose down` |
| `make create` | Interactive create (name + TTL) |
| `make destroy ENV=…` | Destroy one env |
| `make logs ENV=…` | Tail `logs/<ENV>/app.log` |
| `make health` | Table of env IDs, status, TTL remainder, last health lines |
| `make simulate ENV=… MODE=…` | Chaos wrapper (see below) |
| `make clean` | Aggressive wipe of local state/log artefacts |

## Control API

All routes are JSON where applicable:

| Method | Path | Behaviour |
|--------|------|-----------|
| `POST` | `/envs` | Body `{"name":"…","ttl":1800}` → `create_env.sh` |
| `GET` | `/envs` | List active envs + **TTL remaining** |
| `DELETE` | `/envs/{id}` | `destroy_env.sh` |
| `GET` | `/envs/{id}/logs` | Last **100** lines of `app.log` |
| `GET` | `/envs/{id}/health` | Last **10** structured health probes |
| `POST` | `/envs/{id}/outage` | Body `{"mode":"crash"}` → `simulate_outage.sh` |

## Demo walkthrough

1. **Bootstrap:** `make quickstart` and wait until `docker compose ps` shows `sandbox-nginx` + `sandbox-api` healthy.
2. **Create:** `SANDBOX_ROOT="$PWD" bash platform/create_env.sh staging 1800` (note printed `env-…` URL).
3. **Deploy / verify:** `curl http://127.0.0.1:80/env/<id>/` and `/health`.
4. **Observe health:** `make health` — after ~30s you should see JSON lines appended in `logs/<id>/health.log`.
5. **Simulate outage:** `make simulate ENV=<id> MODE=crash` — within **≤90s** (three 30s poller cycles) the state file flips to `degraded` and stderr shows a warning.
6. **Recover:** `make simulate ENV=<id> MODE=recover`.
7. **Auto-destroy:** create with a tiny TTL (e.g. `60`) and watch `logs/cleanup.log`; `destroy_env.sh` should run automatically and archive logs to `logs/archived/<id>/`.

Chaos modes supported by `platform/simulate_outage.sh`:

- `crash` — `docker kill` workload (recover = `docker start`)
- `pause` — `docker pause` (recover = `docker unpause`)
- `network` — disconnect workload from its env network (recover = reconnect)
- `recover` — undo the last recorded simulation for that env
- `stress` — starts a tight busy loop inside the workload (recover tries `pkill` best-effort)

**Safety guard:** simulations refuse containers labeled `sandbox.platform=control` and refuse the configured `NGINX_CONTAINER_NAME` / `API_CONTAINER_NAME`.

## GitHub Actions

This repository is intentionally minimal; add a workflow that runs `shellcheck`, builds `Dockerfile.api`, and runs a compose smoke test if you want CI gold stars.

## Known limitations

- **Single-node only** — everything assumes one Docker host; there is no multi-VM orchestration.
- **Approach A log shipping** — if the host reboots, stored PIDs may be stale; environments should be recreated or destroyed cleanly.
- **Health poller location** — the Makefile starts it on the **host** so it can hit `127.0.0.1:${NGINX_HTTP_PORT}`; moving it into a container requires routing/proxy adjustments.
- **`stress` cleanup** — recovery uses pattern-based `pkill` and may be imperfect on unusual images.
- **Nginx snippet reload** — rapid churn of many environments may hit `open file` limits; not load-tested.
- **Windows** — development on Windows is untested; Linux VM is the reference platform.

## Submission  

- **Walkthrough video** :  https://drive.google.com/file/d/1qf7CvUC32DKePSElOvqUax1l9GLANbhH/view?usp=sharing

```
devops-sandbox/
├── docs/
│   ├── Environment Lifecycle.png
│   ├── Outage Simulation.png
│   ├── System Overview.png
│   └── TTL Auto-Cleanup.png
├── platform/
│   ├── api.py
│   ├── cleanup_daemon.sh
│   ├── common.sh
│   ├── create_env.sh
│   ├── demo/
│   ├── destroy_env.sh
│   ├── patch_env_root.py
│   ├── show_health.py
│   └── simulate_outage.sh
├── nginx/
│   ├── conf.d/
│   └── nginx.conf
├── monitor/
│   └── health_poller.py
├── logs/
├── envs/
├── docker-compose.yml
├── Dockerfile.api
├── Makefile
└── README.md
```
