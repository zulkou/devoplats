# Remote Server Setup

Step-by-step runbook for a fresh, always-on Linux server running the all-in-one
layout (webhook, runners, and Docker on the same host). The webhook is exposed
through a **Cloudflare Tunnel** — no public IP, no open inbound port, and TLS
handled for you.

For org-owned repos you can use one org-level webhook instead of per-repo
webhooks; see [GitHub side](#6-github-side). Everything else is identical.

This runbook assumes the checkout includes per-event repo routing in repo scope
(the webhook reads `repository.full_name` from each event, so one service
serves many repos). `REPO_URL` is only a fallback.

## 1. Host packages

```bash
sudo apt update
sudo apt install -y python3 python3-venv curl yq
# Docker Engine + Compose v2.6+ — follow Docker's official guide:
# https://docs.docker.com/engine/install/debian/
sudo usermod -aG docker "$USER"   # re-login afterwards
```

Docker Engine with Compose v2.6+ is the minimum (`devops doctor` enforces it).
Outbound access to `github.com` and `ghcr.io` is required; with Cloudflare
Tunnel no inbound port except SSH needs to be open.

## 2. Clone and install the webhook

```bash
sudo git clone <your-repo-url> /opt/devoplats
sudo chown -R "$USER:" /opt/devoplats
cd /opt/devoplats
python3 -m venv .venv
.venv/bin/pip install -e .
```

The venv install creates `/opt/devoplats/.venv/bin/devoplats-webhook`; without
it `devops webhook run|install` fails with "Webhook entrypoint not found".

## 3. Configure `.env`

```bash
cp .env.example .env && chmod 600 .env
```

Fill in:

| Key | Value |
|---|---|
| `GITHUB_WEBHOOK_SECRET` | `openssl rand -hex 32`; the same value goes into every GitHub webhook |
| `ACCESS_TOKEN` | PAT with admin on every connected repo (classic `repo` scope works); runners register with it |
| `REGISTRY` | `ghcr.io/<your-owner>` |
| `GHCR_USERNAME` / `GHCR_TOKEN` | Credentials with GHCR package read access |
| `RUNNER_SCOPE` | `repo` for personal-account repos; `org` + `ORG_NAME` for org repos |
| `WEBHOOK_HOST` | `127.0.0.1` — the tunnel is the only public entry point |
| `DEPLOY_ENVS` | Environments `--env` accepts (default `dev prod`) |

In repo scope, do not set `REPO_URL`: the repo comes from each webhook event.
With `RUNNER_SCOPE=org`, one org webhook covers all repos in the org and
`ORG_NAME` is required instead.

## 4. Start the webhook service

```bash
sudo /opt/devoplats/bin/devops webhook install
sudo /opt/devoplats/bin/devops webhook start
/opt/devoplats/bin/devops webhook status
```

`install` renders `gh-runner-webhook.service` (runs as root, reads
`/opt/devoplats/.env`) and enables it. Use the absolute path with `sudo`;
`run`, `status`, and `logs` do not need root.

## 5. Expose it with Cloudflare Tunnel (recommended)

The domain must be managed by Cloudflare (nameservers pointed at Cloudflare)
for `route dns` to work. Install `cloudflared` from Cloudflare's apt repo:

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared
```

Create the tunnel on the server:

```bash
cloudflared tunnel login          # prints a URL; open it in your local browser
cloudflared tunnel create devoplats
```

`create` prints the tunnel ID and writes credentials to
`~/.cloudflared/<tunnel-id>.json`. Put the config where the root-owned service
can read it:

```bash
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/<tunnel-id>.json /etc/cloudflared/
```

Write `/etc/cloudflared/config.yml`:

```yaml
tunnel: devoplats
credentials-file: /etc/cloudflared/<tunnel-id>.json
ingress:
  - hostname: devops.example.com
    service: http://127.0.0.1:10000
  - service: http_status:404
```

Route DNS and run it as a service:

```bash
cloudflared tunnel route dns devoplats devops.example.com
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Verify from anywhere: `curl https://devops.example.com/healthz` returns
`{"status":"ok"}`.

### Alternative: public IP + reverse proxy

If the server has a public IP and you prefer not to use Cloudflare, skip the
tunnel and put Caddy in front of the webhook instead (`sudo apt install -y caddy`).
Keep `WEBHOOK_HOST=127.0.0.1`, open 443, and use this Caddyfile:

```caddy
devops.example.com {
    reverse_proxy 127.0.0.1:10000
}
```

## 6. GitHub side

**Personal-account repos (repo scope):** add a webhook in *each* repo —
Settings → Webhooks → Add webhook:

- Payload URL: `https://devops.example.com/webhooks/github`
- Content type: `application/json`
- Secret: `GITHUB_WEBHOOK_SECRET`
- Events: **Workflow jobs** only

**Org repos (org scope):** add one webhook at the org level (Settings →
Webhooks) with the same settings, and make sure the org allows self-hosted
runners for the repos.

Check **Recent Deliveries** for a 2xx ping. A 403 means the secret does not
match; no delivery at all means the tunnel or DNS is wrong.

## 7. Adopt each app

In the app repository:

- `Dockerfile` at the repository root (build context is the repo root).
- `compose.yml` and `.github/workflows/{build,deploy,deploy-dev}.yml` copied
  from [`examples/`](../examples).
- `dev` and `main` branches.

On the platform host:

- `<APPS_ROOT>/<app>/compose.yml` (default `/opt/apps/<app>/`).
- `/opt/devoplats/configs/<app>/config.yml` — start from
  [`examples/config.yml`](../examples/config.yml).
- `/opt/devoplats/configs/<app>/.env` — app secrets, mode `600`.
- Optional: `BACKUP_<APP>_USER` / `BACKUP_<APP>_PASS` in the root `.env`.

## 8. Verify

```bash
/opt/devoplats/bin/devops doctor
/opt/devoplats/bin/devops doctor --app <app> --env dev
```

Then push to an app's `dev` branch and confirm: webhook delivery 2xx, an
ephemeral runner container starts, the deploy finishes green, and
`history/<app>.log` records it. When something does not reach a deploy, start
with `devops webhook logs` and `devops webhook status`.

## 9. Optional

- Runner cleanup cron:
  `echo '*/5 * * * * root /opt/devoplats/github-runners/cleanup.sh' | sudo tee /etc/cron.d/devoplats-cleanup`
- Split layout with a separate Docker host: [remote-docker.md](remote-docker.md).
- Secret layout and rotation: [secret-management.md](secret-management.md).

## Notes

- Locks, versions, history, logs, and backups are local files under the
  install root. Moving hosts means moving that state.
- With Cloudflare Tunnel the webhook port never leaves localhost; the HMAC
  check still verifies every delivery, so a leaked URL alone is not enough to
  trigger runners.
- `ACCESS_TOKEN` is admin on every connected repo — keep `.env` at mode `600`
  and treat it as the most sensitive file on the box.
