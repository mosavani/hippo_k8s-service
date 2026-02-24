# First-Time Setup

## Prerequisites

- `helm` >= 3.10
- `kubectl` configured and pointed at the target GKE cluster
- `gcloud` CLI authenticated

The GKE cluster itself is provisioned by `hippo_cloud`. Complete that setup first.

---

## Step 1 — Authenticate kubectl

```bash
gcloud auth login
gcloud container clusters get-credentials hippo-dev-cluster \
    --zone us-central1-a \
    --project project-ec2467ed-84cd-4898-b5b
kubectl cluster-info   # should return the API server URL
```

---

## Step 2 — Clone and verify local tooling

```bash
git clone <this-repo>
cd hippo_k8s-service
make lint    # sanity check: should pass with no errors
make test    # renders all test scenarios in tests/values/
```

---

## Step 3 — Apply Terraform in hippo_cloud

All GCP resources (service accounts, WIF bindings, Secret Manager secrets) are
managed by Terraform. Run this before the setup script.

```bash
cd ../hippo_cloud
make apply-dev
```

This creates:

| Resource | Purpose |
|---|---|
| `hippo-dev-cluster-nodes` GCP SA | Dedicated least-privilege node SA (`artifactregistry.reader`, logging, monitoring) |
| `hippo-dev-cluster-eso` GCP SA | Used by External Secrets Operator to read Secret Manager |
| WIF binding for `eso` | Lets the ESO K8s SA impersonate the GCP SA via ambient ADC |
| `hippo-dev-cluster-argocd-gar` GCP SA | Dedicated SA with `artifactregistry.reader`; its key is stored in Secret Manager |
| Secret Manager secret shell (`hippo-dev-cluster-argocd-gar-key`) | Container for the SA key JSON; ESO reads from here |
| `secretAccessor` IAM binding | Grants the ESO GCP SA access to the secret above |

**The SA key must be uploaded manually.** GCP org policy blocks Terraform from creating SA keys directly. After `make apply-dev`, run:

```bash
gcloud iam service-accounts keys create /tmp/argocd-gar-key.json \
  --iam-account=hippo-dev-cluster-argocd-gar@project-ec2467ed-84cd-4898-b5b.iam.gserviceaccount.com

gcloud secrets versions add hippo-dev-cluster-argocd-gar-key \
  --data-file=/tmp/argocd-gar-key.json \
  --project=project-ec2467ed-84cd-4898-b5b

shred -u /tmp/argocd-gar-key.json
```

**Why a SA key instead of WIF token for ArgoCD?**
ArgoCD's internal Go OCI client uses Basic Auth (`_json_key:password`) when resolving
OCI Helm chart manifests from GAR. ESO fetches the key from Secret Manager using WIF
(no key in Git) and keeps the K8s Secret up to date automatically.

**Note on ArgoCD v3 OCI path behavior:** ArgoCD v3 does not append the `chart` field
to the OCI v2 API path — it uses `repoURL` as-is. The `applicationset.yaml` includes the
chart artifact name (`/hippo-service`) directly in `repoURL` to work around this.

---

## Step 4 — Install ArgoCD and bootstrap the platform

```bash
./scripts/setup-argocd.sh
```

The script runs these steps in order:

| Step | What it does |
|---|---|
| 1 | Creates the `argocd` namespace |
| 2 | Installs ArgoCD via `--server-side` apply (avoids 262 KB annotation limit) |
| 3 | Waits for ArgoCD CRDs and pods to be ready |
| 4 | Installs ESO via Helm (with WIF annotation on ESO K8s SA), applies `argocd/eso.yaml` (ClusterSecretStore), applies `argocd/argocd-gar-external-secret.yaml`, waits for Secret to sync |
| 5 | Applies `argocd/platform-app.yaml` (App of Apps — ArgoCD self-manages `argocd/` from this point) |
| 6 | Verifies applications and applicationsets |

After it completes:

