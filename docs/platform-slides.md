# Hippo Platform: Developer Velocity at Scale

---

## Slide 1 — The Platform & How It Works

### Problem → Solution

| Challenge | What We Built |
|-----------|---------------|
| "Deploy a Flask app with HPA on GKE via Terraform" | A full three-layer platform where deploying any new service takes one YAML file |
| Manual cluster setup, manual deploys, manual rollbacks | Fully automated: push a git tag → image built → manifest updated → cluster syncs |
| CPU spikes crash pods, scale-in thrashes | HPA with asymmetric thresholds: scale up at 50% CPU, scale in only at <20% |
| Bad deploys reach 100% of traffic | Progressive canary rollout with automated health gates that abort & rollback on breach |

---

### Architecture: Three Layers

```
┌────────────────────────────────────────────────────────────────────┐
│  LAYER 1 — IaaC (hippo_cloud · Terraform)                          │
│                                                                    │
│  VPC · GKE Cluster (e2-standard-2, spot VMs, private nodes)        │
│  Cloud NAT · Workload Identity Federation                          │
│  Artifact Registry (images + Helm charts) · Secret Manager         │
│                                                                    │
│  One command: terraform apply                                      │
└────────────────────────────────────────────────────────────────────┘
              ↓ cluster ready, WIF bindings in place
┌────────────────────────────────────────────────────────────────────┐
│  LAYER 2 — PaaS (hippo_k8s-service · Helm + ArgoCD)               │
│                                                                    │
│  Helm Chart "hippo-service"  ──────────────────────────────────── │
│  • Deployment or Argo Rollout (canary)                            │
│  • HPA: CPU 50%↑ / 20%↓, min 1 / max 3 (dev)                    │
│  • Ingress (GCE), NetworkPolicy, PDB, PodMonitoring               │
│  • AnalysisTemplates: CPU & memory health gates via GMP           │
│                                                                    │
│  ArgoCD ApplicationSet ───────────────────────────────────────── │
│  • Matrix(git manifest × env list) → 1 App per service per env   │
│  • Pulls Helm chart from GAR OCI, values from service git repo    │
│  • Auto-sync + self-heal + server-side apply                      │
└────────────────────────────────────────────────────────────────────┘
              ↓ platform manages all k8s objects
┌────────────────────────────────────────────────────────────────────┐
│  LAYER 3 — Service (hippo_hello_world · Flask + GitHub Actions)    │
│                                                                    │
│  App: Flask, gunicorn 2 workers, /health /ready /metrics          │
│  Metrics: request count, latency histogram, error rate, CPU burn  │
│                                                                    │
│  Developer touch-points (that's it):                              │
│    service-settings/components-manifest.yml  ← register service   │
│    service-settings/default/values.yml       ← configure it       │
│    git tag v0.0.N                            ← release it         │
└────────────────────────────────────────────────────────────────────┘
```

---

### Key Design Decisions

**Zero long-lived credentials** — All auth (GitHub Actions CI, ArgoCD pulling charts, GMP frontend, ESO reading secrets) uses Workload Identity Federation. No JSON keys in git.

**YAML as the API surface** — Developers own two files. Everything else (Rollout, HPA, NetworkPolicy, PodMonitoring, PDB, Ingress, AnalysisTemplates) is rendered by the platform Helm chart. New service = add one entry to ApplicationSet git generator.

**Asymmetric HPA** — Scale up fast when CPU > 50%, but only scale down after CPU stays below 20% for 2 minutes. Prevents thrashing under bursty load.

**Managed Prometheus (GMP)** — No self-hosted Prometheus. GKE Managed Prometheus scrapes pods; `gmp-frontend` proxy lets Argo Rollouts AnalysisTemplates query Cloud Monitoring using standard PromQL syntax.

---

## Slide 2 — The Flywheel: CI/CD → GitOps → Reliability

### The Velocity Flywheel

```
Developer pushes                  ArgoCD detects           Argo Rollouts
git tag v0.0.N                    manifest change          runs canary
     │                                  │                       │
     ▼                                  ▼                       ▼
┌─────────────┐   image pushed    ┌──────────────┐   50% weight  ┌───────────────────┐
│ GitHub      │ ─────────────── ▶ │ components-  │ ──────────── ▶│ AnalysisTemplate  │
│ Actions CI  │   tag + latest    │ manifest.yml │   pause 2m    │ queries GMP:      │
│             │                   │ image_tag    │               │  CPU < 70%? ✓     │
│ ruff + pytest│  chart pushed    │ bumped       │               │  mem < 80%? ✓     │
│ docker build│ ─ (on k8s-svc   │              │               │                   │
│ docker push │    tag)           │              │  promote      │  breach → abort   │
└─────────────┘                   └──────────────┘ ──────────── ▶│  rollback auto    │
                                                                  └───────────────────┘
                                                                          │
                                                                          ▼
                                                                  stable 100% traffic
                                                                  HPA scales to demand
```

### End-to-End Flow (from `git tag` to production traffic)

