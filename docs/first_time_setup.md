# First-Time Setup

## Prerequisites

- `helm` >= 3.10
- `kubectl` configured and pointed at the target GKE cluster
- ArgoCD >= 2.3

The GKE cluster itself is provisioned by `hippo_cloud`. Complete that setup first before continuing here.

---

## Step 1 — Clone and verify local tooling

```bash
git clone <this-repo>
cd hippo_k8s-service
make lint    # sanity check: should pass with no errors
make test    # renders all test scenarios in tests/values/
```

---

## Step 2 — Install ArgoCD and apply the ApplicationSet

Use the setup script — it handles CRD readiness, the annotation-size issue with `kubectl apply`, and pod readiness in the correct order:

```bash
./scripts/setup-argocd.sh
```

The script:
1. Creates the `argocd` namespace if it doesn't exist
2. Installs ArgoCD using `--server-side` apply (avoids the 262 KB annotation limit)
3. Waits for all ArgoCD CRDs (`applications`, `applicationsets`, `appprojects`) to be established
4. Waits for all ArgoCD pods to be ready
5. Applies `argocd/applicationset.yaml` using `--server-side` apply

Run from the repo root. Requires `kubectl` with an active cluster context.

After it completes, verify:

```bash
kubectl get applicationset hippo-services -n argocd
kubectl get applications -n argocd
```

### Accessing the ArgoCD UI

Port-forward the ArgoCD server to access the UI locally:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Then open: **https://localhost:8080** (accept the self-signed cert warning)

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Login with username `admin` and the printed password.

---

## Step 3 — Configure GitHub Secrets (for release workflow)

The release workflow authenticates to GCP using **Workload Identity Federation**. The GCP service account and WIF binding are declared in `hippo_cloud/environments/dev/wif.yml` under `github_ci` and managed by Terraform.

After running `make apply-dev` in `hippo_cloud`, get the SA email:

```bash
terraform -chdir=environments/dev output github_ci_service_accounts
```

Set these secrets in **GitHub repo → Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | same value as `hippo_cloud`'s `GCP_WORKLOAD_IDENTITY_PROVIDER` secret |
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

Any template error in `tests/values/` fails the build. This is the main safety net for chart changes.

**Adding a new test scenario:** drop a `.yml` file into `tests/values/` — CI picks it up automatically with no workflow changes.

### `release.yml` — Triggered by pushing a semver tag `v*.*.*`

```
1. Strip 'v' prefix → chart version (e.g. v1.2.3 → 1.2.3)
2. Set up Helm 3.14.0
3. Authenticate to GCP via Workload Identity Federation (no key file)
4. Configure Docker credential helper for GAR
5. Stamp version into Chart.yaml (source file keeps version: 0.0.0)
6. helm lint (final check at release version)
7. helm package → dist/hippo-service-1.2.3.tgz
8. helm push → oci://<GAR_LOCATION>-docker.pkg.dev/<GAR_PROJECT_ID>/<GAR_REPOSITORY>
9. Writes OCI URL to GitHub job summary
```

**To cut a release:**

```bash
git tag v1.2.3
git push origin v1.2.3
```

The workflow handles everything else and publishes the chart to GAR.

---

## Key Design Decisions

- **`Chart.yaml` keeps `version: 0.0.0` in source** — the release workflow stamps the real version at publish time, avoiding version bump commits on every release.
- **CI has no GCP dependency** — lint and render work fully offline. Only the release workflow needs cloud credentials.
- **No long-lived GCP keys** — the release workflow uses WIF. The SA and binding are declared in `hippo_cloud/environments/dev/wif.yml` and applied by Terraform.
- **Test scenarios are the CI coverage** — the files in `tests/values/` represent different feature combinations (simple, ingress, HPA, HA prod, canary). Adding coverage means adding files there.
- **ArgoCD setup is scripted** — `scripts/setup-argocd.sh` handles ordering and server-side apply to avoid common installation pitfalls.
