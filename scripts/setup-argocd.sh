#!/usr/bin/env bash
# setup-argocd.sh — Install ArgoCD and apply the ApplicationSet on a GKE cluster.
#
# Usage:
#   ./scripts/setup-argocd.sh
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#     (run: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>)
#   - curl available

set -euo pipefail

ARGOCD_NAMESPACE="argocd"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
IMAGE_UPDATER_INSTALL_URL="https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml"
ARGOCD_WI_FILE="argocd/argocd-repo-server-wi.yaml"
TOKEN_REFRESHER_FILE="argocd/gar-token-refresher.yaml"
IMAGE_UPDATER_FILE="argocd/argocd-image-updater.yaml"
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

command -v kubectl >/dev/null 2>&1 || die "kubectl not found. Install it and configure access to the cluster."
command -v curl    >/dev/null 2>&1 || die "curl not found."
[[ -f "${TOKEN_REFRESHER_FILE}" ]] \
  || die "${TOKEN_REFRESHER_FILE} not found. Run this script from the repo root."
[[ -f "${IMAGE_UPDATER_FILE}" ]] \
  || die "${IMAGE_UPDATER_FILE} not found. Run this script from the repo root."

CONTEXT=$(kubectl config current-context 2>/dev/null) \
  || die "No kubectl context set. Run: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>"
info "Using kubectl context: ${CONTEXT}"

[[ -f "${PLATFORM_APP_FILE}" ]] \
  || die "${PLATFORM_APP_FILE} not found. Run this script from the repo root."

# Verify cluster is reachable
kubectl cluster-info >/dev/null 2>&1 \
  || die "Cannot reach the cluster API server. Check your kubeconfig and network."

# ── Step 1: Create namespace ────────────────────────────────────────────────────
info "Step 1/8 — Ensuring namespace '${ARGOCD_NAMESPACE}' exists..."
if kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  info "Namespace '${ARGOCD_NAMESPACE}' already exists."
else
  kubectl create namespace "${ARGOCD_NAMESPACE}"
  info "Namespace '${ARGOCD_NAMESPACE}' created."
fi

# ── Step 2: Install ArgoCD (server-side apply avoids annotation size limit) ────
info "Step 2/8 — Installing ArgoCD (server-side apply)..."
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${ARGOCD_INSTALL_URL}"
info "ArgoCD manifests applied."

# ── Step 3: Wait for CRDs to be established ─────────────────────────────────────
info "Step 3/8 — Waiting for ArgoCD CRDs to be established..."

for crd in \
  applications.argoproj.io \
  applicationsets.argoproj.io \
  appprojects.argoproj.io; do
  info "  Waiting for CRD: ${crd}"
  kubectl wait \
    --for=condition=Established \
    --timeout=120s \
    crd/"${crd}" \
  || die "CRD ${crd} did not become Established within 120s."
done

info "All ArgoCD CRDs established."

# ── Step 4: Wait for all ArgoCD pods to be ready ────────────────────────────────
info "Step 4/8 — Waiting for ArgoCD pods to be ready (timeout: 3m)..."
kubectl wait \
  --for=condition=Ready \
  pods --all \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=180s \
|| die "ArgoCD pods did not become Ready within 3 minutes. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"

info "All ArgoCD pods are ready."
kubectl get pods -n "${ARGOCD_NAMESPACE}"

# ── Step 5: Configure Workload Identity for argocd-repo-server ──────────────────
info "Step 5/8 — Configuring Workload Identity for argocd-repo-server..."

[[ -f "${ARGOCD_WI_FILE}" ]] \
  || die "${ARGOCD_WI_FILE} not found. Run this script from the repo root."

kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${ARGOCD_WI_FILE}"

# Restart repo-server so it picks up the new SA annotation and WI token.
kubectl rollout restart deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}"
kubectl rollout status deployment/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=120s \
  || die "argocd-repo-server did not restart cleanly. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"

info "Workload Identity configured for argocd-repo-server."

# ── Step 6: Deploy GAR token refresher ──────────────────────────────────────────
# The CronJob runs every 45 min and patches the argocd-gar-repo-creds Secret
# with a fresh GCP OAuth2 token. ArgoCD's Go OCI client reads from that Secret.
# We trigger an immediate Job run here so the Secret is populated before
# platform-app.yaml is applied — otherwise the first ArgoCD sync will 403.
info "Step 6/8 — Deploying GAR token refresher and seeding initial token..."

kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${TOKEN_REFRESHER_FILE}"

# Trigger an immediate run so the placeholder password is replaced before
# ArgoCD tries to pull the chart for the first time.
kubectl create job gar-token-seed \
  --from=cronjob/gar-token-refresher \
  -n "${ARGOCD_NAMESPACE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl wait job/gar-token-seed \
  -n "${ARGOCD_NAMESPACE}" \
  --for=condition=Complete \
  --timeout=60s \
  || die "Initial token seed Job did not complete. Check: kubectl logs -l job-name=gar-token-seed -n ${ARGOCD_NAMESPACE}"

info "GAR token refresher deployed and initial token seeded."

# ── Step 7: Install ArgoCD Image Updater + configure WIF for GAR ────────────────
info "Step 7/8 — Installing ArgoCD Image Updater and configuring WIF for GAR..."

# Install upstream Image Updater manifest (creates Deployment, SA, RBAC).
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${IMAGE_UPDATER_INSTALL_URL}"

# Apply our overlay: annotates the Image Updater SA with the GCP SA for WIF,
# and writes the registries.conf ConfigMap with provider: google.
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${IMAGE_UPDATER_FILE}"

# Restart so the pod picks up the new SA annotation and registry config.
kubectl rollout restart deployment/argocd-image-updater -n "${ARGOCD_NAMESPACE}"
kubectl rollout status deployment/argocd-image-updater -n "${ARGOCD_NAMESPACE}" --timeout=120s \
  || die "argocd-image-updater did not restart cleanly. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"

info "Image Updater installed and configured with WIF for GAR."

# ── Step 8: Apply the platform App of Apps ──────────────────────────────────────
# This is the only manual apply ever needed. After this, ArgoCD watches
# argocd/ in this repo and self-updates: any push to main (applicationset.yaml,
# chart-config.yaml, platform-app.yaml) is automatically synced to the cluster.
info "Step 8/8 — Applying platform App of Apps (hippo-platform)..."
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${PLATFORM_APP_FILE}"

info "hippo-platform Application applied. ArgoCD will now self-manage the argocd/ directory."

# ── Summary ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} ArgoCD setup complete (with Image Updater + WIF for GAR)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Verify:"
echo "  kubectl get application hippo-platform -n ${ARGOCD_NAMESPACE}"
echo "  kubectl get applicationset hippo-services -n ${ARGOCD_NAMESPACE}"
echo "  kubectl get applications -n ${ARGOCD_NAMESPACE}"
echo ""
echo "Get the ArgoCD UI admin password:"
echo "  kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \\"
echo "    -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Access the ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
echo "  Then open: https://localhost:8080  (user: admin)"