| Step | What Happens | Who Does It |
|------|-------------|-------------|
| `git tag v0.0.21` | CI builds Docker image, pushes to GAR | GitHub Actions (WIF) |
| Manifest commit | `image_tag: "0.0.21"` written back to main | GitHub Actions |
| ArgoCD detects | ApplicationSet re-renders → new Rollout spec | ArgoCD (self-heal) |
| Canary starts | 50% weight on new image, stable keeps 50% | Argo Rollouts |
| Health gates | AnalysisRun queries GMP every 30s × 3 checks | Argo Rollouts |
| Pass → promote | 100% traffic to new pods | Argo Rollouts |
| Fail → abort | Auto-rollback to stable, zero manual intervention | Argo Rollouts |

---

### Reliability Mechanisms

```
RELIABILITY LAYER                WHAT IT DOES                        VALUES (dev)
─────────────────────────────────────────────────────────────────────────────────
HPA (scale out)       CPU > 50% → add pods                        min=1, max=3
HPA (scale in)        CPU < 20% for 2min → remove pods            stabilization=120s
Canary rollout        Route 50% traffic, measure, then promote    setWeight: 50
Analysis gates        Abort if CPU > 70% or memory > 80%          interval=30s, count=3
PDB                   Always keep ≥ 1 pod during node drain       minAvailable: 1
Pod anti-affinity     Spread pods across nodes (soft)             topology=hostname
Liveness probe        Restart stuck pods                          /health, period=60s
Readiness probe       Remove unready pods from LB                 /ready, period=30s
NetworkPolicy         Default-deny ingress, allow kube-system     enabled=true
ignoreDifferences     Stop ArgoCD fighting Rollouts over selectors stable+canary svc
```

### Cost Controls

- **Spot VMs** — GKE node pool uses spot instances (preemptible=false, spot=true). Dev cluster costs ~60% less than on-demand.
- **No CPU limits** — Requests set (100m), limits omitted. Prevents throttling; HPA manages actual scaling.
- **Scale-to-1** — Dev HPA `minReplicas: 1`. Idle services cost one pod, not two.
- **Managed Prometheus** — GKE Managed Prometheus included in GKE cost. No extra Prometheus nodes.

### Observability Stack

```
Flask /metrics  ──▶  GKE Managed Prometheus  ──▶  Cloud Monitoring
  (PodMonitoring)       (gmp-system collector)       (dashboards, alerts)
                                                             │
                                                             ▼
                                                    gmp-frontend proxy
                                                    (gmp-public:9090)
                                                             │
                                                             ▼
                                              Argo Rollouts AnalysisTemplates
                                              (canary health gates)
```

**Queries for your dashboard:**

| Signal | PromQL (via GMP frontend) |
|--------|--------------------------|
| Request rate | `rate(http_requests_total[5m])` |
| P99 latency | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` |
| Error rate % | `100 * rate(http_requests_total{http_status=~"5.."}[5m]) / rate(http_requests_total[5m])` |
| Pod CPU % | `100 * kubernetes_io:container_cpu_request_utilization{namespace_name="svc-hippo-hello-world"}` |
| Pod memory % | `100 * kubernetes_io:container_memory_request_utilization{namespace_name="svc-hippo-hello-world"}` |

---

### Onboarding a New Service

```yaml
# 1. Add to hippo_k8s-service/argocd/applicationset.yaml (one block):
- git:
    repoURL: https://github.com/yourorg/new-service.git
    revision: HEAD
    files:
      - path: service-settings/components-manifest.yml

# 2. In your service repo, add two files:
#    service-settings/components-manifest.yml
#    service-settings/default/values.yml

# 3. Push git tag → done.
# ArgoCD generates the Application, renders the chart, deploys to GKE.
# HPA, canary rollout, analysis, NetworkPolicy, PDB all active by default.
```

**That's the whole developer experience.** The platform handles the rest.

---

### Addresses Original Requirements

| Requirement | Implementation |
|-------------|---------------|
| GKE cluster via Terraform | `hippo_cloud/modules/gke/` — standard (non-Autopilot), `e2-standard-2`, release channel REGULAR |
| Helm deployment | `hippo_k8s-service/hippo-service/` — 15+ template files, versioned, published to GAR OCI |
| Ingress (not raw LoadBalancer) | GCE Ingress class, external IP `34.149.125.84`, app live at `http://34.149.125.84/` |
| HPA: scale out >50%, in <20% | `hpa.targetCPUUtilizationPercentage: 50`, `hpa.scaleDownCPUThreshold: 20` |
| HPA: min 1 / max 3 | `hpa.minReplicas: 1`, `hpa.maxReplicas: 3` |
| Simulate CPU load | Flask app burns 0–200ms CPU per request; `hey -n 10000 http://<ip>/` triggers HPA |
| CI/CD pipeline | GitHub Actions: lint→test→build→push→manifest update→ArgoCD sync, end-to-end automated |
| Logging/monitoring (optional) | Cloud Logging (stdout), GKE Managed Prometheus, Cloud Monitoring dashboards |
| Architecture diagram | See Layer diagram above |
