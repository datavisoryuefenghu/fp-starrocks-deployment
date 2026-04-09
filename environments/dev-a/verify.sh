#!/usr/bin/env bash

# Post-deploy verification for CRE-6630 on dev-a (duckdb namespace).
# Runs Phase 1–3 checks and reports pass/fail for each.
#
# Usage:
#   export KUBECONFIG=/path/to/dev_a.config
#   bash environments/dev-a/verify.sh

NAMESPACE="${NAMESPACE:-duckdb}"
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

echo "=== CRE-6630 Verification: ${NAMESPACE} on dev-a ==="
echo ""

# ── Phase 1: Infrastructure ──────────────────────────────────────────
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

# ── Phase 2: Connector Status ────────────────────────────────────────
echo ""
echo "Phase 2: Connectors"

CONNECTORS=$(kn exec deploy/iceberg-kafka-connect -- curl -s http://localhost:8083/connectors 2>/dev/null || echo "[]")
if [[ "$CONNECTORS" == "[]" ]] || [[ -z "$CONNECTORS" ]]; then
  echo "  [INFO] No connectors registered — register one to test e2e data flow"
else
  CONNECTOR_NAME=$(echo "$CONNECTORS" | tr -d '[]" ' | cut -d',' -f1)
  STATUS=$(kn exec deploy/iceberg-kafka-connect -- curl -s "http://localhost:8083/connectors/${CONNECTOR_NAME}/status" 2>/dev/null || echo "{}")
  if echo "$STATUS" | grep -q '"state":"RUNNING"'; then
    ok "Connector ${CONNECTOR_NAME} RUNNING"
  else
    fail "Connector ${CONNECTOR_NAME} not running"
  fi
fi

# ── Phase 3: E2E Data ────────────────────────────────────────────────
echo ""
echo "Phase 3: End-to-End Data"

DBS=$(kn exec starrocks-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root --ssl-mode=DISABLED \
  -e "SHOW DATABASES FROM iceberg_catalog;" 2>/dev/null || echo "")

if echo "$DBS" | grep -q "qaautotest"; then
  ok "qaautotest namespace in iceberg_catalog"

  kn exec starrocks-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root --ssl-mode=DISABLED \
    -e "REFRESH EXTERNAL TABLE iceberg_catalog.qaautotest.event_result;" 2>/dev/null || true

  COUNT=$(kn exec starrocks-fe-0 -- mysql -h 127.0.0.1 -P 9030 -u root --ssl-mode=DISABLED \
    -N -e "SELECT COUNT(*) FROM iceberg_catalog.qaautotest.event_result;" 2>/dev/null || echo "0")

  if [[ "$COUNT" -gt 0 ]]; then
    ok "event_result has ${COUNT} rows"
  else
    echo "  [INFO] event_result empty — send test messages and wait for commit interval"
  fi
else
  echo "  [INFO] qaautotest not in iceberg_catalog — register a connector to create it"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
