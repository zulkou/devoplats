# Secret Management

All secrets are local files. There is no secret-store provider, network fetch,
or CLI dependency. Two scopes exist:

| Scope | File | Loaded by |
|---|---|---|
| Platform / infra / backup | `<install-root>/.env` | `load_infra_env()` |
| App secrets | `<install-root>/configs/<app>/.env` | `fetch_env()` |

`fetch_env()` copies the app file to `<APPS_ROOT>/<app>/.env` (mode `600`) so
Compose can read it. The runtime copy is generated; edit only the config-side
file.

## Layout

```text
<install-root>/
  .env                         platform config, infra creds, BACKUP_*
  configs/<app>/
    config.yml                 healthcheck, migration, backup, tests
    .env                       canonical app secrets (600)
<APPS_ROOT>/<app>/
  compose.yml
  .env                         generated copy, rewritten by deploy/rollback/test
```

- `<install-root>/.env` should be `600` or `640`. `load_infra_env()` warns on
  loose permissions; `doctor` warns when the file is missing (shell environment
  only).
- App env sources should be `600` or `640`; `fetch_env()` warns otherwise.
- The generated runtime copy is always `chmod 600`.
- `fetch_env()` warns and ignores local-only keys (`BACKUP_*`) in app env
  files; those credentials belong in the root `.env`.

## Deploy and test behavior

- `deploy` runs `fetch_env` **before** `validate_app_config`, so the runtime
  file exists for the first Compose validation.
- `test` and `rollback` also sync the app env before using the app.
- If the canonical app env is missing, the command fails with the path and a
  migration hint. There is no fallback to an existing runtime `.env`.
- A stale runtime `.env` is overwritten on every sync.
- `doctor --app` checks the canonical file, warns on loose permissions, and
  points at a legacy runtime file when the canonical one is missing.

## Local-only backup credentials

`BACKUP_<SLUG>_{USER,PASS}` are read only from `<install-root>/.env` (or an
explicit shell override). They are never copied into app env files. The prefix
list is configurable via `LOCAL_ONLY_ENV_PREFIXES` (default `BACKUP_`).

When a configured backup cannot be dumped (missing credentials, unsupported
engine, dump error), remaining databases are still attempted, partial
`.sql.gz` files are removed, and the backup step exits non-zero. Apps with no
configured databases skip cleanly.

## Rotation runbooks

- **Webhook credentials**: edit `GITHUB_WEBHOOK_SECRET` or `ACCESS_TOKEN` in
  `<install-root>/.env`, then restart the webhook
  (`<install-root>/bin/devops webhook restart`) because those values are read
  at boot.
- **Registry credentials**: edit `GHCR_USERNAME`/`GHCR_TOKEN` in
  `<install-root>/.env`; deploys and doctor read them on the next run.
- **App secrets**: edit `<install-root>/configs/<app>/.env`; the next deploy,
  test, or rollback copies it to the runtime location.
- **Backup credentials**: edit `BACKUP_<SLUG>_{USER,PASS}` in
  `<install-root>/.env`; no restart is needed.

The webhook server refuses to start without `GITHUB_WEBHOOK_SECRET` — it must
never run with signature verification disabled.

## Hygiene rules

- Keep the root `.env` at `600`/`640`.
- Keep canonical app env files at `600`/`640`.
- Never commit either file; `.gitignore` covers `configs/` and `**/.env`.
- Keep copies of irreplaceable credentials in your team password manager.
