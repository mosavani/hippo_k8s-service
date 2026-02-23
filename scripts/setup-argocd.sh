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
APPLICATIONSET_FILE="argocd/applicationset.yaml"

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

CONTEXT=$(kubectl config current-context 2>/dev/null) \
  || die "No kubectl context set. Run: gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>"
info "Using kubectl context: ${CONTEXT}"

[[ -f "${APPLICATIONSET_FILE}" ]] \
  || die "${APPLICATIONSET_FILE} not found. Run this script from the repo root."

# Verify cluster is reachable
kubectl cluster-info >/dev/null 2>&1 \
  || die "Cannot reach the cluster API server. Check your kubeconfig and network."

# ── Step 1: Create namespace ────────────────────────────────────────────────────
info "Step 1/5 — Ensuring namespace '${ARGOCD_NAMESPACE}' exists..."
if kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  info "Namespace '${ARGOCD_NAMESPACE}' already exists."
else
  kubectl create namespace "${ARGOCD_NAMESPACE}"
  info "Namespace '${ARGOCD_NAMESPACE}' created."
fi

# ── Step 2: Install ArgoCD (server-side apply avoids annotation size limit) ────
info "Step 2/5 — Installing ArgoCD (server-side apply)..."
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${ARGOCD_INSTALL_URL}"
info "ArgoCD manifests applied."

# ── Step 3: Wait for CRDs to be established ─────────────────────────────────────
info "Step 3/5 — Waiting for ArgoCD CRDs to be established..."

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
info "Step 4/5 — Waiting for ArgoCD pods to be ready (timeout: 3m)..."
kubectl wait \
  --for=condition=Ready \
  pods --all \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=180s \
|| die "ArgoCD pods did not become Ready within 3 minutes. Check: kubectl get pods -n ${ARGOCD_NAMESPACE}"

info "All ArgoCD pods are ready."
kubectl get pods -n "${ARGOCD_NAMESPACE}"

# ── Step 5: Apply the ApplicationSet ────────────────────────────────────────────
info "Step 5/5 — Applying ApplicationSet..."
kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${ARGOCD_NAMESPACE}" \
  -f "${APPLICATIONSET_FILE}"

info "ApplicationSet applied successfully."

# ── Summary ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} ArgoCD setup complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Verify:"
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
