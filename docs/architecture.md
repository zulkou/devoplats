# Architecture

This document describes the server-side platform: GitHub integration, runners,
the webhook, deployment scripts, and reliability behavior.

## Overview

- **GitHub** is the source of truth and the CI entry point.
- **GitHub Actions** builds app images and pushes them to GHCR.
- **The platform host** runs the webhook, the CLI, and filesystem state.
- **A remote Docker host** (optional) runs app containers, images, and probes.
- **Ephemeral runners** execute self-hosted GitHub jobs and are removed after
  one job.

The platform favours explicit shell scripts, filesystem state, and standard
Docker primitives over a large orchestration system.

## GitHub integration

A push to `dev` or `main` triggers the app repository's workflows. The
`workflow_job` webhook is delivered to the Flask endpoint, which verifies the
HMAC signature and starts an ephemeral runner for queued self-hosted jobs.

The runner image is `myoung34/github-runner:latest`. It is pulled on demand;
`RUNNER_IMAGE` can pin a version or point at a private image. Runners mount:

- the platform checkout at the same path;
- `<APPS_ROOT>`;
- `/var/run/docker.sock` for local runner lifecycle;
- the runner SSH directory at `/root/.ssh` when `RUNNER_SSH_DIR` is set.

The runner uses the host Docker socket for its own lifecycle and reaches the
app daemon through `DOCKER_HOST` when remote Docker is configured.

## Webhook

The webhook is a systemd-managed Flask service started by
`devoplats-webhook`:

- verifies `X-Hub-Signature-256` with `GITHUB_WEBHOOK_SECRET`;
- ignores non-`workflow_job` events;
- deduplicates queued jobs for 5 minutes;
- starts one ephemeral runner per self-hosted queued job;
- exposes `/healthz` for the service check.

It refuses to start without `GITHUB_WEBHOOK_SECRET`. It reads platform settings
from `<install-root>/.env` and does not log in to GHCR; app deploys handle their
own registry login.

`devops webhook install` renders
`github-runners/gh-runner-webhook.service.template`; `start`, `stop`,
`restart`, `status`, and `logs` manage the unit.

## Secrets

All secrets are local files. There is no secret-store provider, network fetch,
or CLI dependency.

- `<install-root>/.env` — platform configuration, infra credentials
  (`GHCR_*`, `ACCESS_TOKEN`, `GITHUB_WEBHOOK_SECRET`), and `BACKUP_*`.
- `<install-root>/configs/<app>/.env` — canonical app secrets.
- `<APPS_ROOT>/<app>/.env` — generated runtime copy (mode `600`) read by
  Compose.

`platform/lib/env.sh` loads the root `.env` and copies the app file into the
runtime directory. `BACKUP_*` keys are filtered out of app env files. See
[secret-management.md](secret-management.md).

## CLI

`bin/devops` is the only CLI entry point. The Python package provides the
webhook service only.

```text
devops deploy --app APP --env ENV --tag TAG
devops rollback --app APP --env ENV
devops backup --app APP --env ENV
devops migrate --app APP --env ENV
devops healthcheck --app APP --env ENV
devops test --app APP
devops restore-db --app APP --backup FILE
devops doctor [--app APP --env ENV] [--tag TAG]
devops webhook run|install|start|stop|restart|status|logs
```

`restore-db` is interactive and must never run unattended from CI. `doctor` is
the preflight for `yq`, SSH, Docker/Compose versions, disk, registry access,
webhook state, and app configuration.

## App contract

An app repository provides:

- `Dockerfile`
- `compose.yml`
- `.github/workflows/deploy.yml`, `build.yml`, and `deploy-dev.yml`
- `dev` and `main` branches

Examples are in [`examples/`](../examples). The server needs the app's Compose
file under `<APPS_ROOT>/<app>/compose.yml`, its config at
`<install-root>/configs/<app>/config.yml`, and its secrets at
`<install-root>/configs/<app>/.env`.

### Naming

The runtime directory must match the repository name passed as `--app`,
byte-for-byte. Docker-facing names use a derived slug: lowercase, runs of
non-alphanumerics become `-`, edges trimmed.

