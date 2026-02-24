# ArgoCD Setup

This document covers how the Hippo platform manages GitOps deployments using ArgoCD. The design goal is to abstract all ArgoCD complexity into the platform layer so developers only interact with `service-settings/components-manifest.yml` in their service repo.

---

## Architecture Overview

```
hippo_k8s-service/
  argocd/
    applicationset.yaml       ← platform-owned, applied once per cluster

hippo_<service>/
  service-settings/
    components-manifest.yml   ← developer-owned, only file needed for deployment
    default/values.yml
    overrides/values.yml
```

A single `ApplicationSet` (owned by the platform team) watches every service repo's `components-manifest.yml`. It generates one ArgoCD `Application` per component per environment automatically. Developers never write or read an ArgoCD manifest.

### What gets generated

For a component named `hippo-hello-world` with environments `dev` and `prod`, the ApplicationSet produces:

| ArgoCD Application | Namespace | Sync |
|---|---|---|
| `hippo-hello-world-dev` | `hippo-hello-world-dev` | Automated (prune + self-heal) |
| `hippo-hello-world-prod` | `hippo-hello-world-prod` | Manual |

---

## Prerequisites

| Requirement | Version |
|---|---|
| ArgoCD | >= 2.6 (tested on v3.3.2) |
| Helm | >= 3.10 |
| Cluster access | `kubectl` pointed at target cluster |

> **ArgoCD v3 OCI behavior:** ArgoCD v3 uses `repoURL` verbatim as the OCI image reference
> path — it does not append the `chart` field. The `applicationset.yaml` template includes
> `/hippo-service` directly in `repoURL` to produce the correct GAR v2 API path.

---

## One-time Platform Setup

These steps are performed once per cluster by the platform team. Service teams do not need to repeat them.

### 1. Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all pods to be ready:

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s
```

### 2. Apply the ApplicationSet

```bash
kubectl apply -f argocd/applicationset.yaml -n argocd
```

That's it. The ApplicationSet immediately begins reading `components-manifest.yml` from every registered service repo and creating `Application` objects.

### 3. Verify

```bash
# List all generated Applications
kubectl get applications -n argocd

# Describe the ApplicationSet
kubectl get applicationset hippo-services -n argocd
```

---

## Adding a New Service (Developer Steps)

No platform changes are required. The developer adds a `components-manifest.yml` to their service repo:

```yaml
# service-settings/components-manifest.yml
components:
  - name: hippo-my-service
    repo_url: https://github.com/mosavani/hippo_my_service.git
    target_revision: HEAD
    image_tag: latest
    deployment_zones:
      - public
    helm_chart_default_values_files:
      - service-settings/default/values.yml
    helm_chart_production_overrides_values_files:
      - service-settings/overrides/values.yml
```

> **Image path:** No `image_repository` field is required. The platform constructs the GAR image path from the component `name`:
> `<GAR_LOCATION>-docker.pkg.dev/<GAR_PROJECT_ID>/<GAR_REPOSITORY>/<name>`
> Service images must be pushed to GAR under a path matching the component name.

Then add the service repo to the `git` generator list in `applicationset.yaml`:

```yaml
- git:
    repoURL: https://github.com/mosavani/hippo_my_service.git
    revision: HEAD
    files:
      - path: service-settings/components-manifest.yml
```

> **Note:** The only platform file that changes is `applicationset.yaml` — and only to add the new repo URL to the generator list. All deployment behaviour is driven by the service's own `components-manifest.yml`.

---

## components-manifest.yml Field Reference

| Field | Required | Description |
|---|---|---|
| `name` | yes | Helm release name. Also used as the ArgoCD Application prefix, namespace suffix, and the final segment of the GAR image path. |
| `repo_url` | yes | HTTPS URL of the service Git repository. |
| `target_revision` | yes | Git ref to deploy (`HEAD`, branch name, or semver tag). Pin to a tag for prod stability. |
| `image_tag` | yes | Image tag to deploy. Updated automatically by the CI release workflow. |
| `deployment_zones` | yes | Informational. `public` = internet-facing via Ingress. `internal` = VPC-only. |
| `helm_chart_default_values_files` | yes | List of values files for dev/staging. Paths are relative to the repo root. |
| `helm_chart_production_overrides_values_files` | yes | List of values files layered on top for production. |

> **Image path convention:** `image_repository` is no longer a manifest field. The platform constructs it as `<GAR_LOCATION>-docker.pkg.dev/<GAR_PROJECT_ID>/<GAR_REPOSITORY>/<name>`. The component `name` must match the image name in GAR.

---

## Sync Behaviour by Environment

| Environment | Automated | Prune | Self-heal | Notes |
|---|---|---|---|---|
| `dev` | yes | yes | yes | Any Git push deploys immediately |
| `prod` | no | — | — | Requires manual sync approval in ArgoCD UI or CLI |

To manually sync production:

```bash
argocd app sync hippo-hello-world-prod
```

Or via the ArgoCD UI: select the application → **Sync** → **Synchronize**.

---

## Updating the Image Tag

The CI release workflow (`release.yml`) updates `image_tag` in `components-manifest.yml` on every tagged release. For dev, `image_tag: latest` is sufficient — the automated sync picks up new images on the next reconciliation cycle (default: 3 minutes).

For production, pin `target_revision` to a specific Git tag and set `image_tag` to the corresponding release version:

```yaml
target_revision: v1.2.3
image_tag: "1.2.3"
```

---

## Rollback

### Dev

Force a previous revision to sync:

```bash
argocd app rollback hippo-hello-world-dev <revision-number>
```

### Prod

Update `target_revision` and `image_tag` in `components-manifest.yml` back to the previous values, commit, then trigger a manual sync.

---

## Canary Deployments (Argo Rollouts)

To enable canary for a component, set `rollout.enabled: true` in its values file:

```yaml
# service-settings/default/values.yml
rollout:
  enabled: true
  steps:
    - setWeight: 20
    - pause:
        duration: 60s
    - setWeight: 100
```

The Argo Rollouts controller must be installed separately on the cluster:

```bash
kubectl create namespace argo-rollouts

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

Monitor a rollout:

```bash
kubectl argo rollouts get rollout <name> -n <namespace> --watch
```

Promote (skip remaining pause steps):

```bash
kubectl argo rollouts promote <name> -n <namespace>
```

Abort and roll back:

```bash
kubectl argo rollouts abort <name> -n <namespace>
```

---

## Ownership Model

| File | Owner | Edit frequency |
|---|---|---|
| `argocd/applicationset.yaml` | Platform team | Rarely — only to add new service repos |
| `service-settings/components-manifest.yml` | Service team | Per release (image tag) |
| `service-settings/default/values.yml` | Service team | As needed |
| `service-settings/overrides/values.yml` | Service team | As needed |
| ArgoCD `Application` objects | Generated — do not edit | Never |
