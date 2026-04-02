# CRE-6630 Feature Stats — Presentation

> Goal: Give the team a complete walkthrough of this project's background, responsibilities, deployment components, data flow, validation approach, and next steps.

---

## 1. What is the Requirement (Problem Statement)

### 1.1 Business Background

Customers (e.g. SoFi) need to run **multi-dimensional, multi-time-window aggregation statistics** over historical event data — i.e., OLAP analytics capability:

- Group by custom **dimensions** (e.g. by country, by IP range)
- Aggregate a **feature column** (e.g. `txn_amount`, `age`)
- Return count / sum / mean / p95 / distinct_count over time windows such as **30d / 90d / 180d**

### 1.2 Why the Existing ClickHouse is Insufficient

| Capability | ClickHouse (existing) | StarRocks + Iceberg (new) |
|------|--------------------|--------------------------|
| Store raw event detail | ✅ | ✅ |
| Query with fixed schema | ✅ | ✅ |
| Custom CASE WHEN dimension expressions | ❌ Hard to define dynamically | ✅ Generate MV via Cube config |
| Large-window aggregation (30d/90d/180d) | ❌ Full table scan, slow | ✅ MV pre-aggregation, millisecond-level |
| Columnar Parquet + S3 storage cost | ❌ Self-hosted storage | ✅ Iceberg on S3, pay-as-you-go |
| Elastic scaling | ❌ Static deployment | ✅ CN is stateless, can scale horizontally on demand |

**In a nutshell**: ClickHouse is well-suited for fixed-schema event queries, but cannot support the scenario of "user-defined dimensions + large time-window pre-aggregation."

### 1.3 How Users Interact with the System

Users define "what statistical perspectives they want to see" through configuration abstractions, and the system handles the underlying data automatically:

**Step 1 — Create a Dimension (grouping axis)**
```json
POST /sofi/dimension
{
  "name": "By Country",
  "type": "expression",
  "expr": "CASE WHEN country='CN' THEN 'China' WHEN country='US' THEN 'United States' ELSE 'Other' END"
}
```

**Step 2 — Create a Cube (select dimensions + measures + target feature columns)**
```json
POST /sofi/cube
{
  "name": "Country Stats",
  "dimension_id": 1,
  "target_features": ["txn_amount", "age"],
  "measures": ["count", "sum", "mean", "p95", "distinct_count"]
}
```

**Step 3 — Query (return aggregated results by window)**
```
GET /sofi/stats?cube=Country%20Stats&window=30d

Returns:
  segment_value=China:        count=8000, sum=2400000, mean=300, p95=1200
  segment_value=United States: count=5000, sum=1500000, mean=300, p95=950
  segment_value=Other:         count=1000, sum=300000,  mean=300, p95=800
```

---

## 2. Responsibilities (Who Does What)

| Role | Responsible For | Status |
|------|---------|------|
| **You (Infra)** | Deploy 5 infrastructure components: Iceberg + Kafka Connect + StarRocks FE+CN. Validate that data can be written to S3 and queried from StarRocks | ✅ Validated on dev_a |
| **fp-async team (Dev)** | Cube/Dimension CRUD API; generate MV DDL from Cube config and submit to StarRocks; implement Stats query API (connecting to StarRocks via JDBC) | ❌ Pending development |

**Why you are doing this**: To prove that the infrastructure pipeline is end-to-end viable. Data flows in from Kafka, gets transformed by SMT, lands in S3 in Iceberg format, and can be queried from StarRocks — this is a necessary prerequisite for Dev to write code, not the final destination.

---

## 3. What Was Deployed (5 Components)

| # | Component | K8s Type | Service | Image |
|---|------|---------|---------|------|
| 1 | Iceberg Catalog MySQL | StatefulSet (1) + PVC | `iceberg-catalog-mysql:3306` | `mysql:8.0` |
| 2 | Iceberg REST Catalog | Deployment (1) | `iceberg-rest-catalog:8181` | `tabulario/iceberg-rest:1.6.0` |
| 3 | Kafka Connect + SMT | Deployment (1) | `iceberg-kafka-connect:8083` | `confluentinc/cp-kafka-connect-base:7.7.1` (with custom SMT jar) |
| 4 | StarRocks FE | StatefulSet (1) + PVC | `starrocks-fe:9030` | `starrocks/fe-ubuntu:3.3-latest (v3.3.22)` |
| 5 | StarRocks CN | Deployment (1) | `starrocks-cn:9050` | `starrocks/cn-ubuntu:3.3-latest (v3.3.22)` |

**External dependencies (already in place, not modified)**:

| Dependency | Address | Purpose |
|------|------|------|
| Kafka | `kafka3.duckdb:9092` (3 brokers) | Kafka Connect consumes the `velocity-al` topic |
| FP MySQL | `fp-mysql.duckdb:3306` | SMT queries the feature table for ID→name mapping (`dv.ro` read-only) |
| S3 Bucket | `datavisor-dev-us-west-2-iceberg` | Kafka Connect writes Parquet; StarRocks reads Parquet |
| fp-async | `fp-async.duckdb:8080` | Produces velocity-al messages; our data source |

---

## 4. How These Components Work Together

### 4.1 Overall Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      已有链路（不变）                            │
│                                                                 │
│  客户请求 → FP API → Kafka: velocity → fp-async Consumer        │
│                                  ├──→ YugabyteDB（实时聚合）    │
│                                  └──→ Kafka: velocity-al ───┐  │
└──────────────────────────────────────────────────────────────┼──┘
                                                               │
                    ┌──────────────────────────────────────────┘
                    │  velocity-al topic（我们接管的起点）
                    ↓
         ┌─────────────────────┐      ┌─────────────────────────┐
         │ ConsumerForCH（已有）│      │ Kafka Connect（新增）    │
         │ 写 ClickHouse        │      │ + SMT 转换               │
         └─────────────────────┘      └──────────┬──────────────┘
                                                  │ 写 Parquet（每10min一批）
                                                  ↓
                                    ┌─────────────────────────────┐
                                    │ S3: Parquet（Iceberg 格式）  │
                                    │ .../qaautotest/event_result/ │
                                    └──────────┬──────────────────┘
                                               │ commit snapshot
                                               ↓
                                    ┌─────────────────────────────┐
                                    │ Iceberg REST Catalog (:8181) │
                                    │ → Iceberg Catalog MySQL      │
                                    └──────────┬──────────────────┘
                                               │ External Catalog
                                               ↓
                              ┌────────────────────────────────────┐
                              │ StarRocks FE (:9030)               │
                              │  - 查询规划 / CBO 改写              │
                              │  - MV 刷新调度                     │
                              └──────────┬─────────────────────────┘
                                         │
                                         ↓
                              ┌────────────────────────────┐
                              │ StarRocks CN（单节点，Spot）│
                              │ 白天: 在线查询（读 MV）     │
                              │ 凌晨: MV refresh（扫 S3）   │
                              └────────────┬───────────────┘
                                           ↑
                                    fp-async Stats API
                                    (JDBC 9030)