| Repo / `--app` | Slug | Backup keys |
|---|---|---|
| `myapp` | `myapp` | `BACKUP_MYAPP_{USER,PASS}` |
| `My-App.v2` | `my-app-v2` | `BACKUP_MY_APP_V2_{USER,PASS}` |

Image: `${REGISTRY}/<slug>`. Compose project and container:
`${APP_SLUG}-${ENVIRONMENT}`. Two names that derive the same slug collide.

### Compose

See [`examples/compose.yml`](../examples/compose.yml). Compose receives
`APP_SLUG`, `ENVIRONMENT`, `IMAGE`, and `IMAGE_TAG` from the platform.

Bind mounts from the platform host are rejected because the Docker daemon may
be remote. Use named volumes or bake files into the image. Healthcheck URLs
must target the app container by name, for example
`http://${APP_SLUG}-${ENVIRONMENT}:80/`.

### Config

```yaml
healthcheck:
  url: http://${APP_SLUG}-${ENVIRONMENT}:80/
  expected_status: 200

migration:
  enabled: true
  automatic: true
  service: app
  command: ["php", "vendor/bin/phinx", "migrate"]

backup:
  databases:
    - engine: postgres
      service: postgres
      name: myapp_prod

test:
  enabled: true
  command: ["sh", "-c", "npm test"]
```

`yq` is required to read this file.

## Networking

Each app gets its own Compose network, created on first deploy and removed by
`docker compose down`. Services in the same app resolve each other by name.
The deploy healthcheck inspects the app container's attached networks and runs
its probe on them, so no platform-wide network exists.

External infrastructure is not part of the standalone app layout; attach it
explicitly when an app needs it.

## Remote Docker

The daemon may run on a remote host reached over SSH
(`DOCKER_HOST=ssh://<alias>`). Compose and the platform scripts still run on
the platform host or ephemeral runner; images, containers, networks, and probes
run on the remote daemon.

The remote host does not need the Compose plugin, the platform checkout, or the
app runtime directory. See [remote-docker.md](remote-docker.md).

## Environments

- `dev` — integration/testing environment with its own database.
- `prod` — user-facing environment.
- `DEPLOY_ENVS` controls the accepted `--env` values.

Environments have independent version state, locks, and backups. They may share
a Docker host.

## Deployment flow

1. Sync `<install-root>/configs/<app>/.env` to
   `<APPS_ROOT>/<app>/.env` (mode `600`).
2. Validate the app's healthcheck and Compose file.
3. Log in to the app registry.
4. Record the running image digest as the rollback target.
5. For `prod`, back up configured databases.
6. Pull the requested image and run `docker compose up -d`.
7. Wait for the service container to become healthy.
8. Run migrations when enabled.
9. Probe the app `/healthcheck` URL.
10. On success, record the deployed digest and append to history. On failure,
    roll back to the previous digest and verify it.

Deploy and rollback take a non-blocking `flock` per app and environment under
`<install-root>/locks/`. Automatic rollback inherits the lock from the failed
deploy.

## Reliability

- **Rollback** uses immutable image digests; the requested tag is only recorded
  in history.
- **Backups** run before every prod deploy, with databases and credentials
  defined per app. Dumps are stored in `<install-root>/backups/<app>/`.
- **Restore** is interactive and uses the same backup config.
- **Migrations** run after the new container is up and before the HTTP
  healthcheck. A failed migration triggers rollback.
- **Locks** prevent concurrent operations on the same app/environment.
- **History** is stored in `<install-root>/history/<app>.log`; detailed logs
  are in `<install-root>/logs/<app>/`.

## Operations

Version state lives in `<install-root>/platform/versions/`:

- `<app>.<env>.current` — current deployed digest
- `<app>.<env>.previous` — rollback digest

`github-runners/cleanup.sh` reaps runner containers older than 10 minutes,
refreshes the runner image when missing, and prunes dangling images older than
24 hours on local and remote daemons. It never removes tagged app images or
rollback images. Scheduling is optional; run it manually or from cron/systemd.
