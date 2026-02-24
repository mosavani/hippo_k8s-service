#!/usr/bin/env bash
# setup-argocd.sh — Install ArgoCD, ESO, and bootstrap the platform on a GKE cluster.
#
# Usage:
#   ./scripts/setup-argocd.sh
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#     (run: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>)
#   - curl available
#   - `make apply-dev` has been run in hippo_cloud so that:
#       * ESO GCP SA (hippo-dev-cluster-eso) exists with WIF binding
#       * ArgoCD GAR SA key exists in Secret Manager (hippo-dev-cluster-argocd-gar-key)

set -euo pipefail

ARGOCD_NAMESPACE="argocd"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
# ESO installed via Helm in step 4 — see below
ESO_FILE="argocd/eso.yaml"
EXTERNAL_SECRET_FILE="argocd/argocd-gar-external-secret.yaml"
PLATFORM_APP_FILE="argocd/platform-app.yaml"

# ── Colours ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Preflight checks ───────────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v kubectl >/dev/null 2>&1 || die "kubectl not found."
command -v curl    >/dev/null 2>&1 || die "curl not found."
command -v helm    >/dev/null 2>&1 || die "helm not found."

for f in "${ESO_FILE}" "${EXTERNAL_SECRET_FILE}" "${PLATFORM_APP_FILE}"; do
  [[ -f "$f" ]] || die "$f not found. Run this script from the repo root."
done

CONTEXT=$(kubectl config current-context 2>/dev/null) \
  || die "No kubectl context set. Run: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>"
info "Using kubectl context: ${CONTEXT}"

kubectl cluster-info >/dev/null 2>&1 \
  || die "Cannot reach the cluster API server. Check your kubeconfig and network."

# ── Step 1: Create namespace ────────────────────────────────────────────────────
info "Step 1/6 — Ensuring namespace '${ARGOCD_NAMESPACE}' exists..."
if kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  info "Namespace '${ARGOCD_NAMESPACE}' already exists."
else
  kubectl create namespace "${ARGOCD_NAMESPACE}"
  info "Namespace '${ARGOCD_NAMESPACE}' created."
fi

# ── Step 2: Install ArgoCD ─────────────────────────────────────────────────────
info "Step 2/6 — Installing ArgoCD (server-side apply)..."
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${ARGOCD_INSTALL_URL}"
info "ArgoCD manifests applied."

# ── Step 3: Wait for CRDs and pods ─────────────────────────────────────────────
info "Step 3/6 — Waiting for ArgoCD CRDs to be established..."
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  info "  Waiting for CRD: ${crd}"
  kubectl wait --for=condition=Established --timeout=120s crd/"${crd}" \
    || die "CRD ${crd} did not become Established within 120s."
done

info "Waiting for ArgoCD pods to be ready (timeout: 3m)..."
kubectl wait \
  --for=condition=Ready \
  pods --all \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=180s \
  || die "ArgoCD pods did not become Ready within 3 minutes. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"

info "All ArgoCD pods are ready."
kubectl get pods -n "${ARGOCD_NAMESPACE}"

# ── Step 4: Install External Secrets Operator ──────────────────────────────────
# ESO syncs the ArgoCD GAR SA key from GCP Secret Manager into argocd-gar-repo-creds.
# That Secret registers the GAR OCI registry URL with ArgoCD and provides
# _json_key Basic Auth credentials for OCI manifest resolution.
info "Step 4/6 — Installing External Secrets Operator (ESO)..."

helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"=hippo-dev-cluster-eso@project-ec2467ed-84cd-4898-b5b.iam.gserviceaccount.com \
  --wait \
  --timeout 3m

info "Waiting for ESO CRDs to be established..."
for crd in clustersecretstores.external-secrets.io externalsecrets.external-secrets.io secretstores.external-secrets.io; do
  kubectl wait --for=condition=Established --timeout=60s crd/"${crd}" \
    || die "CRD ${crd} did not become Established within 60s."
done

info "ESO installed. Applying ClusterSecretStore and ExternalSecret..."

# Invalidate kubectl's discovery cache so it picks up the newly registered ESO API groups.
# Without this, kubectl apply can fail with "no matches for kind ClusterSecretStore"
# even after the CRDs are Established, because the local cache is stale.
sleep 5
kubectl api-resources --api-group=external-secrets.io > /dev/null 2>&1 || true

# ClusterSecretStore: tells ESO to use WIF to access GCP Secret Manager
kubectl apply \
  --server-side \
  --force-conflicts \
  -f "${ESO_FILE}"

sleep 5
info "Applying ExternalSecret..."
# ExternalSecret: syncs the SA key JSON into argocd-gar-repo-creds
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${EXTERNAL_SECRET_FILE}"

# Wait up to 60s for ESO to sync the secret
info "Waiting for ExternalSecret to sync (timeout: 60s)..."
kubectl wait externalsecret/argocd-gar-repo-creds \
  -n "${ARGOCD_NAMESPACE}" \
  --for=condition=Ready \
  --timeout=60s \
  || die "ExternalSecret did not sync. Check: kubectl describe externalsecret argocd-gar-repo-creds -n ${ARGOCD_NAMESPACE}"

info "argocd-gar-repo-creds Secret populated by ESO."

# ── Step 5: Apply the platform App of Apps ─────────────────────────────────────
info "Step 5/6 — Applying platform App of Apps (hippo-platform)..."
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${PLATFORM_APP_FILE}"

info "hippo-platform Application applied. ArgoCD will now self-manage the argocd/ directory."

# ── Step 6: Verify ─────────────────────────────────────────────────────────────
info "Step 6/6 — Verifying..."
kubectl get application hippo-platform -n "${ARGOCD_NAMESPACE}" || true
kubectl get applicationset hippo-services -n "${ARGOCD_NAMESPACE}" 2>/dev/null || \
  warn "ApplicationSet not yet synced — ArgoCD may still be starting. Check in 60s."

# ── Summary ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} ArgoCD setup complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Verify:"
echo "  kubectl get application hippo-platform -n ${ARGOCD_NAMESPACE}"
echo "  kubectl get applicationset hippo-services -n ${ARGOCD_NAMESPACE}"
echo "  kubectl get applications -n ${ARGOCD_NAMESPACE}"
echo "  kubectl get externalsecret argocd-gar-repo-creds -n ${ARGOCD_NAMESPACE}"
echo ""
echo "Get the ArgoCD UI admin password:"
echo "  kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \\"
echo "    -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Access the ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
echo "  Then open: https://localhost:8080  (user: admin)"