```

### 4.2 Detailed Data Flow (What Happens at Each Hop)

**Hop 1: FP → Kafka velocity-al**

After the fp-async Consumer processes an event, it serializes each EventResult to JSON and writes it to the `velocity-al` topic:

```json
{
  "eventId": "abc-123",
  "eventType": "transaction",
  "userId": "user_42",
  "eventTime": 1774597200000,
  "processingTime": 1774597201000,
  "featureMap": {
    "8":  299.99,
    "7":  "US",
    "15": "merchant_xyz"
  }
}
```

> **Why does featureMap use integer IDs?** To reduce Kafka message size. A single event has approximately 700 features; if every key were a string name, messages would be 10x larger. Integer IDs are the internal compact format.

**Hop 2: Kafka Connect + SMT Transformation**

The SMT (`FeatureResolverTransform`) converts integer IDs in featureMap into named, typed columns:

```
Input (Kafka message):  featureMap: {"8": 299.99, "7": "US"}
                                    ↓ SMT queries FP MySQL cache (refreshed every 60s)
Output (Parquet row):  amount=299.99 (DOUBLE), country="US" (STRING), ...
```

The schema is **dynamic**: when new features are added, the SMT automatically refreshes its cache, and Iceberg supports schema evolution (columns are added automatically). Each tenant has approximately 700 feature columns.

**Hop 3: Kafka Connect → S3 (Iceberg format)**

An Iceberg commit is performed every 10 minutes, writing Parquet data files to S3 and updating Iceberg metadata (snapshot + manifest).

**Hop 4: Iceberg Catalog → StarRocks**

StarRocks FE discovers new partitions via the Iceberg External Catalog:

```sql
-- Only needs to be configured once on the StarRocks side
CREATE EXTERNAL CATALOG iceberg_catalog
PROPERTIES (
  "type" = "iceberg",
  "iceberg.catalog.type" = "rest",
  "iceberg.catalog.uri" = "http://iceberg-rest-catalog:8181"
);

-- Then query directly
SELECT COUNT(*) FROM iceberg_catalog.qaautotest.event_result;
```

**Hop 5 (nightly batch): CN refreshes MV**

```
Same CN node (no query traffic at night, exclusive use of all resources)
Scans S3 new partitions (~10 million rows/day/tenant)
→ GROUP BY (dimension × measure)
→ Writes MV daily partition (only a few hundred rows/day, a few KB)
```

> **Note**: No separate CN Refresh node is needed. ToB systems have no user queries at night; a single CN handles both querying and refresh, naturally serialized with no resource contention (see design-qa D5).

**Hop 6 (online query): fp-async → FE → CN → result**

```
fp-async: SELECT country, sum(amount) FROM raw_events WHERE event_time > now()-30d
      ↓ FE CBO transparent rewrite
SELECT country, sum(amount) FROM mv_country_txn_amount
  WHERE stat_date BETWEEN today-30 AND today
      ↓ CN merges 30 daily partitions
      ↓ Returns in milliseconds
```

---

## 5. What Are Materialized Views (MV)

### 5.1 The Essence of MV

MV = **pre-computation + stored results**. The aggregation results for each day are computed ahead of time and stored; at query time, only N days' worth of pre-aggregated rows need to be merged, rather than scanning hundreds of millions of raw rows.

```
Raw raw_events (~10 million rows/day)
         ↓ GROUP BY at night
MV daily partition (a few hundred rows/day, a few KB)

Query 30d:  merge 30 partitions × a few hundred rows = completes in seconds
Query 180d: merge 180 partitions × a few hundred rows = still very fast
```

### 5.2 MV Refresh Cadence (analogous to Cron)

Think of a Cube as "configuring and enabling a daily refresh scheduled task":
- Create Cube → backend generates `CREATE MATERIALIZED VIEW ... REFRESH ASYNC EVERY (INTERVAL 1 DAY)`
- The same CN node triggers an incremental refresh every night (only computes newly added partitions from the previous day)
- Not real-time; write latency is approximately 10 min (Kafka Connect commit interval) + nightly MV refresh

### 5.3 The Cold Start Problem (First Query is Slow)

| State | Query Path | Speed |
|------|---------|------|
| MV not yet refreshed (just created Cube) | FE falls back to scanning raw_events Parquet | Slow (seconds to minutes) |
| MV has data for some days | FE CBO rewrite, merges available daily partitions | Fast, but returns `coverage<100%` |
| MV is complete | FE CBO rewrite, merges all daily partitions | Millisecond-level |

**The latency gap during fallback is an order of magnitude**: MV queries take tens of milliseconds vs. raw Parquet scans taking minutes to tens of minutes. The most common trigger is **when a new tenant onboards before its historical MV is ready**.

**Mitigation strategy**: Trigger historical MV backfill immediately at onboarding time. Show "data processing" on the frontend until MV is ready, then open up queries. Scaling is not the solution for fallback — ensuring the MV is always ready is (see Appendix D13).

---

## 6. The Target End State

### Phase 1: Infrastructure Validation (Completed ✅)

```
Data written to S3 + queryable from StarRocks

Validation command:
SELECT COUNT(*) FROM iceberg_catalog.qaautotest.event_result;
→ Returns 35 rows ✅
```

### Phase 2: Full OLAP Capability (Upcoming)

```
fp-async creates MV:
  POST /sofi/cube → fp-async generates DDL → CREATE MATERIALIZED VIEW → StarRocks FE

fp-async Stats API query:
  GET /sofi/stats?cube=Country Stats&window=30d
  → fp-async (JDBC) → StarRocks FE (CBO rewrite) → CN (reads MV)
  → Returns in milliseconds:
     China:         count=8000, sum=2400000, p95=1200
     United States: count=5000, sum=1500000, p95=950
```

### Full End-to-End Flow Diagram

```
[Write path — real-time, ~10min latency]
FP processes event → fp-async → velocity-al → Kafka Connect → S3 Parquet

[Refresh path — nightly batch]
CN scans S3 yesterday's partitions → GROUP BY → writes MV daily partition (a few hundred rows/day)

[Query path — millisecond-level]
Customer calls Stats API → fp-async → FE (CBO rewrite) → CN merges N daily partitions → returns result

[Fallback path — when MV is not ready]
FE automatically falls back → CN scans raw Parquet (slow but most up-to-date data)
```

---

## 7. Validation Approach (Layer-by-Layer Check)

Validation logic: from data ingress to query egress, each hop can be validated independently.

### ① Kafka has data
```bash
kubectl -n duckdb exec kafka3-0 -- bash -c "
  echo '=== earliest ===' && \
  kafka-get-offsets.sh --bootstrap-server localhost:9092 \
    --topic duckdb_fp_velocity-al-.qaautotest --time -2 && \
  echo '=== latest ===' && \
  kafka-get-offsets.sh --bootstrap-server localhost:9092 \
    --topic duckdb_fp_velocity-al-.qaautotest
"
# Expected: latest - earliest > 0
```

### ② Connector is running
```bash
kubectl -n duckdb exec <connect-pod> -- \
  curl -s http://localhost:8083/connectors/iceberg-sink-qaautotest/status
# Expected: connector.state=RUNNING, tasks[*].state=RUNNING
```

### ③ Consumer has caught up (LAG=0)
```bash
# Note: the consumer group name is not the CONNECT_GROUP_ID you configured
# but rather in the format connect-<connector-name>
kubectl -n duckdb exec kafka3-0 -- bash -c \
  "kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
   --describe --group connect-iceberg-sink-qaautotest"
# Expected: LAG=0
```

### ④ S3 has Parquet files
```bash
aws s3 ls s3://datavisor-dev-us-west-2-iceberg/cre-6630/duckdb/qaautotest/ --recursive
# Expected: .../event_result/data/00000-xxx.parquet files
```

### ⑤ StarRocks can query the data
```bash
kubectl -n duckdb exec starrocks-fe-0 -- \
  mysql -h 127.0.0.1 -P 9030 -u root -e "
    SHOW CATALOGS;
    SHOW COMPUTE NODES\G
    SELECT COUNT(*) FROM iceberg_catalog.qaautotest.event_result;
    SELECT event_id, event_type, user_id, event_time
      FROM iceberg_catalog.qaautotest.event_result LIMIT 5;
  "
