# Hippo Platform — Architecture

## Overview

The Hippo platform is a GitOps-based, three-layer system for deploying Kubernetes services on GKE. It separates concerns across three repositories so infrastructure, platform, and application teams can move independently.

| Layer | Repo | Owns | Changed by |
|---|---|---|---|
| **1 — Cloud** | `hippo_cloud` | GKE, VPC, IAM, WIF, GAR, Secret Manager | Platform/Infra team via Terraform |
| **2 — Platform** | `hippo_k8s-service` | Helm chart, ArgoCD, CI/CD standard, monitoring | Platform team via chart release tags |
| **3 — Workload** | `hippo_hello_world` | App code, Dockerfile, service-settings | Dev team — only touches `service-settings/` for K8s config |

---

## Diagrams

- [1. Flowchart — CI/CD & Deployment Flows](#1-flowchart--cicd--deployment-flows)
- [2. Sequence — App Release End-to-End](#2-sequence--app-release-end-to-end)
- [3. C4 — System Context](#3-c4--system-context)
- [4. C4 — Container (GKE internals)](#4-c4--container-gke-internals)
- [5. Mindmap — Platform Capabilities](#5-mindmap--platform-capabilities)
- [6. Class — Values Hierarchy](#6-class--values-hierarchy)

---

## 1. Flowchart — CI/CD & Deployment Flows

```mermaid
flowchart TD
    subgraph DEV["Developer Actions"]
        D1[git tag v0.0.x\nhippo_hello_world]
        D2[git tag v0.0.x\nhippo_k8s-service]
        D3[PR merge\nhippo_cloud]
    end

    subgraph GHA["GitHub Actions (WIF — no long-lived keys)"]
        CI_APP["hippo_hello_world CI\n1. docker build\n2. docker push → GAR\n3. update image_tag\n   in components-manifest.yml\n4. git push main"]
        CI_CHART["hippo_k8s-service CI\n1. helm lint\n2. helm package\n3. helm push → GAR OCI\n4. bump chart_version\n   in applicationset.yaml\n5. git push main"]
        CI_TF["hippo_cloud CI\n1. terraform fmt/lint/validate\n2. terraform plan (on PR)\n3. terraform apply (on merge)"]
    end

    subgraph GCP["Google Cloud Platform"]
        GAR_IMG["GAR: hippo-images\nhippo-hello-world:0.0.14"]
        GAR_CHART["GAR: hippo-helm-charts\nhippo-service:0.0.11 (OCI)"]
        SM["Secret Manager\nargocd-gar-key"]
        GKE["GKE Cluster\nhippo-dev-cluster"]
    end

    subgraph ARGOCD["ArgoCD (in GKE — argocd ns)"]
        PLATFORM["App of Apps\nhippo-platform\n(watches argocd/ dir)"]
        APPSET["ApplicationSet\nhippo-services\n(matrix: git × list)"]
        APP["Application\nhippo-hello-world-dev"]
    end

    subgraph ESO["ESO (in GKE — external-secrets ns)"]
        CSS["ClusterSecretStore\ngcp-secret-manager"]
        ES["ExternalSecret\nargocd-gar-repo-creds"]
        SEC["K8s Secret\nargocd-gar-repo-creds\nusername: _json_key"]
    end

    subgraph SVC["svc-hippo-hello-world ns"]
        DEP["Deployment\nsvc-hippo-hello-world\nimage: 0.0.14"]
        HPA_R["HPA\n1–3 replicas\nCPU target: 50%"]
        ING["Ingress\nGKE external LB"]
        PM["PodMonitoring\n/metrics → GMP"]
    end

    D1 --> CI_APP
    D2 --> CI_CHART
    D3 --> CI_TF

    CI_APP --> GAR_IMG
    CI_APP -->|"updates image_tag"| APPSET
    CI_CHART --> GAR_CHART
    CI_CHART -->|"updates chart_version"| PLATFORM
    CI_TF --> GKE

    PLATFORM -->|"syncs argocd/ dir"| APPSET
    APPSET -->|"generates"| APP
    APP -->|"pulls chart"| GAR_CHART
    APP -->|"pulls values"| CI_APP

    SM -->|"WIF ambient auth"| CSS
    CSS --> ES
    ES --> SEC
    SEC -->|"repo-creds"| APP

    APP -->|"deploys"| DEP
    DEP --> HPA_R
    DEP --> ING
    DEP --> PM

    GAR_IMG -->|"image pull"| DEP
```

---

## 2. Sequence — App Release End-to-End

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant GH as GitHub
    participant CI as GitHub Actions (WIF)
    participant GAR as Artifact Registry
    participant SM as Secret Manager
    participant ESO as ESO Pod
    participant ARGO as ArgoCD
    participant GKE as GKE (svc-hippo-hello-world)

    Dev->>GH: git tag v0.0.14 && git push

    GH->>CI: trigger release workflow
    CI->>CI: exchange OIDC token → GCP token (WIF)
    CI->>GAR: docker push hippo-hello-world:0.0.14
    CI->>GH: update image_tag in components-manifest.yml
    CI->>GH: git commit + push main [skip ci]

    Note over ARGO: Every 3 min — detect git change

    ARGO->>GH: poll components-manifest.yml
    GH-->>ARGO: image_tag = 0.0.14 (changed)

    ARGO->>ESO: (background) ExternalSecret sync
    ESO->>ESO: WIF ambient token → GCP SA
    ESO->>SM: fetch hippo-dev-cluster-argocd-gar-key
    SM-->>ESO: SA JSON key
    ESO->>GKE: write K8s Secret argocd-gar-repo-creds

    ARGO->>GAR: pull hippo-service:0.0.11 (OCI)\nBasic Auth: _json_key + SA key
    GAR-->>ARGO: Helm chart tgz

    ARGO->>ARGO: helm template\nmerge values (chart → default → override)
    ARGO->>GKE: kubectl apply (ServerSideApply)\nDeployment image: 0.0.14

    GKE->>GAR: image pull hippo-hello-world:0.0.14\n(node SA WIF — artifactregistry.reader)
    GAR-->>GKE: image layers

    GKE->>GKE: rolling update (maxSurge=1, maxUnavailable=0)
    GKE-->>ARGO: pods Ready
    ARGO-->>Dev: App status: Synced / Healthy
```

---

## 3. C4 — System Context

```mermaid
C4Context
    title Hippo Platform — System Context

    Person(dev, "Application Developer", "Owns the service code and service-settings. Pushes tags to release.")
    Person(platform, "Platform Engineer", "Owns hippo_k8s-service and hippo_cloud. Releases chart versions and manages infra.")

    System(hippo_hw, "hippo_hello_world", "Example workload repo. Flask app + Dockerfile + service-settings for per-env K8s config.")
    System(hippo_k8s, "hippo_k8s-service", "Platform layer. Shared Helm chart + ArgoCD ApplicationSet. Publishes versioned chart to GAR.")
    System(hippo_cloud, "hippo_cloud", "Infrastructure layer. Terraform modules for GKE, VPC, IAM, WIF, GAR, Secret Manager.")

    System_Ext(gcp, "Google Cloud Platform", "GKE, GAR, Secret Manager, GMP, WIF, Cloud NAT")
    System_Ext(github, "GitHub", "Source of truth for all three repos. OIDC provider for WIF.")

    Rel(dev, hippo_hw, "Pushes code and tags")
    Rel(platform, hippo_k8s, "Releases chart versions, manages ArgoCD config")
    Rel(platform, hippo_cloud, "Applies Terraform changes")

    Rel(hippo_hw, github, "Stores source, triggers CI")
    Rel(hippo_k8s, github, "Stores chart + ArgoCD config, triggers CI")
    Rel(hippo_cloud, github, "Stores Terraform, triggers CI")

    Rel(hippo_hw, gcp, "Publishes Docker image to GAR")
    Rel(hippo_k8s, gcp, "Publishes Helm chart to GAR OCI")
    Rel(hippo_cloud, gcp, "Provisions GKE, IAM, WIF, networking")

    Rel(github, gcp, "WIF: OIDC token exchange → short-lived GCP token")
```

---

## 4. C4 — Container (GKE Internals)

```mermaid
C4Container
    title Hippo Platform — GKE Container View

    System_Ext(gar, "Google Artifact Registry", "Stores Helm charts (OCI) and Docker images")
    System_Ext(sm, "Secret Manager", "Stores argocd-gar-key (SA JSON key)")
    System_Ext(gmp, "GKE Managed Prometheus", "Scrapes /metrics, stores in GCP Monitoring")

    System_Boundary(gke, "GKE Cluster — hippo-dev-cluster") {

        System_Boundary(argocd_ns, "ns: argocd") {
            Container(platform_app, "hippo-platform", "ArgoCD Application", "App of Apps. Watches argocd/ dir in git. Self-manages the ApplicationSet.")
            Container(appset, "hippo-services", "ApplicationSet", "Matrix generator: git (components-manifest) × list (env + chart_version). Generates one Application per service × env.")
            Container(app, "hippo-hello-world-dev", "ArgoCD Application", "Syncs hippo-service Helm chart from GAR OCI + values from service repo.")
            ContainerDb(repo_creds, "argocd-gar-repo-creds", "K8s Secret", "username=_json_key, password=SA key. Created by ESO. Labeled for ArgoCD repo-creds discovery.")
        }

        System_Boundary(eso_ns, "ns: external-secrets") {
            Container(eso, "ESO", "external-secrets operator", "Watches ExternalSecret resources. Authenticates to GCP via WIF ambient ADC.")
            Container(css, "gcp-secret-manager", "ClusterSecretStore", "Configures ESO to use GCP Secret Manager as secret backend.")
            Container(es, "argocd-gar-repo-creds", "ExternalSecret", "Maps Secret Manager key → K8s Secret in argocd namespace. Refreshes every 1h.")
        }

        System_Boundary(svc_ns, "ns: svc-hippo-hello-world") {
            Container(deploy, "svc-hippo-hello-world", "Deployment", "Flask app. 1–3 replicas. Rolling update maxSurge=1.")
            Container(hpa, "svc-hippo-hello-world", "HPA", "CPU target 50%. Min 1, max 3 replicas.")
            Container(svc, "svc-hippo-hello-world", "Service (ClusterIP)", "Port 80 → container 8080.")
            Container(ing, "svc-hippo-hello-world", "Ingress (GKE)", "External HTTP(S) LB.")
            Container(pdb, "svc-hippo-hello-world", "PodDisruptionBudget", "minAvailable=1.")
            Container(pm, "svc-hippo-hello-world", "PodMonitoring", "Scrapes /metrics every 30s for GKE Managed Prometheus.")
        }
    }

    Rel(platform_app, appset, "manages")
    Rel(appset, app, "generates")
    Rel(app, gar, "pulls hippo-service:0.0.11 (OCI Helm chart)")
    Rel(app, repo_creds, "authenticates with")
    Rel(app, deploy, "applies manifests via ServerSideApply")

    Rel(eso, css, "uses")
    Rel(eso, es, "reconciles")
    Rel(eso, sm, "fetches argocd-gar-key (WIF)")
    Rel(es, repo_creds, "writes")

    Rel(deploy, hpa, "scaled by")
    Rel(deploy, pdb, "protected by")
    Rel(svc, ing, "backed by")
    Rel(pm, gmp, "pushes metrics")
```

---

## 5. Mindmap — Platform Capabilities

```mermaid
mindmap
  root((Hippo Platform))
    Infrastructure
      GKE Standard Cluster
        Zonal us-central1-a
        Private nodes + Cloud NAT
        Workload Identity enabled
        Node autoscaling 1-3
      Networking
        VPC hippo-dev-vpc
        Pod CIDR 10.20.0.0/18
        Service CIDR 10.30.0.0/20
      IAM
        Least-privilege node SA
        WIF bindings per workload
        No long-lived keys
      Storage
        GAR Helm charts OCI
        GAR Docker images
        GCS Terraform state
    Platform Services
      ArgoCD
        App of Apps bootstrap
        ApplicationSet matrix generator
        Automated sync + self-heal
        Per-env namespace isolation
      External Secrets Operator
        ClusterSecretStore GCP
        WIF ambient auth
        1h secret refresh
      GKE Managed Prometheus
        PodMonitoring CRD
        Metrics Explorer
    Helm Chart hippo-service
      Workload Resources
        Deployment or Argo Rollout
        Service ClusterIP or LB
        Ingress GKE external
      Reliability
        HPA CPU and memory
        PDB min available
        Pod anti-affinity soft or hard
        Rolling update strategy
      Observability
        Liveness probe
        Readiness probe
        PodMonitoring metrics
      Security
        NetworkPolicy deny-all default
        Non-root container
        No CPU limits by default
    Developer Experience
      service-settings
        components-manifest.yml
        default values dev
        overrides values prod
      Simple YAML config
        No raw K8s manifests
        Schema validated
        Per-env overrides
      CI/CD automated
        Tag to deploy
        Image tag auto-updated
        Chart version auto-bumped
    Security
      Workload Identity Federation
        GitHub OIDC to GCP
        K8s SA to GCP SA
        Short-lived tokens
      Secret Management
        Secret Manager source
        ESO syncs to K8s
        ArgoCD repo-creds
      Supply Chain
        WIF keyless CI auth
        Immutable image tags
        Helm chart versioning
```

---

## 6. Class — Values Hierarchy & Chart Structure

```mermaid
classDiagram
    class ChartDefaults {
        +file: hippo-service/values.yaml
        +replicaCount: 2
        +image.pullPolicy: IfNotPresent
        +service.type: ClusterIP
        +service.port: 80
        +service.targetPort: 8080
        +hpa.enabled: false
        +pdb.enabled: true
        +pdb.minAvailable: 1
        +metrics.enabled: true
        +metrics.path: /metrics
        +metrics.interval: 30s
        +networkPolicy.enabled: true
        +affinity.podAntiAffinity: soft
    }

    class DevValues {
        +file: service-settings/default/values.yml
        +global.env: dev
        +service.replicaCount: 2
        +hpa.enabled: true
        +hpa.minReplicas: 1
        +hpa.maxReplicas: 3
        +hpa.targetCPUUtilizationPercentage: 50
        +ingress.enabled: true
        +ingress.className: gce
        +metrics.port: 8080
        +resources.requests.cpu: 100m
        +resources.requests.memory: 128Mi
    }

    class ProdValues {
        +file: service-settings/overrides/values.yml
        +global.env: prod
        +hpa.minReplicas: 4
        +hpa.maxReplicas: 50
        +hpa.targetCPUUtilizationPercentage: 60
        +affinity.podAntiAffinity: hard
        +resources.requests.cpu: 200m
        +resources.requests.memory: 256Mi
        +resources.limits.memory: 512Mi
    }

    class ArgoInlineValues {
        +source: applicationset.yaml inline
        +global.env: from list generator
        +global.componentName: from manifest
        +image.repository: from GAR coords
        +image.tag: from components-manifest
    }

    class RenderedManifests {
        +Deployment
        +Service
        +Ingress
        +HPA
        +PDB
        +NetworkPolicy
        +PodMonitoring
    }

    class ComponentsManifest {
        +file: service-settings/components-manifest.yml
        +app_name: hippo-hello-world
        +repo_url: github.com/mosavani/hippo_hello_world
        +target_revision: HEAD
        +image_tag: 0.0.14
        +default_values: service-settings/default/values.yml
        +prod_values: service-settings/overrides/values.yml
    }

    ChartDefaults <|-- DevValues : overrides
    ChartDefaults <|-- ProdValues : overrides
    DevValues <|-- ArgoInlineValues : overrides
    ProdValues <|-- ArgoInlineValues : overrides
    ArgoInlineValues --> RenderedManifests : helm template
    ComponentsManifest --> ArgoInlineValues : provides image_tag\nand values file paths
```

---

## Component Inventory

### hippo_cloud — Terraform Modules

| Module | Resources |
|---|---|
| `modules/networking` | VPC, subnet, secondary CIDRs (pods/services), Cloud Router, Cloud NAT |
| `modules/gke` | `google_container_cluster`, node pool, WI, shielded nodes, private cluster |
| `modules/iam` | Node SA, least-privilege roles, `artifactregistry.reader` |
| `modules/workload-identity` | GCP SAs, K8s↔GCP WIF bindings, GitHub Actions OIDC bindings |

### hippo_k8s-service — Helm Chart Templates

| Template | Conditional |
|---|---|
| `deployment.yaml` | Suppressed when `rollout.enabled=true` |
| `rollout.yaml` | Only when `rollout.enabled=true` |
| `service.yaml` | Always |
| `ingress.yaml` | `ingress.enabled=true` |
| `hpa.yaml` | `hpa.enabled=true` |
| `pdb.yaml` | `pdb.enabled=true` |
| `netpolicies.yaml` | `networkPolicy.enabled=true` |
| `podmonitoring.yaml` | `metrics.enabled=true` |

### Auth — WIF Service Accounts

| Identity | Type | Roles | Used by |
|---|---|---|---|
| `hippo-dev-cluster-nodes` | GCP SA (node pool) | `logging.logWriter`, `monitoring.metricWriter`, `artifactregistry.reader` | GKE nodes (image pull) |
| `hippo-dev-cluster-eso` | GCP SA (WIF K8s) | `secretmanager.secretAccessor` | ESO pod → Secret Manager |
| `hippo-dev-cluster-argocd-repo` | GCP SA (WIF K8s) | `artifactregistry.reader` | argocd-repo-server (legacy) |
| `hippo-helm-publisher` | GCP SA (WIF GitHub) | `artifactregistry.writer` | CI: helm push (per-repo binding) |
| `hippo-image-publisher` | GCP SA (WIF GitHub) | `artifactregistry.writer` | CI: docker push (per-org binding) |

---

## Key Design Decisions

**1. Three-repo separation**
Infrastructure, platform config, and application code evolve at different rates and are owned by different teams. Keeping them separate avoids coupling and allows independent release cycles.

**2. ArgoCD v3 OCI repoURL**
ArgoCD v3 uses `repoURL` verbatim as the OCI v2 API path — it does NOT append the `chart` field. The chart artifact name (`/hippo-service`) must be included in `repoURL`:
```
oci://us-central1-docker.pkg.dev/<project>/<repo>/hippo-service
```

**3. App of Apps pattern**
`hippo-platform` (Application) watches the `argocd/` directory and self-manages the ApplicationSet. Any push to `argocd/` on main is automatically applied — no manual `kubectl apply` needed after initial bootstrap.

**4. ESO + Secret Manager over WIF direct for ArgoCD**
ArgoCD's repo-server does not natively support GKE WIF ambient credentials for OCI GAR auth. ESO bridges this: it reads the SA JSON key from Secret Manager (using WIF) and writes it as a K8s Secret that ArgoCD can use with standard `_json_key` Basic Auth.

**5. Federated service-settings**
Each service repo owns its `service-settings/` directory. ArgoCD's ApplicationSet git generator reads `components-manifest.yml` directly from the service repo — no central registration file needed beyond adding the repo URL to the ApplicationSet.

**6. chart_version auto-bump**
The release workflow in `hippo_k8s-service` stamps the chart version into `applicationset.yaml` and commits back to main. This means releasing a new chart version automatically rolls it out to all managed services on the next ArgoCD sync — no manual edits required.
