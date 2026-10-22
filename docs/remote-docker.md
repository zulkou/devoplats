# Remote Docker

The platform can drive either a local Docker daemon or a remote one over SSH.
In the remote layout, the deployment CLI and GitHub runner stay on the platform
host; only the Docker daemon, images, and app containers live on the Docker
host.

```
platform host / ephemeral runner              remote Docker host
┌─────────────────────────────────┐          ┌──────────────────────────────┐
│ devops deploy                   │          │ Docker Engine                │
│ compose.yml + config.yml        │  SSH     │ app containers               │
│ env/secret fetch                │ ───────▶ │ per-app Compose networks     │
│ backups, history, versions      │          │ image pulls, probe containers│
└─────────────────────────────────┘          └──────────────────────────────┘
```

Docker Compose runs on the platform host (or runner) and talks to the remote
daemon through `DOCKER_HOST`. The remote host does **not** need the Compose
plugin, the platform checkout, or the app runtime directory.

## Requirements

- SSH access from the platform host/runner to the Docker host.
- Docker Engine `>= 20.10` on the remote host.
- Docker Compose v2.6+ on the platform host/runner (needed for `config
  --format json`).
- Enough free disk on the remote host for images and containers. The doctor
  default is 5 GiB; change `MIN_FREE_DISK_GB` if needed.
- GHCR credentials with package read access.

## SSH setup

Create an SSH host alias on the platform host and in the runner's mounted SSH
directory:

```sshconfig
Host devoplats-remote
    HostName 203.0.113.10
    User deploy
    IdentityFile ~/.ssh/docker.pem
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts
```

```bash
chmod 600 ~/.ssh/docker.pem
ssh devoplats-remote docker version
```

`RUNNER_SSH_DIR` is the host directory mounted read-only at `/root/.ssh` in
ephemeral runners:

```text
/opt/devoplats-ssh/
├── config
├── docker.pem
└── known_hosts
```

The platform manages runner containers on the **local** daemon and removes
`DOCKER_HOST` for those operations. The deploy/backup/rollback/migrate/
healthcheck/restore-db commands target the remote daemon.

### Rotate the SSH key

The same private key must be installed on the host and in the runner mount:

1. Generate a new key and append its public key to the remote
   `~/.ssh/authorized_keys` while the old key still works.
2. Install the new private key at both paths, owned by the user that reads them
   and mode `600`:

   ```bash
   install -m 600 -o <host-user> -g <host-user> new-key ~/.ssh/docker.pem
   install -m 600 -o root -g root new-key <RUNNER_SSH_DIR>/docker.pem
   ```

3. Close existing ControlMaster sessions (`ssh -O exit <alias>`) and verify a
   fresh connection from the host **and** with the runner-mounted key:
   `ssh -i <RUNNER_SSH_DIR>/docker.pem <alias> true`.
4. Remove the old public key from `~/.ssh/authorized_keys`, keep the file mode
   `600`, and confirm the old private key is rejected.
5. Run `./bin/devops doctor` to confirm Docker and registry access still work.

## Site configuration

Add these values to `<install-root>/.env`:

```dotenv
DOCKER_HOST=ssh://devoplats-remote
RUNNER_SSH_DIR=/opt/devoplats-ssh
REGISTRY=ghcr.io/your-owner
HEALTHCHECK_PROBE_IMAGE=curlimages/curl:latest

GHCR_USERNAME=your-user
GHCR_TOKEN=ghp_xxx
```

Each app's Compose network is created on the remote daemon during its first
deploy; no network setup is required.

Then run the preflight:

```bash
./bin/devops doctor
./bin/devops doctor --app my-app --env dev
```

The doctor checks:

| Check | Behavior |
|---|---|
| Docker/SSH | `docker info` through `DOCKER_HOST`; separate SSH probe when the host is `ssh://` |
| Engine | Server version against `MIN_DOCKER_VERSION` (default `20.10.0`) |
| Compose | Local Compose v2 against `MIN_COMPOSE_VERSION` (default `2.6.0`) |
| Disk | Free space under the daemon's `DockerRootDir` against `MIN_FREE_DISK_GB` (default `5`) |
| Registry | GHCR login with `GHCR_USERNAME`/`GHCR_TOKEN`; optional image manifest check with `--tag` |
| App | With `--app`/`--env`: rejects bind mounts and non-container healthcheck URLs |

Use `--tag` to check the exact image that a deploy will pull:

```bash
./bin/devops doctor --app my-app --env prod --tag prod
```

The command exits non-zero if any check fails. Disk checks for non-SSH remotes
are reported as warnings because the platform cannot inspect the host filesystem.

## App constraints

### No bind mounts

Remote Docker cannot see paths on the platform host. Compose files must use
named volumes or `tmpfs`:

```yaml
services:
  app:
    volumes:
      - app-data:/var/lib/app
volumes:
  app-data: {}
```

These are rejected by `devops deploy` before pull/backup and by `devops doctor`:

```yaml
volumes:
  - ./.env:/app/.env          # bind mount
  - /srv/data:/data           # bind mount
  - type: bind                # explicit bind
    source: ./data
    target: /data
```

App secrets belong in `env_file`/`environment`; Compose resolves those on the
platform host and injects them into the container.

### Container-only healthchecks

The healthcheck URL must target the app container by name:

```yaml
healthcheck:
  url: http://${APP_SLUG}-${ENVIRONMENT}:80/health
  expected_status: 200
```

`localhost`, IP addresses, and external hostnames are rejected. The probe runs
from a throwaway container attached to the app's Compose network, discovered by
inspecting the app container.

### Backups and migrations

- Backups run on the platform host and are stored under
  `<install-root>/backups/<app>/`, even when the database runs remotely.
- `backup.databases[].service` is the **container name**, not the Compose
  service name.
- `migration.service` is the **Compose service name**.
- Backup credentials (`BACKUP_<APP>_USER/PASS`) stay in the local `.env`.

## Rollback behavior

Rollback is a recovery path. It deliberately skips the bind-mount and
healthcheck-host preflight checks so an app deployed before an upgrade can still
be restored. It logs a warning that the preflight was skipped; the next normal
deploy enforces the checks again.

## Troubleshooting

| Symptom | Check |
|---|---|
| `Docker daemon unreachable` | `ssh <alias> docker version`; key permissions, `known_hosts`, username |
| `Disk ... free` failure | remove unused images/containers on the remote host; increase disk |
| `Registry login ... failed` | `GHCR_USERNAME/GHCR_TOKEN`, package read scope, token expiry |
| `Bind mount rejected` | replace the bind mount with a named volume or bake the file into the image |
| `healthcheck.url host ... is not the app container` | use `${APP_SLUG}-${ENVIRONMENT}` as the URL host |
| Compose validation fails | run `docker compose -f <compose> config` on the platform host |

`github-runners/cleanup.sh` prunes dangling images older than 24 hours on the
remote daemon when it is run (manually or from a future schedule). It does not
remove tagged app images or current/previous rollback images. Prune tagged
images manually when needed.