```

### Actual Validation Results

```
Manual deployment (2026-03-27):
  06:27  Deployed all components
  06:43  StarRocks init complete (CN registered + Iceberg catalog created)
  06:44  Wrote 30 test messages
  06:50  Commit: 30 records → qaautotest.event_result ✅
  06:50  SELECT COUNT(*) = 30 ✅

Helm deployment (same day):
  06:58  helm install
  07:01  All pods Running
  07:01  Wrote 35 test messages
  07:05  Commit: 35 records → qaautotest.event_result ✅
  07:05  SELECT COUNT(*) = 35 ✅
```

Actual query results (Helm deployment):
```
mysql> SELECT COUNT(*) FROM iceberg_catalog.qaautotest.event_result;
+------------+
| total_rows |
+------------+
|         35 |
+------------+

mysql> SELECT event_id, event_type, user_id FROM iceberg_catalog.qaautotest.event_result LIMIT 5;
+-------------+------------+-------------+
| event_id    | event_type | user_id     |
+-------------+------------+-------------+
| helm-test-1 | payment    | helm_user_1 |
| helm-test-2 | payment    | helm_user_2 |
| helm-test-3 | payment    | helm_user_3 |
| helm-test-4 | payment    | helm_user_4 |
| helm-test-5 | payment    | helm_user_5 |
+-------------+------------+-------------+
```

> **Note**: The test data has an empty `featureMap: {}`, so all ~700 feature columns are NULL.
> Real fp-async data (e.g. from the yysecurity tenant in the QA environment) will have complete feature values (country="US", amount=299.99, etc.).

---

## 8. Environment Setup (dev_a, duckdb namespace)

```
Cluster:   dev_a (us-west-2)
Namespace: duckdb
Test tenant: qaautotest
S3 path:   s3://datavisor-dev-us-west-2-iceberg/cre-6630/duckdb/
```

**S3 data paths (validated)**:
```
cre-6630/duckdb/qaautotest/event_result/
  data/     ← Parquet data files (one batch per commit, ~188KB)
  metadata/ ← Iceberg metadata (schema, snapshot, manifest)
```
> For Iceberg metadata layer details, see Appendix QA C4/C5.

**Deployment order** (strict ordering required due to dependencies):
```
00-secrets.yaml           → Secrets (MySQL password, SMT password)
10-iceberg-catalog-mysql  → Wait for StatefulSet Ready
11-iceberg-rest-catalog   → Wait for Deployment Ready (depends on MySQL above)
19-smt-source.yaml        → ConfigMap (SMT jar + pom.xml)
20-kafka-connect          → Wait for Deployment Ready
21-kafka-connect-register → Job: register connector
30-starrocks-fe           → Wait for StatefulSet Ready
31-starrocks-cn           → Wait for Deployment Ready
32-starrocks-init         → Job: register CN + create Iceberg catalog
```

---

## 9. Pitfalls Encountered

For issues encountered during deployment and their resolutions, see [Appendix — Pitfalls Log](#pitfalls-log).

---

## 10. Next Steps TODO (Who / Priority)

### 10.1 fp-async Team (Dev)

| Task | Description | Priority |
|------|------|--------|
| fp-async connects to StarRocks via JDBC | Stats API queries StarRocks via JDBC 9030 | P0 |
| fp-async generates MV DDL | Generate `CREATE MATERIALIZED VIEW` from Cube config and submit to FE | P0 |
| Dimension / Cube CRUD API | `/sofi/dimension`, `/sofi/cube` endpoints | P0 |

### 10.2 Infra

| Task | Description | Priority |
|------|------|--------|
| CN node Spot migration | Create Spot ASG + Launch Template (m5.2xlarge), run CN on Spot to save ~74% cost | P0 |
| CN node spec upgrade | Current 1C/4Gi is dev spec; production requires 8C/32Gi (see design-qa D3) | P0 |
| Kafka Connect commit interval adjustment | Change from 60s to 10min to reduce small files (see design-qa D14) | P0 |
| Kafka Connect templatization | Current connector config is hand-written per-tenant; needs parameterization to support new tenant onboarding | P1 |
| ~~Warehouse split / CN Query Pool HPA / CN Refresh CronJob~~ | ~~Evaluated; not needed at this stage. ToB has no queries at night; 1 CN is sufficient (see design-qa D4/D5)~~ | On demand |

### 10.3 Variables to Confirm Manually

| Variable | Description | Status |
|------|------|------|
| `kafka_bootstrap_servers` | FP's Kafka address | Check existing FP K8s Service |
| `iceberg_catalog_mysql` | Iceberg Catalog MySQL | **Decided: standalone instance** (Appendix D17) |
| `iceberg_smt_mysql_url` | MySQL for SMT feature table queries | FP's risk database, dv.ro read-only |
| S3 IAM permissions | Node needs S3 read/write permissions | Use Node Instance Profile, not IRSA |

> For IAM configuration details, see [Appendix — Deployment Variables & IAM](#deployment-variables--iam).

---

## 11. Data Latency SLA (Needs to Be Communicated Externally)

| Path | Latency | Description |
|------|------|------|
| Event occurs → S3 Parquet | ~10min | Kafka Connect commit interval (adjusted from 60s to 10min) |
| S3 Parquet → MV queryable | ~after nightly run | CN batch-processes nightly (same CN, no query contention) |
| Stats API query latency | Millisecond-level | When MV is ready; first query (cold start) may be second-level |
| New feature column appears | ~60s | SMT refreshes feature cache every 60s; Iceberg schema auto-evolves |

---

## 12. Multi-Tenant Isolation

Each tenant has its own independent Iceberg namespace with the same table name `event_result`:

```
iceberg_catalog.qaautotest.event_result   ← qaautotest's data
iceberg_catalog.yysecurity.event_result   ← yysecurity's data
```

- S3 paths are physically isolated: `s3://.../qaautotest/event_result/` vs `s3://.../yysecurity/event_result/`
- Schema evolves independently: different tenants' feature column sets do not affect each other
- One Kafka Connect connector per tenant

Reasons for not using a shared table with `WHERE tenant` filtering: MV DDL is cleaner, S3 paths are naturally isolated, and debugging is straightforward (see Appendix D9).

---

## 13. Cost & Scaling Design Decisions

### 13.1 Current Stage: 1 CN, No Elastic Scaling

**If scaling were needed, the only candidate is CN** (all other components do not need it). But at the current stage, 1 CN is sufficient, because:

- **Online queries hit MV (pre-aggregated data)** — each query reads only a few hundred rows and completes in tens of milliseconds. A single CN (8 CPU) can handle dozens of concurrent MV queries without exceeding 60% CPU.
- **Nightly MV refresh** is batch processing; ToB systems have no users at night, so speed is not a concern. 1 CN runs for 2-3 hours and finishes before dawn.
- The two workloads are **naturally serialized** (refresh at night, queries during the day) — no resource contention.

| Component | Needs Scaling? | Reason |
|------|--------------|------|
| Iceberg MySQL / REST Catalog | No | Metadata path; write frequency is fixed |
| Kafka Connect | No | Throughput via internal task parallelism, not pod count |
| StarRocks FE | No | Only does query planning; CPU usage is minimal |
| **StarRocks CN** | **Possibly in the future** | The only compute layer — but current MV queries are extremely light; 1 CN is sufficient |

