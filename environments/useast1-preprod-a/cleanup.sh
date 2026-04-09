#!/usr/bin/env bash
set -euo pipefail

# Uninstall CRE-6630 Helm releases from preprod namespace on useast1-preprod-a.
#
# Usage:
#   export KUBECONFIG=/path/to/useast1_preprod_a.config
#   bash environments/useast1-preprod-a/cleanup.sh

NAMESPACE="${NAMESPACE:-preprod}"

echo "=== Cleanup CRE-6630 from ${NAMESPACE} on useast1-preprod-a ==="
echo ""
echo "This will uninstall:"
echo "  - fp-iceberg  (Iceberg REST Catalog + Kafka Connect)"
echo "  - fp-starrocks (StarRocks FE + CN)"
echo "  - iceberg-rest-jdbc secret"
echo "  - PVCs: fe-meta-starrocks-fe-0"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "--- Uninstalling Helm releases ---"
helm uninstall fp-starrocks -n "${NAMESPACE}" 2>/dev/null && echo "  fp-starrocks uninstalled" || echo "  fp-starrocks not found (skip)"
helm uninstall fp-iceberg -n "${NAMESPACE}" 2>/dev/null && echo "  fp-iceberg uninstalled" || echo "  fp-iceberg not found (skip)"

echo ""
echo "--- Deleting secrets ---"
kubectl -n "${NAMESPACE}" delete secret iceberg-rest-jdbc --ignore-not-found=true

echo ""
echo "--- Deleting PVCs ---"
kubectl -n "${NAMESPACE}" delete pvc fe-meta-starrocks-fe-0 --ignore-not-found=true

echo ""
echo "--- Verifying ---"
REMAINING=$(kubectl -n "${NAMESPACE}" get all 2>&1 | grep -E 'starrocks|iceberg' || true)
if [[ -z "$REMAINING" ]]; then
  echo "Clean — no starrocks/iceberg resources remain."
else
  echo "WARNING: Remaining resources:"
  echo "$REMAINING"
fi
