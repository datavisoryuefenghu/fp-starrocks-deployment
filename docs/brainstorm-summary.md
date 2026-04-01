# CRE-6630 StarRocks Production Deployment — Brainstorm Summary

## 1. Core Requirements

Customers configure "statistical views" (Cube = Dimension + Measures + Target Features) in the FP console. The system **automatically pre-aggregates (MV) every night**, after which customers can query 30d/90d/180d statistics at any time with **millisecond-level response**.

### Data Volume Reduction Through the Pipeline

| Stage | Data Volume (Medium tenant) | Who Handles It | When |
|------|----------------------|--------|------|
| Raw events (S3 Parquet) | 43 GB/day, 10M rows | Kafka Connect writes | Real-time |
| MV pre-aggregated results | ~200 rows/day, a few KB | CN Refresh scans raw data GROUP BY | Nightly batch |
| Query response | ~a few thousand rows, a few KB JSON | CN Query merges daily partitions | Online request |

**Online queries are extremely lightweight** — MV compresses TB-scale data down to KB-scale. The heavy lifting all happens in the nightly batch.

---

## 2. Your (Infra) Responsibility Boundary

### What You Own (Module B: Infrastructure)

- Deploy/operate: Kafka Connect, Iceberg REST Catalog, StarRocks (FE + CN)
- S3 Bucket + IAM + Lifecycle
- Compaction CronJob
- CN Refresh elasticity (dcluster spot)
- Monitoring (Prometheus + Grafana)
- New tenant onboarding: register connector

### What Backend Owns (fp-async Java)

- Cube/Dimension CRUD API
- Generate `CREATE MATERIALIZED VIEW` DDL → send to StarRocks FE via JDBC
- Stats query SQL assembly + result formatting
- Partial Window logic

---

## 3. StarRocks Core Concepts

| Role | Analogy | Responsibility | Resource Requirements |
|------|------|------|---------|
| **FE** (Frontend) | Restaurant host | Query planning, MV scheduling, metadata management | Low (4C/16G), fixed 3-node HA |
| **CN** (Compute Node) | Kitchen cook | Scan data, aggregate, sort — does the actual work | High, primary scaling target |
| **S3** | Large cold storage | Stores all data (Iceberg Parquet + MV segments) | Pay-as-you-go, unlimited capacity |

Shared-Data mode: CN is stateless, all data lives in S3, local SSD is cache only. CNs can be added or removed at any time.

---

## 4. Production Architecture: Model C — Shared FE + CN Pool Isolation

```
                         ┌──────────────────────────────┐
                         │        fp-async (Java)        │
                         └──────────┬───────────────────┘
                                    │ JDBC :9030
                         ┌──────────▼───────────────────┐
                         │    StarRocks FE × 3 (HA)     │
                         │    常驻, On-Demand            │
                         └──┬────────────────────┬──────┘
                            │                    │
              ┌─────────────▼──────┐  ┌──────────▼─────────────┐
              │ CN Query Pool      │  │ CN Refresh Pool        │
              │ 常驻 2-3 节点       │  │ 凌晨 dcluster spot     │
              │ On-Demand / RI     │  │ 跑完即释放              │
              │ 在线查询 (10-50ms) │  │ MV 刷新 (分钟~小时级)   │
              └────────────────────┘  └────────────────────────┘
                      │                         │
                      ▼                         ▼
              ┌─────────────────────────────────────────┐
              │                   S3                     │
              │  /raw_events/ (Iceberg Parquet)          │
              │  /starrocks/  (MV segment cache)         │
              └─────────────────────────────────────────┘
                      ▲
              ┌───────┴──────────────────┐
              │ Kafka Connect Workers    │
              │ 2-3 个 Pod (共享)         │
              │ 内跑 N 个 connector/task  │
              └───────┬──────────────────┘
                      │
              ┌───────┴──────────────────┐
              │ Kafka: velocity-al-{t}   │
              └──────────────────────────┘
```

---

## 5. Cross-Cluster Deployment Topology: Per-cluster (Option A)

### Background

The current cloud architecture maintains multiple regions and clusters, with Cluster A/B in an active/standby configuration. Each cluster namespace has a complete set of FP-async, Kafka, ClickHouse, YugabyteDB, etc.

### Decision: Deploy a Separate StarRocks Instance Per Cluster (Per-cluster)

**No centralized deployment**, rationale:

