#!/usr/bin/env bash

# Post-deploy verification for CRE-6630 on uswest2-preprod-a (preprod namespace).
#
# Usage:
#   export KUBECONFIG=/path/to/uswest2_preprod_a.config
#   bash environments/uswest2-preprod-a/verify.sh

NAMESPACE="${NAMESPACE:-preprod}"
PASS=0
FAIL=0

ok() {
  echo "  [PASS] $1"
  ((PASS++))
}

fail() {
  echo "  [FAIL] $1"
  ((FAIL++))
}

kn() { kubectl -n "${NAMESPACE}" "$@"; }

echo "=== CRE-6630 Verification: ${NAMESPACE} on uswest2-preprod-a ==="
echo ""

echo "Phase 1: Pod Status"

for LABEL in iceberg-rest-catalog iceberg-kafka-connect starrocks-fe starrocks-cn; do
  LINE=$(kn get pods -l "app.kubernetes.io/name=${LABEL}" --no-headers 2>/dev/null | head -1)
  if echo "$LINE" | grep -q '1/1.*Running'; then
    ok "${LABEL} Running 1/1"
  else
    fail "${LABEL} — ${LINE:-not found}"
  fi
done

echo ""
echo "Phase 1: StarRocks FE"

OUT=$(kn exec starrocks-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root --ssl-mode=DISABLED -e "SHOW CATALOGS;" 2>/dev/null || echo "")
if echo "$OUT" | grep -q "iceberg_catalog"; then
  ok "iceberg_catalog exists"
else
  fail "iceberg_catalog not found"
fi

OUT=$(kn exec starrocks-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root --ssl-mode=DISABLED -e "SHOW COMPUTE NODES\G" 2>/dev/null || echo "")
if echo "$OUT" | grep -q "Alive: true"; then
  ok "CN node Alive=true"
else
  fail "CN node not alive"
fi

echo ""
echo "Phase 1: Services"

OUT=$(kn exec deploy/iceberg-kafka-connect -- curl -s http://localhost:8083/connectors 2>/dev/null || echo "")
if echo "$OUT" | grep -q '\['; then
  ok "Kafka Connect REST API healthy"
else
  fail "Kafka Connect REST API unreachable"
fi

OUT=$(kn exec deploy/iceberg-kafka-connect -- curl -s http://iceberg-rest-catalog:8181/v1/config 2>/dev/null || echo "")
if echo "$OUT" | grep -q "overrides"; then
  ok "Iceberg REST Catalog healthy"
else
  fail "Iceberg REST Catalog unreachable"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
