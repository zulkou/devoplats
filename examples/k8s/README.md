# Kubernetes apps

Apps delivered to Kubernetes do **not** use the devoplats platform. They use
the same GHCR image pipeline, then hand rollout to a GitOps controller running
inside the cluster (Argo CD or Flux). No webhook, ephemeral runner, `devops`
command, or `configs/<app>/` entry is involved.

```
push main ─▶ build :sha ─▶ GHCR
          ─▶ pin :sha in k8s/overlays/prod ─▶ commit main
                                            │
                              Argo CD / Flux watches main
                                            ▼
                                    rollout + readiness gates
```

## Files

- `deploy.yml` — copy to `.github/workflows/deploy.yml`. Builds the image,
  pins the commit tag in the prod overlay, and commits that pin to `main`.
- `overlays/prod/kustomization.yaml` — the prod overlay; CI only rewrites
  `newTag`.
- `overlays/prod/deployment.yaml` — sample Deployment **with readiness and
  liveness probes**.
- `overlays/prod/service.yaml` — sample Service.

## Set up

1. Replace the placeholders: `OWNER/APP`, `namespace`, container port, probe
   path, and the `myapp` names.
2. Copy `deploy.yml` into `.github/workflows/`.
3. Point an Argo CD / Flux Application at this repository:

   ```yaml
   source:
     repoURL: https://github.com/OWNER/APP
     targetRevision: main
     path: k8s/overlays/prod
   syncPolicy:
     automated: { prune: true, selfHeal: true }
   ```

4. If `main` is protected, the pin commit is rejected: open a PR from the
   workflow instead, or push with a PAT that can bypass the protection.
5. Add your Ingress, image pull secret, and secrets separately (Sealed
   Secrets, SOPS, or External Secrets — never plain `.env` files).

## Things that replace the platform

- **Healthcheck** — the `readinessProbe` in the Deployment. A broken build
  never receives traffic; the old pods keep serving. Do not omit it.
- **Rollback** — revert the pin commit (`git revert`) or `kubectl rollout undo`.
- **Migrations** — a pre-sync Job hook in Argo, or an init container/job you
  wire yourself.
- **Backups** — CronJob, Velero, or managed database snapshots. The platform's
  backup/restore tooling does not apply.
- **Dev environment** — optional AND Compose-only on the platform. Kubernetes
  apps either skip it or run their own dev overlay/Application.