### 13.2 CN Deployment Options

| | Option A | Option B ★ | Option C |
|--|--|--|--|
| Architecture | 1× on-demand | 1× spot | 2× spot (HA) |
| Monthly cost | ~$276 | ~$72 | ~$144 (or ~$100 with smaller spec) |
| Interruption impact | None | Occasional 2-3min | Rare (probability of both being reclaimed simultaneously is very low) |

**Why can a persistent service run on Spot?** CN is stateless — data lives in S3, and local storage is only block cache (which can be rebuilt from S3 if lost). When a Spot instance is reclaimed: in-flight queries fail (fp-async can retry), zero data loss, and a new CN recovers within 2-3 minutes. "Always running" does not mean "cannot be interrupted" — what matters is that the cost of interruption is low.

**Choose Option B**: ToB system; fp-async can retry; occasional 2-3min interruptions are acceptable; saves 74%. Enable Capacity Rebalancing on the ASG (AWS proactively starts a new node when it detects reclamation risk, then terminates the old node) to further reduce the interruption gap.

**If HA is required → Option C variant: 2× smaller spot instances**

With 2 CNs, each node does not need to bear the full compute load, so a smaller spec can be used:

| | Option B (1× large) | Option C variant (2× small) |
|--|--|--|
| Spec | m5.2xlarge (8C/32Gi) | m5.xlarge (4C/16Gi) × 2 |
| Total compute | 8 CPU / 32Gi | 8 CPU / 32Gi (same) |
| Spot unit price | ~$0.10/h | ~$0.05/h × 2 |
| Monthly cost | ~$72 | ~$72 (roughly the same) |
| HA | None; 2-3min interruption | If 1 is reclaimed, the other continues serving |
| Nightly MV refresh | 8 CPU exclusive, fast | StarRocks FE distributes to 2 CNs in parallel; comparable speed |
| Block cache | 16Gi centralized | 8Gi × 2 distributed; slightly lower cache hit rate |

Option C variant trade-off: **nearly the same cost, gains HA, but smaller per-node block cache** (8Gi vs 16Gi). In practice the impact is negligible: MV query data volume is tiny (a few KB) and 8Gi is more than sufficient; when falling back to scanning raw Parquet, the data volume far exceeds any cache size (130,000 files), and 16Gi wouldn't fit it either — the bottleneck is S3 I/O, not cache.

If occasional 2-3min interruptions are acceptable → Option B (simpler). If the team or leadership has zero tolerance for interruptions → Option C variant (same cost, gains HA).

### 13.3 CN Node Spec

**Option B (1 CN)**: m5.2xlarge (8 CPU / 32Gi). CPU requests == limits to avoid throttling. Memory allocation: JVM heap 8Gi (25%) + block cache 16Gi (50%) + system 8Gi (25%).

**Option C variant (2 CN HA)**: m5.xlarge (4 CPU / 16Gi) × 2. JVM heap 4Gi + block cache 8Gi + system 4Gi. Requires PodDisruptionBudget `minAvailable: 1`.

### 13.4 When Scaling Becomes Necessary

Not needed now, but the following scenarios would trigger it:

| Scenario | Symptom | Action |
|------|------|---------|
| **Significant growth in tenant count + query concurrency** | CN CPU sustained >60%; query P99 degrades | Add HPA (controls pod count) + Cluster Autoscaler + Spot ASG (controls node count). HPA scales pods → pods become Pending → CA automatically requests new Spot nodes from ASG |
| **More tenants cause MV refresh to extend into business hours** | Doesn't finish at night; contends with daytime queries | Split CN into Query and Refresh Deployments with independent scaling strategies |
| **Large single-tenant onboard; historical data backfill is slow** | Initial MV backfill takes 24h+ | Temporarily scale up CN to accelerate backfill, then scale back down |
| **MV not ready; fallback scans raw Parquet** | Query latency degrades from milliseconds to minutes | **Do not rely on HPA** — the fundamental solution is to trigger MV backfill at onboarding time and block queries until MV is ready (see Section 5.3). If backfill itself is too slow, temporarily add CNs manually for parallel acceleration |

### 13.5 Why Use Cluster Autoscaler + ASG Instead of dcluster

dcluster can technically do this (e.g., write a bridge that monitors CPU → calls the dcluster API to add/remove nodes), but CA + ASG is the better path.

**Actual effort comparison between the two approaches:**

```
CA + ASG (standard path):
  1. Create Spot ASG + Launch Template        ← AWS configuration
  2. Add Cluster Autoscaler tags              ← 2 tag lines
  3. Add HPA YAML when needed                 ← 1 file
  → Done. Zero code; all standard K8s/AWS components.

dcluster path:
  1. Permanent CN must be managed separately (not via dcluster, or Monitor treats it as orphan and reclaims it)
  2. Write bridge: monitor CPU → on threshold call POST /node/launch → on low threshold call POST /node/destroy
     (includes Prometheus query, API retry on failure, debounce logic)
  3. Or modify dcluster Monitor to add "service type" recognition → risk of regression
  4. Three-way debugging: bridge + dcluster + StarRocks
  → One more custom-built component; any bugs must be fixed in-house.
```

**The core argument is not that dcluster can't do it, but that the cost of doing the same thing differs:**

| Dimension | CA + ASG | dcluster |
|------|---------|----------|
| Engineering cost | Zero code; pure configuration | Requires writing a bridge or modifying Monitor |
| Risk | Mature solution; no regression risk | Modifying Monitor may affect existing Spark/Flink |
| Ongoing maintenance | Standard components; well-documented | Bridge is custom-built; only we can maintain it |
| dcluster's advantages | — | right-sizing, Spot Fleet, instance fallback, job lifecycle |
| **Are these advantages applicable?** | — | **No** — CN spec is fixed; there is no job lifecycle concept |

dcluster's design goal is "run a Spark job → calculate optimal resources → destroy when done." StarRocks CN is "run continuously → add a few more when busy → reduce when idle" — this is exactly the native use case for CA + HPA. dcluster's core advantages (right-sizing, Spot Fleet, job lifecycle management) are all irrelevant in this scenario.

---
---

# Appendix

## Pitfalls Log

| Pitfall | Symptom | Root Cause | Resolution |
|----|------|------|------|
| Wrong consumer group name | `kafka-consumer-groups --group iceberg-connect` finds nothing | Kafka Connect's consumer group name is `connect-<connector-name>`, not `CONNECT_GROUP_ID` | Use `--list \| grep iceberg` to find the group name first; actual name is `connect-iceberg-sink-qaautotest` |
| First commit cycle writes 0 tables | Log: `committed to 0 table(s)` | The Iceberg Sink uses the first cycle for coordination mechanism initialization and does not write data | Wait for the second commit cycle; you will see `addedRecords=20` |
| StarRocks CN registration fails | `SHOW COMPUTE NODES` is empty | The `ALTER SYSTEM ADD COMPUTE NODE` in the init job ran before FE was fully ready | Add an init container to the init job to wait for FE port 9030 |
| featureMap all NULL | Query results have all feature columns as NULL | Test data used an empty `featureMap: {}` | Normal fp-async data will have a complete featureMap; for testing, construct messages with real feature IDs manually |

---

## Deployment Variables & IAM

### Complete Variable List