```bash
kubectl get applications -n argocd
kubectl get externalsecret argocd-gar-repo-creds -n argocd
```

### Accessing the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open: **https://localhost:8080** (accept the self-signed cert warning)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Login with username `admin` and the printed password.

---

## Step 5 — Configure GitHub Secrets (for release workflow)

The release workflow authenticates to GCP using Workload Identity Federation.
The WIF provider and SA are managed by Terraform in `hippo_cloud`.

After `make apply-dev`:

```bash
terraform -chdir=environments/dev output github_ci_service_accounts
```

Set these secrets in **GitHub repo → Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | WIF provider resource name from `hippo_cloud` |
| `GCP_SERVICE_ACCOUNT` | SA email from `github_ci_service_accounts["hippo-helm-publisher"]` output |
| `GAR_LOCATION` | e.g. `us-central1` |
| `GAR_PROJECT_ID` | your GCP project ID |
| `GAR_REPOSITORY` | e.g. `hippo-helm-charts` |

---

## CI Workflows

### `ci.yml` — Runs on every PR and push to `main`

Three steps, no GCP credentials needed:

```
1. Validate values.schema.json      → python3 JSON parse check
2. helm lint hippo-service/         → catches schema violations, YAML errors
3. Render all tests/values/*.yml    → template expansion smoke test
```

**Adding a new test scenario:** drop a `.yml` file into `tests/values/` — CI picks it up automatically.

### `release.yml` — Triggered by pushing a semver tag `v*.*.*`

```
1. Strip 'v' prefix → chart version (e.g. v1.2.3 → 1.2.3)
2. Set up Helm 3.14.0
3. Authenticate to GCP via Workload Identity Federation (no key file)
4. Configure Docker credential helper for GAR
5. Stamp version into Chart.yaml (source keeps version: 0.0.0)
6. helm lint (final check at release version)
7. helm package → dist/hippo-service-1.2.3.tgz
8. helm push → oci://<GAR_LOCATION>-docker.pkg.dev/<GAR_PROJECT_ID>/<GAR_REPOSITORY>
9. Updates argocd/chart-config.yaml with new version, commits to main
```

**To cut a release:**

```bash
git tag v1.2.3
git push origin v1.2.3
```

---

## Key Design Decisions

| Decision | Reason |
|---|---|
| **ESO + SA key for ArgoCD OCI auth** | ArgoCD's Go OCI client uses Basic Auth (`_json_key:SA_JSON`). ESO keeps the key out of Git and auto-syncs from Secret Manager. |
| **WIF for ESO (ambient ADC)** | ESO's K8s SA is annotated with the GCP SA email; GKE injects a projected token via the metadata server. The ClusterSecretStore has no explicit auth block — ESO uses the pod's ambient ADC token directly. |
| **ArgoCD v3 OCI repoURL** | ArgoCD v3 uses `repoURL` verbatim as the OCI image path — it does not append the `chart` field. `repoURL` must include the chart artifact name (`/hippo-service`). |
| **`Chart.yaml` keeps `version: 0.0.0` in source** | Release workflow stamps the real version at publish time — no version bump commits. |
| **CI has no GCP dependency** | Lint and render work fully offline. Only the release workflow needs cloud credentials. |
| **App of Apps pattern** | ArgoCD self-manages `argocd/` — any push to `main` is automatically synced, no manual `kubectl apply` after initial setup. |
| **Dedicated GKE node SA** | `hippo-dev-cluster-nodes` SA has minimal roles (logging, monitoring, `artifactregistry.reader`). Configured in `values.yml` `service_account` field. |
| **SA key rotation** | Delete the old key (`gcloud iam service-accounts keys delete <KEY_ID> --iam-account=hippo-dev-cluster-argocd-gar@...`), create a new one, and upload it with `gcloud secrets versions add hippo-dev-cluster-argocd-gar-key --data-file=...`. ESO detects the new Secret Manager version within 1h and updates the K8s Secret automatically. |