1. **Consistency** — Exactly matches the deployment pattern of ClickHouse, YugabyteDB, and Kafka; no new operational model introduced; team is already familiar with this approach
2. **Data path locality** — Kafka Connect must consume from local Kafka; fp-async JDBC queries to StarRocks require low latency; both require intra-cluster communication
3. **A/B failover requires zero extra work** — When switching clusters, StarRocks follows; no need to change JDBC endpoints or add cross-cluster routing
4. **Fault isolation** — StarRocks failure in one cluster does not affect other clusters
5. **Standby cost is extremely low** — In StarRocks Shared-Data mode, CNs are stateless and all data lives in S3; standby cluster only needs minimal configuration

### Per-cluster Resource Allocation

| Component | Active Cluster | Standby Cluster |
|------|---------------|-----------------|
| Kafka Connect | 2-3 workers (running normally) | 2-3 workers (running normally, continuously writing to S3 to keep data in sync) |
| StarRocks FE | ×3 (HA) | ×1 (minimal, no HA needed) |
| StarRocks CN Query | ×2-3 (always-on) | ×1 (warm standby) |
| StarRocks CN Refresh | ×0-4 (nightly spot) | ×0 (no batch runs) |
| Standby monthly cost increment | — | ~$200-300 |

### Key: Standby Kafka Connect Runs Continuously

The standby cluster's Kafka Connect continuously consumes Kafka and writes to S3, so that:
- Iceberg data on S3 is always complete
- On failover, StarRocks only needs to scale up CNs to serve traffic immediately
- No data catch-up needed after failover

### Pod-level Data Flow (within a single cluster)

```
┌─ Cluster (namespace) ───────────────────────────────────────────┐
│                                                                   │
│  ┌──────────┐   velocity-al    ┌────────────────┐               │
│  │ fp-async  │ ────topic────→  │ Kafka Cluster   │               │
│  │ (Java)    │                 └───────┬─────────┘               │
│  └────┬──────┘                         │ consume                  │
│       │                                ▼                          │
│       │ JDBC :9030            ┌──────────────────┐               │
│       │ (Stats query)        │ Kafka Connect     │               │
│       │                      │ Workers (2-3 Pod) │               │
│       │                      └───────┬───────────┘               │
│       │                              │ write Parquet              │
│       │                              ▼                            │
│  ┌────▼─────────────────────────────────────────┐               │
│  │             StarRocks                         │               │
│  │  FE ×1~3  ← 查询规划 / MV 调度                │               │
│  │    ├── CN Query Pool (常驻, serve Stats API)  │               │
│  │    └── CN Refresh Pool (凌晨 spot, MV 刷新)   │               │
│  └──────────────────┬────────────────────────────┘               │
│                     │ read/write                                  │
└─────────────────────┼─────────────────────────────────────────────┘
                      ▼
             ┌─────────────────┐
             │       S3        │
             │ /raw_events/    │ ← Kafka Connect 写入
             │ /starrocks/     │ ← MV segment
             └─────────────────┘
```

### Rejected Alternatives

**Centralized StarRocks (Option B)** — fp-async would need cross-cluster JDBC queries, introducing network latency and reliability risks; StarRocks becomes a SPOF for all clusters; does not follow the existing architectural pattern.

**Per-region shared (Option C)** — Only worth considering when there are many small clusters within the same region and cost pressure is high; at the current scale this is over-engineering.

---

## 6. Multi-tenant Isolation Model

### Shared (single deployment, used by all tenants)

- StarRocks FE × 3
- StarRocks CN Pools
- Kafka Connect Workers (2-3 Pods)
- Iceberg REST Catalog (1 instance)
- S3 Bucket (1 bucket)

### Per-tenant (independent per client)

- Kafka Connect **connector** (one JSON config per tenant, running on shared workers)
- Iceberg **database** (one per tenant, e.g. `yysecurity.raw_events`)
- StarRocks **MV** (auto-created per tenant × per Cube, managed by fp-async)
- S3 **path prefix** (e.g. `s3://bucket/raw_events/tenant=yysecurity/`)

### Kafka Connect Three-Layer Structure

| Layer | What It Is | Count |
|----|--------|------|
| **Worker** | JVM process / K8s Pod (deployed by you) | 2-3, fixed |
| **Connector** | Logical config JSON (registered via curl) | One per tenant |
| **Task** | Threads that do the actual work (automatically assigned to workers by the framework) | Determined by `tasks.max` |

If a worker goes down → the framework automatically reassigns tasks to surviving workers (rebalance).

### New Tenant Onboarding