| Variable | Description | Where to Get |
|------|------|---------|
| `kafka_bootstrap_servers` | FP's Kafka address | Check existing FP K8s Service |
| `iceberg_catalog_mysql_host` | Iceberg Catalog MySQL | **Decided: standalone instance** (D17) |
| `iceberg_catalog_mysql_password` | MySQL password | Vault / K8s Secret |
| `iceberg_smt_mysql_url` | MySQL URL for SMT feature table queries | FP's risk database |
| `iceberg_smt_mysql_password_secret` | K8s Secret name | Must be created in advance |
| Node IAM Role S3 Policy | Node needs S3 read/write permissions | See below |

### IAM Credentials Approach (Confirmed)

Current deployment (duckdb namespace, kwestdeva) uses **Node Instance Profile**, not IRSA:
- StarRocks FE is configured with `aws_s3_use_instance_profile = true`
- Kafka Connect / Iceberg REST Catalog use the AWS SDK default credential chain → EC2 IMDS → Node Instance Profile

Not needed: `iceberg_kafka_connect_role_arn`, `iceberg_starrocks_role_arn`, OIDC provider ID (all used by IRSA).

The only thing to confirm: whether the node IAM Role already has S3 permissions:
```bash
aws iam list-attached-role-policies --role-name <kwestdeva-node-role>
# Required: s3:GetObject / s3:PutObject / s3:DeleteObject / s3:ListBucket
# Scoped to: arn:aws:s3:::datavisor-dev-us-west-2-iceberg/*
```


---

## Design Q&A

Records key questions, trade-offs, and conclusions from the Infra design phase. Each entry is labeled `[Design Decision]` or `[Conceptual Understanding]` to distinguish which are choices to be made vs. learning/understanding.

**Table of Contents**

