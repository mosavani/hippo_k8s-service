# First-Time Setup

## Prerequisites

- `helm` >= 3.10
- `kubectl` configured and pointed at the target GKE cluster
- `gcloud` CLI authenticated
- ArgoCD >= 2.3

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
| `hippo-dev-cluster-eso` GCP SA | Used by External Secrets Operator to read Secret Manager |
| WIF binding for `eso` | Lets the ESO K8s SA impersonate the GCP SA |
| `hippo-dev-cluster-argocd-gar` GCP SA | Dedicated SA with `artifactregistry.reader` |
| SA key in Secret Manager (`hippo-dev-cluster-argocd-gar-key`) | Key JSON used by ArgoCD for GAR Basic Auth |
| `hippo-dev-cluster-image-updat` GCP SA | Used by ArgoCD Image Updater to poll GAR image tags |
| WIF binding for `image-updater` | Lets the Image Updater K8s SA impersonate the GCP SA |

**Why a SA key instead of WIF token for ArgoCD?**
ArgoCD's internal Go OCI client uses Basic Auth (`username:password`) when talking
to OCI registries. GAR only accepts Basic Auth with a full SA JSON key as the
password — not a short-lived OAuth2 token. ESO fetches the key from Secret Manager
using WIF (no key in Git) and keeps the K8s Secret up to date automatically.

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
| 4 | Installs ArgoCD Image Updater + applies `argocd/argocd-image-updater.yaml` (WIF SA annotation + `provider: google` registry config) |
| 5 | Installs ESO via Helm, applies `argocd/eso.yaml` (ClusterSecretStore), applies `argocd/argocd-gar-external-secret.yaml`, waits for Secret to sync |
| 6 | Applies `argocd/platform-app.yaml` (App of Apps — ArgoCD self-manages `argocd/` from this point) |
| 7 | Verifies applications and applicationsets |

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
| **ESO + SA key for ArgoCD OCI auth** | ArgoCD's Go OCI client uses Basic Auth; GAR only accepts a full SA JSON key as the password, not a short-lived token. ESO keeps the key out of Git and auto-syncs from Secret Manager. |
| **WIF for Image Updater** | Image Updater has native ADC support (`provider: google`) and uses WIF tokens directly — no key needed. |
| **`Chart.yaml` keeps `version: 0.0.0` in source** | Release workflow stamps the real version at publish time — no version bump commits. |
| **CI has no GCP dependency** | Lint and render work fully offline. Only the release workflow needs cloud credentials. |
| **App of Apps pattern** | ArgoCD self-manages `argocd/` — any push to `main` is automatically synced, no manual `kubectl apply` after initial setup. |
| **SA key rotation** | Run `terraform taint module.argocd_gar_key.google_service_account_key.gar_key && make apply-dev` in `hippo_cloud`. ESO detects the new Secret Manager version within 1h and updates the K8s Secret automatically. |
