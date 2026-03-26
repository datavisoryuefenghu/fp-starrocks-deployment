#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config}"
KUBECTL=(kubectl --kubeconfig="$KUBECONFIG_PATH")
NAMESPACE="qa-security"

required_files=(
  "$SCRIPT_DIR/secrets.yaml"
  "$SCRIPT_DIR/05-iceberg-catalog-mysql-secret.yaml"
  "$SCRIPT_DIR/10-iceberg-rest-catalog-secret.yaml"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
done

echo "Using kubeconfig: $KUBECONFIG_PATH"
echo "Deploying into namespace: $NAMESPACE"

"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/00-namespace.yaml"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/secrets.yaml"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/05-iceberg-catalog-mysql-secret.yaml"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/06-iceberg-catalog-mysql.yaml"
"${KUBECTL[@]}" rollout status statefulset/iceberg-catalog-mysql -n "$NAMESPACE" --timeout=5m

"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/10-iceberg-rest-catalog-secret.yaml"
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/11-iceberg-rest-catalog.yaml"
"${KUBECTL[@]}" rollout status deployment/iceberg-rest-catalog -n "$NAMESPACE" --timeout=5m

"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/20-iceberg-kafka-connect.yaml"
"${KUBECTL[@]}" rollout status deployment/iceberg-kafka-connect -n "$NAMESPACE" --timeout=10m
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/21-iceberg-kafka-connect-register-job.yaml"
"${KUBECTL[@]}" wait -n "$NAMESPACE" --for=condition=complete job/iceberg-kafka-connect-register --timeout=10m

"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/30-starrocks.yaml"
"${KUBECTL[@]}" rollout status deployment/cre-6630-starrocks -n "$NAMESPACE" --timeout=10m
"${KUBECTL[@]}" apply -f "$SCRIPT_DIR/31-starrocks-ops.yaml"
"${KUBECTL[@]}" wait -n "$NAMESPACE" --for=condition=complete job/cre-6630-starrocks-init-sql --timeout=15m

echo
echo "Deployment complete. Useful checks:"
echo "  kubectl --kubeconfig=$KUBECONFIG_PATH get pods -n $NAMESPACE"
echo "  kubectl --kubeconfig=$KUBECONFIG_PATH get svc -n $NAMESPACE | egrep 'iceberg|starrocks'"
echo "  kubectl --kubeconfig=$KUBECONFIG_PATH logs job/iceberg-kafka-connect-register -n $NAMESPACE"
echo "  kubectl --kubeconfig=$KUBECONFIG_PATH logs job/cre-6630-starrocks-init-sql -n $NAMESPACE"
