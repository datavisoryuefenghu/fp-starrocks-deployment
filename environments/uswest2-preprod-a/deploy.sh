#!/usr/bin/env bash
set -euo pipefail

# Deploy CRE-6630 Iceberg pipeline + StarRocks to uswest2-preprod-a (preprod namespace).
#
# The iceberg-rest-jdbc secret is auto-created by the chart from the
# existing fp-mysql secret. No manual secret creation needed.
#
# Usage:
#   export KUBECONFIG=/path/to/uswest2_preprod_a.config
#   bash environments/uswest2-preprod-a/deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
NAMESPACE="${NAMESPACE:-preprod}"
TIMEOUT="${TIMEOUT:-10m}"

echo "=== CRE-6630 Helm Deploy to ${NAMESPACE} on uswest2-preprod-a ==="

# --- Pre-checks ---
echo ""
echo "--- Pre-checks ---"

if ! kubectl -n "${NAMESPACE}" get secret fp-mysql &>/dev/null; then
  echo "ERROR: Secret fp-mysql not found in ${NAMESPACE}. Cannot auto-create iceberg-rest-jdbc."
  exit 1
fi
echo "  fp-mysql secret: OK"

SMT_URI=$(grep 'smtJarS3Uri' "${REPO_ROOT}/charts-iceberg/awsuswest2preproda/values.yaml" | awk -F'"' '{print $2}')
if [[ -z "$SMT_URI" ]]; then
  echo "ERROR: smtJarS3Uri is empty in charts-iceberg/awsuswest2preproda/values.yaml"
  exit 1
fi
echo "  SMT JAR URI: ${SMT_URI}"

# --- Deploy charts-iceberg ---
echo ""
echo "--- Installing fp-iceberg (Iceberg REST Catalog + Kafka Connect) ---"
helm upgrade --install fp-iceberg "${REPO_ROOT}/charts-iceberg" \
  -f "${REPO_ROOT}/charts-iceberg/awsuswest2preproda/values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout "${TIMEOUT}"

# --- Deploy charts-starrocks ---
echo ""
echo "--- Installing fp-starrocks (FE + CN) ---"
helm upgrade --install fp-starrocks "${REPO_ROOT}/charts-starrocks" \
  -f "${REPO_ROOT}/charts-starrocks/awsuswest2preproda/values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout "${TIMEOUT}"

# --- Summary ---
echo ""
echo "=== Deploy complete ==="
echo ""
echo "Helm releases:"
helm list -n "${NAMESPACE}" | grep -E 'fp-iceberg|fp-starrocks'
echo ""
echo "Pods:"
kubectl -n "${NAMESPACE}" get pods | grep -E 'starrocks|iceberg'
echo ""
echo "Next: bash environments/uswest2-preprod-a/verify.sh"
