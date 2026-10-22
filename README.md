# devoplats

Self-hosted deployment platform for GitHub: push to `dev`/`main` → ephemeral
self-hosted runner → build & push to GHCR → deploy to Docker Compose with
automatic healthcheck, rollback, backups, and migrations.

Server-side scripts + webhook. Platform settings live in one `.env` file; each
app's secrets live beside its config in `configs/<app>/.env`.

```
push dev/main
   │
   ├─ GitHub Actions (in-repo workflows: build → image :sha → GHCR)
   │
   └─ workflow_job webhook ──▶ Flask endpoint (systemd)
                                 │ verifies HMAC signature
                                 ▼
                          ephemeral runner container
                          (myoung34/github-runner)
                          mounts <install-root> + <APPS_ROOT>, runs on self-hosted label
                                 │
                                 ▼
                          devops deploy ─ sync app env → login → (prod) backup
                                       → pull → compose up → wait → migrate
                                       → healthcheck → OK | auto-rollback
```

## Layout

```
bin/devops              CLI entry point
platform/               deploy, rollback, backup, migrate, healthcheck, restore-db, test, doctor
platform/webhook        webhook systemd management (run/install/start/status/logs)
platform/lib/           shared libs (constants, env loading, docker, healthcheck, ...)
src/devoplats/          Python package: Flask webhook
pyproject.toml          package metadata and entry point
configs/<app>/          per-app config.yml + canonical .env (server, gitignored)
github-runners/
  cleanup.sh            manual: reaps stuck runners / prunes dangling images
  gh-runner-webhook.service.template  systemd unit (rendered by devops webhook install)
docs/                   architecture, remote Docker, secret management
examples/               config.yml, compose.yml, workflow templates
```

## Install

Prerequisites: Linux host, Docker + Compose plugin (v2.6+), `python3`, `curl`,
`yq`, and `ssh` when using a remote Docker daemon.

```bash
git clone <your-repo-url> /opt/devoplats
cd /opt/devoplats
cp .env.example .env && nano .env      # platform settings
```

1. **Install and start the webhook** (systemd-managed; start it before pushing
   so jobs can be dispatched):
   ```bash
   python3 -m venv .venv
   .venv/bin/pip install -e .             # installs devoplats-webhook
   sudo ./bin/devops webhook install      # renders and enables the unit
   sudo ./bin/devops webhook start
   ./bin/devops webhook status            # unit active + /healthz reachable
   ```
2. **Expose the webhook** through your TLS reverse proxy. The service listens
   on `WEBHOOK_HOST:WEBHOOK_PORT` and serves `/webhooks/github` and `/healthz`.
3. **Register the GitHub webhook** on your org/repo: URL
   `https://<your-host>/webhooks/github`, content type `application/json`,
   secret = `GITHUB_WEBHOOK_SECRET`, event = **Workflow jobs**.
4. **Optionally schedule cleanup**:
   ```bash
   echo '*/5 * * * * root /opt/devoplats/github-runners/cleanup.sh' > /etc/cron.d/devoplats-cleanup
   ```
5. **Run the preflight**: `./bin/devops doctor` (see
   [docs/remote-docker.md](docs/remote-docker.md) for remote hosts).

Each app is deployed on its own Compose network, created automatically during
the first deploy; no platform-wide Docker network is required.

The webhook pulls `myoung34/github-runner:latest` when the runner image is not
present locally. Set `RUNNER_IMAGE` only to pin a version or use a private
image.

## Configure

Platform knobs live in `.env` (see `.env.example` for the annotated list):

| Group | Variables |
|---|---|
| Paths | `DEVOPS_ROOT` (auto), `APPS_ROOT`, `LOCKS_ROOT` (auto) |
| Registry | `REGISTRY` |
| Runner | `RUNNER_IMAGE` (default `myoung34/github-runner:latest`), `RUNNER_SCOPE` (`org`/`repo`), `ORG_NAME`, `REPO_URL`, `DNS_SERVERS` |
| Creds | `GHCR_USERNAME/TOKEN`, `ACCESS_TOKEN`, `GITHUB_WEBHOOK_SECRET`, `BACKUP_<APP>_USER/PASS` |
| Webhook | `WEBHOOK_HOST/PORT`, `WEBHOOK_LOG` |
| Docker target | `DOCKER_HOST` (remote daemon), `RUNNER_SSH_DIR`, `HEALTHCHECK_PROBE_IMAGE` |
| Doctor | `MIN_DOCKER_VERSION`, `MIN_COMPOSE_VERSION`, `MIN_FREE_DISK_GB` |
| Platform | `DEPLOY_ENVS`, `SERVICE_WAIT_TIMEOUT` |