```bash
# Only need to register one connector; everything else is automatic
curl -X POST http://kafka-connect:8083/connectors -d '{
  "name": "iceberg-sink-{tenant}",
  "config": { "topics": "velocity-al-{tenant}", "iceberg.tables": "{tenant}.raw_events", ... }
}'
```

---

## 7. Scaling Strategy

### Where to Scale

| Component | Method | Notes |
|------|------|------|
| FE (3 nodes) | Fixed | Query planning; no scaling needed |
| Kafka Connect | Fixed | Stable throughput; rarely needs adjustment |
| CN Query | HPA (reactive) | Online queries; load is unpredictable |
| CN Refresh | dcluster + spot (proactive) | Scheduled batch jobs; release after completion |

### Why Batch Uses dcluster Instead of HPA

| Dimension | HPA | dcluster + spot |
|------|-----|-----------------|
| Cost | On-demand full price | Spot saves 60-70% |
| Timing | Reactive | Proactive scheduling; ready before job starts |
| Spot interruption | Unaware | Can configure fallback to on-demand |
| Best for | Online queries (arrival time unknown) | Batch jobs (run time is known) |

### CN Refresh dcluster Flow

```
00:00                                          06:00
  │  01:00 dcluster 申请 spot (4x r6i.2xlarge)   │
  │  01:10 机器 ready, join K8s, CN pods 启动      │
  │  01:20 StarRocks FE 触发 MV refresh            │
  │  ~04:30 刷新完成                                │
  │  04:40 CN 优雅下线, dcluster 释放 spot          │
```

### How Much Scaling Do Online Queries Actually Need?

If the MV is designed properly: **almost none**. Online queries only read a few thousand rows of MV data (KB-scale); 2-3 small always-on CNs are sufficient.

---

## 8. Resource Configuration (Starting with Medium Tenant)

| Component | Spec | Count | Monthly Cost (1yr RI) |
|------|------|------|----------------|
| StarRocks FE | m6i.xlarge (4C/16G) | 1 | $87 |
| StarRocks CN Query | r6i.xlarge (4C/32G) | 2-3 | $229-$344 |
| StarRocks CN Refresh | r6i.2xlarge spot (4hr/day) | 2 | ~$15 |
| Kafka Connect Worker | m6i.xlarge (4C/16G) | 2 | $174 |
| Iceberg REST Catalog | m6i.large (2C/8G) | 1 | ~$70 |
| S3 (180d retention) | 7.7 TB | - | $177 |
| **Total** | | | **~$1,100-1,400/month** |

See [sizing-sheet.md](sizing-sheet.md) for detailed sizing.

---

## 9. QA vs. Production Differences

| Dimension | QA (current) | Production |
|------|----------|------|
| StarRocks | `allin1` standalone 1 pod | FE×3 + CN Query×2-3 + CN Refresh×0-4 |
| Deployment method | Manual YAML | StarRocks Operator + Helm |
| CN Refresh | Does not exist | dcluster spot, starts/releases nightly |
| Kafka Connect | 1 worker, borrows duckdb Kafka | 2-3 workers, production Kafka |
| Iceberg Catalog | In-pod MySQL | RDS MySQL |
| Compaction | Not configured | CronJob nightly |
| Monitoring | Manual kubectl | Prometheus + Grafana |
| Multi-tenancy | Single tenant | Per-tenant connector + Iceberg DB |

---

## 10. Action Priorities

| Priority | Item | Notes |
|--------|------|------|
| **P0** | StarRocks Operator deployment | Replace standalone; support FE/CN separation |
| **P0** | Split CN into Query/Refresh pools | Isolate online queries from batch processing |
| **P1** | Compaction CronJob | Prevent S3 small file explosion |
| **P1** | S3 Lifecycle Rule | Hot 180d → Warm IA → Cold Glacier → Delete |
| **P1** | Monitoring | FE/CN Prometheus → Grafana |
| **P2** | Multi-tenant connector templating | New tenant = one command |
| **P2** | dcluster integration | Automate spot CN request/register/release |

---

## 11. Output Files

| File | Contents |
|------|------|
| [sizing-sheet.md](sizing-sheet.md) | Detailed resource configuration, cost estimates, and scaling trigger conditions for 4 tenant tiers |
| [brainstorm-summary.md](brainstorm-summary.md) | This file — complete brainstorm summary |
| Excalidraw architecture diagram | Model C multi-tenant deployment topology (on Excalidraw canvas) |
