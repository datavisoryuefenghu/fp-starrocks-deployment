#!/usr/bin/env bash
set -euo pipefail

# Clean up CRE-6630 resources in qa-security namespace on dev-a.
# Removes both Helm releases AND any manual YAML resources.
#
# Usage:
#   export KUBECONFIG=/path/to/dev_a.config
#   bash environments/dev-a-qasecurity/cleanup.sh

NAMESPACE="${NAMESPACE:-qa-security}"

echo "=== CRE-6630 Cleanup: ${NAMESPACE} on dev-a ==="

# --- Step 1: Remove Helm releases (if any) ---
echo ""
echo "--- Removing Helm releases ---"
helm uninstall fp-iceberg  -n "${NAMESPACE}" 2>/dev/null && echo "  fp-iceberg uninstalled" || echo "  fp-iceberg: not found (skip)"
helm uninstall fp-starrocks -n "${NAMESPACE}" 2>/dev/null && echo "  fp-starrocks uninstalled" || echo "  fp-starrocks: not found (skip)"

# --- Step 2: Remove manual YAML resources (leftover from manual deployment) ---
echo ""
echo "--- Removing manual resources (if any) ---"

# StatefulSets
kubectl -n "${NAMESPACE}" delete statefulset starrocks-fe 2>/dev/null && echo "  deleted sts/starrocks-fe" || true

# Deployments
for DEPLOY in starrocks-cn iceberg-kafka-connect iceberg-rest-catalog; do
  kubectl -n "${NAMESPACE}" delete deploy "${DEPLOY}" 2>/dev/null && echo "  deleted deploy/${DEPLOY}" || true
done

# Services
for SVC in starrocks-fe starrocks-cn iceberg-kafka-connect iceberg-rest-catalog; do
  kubectl -n "${NAMESPACE}" delete svc "${SVC}" 2>/dev/null && echo "  deleted svc/${SVC}" || true
done

# ServiceAccounts
for SA in iceberg-kafka-connect; do
  kubectl -n "${NAMESPACE}" delete sa "${SA}" 2>/dev/null && echo "  deleted sa/${SA}" || true
done

# ConfigMaps
for CM in kafka-connect-jmx-config starrocks-fe-config starrocks-cn-config; do
  kubectl -n "${NAMESPACE}" delete configmap "${CM}" 2>/dev/null && echo "  deleted cm/${CM}" || true
done

# Secrets (only iceberg-specific, NOT fp-mysql)
kubectl -n "${NAMESPACE}" delete secret iceberg-rest-jdbc 2>/dev/null && echo "  deleted secret/iceberg-rest-jdbc" || true

# PVCs
kubectl -n "${NAMESPACE}" delete pvc -l app.kubernetes.io/name=starrocks-fe 2>/dev/null && echo "  deleted FE PVCs" || true
kubectl -n "${NAMESPACE}" delete pvc fe-meta-starrocks-fe-0 2>/dev/null && echo "  deleted pvc/fe-meta-starrocks-fe-0" || true

# Jobs (Helm hooks)
for JOB in iceberg-catalog-init starrocks-init; do
  kubectl -n "${NAMESPACE}" delete job "${JOB}" 2>/dev/null && echo "  deleted job/${JOB}" || true
done

# --- Step 3: Verify clean ---
echo ""
echo "--- Remaining resources ---"
kubectl -n "${NAMESPACE}" get all 2>/dev/null | grep -E 'starrocks|iceberg' || echo "  (none — clean)"
echo ""
echo "=== Cleanup complete ==="