**I. Scaling & Cost (Core Design Decisions)**
- [D1: Which components in the architecture need scaling?](#d1-which-components-in-the-architecture-need-scaling)
- [D2: CN Spot deployment option comparison](#d2-cn-spot-deployment-option-comparison)
- [D3: How to choose the CN node spec?](#d3-how-to-choose-the-cn-node-spec)
- [D4: Is HPA needed at the current stage?](#d4-is-hpa-needed-at-the-current-stage)
- [D5: Is it necessary to split CN into Query Pool and Refresh Pool?](#d5-is-it-necessary-to-split-cn-into-query-pool-and-refresh-pool)
- [D6: Nightly MV refresh — 1 CN or 2?](#d6-nightly-mv-refresh--1-cn-or-2)
- [D7: Why use Cluster Autoscaler + ASG + Spot instead of dcluster?](#d7-why-use-cluster-autoscaler--asg--spot-instead-of-dcluster)
- [D8: What problems does dcluster solve that CA cannot?](#d8-what-problems-does-dcluster-solve-that-ca-cannot)

**II. Multi-Tenancy and Data Model**
- [D9: Multi-tenant table structure — shared table vs. independent namespace](#d9-multi-tenant-table-structure--shared-table-vs-independent-namespace)
- [D10: Where do Iceberg event_result column names come from?](#d10-where-do-iceberg-event_result-column-names-come-from)

**III. MV Refresh and Querying**
- [D11: MV refresh frequency (Daily vs. Hourly)](#d11-mv-refresh-frequency-daily-vs-hourly)
- [D12: Validation timing for target_features](#d12-validation-timing-for-target_features)
- [D13: MV fallback scenario (falling back to scanning raw Parquet when MV is not ready)](#d13-mv-fallback-scenario-falling-back-to-scanning-raw-parquet-when-mv-is-not-ready)

**IV. Data Write Pipeline Configuration**
- [D14: Kafka Connect commit interval (is 60s appropriate?)](#d14-kafka-connect-commit-interval-is-60s-appropriate)
- [D15: SMT metadata.refresh.interval.ms (is 60s reasonable?)](#d15-smt-metadatarefreshintervalms-is-60s-reasonable)

**V. Infrastructure and Responsibility Boundaries**
- [D16: Which design points need to be synced with Dev?](#d16-which-design-points-need-to-be-synced-with-dev)
- [D17: Iceberg Catalog MySQL — standalone instance or share FP MySQL?](#d17-iceberg-catalog-mysql--standalone-instance-or-share-fp-mysql)

**VI. Conceptual Understanding (Iceberg / StarRocks / FP Business Concepts)**
- [C1: What is the relationship between raw_events and event_result?](#c1-what-is-the-relationship-between-raw_events-and-event_result)
- [C2: What is a per-tenant namespace at the Iceberg catalog physical level?](#c2-what-is-a-per-tenant-namespace-at-the-iceberg-catalog-physical-level)
- [C3: The respective responsibilities of StarRocks FE and CN](#c3-the-respective-responsibilities-of-starrocks-fe-and-cn)
- [C4: Iceberg data write order — write S3 first or update Catalog first?](#c4-iceberg-data-write-order--write-s3-first-or-update-catalog-first)
- [C5: What does each Iceberg component store?](#c5-what-does-each-iceberg-component-store)
- [C6: The complete chain for StarRocks querying Iceberg](#c6-the-complete-chain-for-starrocks-querying-iceberg)
- [C7: The respective responsibilities of Iceberg's three K8s Pods](#c7-the-respective-responsibilities-of-icebergs-three-k8s-pods)
- [C8: Business concepts of Feature / Dimension / Measure / Cube](#c8-business-concepts-of-feature--dimension--measure--cube)
- [C9: Where is StarRocks MV data stored?](#c9-where-is-starrocks-mv-data-stored)
- [C10: Is event_result the only main table in Iceberg?](#c10-is-event_result-the-only-main-table-in-iceberg)

---

### I. Scaling & Cost (Core Design Decisions)

## D1: Which components in the architecture need scaling?

`[Design Decision]`

**Conclusion: Only StarRocks CN needs scaling.**

| Component | Workload Nature | Needs Scaling? | Reason |
|------|---------|--------------|------|
| Iceberg Catalog MySQL | Metadata storage, once per commit | No | Write frequency is fixed; does not grow with query volume |
| Iceberg REST Catalog | Lightweight REST proxy | No | Extremely lightweight; metadata path is not on the hot path |
| Kafka Connect | Consume Kafka → S3; `tasks.max` parallelism internally | No pod HPA | Throughput via internal task parallelism, not pod count |
| StarRocks FE | Query planning; coordinates CNs | No | Does not do actual computation; CPU usage is minimal |
| **StarRocks CN** | **Executes queries + MV refresh; scans S3 for aggregation** | **Yes** | The only compute layer |

Core reason: compute-storage separation architecture. Data lives in S3 (permanent storage); CN is pure compute (stateless). Only CN's load grows linearly with query volume.

---

## D2: CN Spot Deployment Option Comparison

`[Design Decision]`

| | Option A | Option B ★ | Option C | ~~Option D~~ (eliminated) |
|--|--|--|--|--|
| **Architecture** | 1× on-demand | 1× spot | 2× spot | 1× spot + temporary scale-up at night |
| **Monthly cost** | ~$276 | ~$72 | ~$144 | ~$90 |
| **Online query availability** | High; no interruption | Occasional 2-3min interruption | Rare interruption | Same as Option B |
| **Spot interruption impact** | None | Query errors; retry needed | If 1 is reclaimed, the other continues | Same as Option B |
| **Nightly MV refresh** | Exclusive; normal | Exclusive; normal | Exclusive; normal | Same as Option B |
| **Implementation complexity** | Simplest | Simple | Simple + PDB | Requires KEDA/CronJob |

**Reason Option D was eliminated**: Its design premise is "nightly query and refresh compete for resources" — ToB systems have no users at night, so this premise does not hold.

**Recommendation: Option B**. ToB internal system; fp-async callers can retry; occasional 2-3min interruptions are acceptable; saves 74% cost.

**Spot interruption protection**: Enable **Capacity Rebalancing** on the ASG. When AWS detects that a spot instance is at risk of reclamation, it proactively requests a new spot instance first → starts the new node, then terminates the old one, minimizing the interruption gap. No code changes required; pure AWS configuration.

---

## D3: How to Choose the CN Node Spec?

`[Design Decision]`

Recommended starting spec: **m5.2xlarge (8 CPU / 32Gi)**

**Memory allocation:**

```
Container 32Gi
├── JVM heap (-Xmx8192m)      ~25% = 8Gi   ← SQL execution working memory
├── Off-heap block cache       ~50% = 16Gi  ← S3 data cache; cache hit avoids going back to S3
└── System + network buffer    ~25% = 8Gi
```

**Why not 4 CPU / 16Gi:**
- StarRocks CN queries use internal parallelism; below 4 CPUs, parallelism is insufficient
- Block cache is only ~8Gi; on S3 scan fallback, cache miss rate is high and latency is unstable

**Why CPU requests == limits:**
- K8s CPU throttling has a direct impact on query latency (millisecond-level throttle is observable)
- requests < limits will trigger throttling under high load

**Corresponding cn.conf settings:**
```
JAVA_OPTS="-Xmx8192m -XX:+UseG1GC ..."
storage_page_cache_size=16384   # 16Gi, unit: MB
```

---

## D4: Is HPA Needed at the Current Stage?

`[Design Decision]`. **This conclusion overrides the HPA YAML design from an earlier Q8.**

**Conclusion: No.**

MV queries place almost no computational load on CN (each query reads a few hundred pre-aggregated rows and completes in tens of milliseconds). A single CN (8 CPU) can handle dozens of concurrent MV queries without exceeding 60% CPU.

**Current recommended configuration:**
```
replicas: 1
spot ASG: min=1, max=1   # No scaling; always running
```

**When to add HPA:**
- CN CPU sustained > 60% (confirmed via monitoring, not guesswork)
- Typically requires a significant number of tenants × query frequency

**Reference HPA configuration (for future use):**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment          # CN is a Deployment, not a StatefulSet
    name: starrocks-cn
  minReplicas: 2
  maxReplicas: 8
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 120
      policies:
        - type: Pods
          value: 2
          periodSeconds: 300
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 600
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

Spot configuration (ASG spot node group + toleration + affinity) refers to the earlier design and still applies:

```yaml
tolerations:
  - key: node.kubernetes.io/lifecycle
    value: spot
    effect: NoSchedule
affinity:
  nodeAffinity:
    preferredDuringScheduling:   # preferred, to avoid being stuck if Spot is exhausted
      - weight: 80
        preference:
          matchExpressions:
            - key: node.kubernetes.io/lifecycle
              operator: In
              values: [spot]
```

---

## D5: Is It Necessary to Split CN into Query Pool and Refresh Pool?

`[Design Decision]`

**Conclusion: Not needed at the current stage; this would be over-engineering.**

### Earlier Proposal

Split into `starrocks-cn-query` + `starrocks-cn-refresh` as two Deployments, isolated via StarRocks Warehouse:

| Dimension | CN Query | CN Refresh |
|------|----------|------------|
| Trigger | On-demand requests at any time | Fixed window nightly |
| Latency requirement | P99 < 500ms | None |
| Interruptibility | Cannot be interrupted | Can be re-run |
| Spot strategy | On-Demand guaranteed | Pure Spot |
| Scaling method | HPA | CronJob scaler |

### Why Splitting Is Not Needed

The premise for splitting is "MV refresh and online queries will contend for resources simultaneously." In reality:

| Time | Query Load | Refresh Load | Contention? |
|------|---------|------------|--------|
| 1–4am | **0** (ToB system; users are not working) | MV refresh running | **No contention** |
| Daytime | MV queries are extremely light (tens of ms) | Not running | **No contention** |

The two workloads are naturally serialized; there is no resource contention. Splitting would introduce real costs (two Deployments, two Warehouses, two sets of operations) to solve a non-existent problem.

### Conditions That Would Trigger Reconsideration of Splitting
- Tenant growth causes MV refresh window to extend into business hours
- Query QPS grows to the point where a single CN cannot handle it

---

## D6: Nightly MV Refresh — 1 CN or 2?

`[Design Decision]`

**Conclusion: 1 CN, run slowly, most cost-optimal.**

```
Constraints at night:
  User queries: 0 (ToB)
  Deadline: just needs to finish before dawn (before 6am start of business)
  Resource contention: none

1 CN:
  All 8 CPUs dedicated to MV refresh
  Runs 2-3 hours → fully meets the time window
  Additional cost: $0 (this spot instance is already running)

2 CNs (temporary scale-up):
  Finishes in 1–1.5 hours; 2x faster
  Additional cost: $0.10 × 3h × 30 days ≈ $9/month
  Business value of finishing faster: nobody cares at 3am
```

No deadline pressure; finishing faster has no business value; spending more money has no justification.

---

## D7: Why Use Cluster Autoscaler + ASG + Spot Instead of dcluster?

`[Design Decision]`

dcluster is an internal company cluster management service built for Spark/Flink batch jobs; it is **not suited for StarRocks CN**, which is a long-running service:

| Dimension | dcluster | CA + ASG + Spot |
|------|---------|-----------------|
| Design goal | Full lifecycle management of Spark/Flink batch jobs | General-purpose pod elastic scaling |
| Trigger mechanism | Explicit REST API calls (POST /node/launch) | Automatically detects Pending Pods |
| HPA integration | Not supported; requires custom bridge | Native chaining (Pending Pod is the contact point) |
| Node cleanup | Depends on "job ends" event; Monitor treats nodes without jobs as garbage and reclaims them | Based on node utilization |
| Migration cost | Medium (requires modifying Monitor; risk of breaking existing Spark/Flink) | Zero (configure ASG + Launch Template) |

**Can dcluster manage temporarily scaled-out CN nodes?**

Technically feasible: permanent CN does not go through dcluster; temporary CNs are managed by dcluster as "jobs" and naturally reclaimed by the dcluster Monitor when done. However, this requires writing a bridge (monitor CPU → call dcluster API), and having permanent CN and temporary CN managed by two separate mechanisms doubles operational complexity.

CA + ASG uses a single mechanism to manage all CNs (permanent + temporary); HPA uniformly controls pod count; CA uniformly controls node count. dcluster's core advantages (right-sizing, Spot Fleet, instance fallback, job lifecycle) are all inapplicable in a scenario where CN spec is fixed and there is no job concept.

**Conclusion**: Leave dcluster untouched; StarRocks CN follows the CA + ASG + Spot standard path. The two systems do not interfere with each other.

**HPA + CA + ASG three-way chaining logic (when HPA is enabled in the future):**

```
HPA increases CN replicas
  → New Pods become Pending (no suitable node)
  → Cluster Autoscaler sees Pending Pods
  → CA calls ASG scale-out
  → ASG uses Launch Template to start Spot EC2
  → Node joins K8s (with label: role=starrocks-cn)
  → Scheduler places Pending Pod on the node

HPA decreases CN replicas
  → Node becomes empty / low utilization
  → CA calls ASG scale-in → EC2 terminates
```

The three components chain automatically via the two signals **Pending Pod → underutilized node**, requiring no custom code.

---

## D8: What Problems Does dcluster Solve That CA Cannot?

`[Conceptual Understanding]`. Explains the value of dcluster; not a StarRocks design decision.

CA's capability boundary: "Pending Pod → add node; idle node → remove node." It is completely unaware of upper-layer workloads.

Problems dcluster additionally solves for Spark/Flink:

| Capability | Description |
|------|------|
| **Right-sizing / bin-packing** | Reads job config → queries EC2 API for instance specs → calculates workers_per_slave → requests minimum sufficient instances |
| **Spot Fleet** | Simultaneously bids on multiple instance types; weighted capacity ensures total compute meets requirements |
| **Instance fallback** | r7i.2xlarge unavailable → automatically falls back to r6i → r5 |
| **Full job lifecycle** | Job submitted → start nodes → Helm deploy → monitor anomalies → destroy immediately when job ends |
| **Orphan node cleanup** | Monitor checks every 5 min for nodes with no running jobs and immediately reclaims them |
| **Multi-cloud abstraction** | Unified API across AWS / GKE / on-premise |

In short: CA is infrastructure-layer ("my pods don't fit"), dcluster is workload-layer ("help me run a Spark job end-to-end").

---

### II. Multi-Tenancy and Data Model

## D9: Multi-Tenant Table Structure — Shared Table vs. Independent Namespace

`[Design Decision]`

**Conclusion: Use independent namespace (per-tenant); validated.**

| Dimension | Option A: Shared Table | Option B: Independent Namespace ★ |
|--|--|--|
| Isolation approach | `tenant` column + partition pruning | Iceberg namespace physical isolation |
| MV DDL | Requires `WHERE tenant = 'xxx'` | No filter needed; the FROM clause is already isolated |
| S3 physical path | `s3://bucket/raw_events/tenant=sofi/` | `s3://bucket/{tenant}/event_result/` |
| Schema evolution | One ALTER affects all tenants | Each namespace evolves independently; no cross-tenant impact |
| Debugging scope | Must add `WHERE tenant` filter | S3 paths are naturally scoped to tenant level |

Core rationale: MV DDL is cleaner; different tenants' feature column sets are completely independent; S3 is naturally isolated.

---

## D10: Where Do Iceberg event_result Column Names Come From?

`[Conceptual Understanding]`

**They come from Feature definitions, not from Cube.**

```
Feature published → FP MySQL feature table (id=7, name="country")
  → EventResult.featureMap = {7: "US"}
  → Kafka velocity-al
  → SMT queries MySQL: id=7 → name="country"
  → Iceberg ALTER TABLE ADD COLUMN country STRING
```

The role of Cube is to "build a pre-aggregated view on top of the raw Iceberg table"; it does not determine the columns of the raw table.

---

### III. MV Refresh and Querying

## D11: MV Refresh Frequency (Daily vs. Hourly)

`[Design Decision]`

### MV Refresh Frequency vs. K8s Resource Scheduling — Two Different Levels

| Level | Controller | Configuration Location | Determines |
|--|--|--|--|
| MV refresh frequency | StarRocks FE scheduler | `CREATE MV ... REFRESH ASYNC EVERY(...)` | Data freshness (business SLA) |
| When CN resources are online | K8s (current approach: 1 permanent CN) | Deployment replicas | Compute availability window |

> **Note**: An earlier design considered a dedicated CN Refresh CronJob (start at night / scale to zero during the day). Based on the conclusion from D5 (no CN split), the current approach changes to 1 permanent CN handling both queries and refresh; no CronJob scaler is needed.

### Daily vs. Hourly Trade-offs

| Dimension | Daily (recommended starting point) | Hourly |
|--|--|--|
| Data latency SLA | Up to ~24h | Up to ~1h |
| CN resources | Nightly refresh 2-3h; only queries during the day | Refresh runs continuously; contends with queries |
| Cost | Low | High (refresh consumes more CPU time) |
| Use case | Offline analytics, T+1 reports | Near-real-time trend queries |

**Conclusion**: Start with Daily. MV refresh frequency is a business decision, determined by the stakeholder based on the acceptable data latency SLA.

---

## D12: Validation Timing for target_features

`[Design Decision]`

**Conclusion: Two-layer validation with clear separation of responsibilities.**

**At creation time (lightweight validation)**
- Whether the `target_features` field format is valid
- Whether the referenced feature IDs exist for the current tenant

**Before MV refresh (deep validation)**
- Whether the feature data types are compatible with the aggregation functions
- Validation failure → `Cube.status = ERROR`; write `error_message`

> Key point: runtime validation happens **before refresh starts**, not **after failure** — proactive validation is more controllable than reactive exception catching.

**Infra debugging paths (three categories):**

```
Cube.status == ERROR → check error_message
  ├── "feature xxx not found"        → slipped through creation-time validation (should not happen)
  ├── "type incompatible: ..."       → pre-refresh validation failure (configuration issue)
  └── "SQL execution error: ..."     → infrastructure issue
```

Responsibility boundary: Dev writes validation logic; Infra debugs by the three path categories.

---

## D13: MV Fallback Scenario (Falling Back to Scanning Raw Parquet When MV Is Not Ready)

`[Design Decision]`

**Trigger conditions:**
1. New tenant just onboarded; historical MV not yet built (**most common**)
2. MV refresh failed
3. Query arrives before nightly refresh completes (generally won't happen in ToB)

**Latency gap — order-of-magnitude difference:**

```
MV query:          tens of milliseconds ~ 1 second (reads a few hundred pre-aggregated rows)
Raw Parquet scan:  a few minutes ~ tens of minutes (scans 90 days × 1,440 files/day ≈ 130,000 S3 files)
```

**Recommended design (fix the root cause; don't rely on scaling):**

| Approach | Description | Recommendation |
|------|------|--------|
| Trigger historical MV backfill immediately at onboarding | Show "data processing" on frontend until MV is ready; open queries after | ★★★ Root cause fix |
| Limit query time range during fallback | Automatically downgrade 90d to 7d; reduces scan volume by 13x | ★★ Safety fallback |
| Temporarily scale up to accelerate backfill | Only needed when a single tenant's data volume is extremely large | ★ On demand |

**Core principle**: Scaling is not the solution for fallback — ensuring the MV is always ready is.

---

### IV. Data Write Pipeline Configuration

## D14: Kafka Connect Commit Interval (Is 60s Appropriate?)

`[Design Decision]`

**Conclusion: Recommend changing to 10min (600000ms).**

60s is overly aggressive for a daily MV scenario; main side effects:
- ~2,880 small file batches per day; when CN falls back to scanning, opening a large number of files is slow
- Iceberg catalog manifest entries grow quickly
- 60s vs 10min has absolutely no effect on MV results

| Commit interval | Daily file batches | Data visibility latency | Assessment |
|----------|------------|------------|------|
| 60s | ~2,880 | ≤60s | Overly aggressive |
| **10min** | **~288** | **≤10min** | **Recommended** ✓ |
| 30min | ~96 | ≤30min | Pure batch processing |

The only reason to keep 60s: if there is a strong SLA requiring "data from the last 1 minute must be visible" — this system has no such requirement.

---

## D15: SMT metadata.refresh.interval.ms (Is 60s Reasonable?)

`[Design Decision]`

**Conclusion: 60s is reasonable.**

The SMT performs a full query of FP MySQL every 60s: `SELECT id, name, return_type FROM feature WHERE status='PUBLISHED'`. Feature publishing is a low-frequency operation; a visibility latency of ≤60s is completely acceptable. The query is extremely lightweight and has no perceptible load on FP MySQL.

---

### V. Infrastructure and Responsibility Boundaries

## D16: Which Design Points Need to Be Synced with Dev?

`[Design Decision]`

### Must sync with Dev

| Design Point | Questions to Confirm |
|--|--|
| Stats API request/response schema | What is the window parameter format? How are coverage/actual_days conveyed in the response? |
| event_result table name vs. raw_events | Which name to standardize on? |
| MV refresh frequency (daily vs. hourly) | What data latency SLA is acceptable to the business? |
| target_features validation timing | Dev writes validation logic; Infra debugging paths depend on this decision |

### Infra decides independently

- Kafka Connect commit interval → decided: 10min (D14)
- CN node spec and Spot/HPA strategy → decided (D2-D4)
- S3 path naming convention
- Iceberg catalog MySQL standalone instance → decided (D17)
- per-tenant namespace → decided (D9)

---

## D17: Iceberg Catalog MySQL — Standalone Instance or Share FP MySQL?

`[Design Decision]`

**Conclusion: Standalone instance.**

Core risk: Iceberg Vacuum's long transactions will cause FP's short transactions to queue for locks, directly raising the p99 latency of real-time detection.

| Dimension | FP MySQL | Iceberg Catalog MySQL |
|------|----------|-----------------------|
| Latency sensitivity | Extremely high (online detection path) | Medium (batch processing; tolerable) |
| Lock characteristics | Brief row locks | Potentially long transactions during Vacuum |
| Peak source | Real-time request traffic | Batch processing schedule cycles |

Iceberg JDBC catalog has low MySQL spec requirements (limited metadata volume); a small instance is sufficient and the cost is low.

---

### VI. Conceptual Understanding (Iceberg / StarRocks / FP Business Concepts)

> The following content is explanatory Q&A and does not involve design choices that need to be made.

## C1: What Is the Relationship Between raw_events and event_result?

**They are the same concept with inconsistent naming.**

| | System Design Document | Actual Implementation |
|--|--|--|
| Table name | `raw_events` | `event_result` |
| Data content | Raw events + all feature columns | Raw events + all feature columns |

`event_result` was chosen in the implementation to align with the existing `event_result` table in ClickHouse — **a ClickHouse mirror of velocity-al → Iceberg**.

---

## C2: What Is a Per-Tenant Namespace at the Iceberg Catalog Physical Level?

**They are different tables, not different partitions of the same table.**

In the Iceberg REST Catalog's underlying MySQL `iceberg_tables`, the `table_namespace` field corresponds to the tenant:

```
catalog_name | table_namespace | table_name   | metadata_location
─────────────────────────────────────────────────────────────────
rest         | qaautotest      | event_result | s3://.../qaautotest/event_result/metadata/v3.metadata.json
rest         | yysecurity      | event_result | s3://.../yysecurity/event_result/metadata/v1.metadata.json
```

Each namespace has completely independent S3 metadata.json and Parquet data files.

---

## C3: The Respective Responsibilities of StarRocks FE and CN

```
FE (Frontend, permanent StatefulSet):
  - SQL parsing + query planning
  - Translates fp-async SQL into execution plans and distributes them to CNs
  - Manages metadata (table schema, MV definitions, CN registration state)
  - Lightweight; does not do actual data computation

CN (Compute Node, stateless Deployment):
  ├── At night: MV refresh — scans raw S3 Parquet, performs GROUP BY, writes aggregated results
  └── During the day: query execution — reads MV pre-aggregated data, merges daily partitions, returns results
```

CN is the only component that performs actual computation.

---

## C4: Iceberg Data Write Order — Write S3 First or Update Catalog First?

**Write S3 first; atomically update Catalog last.**

```
① Write Parquet data file → S3
② Write manifest file (avro) → S3
③ Write snapshot (avro) → S3
④ Write new version metadata.json → S3
⑤ Catalog atomically updates pointer: old metadata.json → new metadata.json  ← commit complete
```

Step ⑤ is the atomic boundary of the commit. If a failure occurs at any earlier stage, there are orphan files on S3 that are not externally visible; Vacuum will clean them up later.

---

## C5: What Does Each Iceberg Component Store?

### Files on S3

| File Type | Stores | Purpose |
|----------|---------|------|
| Parquet (data) | Actual event data, columnar compressed | The source of truth; what CN ultimately reads |
| metadata.json | Schema, partition spec, snapshot list, current pointer | The "master index" of the table; a new version per commit |
| snapshot (avro) | Commit timestamp, type, pointer to manifests | Foundation of MVCC |
| manifest file (avro) | Path + min/max/null stats for each Parquet file | Query acceleration: skip files that don't match the condition |

### Catalog (REST + MySQL)

Stores only one thing: the S3 path of the current metadata.json. Core purpose: concurrency control (CAS atomic update) + service discovery.

---

## C6: The Complete Chain for StarRocks Querying Iceberg

```
StarRocks FE receives SQL
  → asks REST Catalog: where is the metadata?
  → reads S3 metadata.json → finds current snapshot
  → reads snapshot → finds manifest list
  → reads manifests: checks min/max of each Parquet → skips non-matching files
  → pulls only relevant Parquet → CN executes computation → returns result
```

Key point: Iceberg neither holds data nor transmits data. Once FE has the metadata path, all subsequent operations access S3 directly.

---

## C7: The Respective Responsibilities of Iceberg's Three K8s Pods

```
iceberg-catalog-mysql   = Catalog backend (MySQL); stores table→metadata path mapping
iceberg-rest-catalog    = REST API; exposes MySQL pointers as HTTP interface
iceberg-kafka-connect   = Write-side; Kafka → Parquet (S3) + commits Iceberg snapshot
```

After StarRocks FE gets the path from the REST Catalog → it reads S3 directly; it no longer goes through the Catalog.

---

## C8: Business Concepts of Feature / Dimension / Measure / Cube

```
Feature   = Raw material (fields on an event: country, amount, device_risk...)
Dimension = Slicing method (how to group: by country, by event type)
Measure   = Statistical quantity (what to compute after grouping: count, sum, p95, distinct_count)
Cube      = One analytics requirement = Dimension + Measure + which Features
MV        = Pre-computed result of a Cube; partitioned by day; stored in StarRocks S3 path
```

---

## C9: Where Is StarRocks MV Data Stored?

**Also in S3, but in a different format from Iceberg; managed by StarRocks itself (Shared-Data architecture).**

```
s3://warehouse/
├── {tenant}/event_result/        ← Managed by Iceberg (Parquet format; raw full history)
└── starrocks-segments/           ← Managed by StarRocks (Segment format; pre-aggregated results)
    └── mv_{tenant}_{dim}_{feat}/
        ├── stat_date=2026-03-28/ ← One partition per day; very small (~few KB)
        └── stat_date=2026-03-29/
```

CN is stateless: data lives in S3; local cache is only an acceleration layer and can be rebuilt if lost.

---

## C10: Is event_result the Only Main Table in Iceberg?

**Yes.**

```
① Iceberg: event_result (per-tenant namespace)
   = All raw events + all feature columns; continuously written

② StarRocks MV: mv_{tenant}_{dimension}_{feature}
   = Auto-generated per Cube × Feature; daily partitioned
```

An earlier design considered 4 sets of Iceberg storage (raw + daily + agg + cache); ultimately simplified to **1 raw Iceberg table + StarRocks handles all pre-aggregation**.
