# CRE-6630 API Gaps — Resolved vs Still Open

---

## ✅ Resolved

### 1. Dimension CRUD

```
POST /{tenant}/dimension
Body:     { name, type: "expression"|"column", expr: "CASE WHEN country='CN' THEN 'China' ..." }
Response: Dimension object
```

- Validates expression correctness at creation time and writes to the MySQL `dimension` table
- Logic is complete and unambiguous

---

### 2. Cube Creation

```
POST /{tenant}/cube
Body: {
  name: "Country Stats",
  dimension_id: 1,
  target_features: ["txn_amount", "age"],
  measures: ["count", "sum", "p95", "distinct_count"]
}
Response: Cube (including initial status for each MV)
```

- Upon receiving the request, fp-async generates DDL for each target_feature and submits `CREATE MATERIALIZED VIEW` to StarRocks
- MV naming convention is finalized: `mv_{tenant}_{dim_name}_{feature}`
- MV creation is asynchronous (StarRocks begins scheduling the refresh); the API returns immediately without blocking

---

### 3. Measure → StarRocks Function Mapping (hardcoded in fp-async)

| User Measure | What is stored in MV | Window query aggregation |
|-------------|-----------|------------|
| `count` | `count(col) AS cnt` | `sum(cnt)` |
| `sum` | `sum(col) AS sum_val` | `sum(sum_val)` |
| `min` | `min(col) AS min_val` | `min(min_val)` |
| `max` | `max(col) AS max_val` | `max(max_val)` |
| `mean` | reuses `sum_val` + `cnt` | `sum(sum_val) / sum(cnt)` |
| `std` | additional `sum(col*col) AS sum_sq` | `sqrt(sum(sum_sq)/sum(cnt) - pow(sum(sum_val)/sum(cnt), 2))` |
| `p50/p90/p95/p99` | `percentile_union(percentile_hash(col)) AS pct_state` | `percentile_approx_raw(percentile_union(pct_state), 0.95)` |
| `distinct_count` | `hll_union(hll_hash(col)) AS hll_state` | `hll_union_agg(hll_state)` |
| `missing_count` | `count_if(col IS NULL) AS missing_cnt` | `sum(missing_cnt)` |

No need to store the mapping in the database; adding a new Measure only requires extending the mapping table and deploying a code release.

---

### 4. MV DDL Generation (complete example)

After the user submits a Cube, fp-async generates the following DDL for each target_feature:

```sql
CREATE MATERIALIZED VIEW mv_sofi_country_txn_amount
PARTITION BY (stat_date)
DISTRIBUTED BY HASH(segment_value)
REFRESH ASYNC EVERY (INTERVAL 1 DAY)
PROPERTIES ("partition_refresh_number" = "1")
AS
SELECT
    'sofi'                                        AS tenant,
    date_trunc('day', event_time)                 AS stat_date,
    CASE WHEN country='CN' THEN 'China'
         WHEN country='US' THEN 'US'
         ELSE 'Other' END                         AS segment_value,
    count(txn_amount)                             AS cnt,
    sum(txn_amount)                               AS sum_val,
    max(txn_amount)                               AS max_val,
    percentile_union(percentile_hash(txn_amount)) AS pct_state,
    hll_union(hll_hash(txn_amount))               AS hll_state
FROM iceberg_catalog.db.raw_events
WHERE tenant = 'sofi'
GROUP BY tenant, stat_date, segment_value;
```

---

### 5. Cube Modify/Delete Rules

| Operation | Handling |
|------|---------|
| Modify Dimension expr | DROP MV → rebuild (new expr requires full recomputation) |
| Add target_feature | CREATE new MV (existing MVs are not affected) |
| Add Measure | DROP MV → rebuild (new aggregation column must be added) |
| Delete Cube | DROP all associated MVs |
| Delete individual Feature | DROP the corresponding MV |

---

### 6. MySQL Data Model (three tables)

```sql
-- Dimension definition
CREATE TABLE dimension (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    tenant       VARCHAR(128) NOT NULL,
    name         VARCHAR(256) NOT NULL,
    type         VARCHAR(32)  NOT NULL,  -- EXPRESSION / COLUMN
    expr         TEXT         NOT NULL,  -- CASE WHEN expression or column name
    status       VARCHAR(32)  NOT NULL DEFAULT 'ACTIVE',
    creator      VARCHAR(128),
    create_time  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    update_time  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_tenant_name (tenant, name)
);

-- Analysis view
CREATE TABLE cube_config (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    tenant          VARCHAR(128) NOT NULL,
    dimension_id    BIGINT       NOT NULL,
    name            VARCHAR(256) NOT NULL,
    target_features TEXT         NOT NULL,  -- JSON: ["txn_amount", "age"]
    measures        TEXT         NOT NULL,  -- JSON: ["count", "sum", "p95"]
    status          VARCHAR(32)  NOT NULL DEFAULT 'ACTIVE',
    creator         VARCHAR(128),
    create_time     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    update_time     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (dimension_id) REFERENCES dimension(id),
    UNIQUE KEY uk_tenant_name (tenant, name)
);

-- Each Cube × Feature corresponds to one StarRocks MV
CREATE TABLE cube_mv (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    cube_id       BIGINT        NOT NULL,
    feature_name  VARCHAR(512)  NOT NULL,
    mv_name       VARCHAR(512)  NOT NULL,  -- mv_sofi_country_txn_amount
    mv_ddl        TEXT          NOT NULL,  -- generated DDL kept for reference
    status        VARCHAR(32)   NOT NULL DEFAULT 'CREATING',  -- CREATING / ACTIVE / ERROR
    last_refresh  DATETIME,
    error_message TEXT,
    create_time   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (cube_id) REFERENCES cube_config(id)
);
```