Precedence: **shell env > `.env` > built-in default.** No code edits needed to
move paths, switch registry, or add an environment (`staging`).

Per-app settings (healthcheck, migration, backup, and tests) live in
`${CONFIGS_ROOT}/<app>/config.yml`; see
[`examples/config.yml`](examples/config.yml). App secrets live beside it in
`${CONFIGS_ROOT}/<app>/.env`.

## Adopt an app

The app repo needs:

1. `Dockerfile`
2. `compose.yml` — see [`examples/compose.yml`](examples/compose.yml)
3. `.github/workflows/deploy.yml`, `build.yml`, and `deploy-dev.yml` — see
   [`examples/deploy.yml`](examples/deploy.yml), [`examples/build.yml`](examples/build.yml),
   and [`examples/deploy-dev.yml`](examples/deploy-dev.yml) (copy them into the app repo)
4. On the server: `<APPS_ROOT>/<app>/compose.yml` (same file) and
   `<install-root>/configs/<app>/config.yml` — see [`examples/config.yml`](examples/config.yml)
5. App secrets: create `<install-root>/configs/<app>/.env` (mode 600). Deploy
   copies it to `<APPS_ROOT>/<app>/.env` for Compose
6. A `dev` and `main` branch

### Naming

Any GitHub repo name works (letters, digits, `.`, `_`, `-`). The platform keeps
the name as-is for paths — the runtime dir must match the name passed via
`--app`, byte-for-byte — and derives a canonical **slug** for everything
Docker needs: lowercase, runs of non-alphanumerics become `-`, edges trimmed.

| Repo / `--app` | Slug (image, compose project) | Root `.env` keys |
|---|---|---|
| `myapp` | `myapp` | `BACKUP_MYAPP_{USER,PASS}` |
| `My-App.v2` | `my-app-v2` | `BACKUP_MY_APP_V2_{USER,PASS}` |
| `my_app` | `my-app` | `BACKUP_MY_APP_{USER,PASS}` |

`BACKUP_*` is local-only and belongs in the root `.env`. App secrets live at
`${CONFIGS_ROOT}/<app>/.env`; deploy copies that file to
`${APPS_ROOT}/<app>/.env`.

Since images are `${REGISTRY}/<slug>` (registry paths are lowercased
automatically) and compose names are `${APP_SLUG}-${ENVIRONMENT}`, compose
files and `config.yml` should reference `${APP_SLUG}` instead of hardcoding
the app name. Two names that derive the same slug (e.g. `My-App` and
`my.app`) collide — don't adopt both on one platform.

## CLI

```
devops deploy    --app APP --env ENV --tag TAG   # build artifact → running container
devops rollback  --app APP --env ENV             # previous digest, verified by healthcheck
devops backup    --app APP --env ENV             # dump DBs listed in config.yml
devops migrate   --app APP --env ENV             # run migration.command in container
devops healthcheck --app APP --env ENV           # GET healthcheck.url
devops test      --app APP                       # run test.command/steps in <APPS_ROOT>/<app>
devops restore-db --app APP --backup FILE        # interactive only — never from CI
devops doctor [--app APP --env ENV] [--tag TAG]  # SSH/engine/disk/registry preflight
devops webhook run                               # foreground (development)
devops webhook install|start|stop|restart        # systemd unit management (root)
devops webhook status|logs                       # service health / journal
```

Compose files may use named volumes only (bind mounts are rejected), and
healthcheck URLs must target `${APP_SLUG}-${ENVIRONMENT}`. Each app runs on
its own Compose network. See [docs/remote-docker.md](docs/remote-docker.md).

Deploy pipeline: sync app env → login → (prod) backup → pull → `compose up` →
wait for health (60s) → migrate → HTTP healthcheck. Deploy and rollback take a
per-app/environment lock, so a second operation for the same environment fails
fast. Any failure → automatic rollback to the previous image digest. History in
`history/<app>.log`, detail in `logs/<app>/deploy.log`, versions in
`platform/versions/`.

## Docs

- [docs/architecture.md](docs/architecture.md) — server-side architecture and deploy flow
- [docs/remote-docker.md](docs/remote-docker.md) — remote Docker daemon setup, doctor, and constraints
- [docs/secret-management.md](docs/secret-management.md) — local secret layout and rotation runbooks

## License

[MIT](LICENSE)
