#!/usr/bin/env bash
set -euo pipefail

# Create the iceberg-rest-jdbc secret in the preprod namespace on useast1-preprod-a.
#
# Usage:
#   export KUBECONFIG=/path/to/useast1_preprod_a.config
#   bash environments/useast1-preprod-a/create-secrets.sh

NAMESPACE="${NAMESPACE:-preprod}"

echo "=== Create iceberg-rest-jdbc secret in ${NAMESPACE} ==="

if kubectl -n "${NAMESPACE}" get secret iceberg-rest-jdbc &>/dev/null; then
  echo "Secret iceberg-rest-jdbc already exists. Delete it first if you want to recreate:"
  echo "  kubectl -n ${NAMESPACE} delete secret iceberg-rest-jdbc"
  exit 0
fi

echo "Reading fp-mysql root password from secret..."
MYSQL_ROOT_PW=$(kubectl -n "${NAMESPACE}" get secret fp-mysql \
  -o jsonpath='{.data.mysql-root-password}' | base64 -d)

if [[ -z "$MYSQL_ROOT_PW" ]]; then
  echo "ERROR: Could not read mysql-root-password from fp-mysql secret."
  exit 1
fi

kubectl -n "${NAMESPACE}" create secret generic iceberg-rest-jdbc \
  --from-literal=jdbc-user=root \
  --from-literal=jdbc-password="${MYSQL_ROOT_PW}"

echo "Secret iceberg-rest-jdbc created successfully."
