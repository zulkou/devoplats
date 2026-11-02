# Getting Started

Where to run the platform, what it needs from its host, and everything to set up
before the first deploy.

## Where to run it (recommendation)

**Run the platform host on an always-on Linux server with a public domain.**
A small VPS is enough. The apps themselves can run on the same box or on a
separate Docker host (see [Typical layouts](#typical-layouts)).

**A local machine is for evaluation only.** It works with a tunnel, but it is
not a production option (see [Running locally](#running-locally-evaluation-only)).

## Why: what the platform needs from its host

These are not preferences; each one comes from how the platform works:

| Requirement | Why it matters |
|---|---|
| **Public webhook URL** | GitHub POSTs `workflow_job` events to `https://<host>/webhooks/github`. That needs a domain, DNS, a TLS reverse proxy, and an open 443. A machine behind NAT cannot receive the events that start deploys. |
| **Always-on host** | Pushes trigger the webhook, which starts an ephemeral runner. A sleeping or offline host misses webhooks and deploys. |
| **Linux + systemd + root** | `devops webhook install` renders and enables a systemd unit; `start`/`stop`/`status` manage it. |
| **Docker on the host** | Ephemeral runners are Docker containers that mount the platform checkout, `<APPS_ROOT>`, and `/var/run/docker.sock`. Deploy jobs execute there. |
| **Stable home for state** | Locks (`locks/`), versions (`platform/versions/`), history (`history/`), logs (`logs/`), and backups (`backups/`) are local files. Moving hosts means moving this state. |
| **Stable home for secrets** | `ACCESS_TOKEN`, `GITHUB_WEBHOOK_SECRET`, and `GHCR_*` live in `<install-root>/.env`. Keep them on a managed server, not a laptop. |

Builds do **not** run here: GitHub Actions builds and pushes images to GHCR.
The platform host dispatches runners and runs the deploy/rollback/backup/
migration commands.

## Typical layouts

**All-in-one** — webhook, runners, and the local Docker daemon on one server.
Simplest; good when apps fit on the same box.

**Split** — a small platform host (public, always-on) plus a separate Docker
host for app containers, reached over SSH with `DOCKER_HOST=ssh://<alias>`.
The remote host needs neither the platform checkout nor the Compose plugin.
See [remote-docker.md](remote-docker.md).

**Suggested sizing for the platform host:** 2 vCPU, 2 GB RAM, and at least
10 GB free disk. `devops doctor` fails below `MIN_FREE_DISK_GB` (default 5).
Size the Docker host for the apps themselves.

## Running locally (evaluation only)

Local works only if GitHub can reach the webhook, so you need a public tunnel
(cloudflared, ngrok, Tailscale Funnel, ...). Start with the existing
`WEBHOOK_PORT` (default `10000`):

```bash
# bind the webhook to localhost only; the tunnel is the public entry point
# set WEBHOOK_HOST=127.0.0.1 in .env, then:
./bin/devops webhook run

# in another terminal: expose it
cloudflared tunnel --url http://localhost:10000
# → https://<random>.trycloudflare.com
```

Register `https://<random>.trycloudflare.com/webhooks/github` as the GitHub
webhook, after `devoplats` is running and the tunnel is up.

Caveats:

- **The URL changes on every quick-tunnel start.** Re-register the GitHub
  webhook each time, or use a named tunnel with your own domain.
- **The machine must stay awake.** Sleep, network changes, or a dead tunnel
  means missed webhooks and missed deploys.
- **Your laptop holds production secrets.** `ACCESS_TOKEN` and
  `GITHUB_WEBHOOK_SECRET` end up on a personal device, outside the server's
  backup and access controls.
- **Tunnel URLs are public.** Anyone who learns the URL can send requests; the
  HMAC check protects the endpoint, but the exposure is still wider than a
  firewalled server.

Use local for a demo or for developing the platform itself, then move to a
server before pointing real applications at it.

## Setup checklist

### 1. Server and network

- [ ] An always-on Linux server with a domain (or subdomain) pointed at it.
- [ ] A TLS reverse proxy (Caddy, nginx, ...) forwarding to
      `WEBHOOK_HOST:WEBHOOK_PORT`. It must pass `/webhooks/github` and
      `/healthz` through unchanged.
- [ ] Firewall: allow `443` (and your admin port, e.g. `22`). Keep
      `WEBHOOK_PORT` internal — only the proxy should reach it.
- [ ] Docker Engine and the Compose plugin (v2.6+), `python3`, `curl`, and
      `yq` installed. `ssh` too when using a remote Docker host.
- [ ] Outbound access to `github.com` and `ghcr.io`.

### 2. Install the platform

```bash
git clone <your-repo-url> /opt/devoplats
cd /opt/devoplats
cp .env.example .env && nano .env
```

Fill in `.env`:

| Key | Value |
|---|---|
| `REGISTRY` | `ghcr.io/<your-owner>` |
| `GHCR_USERNAME` / `GHCR_TOKEN` | Credentials with package **read** access (the platform pulls app images) |
| `ACCESS_TOKEN` | PAT the runner image uses to register runners: `repo` scope for repo runners, `admin:org` for org runners |
| `GITHUB_WEBHOOK_SECRET` | Random string; the same value goes into the GitHub webhook |
| `RUNNER_SCOPE` + `ORG_NAME` or `REPO_URL` | Where the ephemeral runners register |
| `DEPLOY_ENVS` | Environments `--env` accepts (default `dev prod`) |

Then:

- [ ] `.env` is mode `600` (`chmod 600 .env`).
- [ ] Install and start the webhook:

  ```bash
  python3 -m venv .venv
  .venv/bin/pip install -e .
  sudo ./bin/devops webhook install
  sudo ./bin/devops webhook start
  ./bin/devops webhook status    # unit active + /healthz reachable
  ```

### 3. GitHub side

- [ ] Register a webhook on the org or repo:
  - Payload URL: `https://<your-host>/webhooks/github`
  - Content type: `application/json`
  - Secret: `GITHUB_WEBHOOK_SECRET`
  - Event: **Workflow jobs** (only this event is processed)
- [ ] With `RUNNER_SCOPE=org`, the `ACCESS_TOKEN` needs org runner
      registration rights, and the repos must be allowed to use org
      self-hosted runners.
- [ ] Send a test delivery (or push to `dev`) and confirm GitHub's
      **Recent Deliveries** show a 2xx.

### 4. Adopt an app

In the app repository:

- [ ] `Dockerfile` at the repository root (the build context is the repo root).
- [ ] `compose.yml` — start from [`examples/compose.yml`](../examples/compose.yml).
- [ ] `.github/workflows/build.yml`, `deploy.yml`, and `deploy-dev.yml` —
      copy from [`examples/`](../examples).
- [ ] `dev` and `main` branches.

On the platform host:

- [ ] `<APPS_ROOT>/<app>/compose.yml` (the same file as the app repo).
- [ ] `<install-root>/configs/<app>/config.yml` — healthcheck, migration,
      backup, tests. Start from [`examples/config.yml`](../examples/config.yml).
- [ ] `<install-root>/configs/<app>/.env` — app secrets, mode `600`.
- [ ] Optional: `BACKUP_<APP>_USER/PASS` in the root `.env` for database
      backups.

Optional extras:

- [ ] Schedule runner cleanup:
      `echo '*/5 * * * * root /opt/devoplats/github-runners/cleanup.sh' > /etc/cron.d/devoplats-cleanup`
- [ ] Use a remote Docker host — see [remote-docker.md](remote-docker.md).
- [ ] Review the secret layout and rotation steps in
      [secret-management.md](secret-management.md).

### 5. Verify

- [ ] `./bin/devops doctor` passes.
- [ ] `./bin/devops doctor --app <app> --env dev` passes for the app.
- [ ] Push to `dev`: the webhook delivery returns 2xx, an ephemeral runner
      starts, and the deploy finishes green.
- [ ] `history/<app>.log` records the deploy and `logs/<app>/deploy.log`
      shows the detail.
- [ ] `./bin/devops webhook logs` and `./bin/devops webhook status` are the
      first stop when a delivery does not reach a deploy.

## Next

- [architecture.md](architecture.md) — GitHub integration, runners, deploy flow, reliability
- [remote-docker.md](remote-docker.md) — split layout, SSH setup, doctor checks, constraints
- [secret-management.md](secret-management.md) — secret layout and rotation runbooks
