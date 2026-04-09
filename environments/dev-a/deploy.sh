#!/usr/bin/env bash
set -euo pipefail

# Deploy CRE-6630 Iceberg pipeline + StarRocks to dev-a (duckdb namespace).
#
# The iceberg-rest-jdbc secret is auto-created by the chart from the
# existing fp-mysql secret. No manual secret creation needed.
#
# Usage:
#   export KUBECONFIG=/path/to/dev_a.config
#   bash environments/dev-a/deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
NAMESPACE="${NAMESPACE:-duckdb}"
TIMEOUT="${TIMEOUT:-10m}"

echo "=== CRE-6630 Helm Deploy to ${NAMESPACE} on dev-a ==="

# --- Pre-checks ---
echo ""
echo "--- Pre-checks ---"

# Verify fp-mysql secret exists (source for auto-created iceberg-rest-jdbc)
if ! kubectl -n "${NAMESPACE}" get secret fp-mysql &>/dev/null; then
  echo "ERROR: Secret fp-mysql not found in ${NAMESPACE}. Cannot auto-create iceberg-rest-jdbc."
  exit 1
fi
echo "  fp-mysql secret: OK"

# Verify SMT JAR S3 URI is set
SMT_URI=$(grep 'smtJarS3Uri' "${REPO_ROOT}/charts-iceberg/awsuswest2deva/values.yaml" | awk -F'"' '{print $2}')
if [[ -z "$SMT_URI" ]]; then
  echo "ERROR: smtJarS3Uri is empty in charts-iceberg/awsuswest2deva/values.yaml"
  exit 1
fi
echo "  SMT JAR URI: ${SMT_URI}"

# --- Deploy charts-iceberg ---
echo ""
echo "--- Installing fp-iceberg (Iceberg REST Catalog + Kafka Connect) ---"
helm upgrade --install fp-iceberg "${REPO_ROOT}/charts-iceberg" \
  -f "${REPO_ROOT}/charts-iceberg/awsuswest2deva/values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout "${TIMEOUT}"

# --- Deploy charts-starrocks ---
echo ""
echo "--- Installing fp-starrocks (FE + CN) ---"
helm upgrade --install fp-starrocks "${REPO_ROOT}/charts-starrocks" \
  -f "${REPO_ROOT}/charts-starrocks/awsuswest2deva/values.yaml" \
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
echo "Next: bash environments/dev-a/verify.sh"