---

### 7. Partial Window Query Logic

When MV data does not cover the full window (e.g., a newly created Cube or a newly onboarded tenant), queries can still return results but include coverage information:

```sql
SELECT
    segment_value,
    sum(cnt)                              AS total_count,
    count(DISTINCT stat_date)             AS actual_days,
    count(DISTINCT stat_date) / 30.0      AS coverage
FROM mv_sofi_country_txn_amount
WHERE stat_date BETWEEN current_date - INTERVAL 30 DAY AND current_date
GROUP BY segment_value;
```

The application layer marks the result as `COMPLETE` or `PARTIAL` based on `coverage`, and the frontend displays "calculated from N days of data."

---

### 8. Query Rewrite Path (transparent to fp-async)

fp-async issues SQL against `raw_events`; the FE CBO transparently rewrites it to query the MV, so application code does not need to be aware of MV existence:

```
fp-async:  SELECT ... FROM raw_events WHERE tenant='sofi' AND event_time BETWEEN ...
               ↓ StarRocks FE CBO rewrites automatically
StarRocks: SELECT ... FROM mv_sofi_country_txn_amount WHERE stat_date BETWEEN ...
               ↓ CN Query merges N daily partitions (millisecond-level)
fp-async:  receives aggregated result, wraps it into Stats API response and returns
```

---

## ❌ Still Open

### 1. Stats API Exact Interface (most critical gap)

The system design document contains only a single illustrative line:

```
GET /sofi/stats?cube=Country%20Stats&window=30d
```

**Not yet documented**:

| Question | Notes |
|------|------|
| Does `cube` parameter use id or name? | Both can uniquely identify the cube, but the API spec must settle on one |
| What values does `window` support? | Only 30d/90d/180d, or any number of days? |
| Can multiple features be queried in one call? | `features=["txn_amount","age"]` or only one feature per call? |
| Are additional filters supported? | e.g., `event_type=transaction`, or can results only be grouped by Dimension? |
| Response JSON schema? | How are `coverage`, `actual_days`, and `segment_value` structured? |
| Error code specification? | What is returned when MV is still in CREATING state? What is the fallback logic when StarRocks is unreachable? |

---

### 2. Cube Status Query API

MV creation is asynchronous — how does the user know when the MV is ready after creating a Cube?

- Is a `GET /{tenant}/cube/{id}` status endpoint needed?
- State machine for `cube_mv.status`: `CREATING → ACTIVE / ERROR` — how does fp-async detect the refresh status on the StarRocks side and update this table? (polling? callback?)
- This feedback loop is not described in the documentation.

---

### 3. Full Behavior of Dimension Column Reference Type (type=column)

The documentation describes the `expression` type (CASE WHEN), but for the `column` type it only mentions "direct column reference" without clarifying:

- When generating DDL, does `segment_value` simply take the raw column value?
- Is the column name an FP feature name or an Iceberg raw_events column name? In theory they are one-to-one, but this needs to be confirmed.

---

### 4. Column Name Source and Validation Timing for target_features

For the names in `target_features: ["txn_amount", "age"]`:

- Are these FP feature names or Iceberg `raw_events` column names? (In theory they are the same, but needs confirmation)
- If a feature exists in FP but SMT has not yet synced it to the Iceberg schema (a new feature with no data yet), what happens?
- **Validation timing**: validate and return an error at `POST /cube` time, or fail during MV refresh and write to `cube_mv.error_message`?

---

### 5. Multi-Tenant raw_events Table Structure (affects the FROM clause in MV DDL)

Two options, no final decision yet:

| Option | Iceberg table structure | MV DDL FROM clause |
|------|--------------|----------------|
| Shared table + tenant partition | `raw_events` PARTITIONED BY (tenant, day) | `FROM iceberg_catalog.db.raw_events WHERE tenant='sofi'` |
| Separate table per tenant | `{tenant}.event_result` (current dev_a setup) | `FROM iceberg_catalog.qaautotest.event_result` |

**The current dev_a deployment uses per-tenant tables** (`qaautotest.event_result`), while the system design document describes a shared table. The two are inconsistent; the production approach needs to be confirmed.

---

### 6. Whether MV Refresh Frequency Is Configurable

The system design specifies:

```sql
REFRESH ASYNC EVERY (INTERVAL 1 DAY)
```

However, TODO.md contains an open item:

> Confirm MV refresh frequency (daily or hourly?)

Switching to hourly would reduce query latency from "queryable after the following midnight" to "queryable within 1 hour," but CN Refresh resource consumption would increase approximately 24x. No final decision has been made.

---

## Priority Recommendations

| Gap | Why it is prioritized |
|------|----------|
| Stats API request/response schema | Must be finalized before dev starts writing code; otherwise frontend and backend will be misaligned |
| Cube status query API | MV creation is async; without this endpoint the UI cannot display progress |
| Multi-tenant raw_events table structure | Directly determines the MV DDL FROM clause and affects all deployed configurations |
| target_features validation timing | Affects error handling paths and user experience |
| MV refresh frequency | Affects resource planning and CN Refresh CronJob configuration |
