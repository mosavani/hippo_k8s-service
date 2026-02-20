# hippo_k8s-service

A **central shared Helm chart** that abstracts Kubernetes boilerplate away from service teams. Developers write a short values file describing their service; this chart turns it into all the Kubernetes objects needed to run it on GKE.

---

## How it fits into the bigger picture

```
hippo_k8s-service (this repo)
─────────────────────────────
Helm chart source code
CI: lint + render test scenarios
Release: package + push chart to GAR
                │
                │  published as OCI chart
                ▼
   Google Artifact Registry
   oci://.../hippo-helm-charts/hippo-service:1.2.3
                │
                │  referenced by version
                ▼
frontend_web_app (developer's repo)        other_service_repo / ...
──────────────────────────────────         ─────────────────────────
service-settings/                          service-settings/
  components-manifest.yml                    components-manifest.yml
  default/web-values.yml                     default/worker-values.yml
  overrides/web-values.yml                   overrides/worker-values.yml
argocd/
  web-app.yaml  ← ArgoCD Application
      repoURL: oci://...GAR.../hippo-service
      targetRevision: "1.2.3"
      valueFiles: service-settings/...
                │
                │  ArgoCD syncs
                ▼
          GKE Cluster
```

**Responsibilities by repo:**

| | `hippo_k8s-service` | Developer service repo |
|---|---|---|
| Helm chart templates | yes | no |
| Default values | yes | no |
| Service-specific values | no (examples only) | yes |
| ArgoCD Application manifests | no | yes |
| CI (lint + render) | yes | optional |
| Release to GAR | yes | no |

---

## Repository Layout

```
hippo_k8s-service/
├── hippo-service/                      # Helm chart (published to GAR)
│   ├── Chart.yaml
│   ├── values.yaml                     # Chart-level defaults with inline comments
│   ├── values.schema.json              # Validation schema
│   └── templates/
│       ├── deployment.yaml             # Deployment (suppressed when rollout enabled)
│       ├── rollout.yaml                # Argo Rollout canary (opt-in)
│       ├── service.yaml                # Service (ClusterIP or LoadBalancer)
│       ├── service-rollout.yaml        # Stable + canary Services for Argo traffic split
│       ├── ingress.yaml                # GKE Ingress (opt-in)
│       ├── hpa.yaml                    # HPA — targets Deployment or Rollout automatically
│       ├── pdb.yaml                    # Pod Disruption Budget
│       ├── netpolicies.yaml            # NetworkPolicy (deny-all default)
│       └── defines/
│           ├── _hippo.labels.tpl       # Name, fullname, selector labels
│           ├── _hippo.affinity.tpl     # Pod anti-affinity + node pool pin
│           └── _hippo.rollout.tpl      # Canary step rendering
├── service-settings/                   # Example values — for reference and local testing only
│   ├── components-manifest.yml         # Example component registry
│   ├── default/
│   │   ├── api-values.yml
│   │   └── worker-values.yml
│   └── overrides/
│       ├── api-values.yml
│       └── worker-values.yml
├── tests/
│   ├── globals/                        # Cluster-level globals used during test renders
│   │   ├── dev.yaml
│   │   └── prod.yaml
│   └── values/                         # Test scenarios rendered in CI
│       ├── service-api-simple.yml
│       ├── service-api-with-ingress.yml
│       ├── service-worker-with-hpa.yml
│       ├── service-prod-ha.yml
│       └── rollout-canary.yml
├── docs/
│   └── template_readme.md              # Helm template helpers reference
├── .github/workflows/
│   ├── ci.yml                          # Lint + render on every PR
│   └── release.yml                     # Package + push to GAR on tag
└── Makefile
```

---

## For Chart Maintainers

### Local development

```bash
# Lint the chart
make lint

# Render a single test scenario
make render ONE=tests/values/service-api-simple.yml

# Render all test scenarios
make test

# Package the chart
make package
```

Requires: `helm` >= 3.10

### Releasing a new chart version

Tag the commit with a semver tag — the `release.yml` workflow fires automatically:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The workflow:
1. Stamps the tag version into `Chart.yaml`
2. Runs `helm lint`
3. Runs `helm package`
4. Pushes the OCI artifact to GAR:
   ```
   oci://<GAR_LOCATION>-docker.pkg.dev/<GAR_PROJECT_ID>/<GAR_REPOSITORY>/hippo-service:1.2.3
   ```

**Required GitHub secrets:**

| Secret | Value |
|---|---|
| `GAR_LOCATION` | e.g. `us-central1` |
| `GAR_PROJECT_ID` | GCP project ID |
| `GAR_REPOSITORY` | AR repository name |
| `GCP_SA_KEY` | Base64 GCP SA key (`roles/artifactregistry.writer`) |

---

## For Service Developers

You do **not** work in this repo. In your own service repo:

### 1. Create `service-settings/components-manifest.yml`

```yaml
components:
  - name: frontend-web-app
    type: service
    deployment_zones:
      - public
    helm_chart_default_values_files:
      - default/web-values.yml
    helm_chart_production_overrides_values_files:
      - overrides/web-values.yml
```

### 2. Create `service-settings/default/web-values.yml`

