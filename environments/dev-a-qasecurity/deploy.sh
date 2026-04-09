#!/usr/bin/env bash
set -euo pipefail

# Deploy CRE-6630 Iceberg pipeline + StarRocks to dev-a (qa-security namespace).
#
# This namespace has only 1 Kafka broker, so replicationFactor is set to 1.
#
# Usage:
#   export KUBECONFIG=/path/to/dev_a.config
#   bash environments/dev-a-qasecurity/deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
NAMESPACE="${NAMESPACE:-qa-security}"
TIMEOUT="${TIMEOUT:-10m}"

echo "=== CRE-6630 Helm Deploy to ${NAMESPACE} on dev-a ==="

# --- Pre-checks ---
echo ""
echo "--- Pre-checks ---"

if ! kubectl -n "${NAMESPACE}" get secret fp-mysql &>/dev/null; then
  echo "ERROR: Secret fp-mysql not found in ${NAMESPACE}. Cannot auto-create iceberg-rest-jdbc."
  exit 1
fi
echo "  fp-mysql secret: OK"

SMT_URI=$(grep 'smtJarS3Uri' "${REPO_ROOT}/charts-iceberg/awsuswest2deva-qasecurity/values.yaml" | awk -F'"' '{print $2}')
if [[ -z "$SMT_URI" ]]; then
  echo "ERROR: smtJarS3Uri is empty in charts-iceberg/awsuswest2deva-qasecurity/values.yaml"
  exit 1
fi
echo "  SMT JAR URI: ${SMT_URI}"

# --- Deploy charts-iceberg ---
echo ""
echo "--- Installing fp-iceberg (Iceberg REST Catalog + Kafka Connect) ---"
echo "NOTE: replicationFactor=1 (qa-security has 1 Kafka broker)"
helm upgrade --install fp-iceberg "${REPO_ROOT}/charts-iceberg" \
  -f "${REPO_ROOT}/charts-iceberg/awsuswest2deva-qasecurity/values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout "${TIMEOUT}"

# --- Deploy charts-starrocks ---
echo ""
echo "--- Installing fp-starrocks (FE + CN) ---"
helm upgrade --install fp-starrocks "${REPO_ROOT}/charts-starrocks" \
  -f "${REPO_ROOT}/charts-starrocks/awsuswest2deva-qasecurity/values.yaml" \
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
echo "Next: run verify.sh or check T2 health commands"