```yaml
service:
  replicaCount: 2
  type: ClusterIP
  port: 80
  targetPort: 3000
  liveness:
    enabled: true
    path: /health
  readiness:
    enabled: true
    path: /ready

ingress:
  enabled: true
  className: "gce"
  annotations:
    kubernetes.io/ingress.allow-http: "false"
    networking.gke.io/managed-certificates: web-app-cert
  host: www.example.com
  path: /

hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

pdb:
  enabled: true
  minAvailable: 1

affinity:
  podAntiAffinity: soft

networkPolicy:
  enabled: true
  ingressNamespace: kube-system

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    memory: 512Mi
```

### 3. Create an ArgoCD Application manifest in your repo

```yaml
# argocd/web-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: frontend-web-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://us-central1-docker.pkg.dev/my-gcp-project/hippo-helm-charts
    chart: hippo-service
    targetRevision: "1.2.3"
    helm:
      releaseName: frontend-web-app
      valueFiles:
        - $values/service-settings/default/web-values.yml
  destination:
    server: https://kubernetes.default.svc
    namespace: frontend
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

ArgoCD watches your service repo. When you push a values change or bump `targetRevision`, it syncs the cluster automatically.

---

## Features Reference

### Service type

| `service.type` | When to use |
|---|---|
| `ClusterIP` | Default. Use when Ingress handles external traffic. |
| `LoadBalancer` | Direct GKE L4 LoadBalancer (no Ingress needed). |

### Ingress (GKE HTTP(S) LoadBalancer)

```yaml
ingress:
  enabled: true
  className: "gce"              # gce = external, gce-internal = internal
  annotations:
    kubernetes.io/ingress.allow-http: "false"
    networking.gke.io/managed-certificates: my-cert
    kubernetes.io/ingress.global-static-ip-name: my-static-ip
  host: api.example.com
  path: /
```

### Horizontal Pod Autoscaler

Scales on CPU and/or memory. Automatically targets the Rollout instead of the Deployment when `rollout.enabled: true`.

```yaml
hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 20
  targetCPUUtilizationPercentage: 65
  targetMemoryUtilizationPercentage: 80   # optional
  scaleDownStabilizationWindowSeconds: 300
```

### Liveness and Readiness Probes

```yaml
service:
  targetPort: 8080
  liveness:
    enabled: true
    path: /health
    initialDelaySeconds: 15
    periodSeconds: 30
    timeoutSeconds: 5
    failureThreshold: 3
  readiness:
    enabled: true
    path: /ready
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
```

### Pod Disruption Budget

```yaml
pdb:
  enabled: true
  minAvailable: 1   # or "50%"
```

### Pod Anti-Affinity and Node Affinity

```yaml
affinity:
  podAntiAffinity: soft   # soft | hard | none
  nodePool: high-mem-pool # optional: pin to a specific GKE node pool
```

- `soft` — prefer different nodes and zones (best-effort)
- `hard` — require different nodes (recommended for prod HA)
- `none` — no rules

### Network Policy

Deny-all ingress by default. Whitelist namespaces as needed.

```yaml
networkPolicy:
  enabled: true
  ingressNamespace: kube-system   # also allow from this namespace
```

### Deployment Zones

`deployment_zones` in `components-manifest.yml` is read by the **deployment pipeline**, not by the Helm chart. It tells the pipeline which clusters to deploy a component to.

| Zone | Used for |
|---|---|
| `public` | Internet-facing services with a public GKE Ingress |
| `internal` | VPC-only background workers, no public Ingress |

---

## Argo Rollouts (Canary)

Set `rollout.enabled: true` to replace the standard Deployment with an Argo Rollout. The chart automatically:
- Renders a `Rollout` object instead of a `Deployment`
- Creates `<name>-stable` and `<name>-canary` Services for traffic splitting
- Points the HPA at the `Rollout` instead of the `Deployment`

**Prerequisites** — Argo Rollouts controller must be installed in the cluster:

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

**Example values:**

```yaml
rollout:
  enabled: true
  autoPromote: false
  maxSurge: 25
  maxUnavailable: 0
  progressDeadlineSeconds: 600
  progressDeadlineAbort: true
  steps:
    - setWeight: 10
    - pause:
        duration: 60s
    - setWeight: 50
    - pause:
        duration: 120s
    - setWeight: 100
```

**Monitor a rollout:**

```bash
kubectl argo rollouts get rollout <release-name> -n <namespace> --watch
kubectl argo rollouts promote <release-name> -n <namespace>   # manual promote
kubectl argo rollouts abort   <release-name> -n <namespace>   # roll back
```

**Objects rendered** when `rollout.enabled: true`:

| Object | Count | Notes |
|---|---|---|
| `Rollout` | 1 | Replaces `Deployment` |
| `Service` | 3 | main + `-stable` + `-canary` |
| `HorizontalPodAutoscaler` | 1 (if enabled) | targets the Rollout |
| `PodDisruptionBudget` | 1 (if enabled) | |
| `Ingress` | 1 (if enabled) | points at main Service |
| `NetworkPolicy` | 1 (if enabled) | |

---

## Further Reading

- [Helm template helpers reference](docs/template_readme.md) — what each `*.tpl` file does
