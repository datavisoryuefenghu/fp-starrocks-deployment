# StarRocks CN HA/Scaling Strategy Design

> 设计目标：覆盖三种 CN 需要 HA/Scaling 的场景，统一使用 dcluster 作为扩缩容机制。
>
> **当前状态**：Scenario 1（MV 并发峰值）已评估为极低概率场景，实现已 **DEFERRED**。当前活跃场景为 Scenario 2（Ad-hoc 重查询）和 Scenario 3（夜间 Refresh 隔离）。

## Context

Current state: 1 CN on-demand (m5.2xlarge, 8C/32Gi). Need HA strategy for three scenarios. CTO prefers proactive dcluster-based scaling — fp-async/FE judges whether a query needs extra resources BEFORE executing, then proactively calls dcluster to launch CN nodes.

---

## The Three Scenarios

| # | Scenario | Query type | CN load | Frequency |
|---|----------|-----------|---------|-----------|
| 1 | MV query concurrency spike | MV (lightweight, ~200KB) | Low per query, high aggregate | Continuous, unpredictable |
| 2 | Ad-hoc heavy query (no MV) | Raw Parquet scan (130K files) | Very high per query | Infrequent, fp-async knows beforehand |
| 3 | Night refresh + query coexistence | Refresh = heavy batch; query = light | Refresh consumes 100% CN | Daily, predictable schedule |

**Additional edge case**: MV partial coverage (MV exists but doesn't cover full window). FE may do partial MV + partial raw scan. This falls under Scenario 2 behavior — fp-async can detect via `cube_mv` status/coverage and classify accordingly.

---

## Architecture: Three Warehouses

三个 warehouse 仍然必要，核心原因是 **on-demand vs spot 隔离**：用户 MV 查询不能被路由到 spot CN（spot 被回收 = query 失败）。Warehouse 边界强制保证这一点。refresh_wh 与 adhoc_wh 理论上可合并为 `spot_wh`，但保持独立可避免 refresh 与 adhoc 同时触发时竞争资源，lifecycle 管理也更清晰。

```
                        fp-async
                  ┌───────┴────────┐
                  │ QueryClassifier │
                  │ MV hit? ad-hoc? │
                  └──┬──────────┬──┘
                     │          │
               MV path     Ad-hoc path
               (JDBC)      1. dcluster launch CN
                            2. wait RUNNING (~3-5min)
                            3. register CN in adhoc_wh
                            4. execute query
                            5. teardown CN
                     │          │
              ┌──────▼──────────▼────────────────────┐
              │           StarRocks FE                 │
              └──┬──────────┬──────────┬──────────────┘
                 │          │          │
        ┌────────▼───┐ ┌───▼──────┐ ┌─▼───────────┐
        │ query_wh   │ │refresh_wh│ │ adhoc_wh    │
        │ CN x1      │ │ CN x0-2  │ │ CN x0-2     │
        │ Always-on  │ │ Nightly  │ │ On-demand   │
        │ on-demand  │ │ CronJob  │ │ dcluster    │
        │ [scaling   │ │ +dcluster│ │ (fp-async   │
        │  DEFERRED] │ │ spot CN  │ │  triggered) │
        │ MV queries │ │ MV refr. │ │ raw Parquet │
        └────────────┘ └──────────┘ └─────────────┘
             on-demand      spot          spot
                 │          │          │
                 └──────────▼──────────┘
                       Iceberg on S3
              (iceberg-rest-catalog:8181 → S3)
```

### Warehouse 路由机制

StarRocks FE 维护 `warehouse → CN list` 映射，`SET WAREHOUSE` 后查询 fragments 只分发给该 warehouse 下的 CN，物理上完全隔离。

**CN 注册**（dcluster 启动后执行）：
```sql
-- 将新启动的 spot CN 注册到指定 warehouse
ALTER SYSTEM ADD COMPUTE NODE 'host:9050' TO WAREHOUSE 'refresh_wh';
ALTER SYSTEM ADD COMPUTE NODE 'host:9050' TO WAREHOUSE 'adhoc_wh';
```

**查询路由**（fp-async JDBC session 级别）：
```sql
-- MV 查询：走 always-on CN
SET WAREHOUSE = 'query_wh';
SELECT ... FROM mv_table ...;

-- Ad-hoc 重查询：走临时 spot CN
SET WAREHOUSE = 'adhoc_wh';
SELECT ... FROM raw_events ...;
```

**MV Refresh 绑定**（DDL 级别，永久生效）：
```sql
-- Refresh 任务永远跑在 refresh_wh
CREATE MATERIALIZED VIEW ...
PROPERTIES("warehouse"="refresh_wh");
```

---

## Spot 回收自动恢复（dcluster Rescale 机制）

Scenario 2 和 3 使用 spot CN，spot 被 AWS 回收是必须处理的场景。dcluster 已实现 **rescale 机制**：spot 回收后不销毁 cluster，而是自动申请新 spot 节点，让 K8s 自动调度 Pending pod。上层（fp-async / FE）无感。

### Rescale 流程

```
T+0     AWS 回收 spot instance
        → node 消失
        → CN pod 被 evict → Pending (无可调度节点)
        → FE 心跳超时，标记 CN 不可用

T+5min  monitorStarRocksCNCluster cron 触发 (每 5 分钟)
        → pod count 0 < requested 1
        → rescaleAttempts < MAX (3)
        → 进入 rescaleStarRocksCNCluster()

        rescaleStarRocksCNCluster:
          1. status=RESCALING, rescaleAttempts++
          2. cancelSpotFleetRequest (取消旧 fleet)
          3. delete 旧 nodes 记录 (腾出 unique key)
          4. async: nodeService.launchK8sNodes(use_on_demand=false)
             → 新 Spot Fleet Request → 新 EC2 instance
             → 新 node 加入 K8s，同样的 taint

T+7min  新 node Ready
        → K8s Deployment 自动调度 Pending pod 到新 node
        → CN 启动 → 自动注册 FE → 心跳恢复
        → K8s Service DNS 不变 → fp-async 无感
        → status=RUNNING
```

### Status Flow

```
LAUNCHING → RUNNING → [spot 回收] → RESCALING → RUNNING
                                  → RESCALING → RUNNING
                                  → RESCALING → RUNNING   (最多 3 次)
                                  → 第 4 次 → TERMINATED
```

### 约束

- **30 分钟保护期**：cluster 创建后 30 分钟内不触发 rescale（避免启动阶段误判）
- **最多 3 次** rescale 重试，之后销毁
- 全程 spot，不切 on-demand

### 为什么 fp-async / FE 无需感知

| Layer | Reason |
|-------|--------|
| FE | CN 通过 `fe_address` 自动注册，FE 内部心跳感知上下线，CN 恢复后自动重新注册 |
| fp-async | 连接 K8s Service DNS，service 不变，pod 替换后自动路由。需要 fp-async 有 query 重试 |
| dcluster | 只负责确保有可用节点，其余交给 K8s Deployment controller 和 StarRocks 心跳 |

### 对各场景的影响

| Scenario | 影响 | 说明 |
|----------|------|------|
| Scenario 2 (ad-hoc) | 查询中 spot 回收 → CN 挂 → 查询失败 | fp-async 需要捕获异常并重试（rescale 恢复后重新执行） |
| Scenario 3 (refresh) | refresh 中 spot 回收 → refresh task 失败 | CronJob 需要检测失败并在 CN 恢复后重新触发 REFRESH |
| query_wh (always-on) | 不受影响 | query_wh 使用 on-demand，不走 spot |

---

## Per-Scenario Design

### Scenario 1: MV Query Concurrency Spike — **[DEFERRED]**

> **评估结论：此场景极难出现，实现暂缓。**
> 单用户一次请求顶多触发 5-10 个并发 MV 查询（对应 Dashboard 图表数），每次 50ms，单 CN（8C）轻松应对；多用户同时高并发需要数百用户同时刷页面才可能触达瓶颈。
> **如果真的出现压力，替代方案**：API 层加 rate limit + 手动扩容 CN，无需 QueryPoolScaler 的复杂度。

**Mechanism: dcluster (fp-async application-level autoscaling)**

| Aspect | Design |
|--------|--------|
| Trigger | fp-async tracks in-flight MV query count to query_wh |
| Who triggers | fp-async `QueryPoolScaler` service |
| Routing | fp-async default JDBC: `SET WAREHOUSE = 'query_wh'` |
| Scaling | base=1 CN on-demand, burst up to max=3 via dcluster |
| Reclamation | fp-async tears down extra CN after idle cooldown (10min) |

**Design**: fp-async maintains an `AtomicInteger inFlightCount` for query_wh. This is the application-level equivalent of HPA:

```
MV query arrives → inFlightCount.incrementAndGet()
  → if inFlightCount > SCALE_THRESHOLD (e.g., 10) AND no pending scale-up:
      → async: dcluster launch CN → register in query_wh
  → execute query on query_wh
  → inFlightCount.decrementAndGet()

Background: if extra CN idle for COOLDOWN_MINS (e.g., 10min):
  → deregister CN → dcluster destroy
```

**Trade-off acknowledged**: This is the "bridge" pattern — fp-async is manually reimplementing HPA's feedback loop. Accepted per CTO preference for unified dcluster approach. Key mitigations:
- Keep the bridge logic simple: single counter + threshold, no complex metrics
- dcluster Monitor 30min timeout as safety net for leaked CNs
- Scale-up is async (non-blocking) — current queries still execute on existing CN while new CN launches
- The 3-5min launch delay means burst CN helps *subsequent* queries, not the ones that triggered the scale-up. For MV queries (50ms each) this is acceptable — existing CN handles the burst, extra CN absorbs sustained load

### Scenario 2: Ad-hoc Heavy Query

**Mechanism: dcluster (proactive, fp-async triggered)**

| Aspect | Design |
|--------|--------|
| Trigger | fp-async `QueryClassifier`: no MV coverage for requested cube/window |
| Who triggers | fp-async `StarRocksCnScaler` service |
| Routing | `SET WAREHOUSE = 'adhoc_wh'` on this specific JDBC connection |
| Scaling | dcluster launches 1-2 spot CN, registers with FE in adhoc_wh |
| Reclamation | fp-async explicitly destroys after query completes |

#### 完整流程：三个阶段

**阶段一：判断（毫秒级，用户无感知）**

Stats API 请求进来，携带 `cube_id` + `time_window`：

```
fp-async 收到 Stats 请求
  → QueryClassifier 查 cube_mv 表：
      SELECT status, coverage FROM cube_mv WHERE cube_id = ?

  情况 A：status = ACTIVE 且 coverage 覆盖请求窗口
      → MV 命中，走 query_wh
      → SET WAREHOUSE='query_wh'; SELECT FROM mv_table
      → ~50ms 返回

  情况 B：status != ACTIVE，或 coverage 不足（新 tenant / 窗口超出 MV 范围）
      → 判定为 ad-hoc，进入阶段二
```

**阶段二：准备（~3-5min，用户等待，前端显示"数据处理中"）**

```
fp-async → dcluster: POST /launch/starrocks-cn/cluster (spot)
  dcluster: provision spot EC2 → bootstrap CN 进程

CN 启动后：
  CN 进程读 cn.conf 中的 fe_address，主动连接 FE 并发送心跳
  dcluster 返回 status=RUNNING + hostname:port

fp-async:
  ALTER SYSTEM ADD COMPUTE NODE 'host:9050' TO WAREHOUSE 'adhoc_wh'
  FE 将此 CN 加入 adhoc_wh 可用列表
```

**阶段三：执行（~5-10min）**

```
fp-async JDBC:
  SET WAREHOUSE = 'adhoc_wh';
  SELECT dimension, sum(measure)
  FROM iceberg_catalog.{tenant}.event_result
  WHERE event_time BETWEEN ? AND ?
  GROUP BY dimension;

FE:
  CBO 再次检查 MV（此时仍无）→ 回退 Iceberg 原表
  将查询拆成多个 fragments，分发给 adhoc_wh 下的 CN

CN 执行（MPP）：
  访问 iceberg-rest-catalog:8181
    → 读 snapshot + manifest，根据 event_time 做 partition pruning
  扫 S3 Parquet（pruned 后的子集，非全量 130K 文件）
  聚合，结果返回 FE coordinator → fp-async → 用户

执行完毕：
  fp-async: ALTER SYSTEM DROP COMPUTE NODE 'host:9050'
  fp-async: DELETE /terminate/starrocks-cn/{id}
```

**时间线**：
```
t=0        用户发起请求，判断无 MV（毫秒级）
t=0~3min   dcluster 拉 spot EC2，CN 启动，注册到 adhoc_wh
t=3~8min   CN 扫 Iceberg/S3，执行聚合
t=8~13min  结果返回用户
t=13min+   fp-async 销毁 CN
```

**Detailed Flow**:

```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────┐
│ fp-async │  │ dcluster │  │    FE    │  │    CN    │  │ Iceberg Catalog │
└────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────────┬────────┘
     │              │              │              │                 │
     │ Stats query arrives          │              │                 │
     │ QueryClassifier:             │              │                 │
     │ cube_mv.status ≠ ACTIVE      │              │                 │
     │              │              │              │                 │
     │ POST /cluster/launch/starrocks-cn (spot)    │                 │
     │─────────────>│              │              │                 │
     │              │ provision spot EC2           │                 │
     │              │ bootstrap CN proc            │                 │
     │              │              │  CN starts,  │                 │
     │              │              │<─────────────│                 │
     │              │              │ heartbeat    │                 │
     │ poll (30s)   │              │              │                 │
     │<─ ─ ─ ─ ─ ─ ─│              │              │                 │
     │ RUNNING      │              │              │                 │
     │              │              │              │                 │
     │ ALTER SYSTEM ADD COMPUTE NODE 'host:9050' TO WAREHOUSE 'adhoc_wh'
     │─────────────────────────────>│              │                 │
     │              │              │ adds CN to   │                 │
     │              │              │ adhoc_wh     │                 │
     │              │              │              │                 │
     │ SET WAREHOUSE='adhoc_wh'; SELECT ... FROM iceberg_catalog.event_result
     │─────────────────────────────>│              │                 │
     │              │              │ CBO: no MV,  │                 │
     │              │              │ fallback to  │                 │
     │              │              │ Iceberg table│                 │
     │              │              │ split fragments              │
     │              │              │─────────────>│                 │
     │              │              │              │ GET metadata    │
     │              │              │              │────────────────>│
     │              │              │              │ manifest+pruned │
     │              │              │              │ file list       │
     │              │              │              │<────────────────│
     │              │              │              │ scan S3 Parquet │
     │              │              │              │ (pruned subset) │
     │              │              │<─────────────│                 │
     │              │              │   results    │                 │
     │<─────────────────────────────│              │                 │
     │ results returned             │              │                 │
     │              │              │              │                 │
     │ ALTER SYSTEM DROP COMPUTE NODE 'host:9050'  │                 │
     │─────────────────────────────>│              │                 │
     │ DELETE /cluster/terminate/{id}              │                 │
     │─────────────>│              │              │                 │
     │              │ terminate EC2│              │                 │
```

**各层职责**：

| 层 | 职责 |
|----|------|
| **fp-async** | QueryClassifier 判断无 MV → 调 dcluster 启 spot CN → 轮询等待 RUNNING → 注册 CN 到 FE adhoc_wh → 执行查询 → 反注册 + 销毁 |
| **dcluster** | 拉起 spot EC2 → 启动 CN 进程 → 返回 hostname:port；不感知 StarRocks 内部逻辑 |
| **StarRocks FE** | 收到 ADD COMPUTE NODE → 更新 adhoc_wh CN list；收到查询 → CBO 尝试改写为 MV（无 MV 则回退 Iceberg 原表）→ 按 warehouse 分发 fragments 到 CN |
| **StarRocks CN** | 启动后主动向 FE 发心跳；收到 fragments → **先访问 Iceberg REST Catalog 读 metadata/manifest → partition pruning → 扫 S3 Parquet → 聚合 → 返回结果** |

**响应机制**：FE 采用 MPP 执行模型，query 拆成多个 fragments 分发给 adhoc_wh CN 并行执行。CN 读 Iceberg 数据的路径：

```
CN 收到 fragment
  → 访问 iceberg-rest-catalog:8181
      → 读 metadata.json + manifest list + manifest files
      → 根据 event_time 分区做 partition pruning（过滤大量文件）
  → 扫 S3 Parquet 数据文件（实际扫描量远少于全表 130K 文件）
  → 列式解码，执行聚合
  → 结果返回 FE coordinator → fp-async
```

**spot CN 启动后的网络依赖**（三个都必须可达）：
- `starrocks-fe:9030` — FE heartbeat + query distribution
- `iceberg-rest-catalog:8181` — Iceberg metadata（ad-hoc 查询的必要依赖）
- S3 (`datavisor-*-iceberg` bucket) — Parquet 数据文件读取

**dcluster Monitor conflict**: Configure 30min idle timeout for `starrocks-cn` type (vs 5min for Spark/Flink). fp-async always explicitly tears down; Monitor is safety net for leaked CNs.

**No warm pool**: Ad-hoc is infrequent. Don't pay for an idle CN. User accepts the 3-5min extra wait.

### Scenario 3: Night Refresh + Query Coexistence

**Mechanism: CronJob + dcluster (hybrid)**

| Aspect | Design |
|--------|--------|
| Trigger | CronJob at 01:50 UTC |
| Who triggers | CronJob script calls dcluster |
| Routing | MV DDL: `PROPERTIES("warehouse"="refresh_wh")` |
| Scaling | dcluster launches 1-2 spot CN for refresh_wh |
| Reclamation | Script monitors refresh completion, then destroys |

**Detailed Flow**:

```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────┐
│ CronJob  │  │ dcluster │  │    FE    │  │    CN    │  │ Iceberg Catalog │
└────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────────┬────────┘
     │              │              │              │                 │
     │ 01:50 UTC triggers           │              │                 │
     │ POST /cluster/launch/starrocks-cn (spot)    │                 │
     │─────────────>│              │              │                 │
     │              │ provision spot EC2           │                 │
     │              │ bootstrap CN proc            │                 │
     │              │              │  CN starts,  │                 │
     │              │              │<─────────────│                 │
     │              │              │  heartbeat   │                 │
     │ poll (30s)   │              │              │                 │
     │<─ ─ ─ ─ ─ ─ ─│              │              │                 │
     │ RUNNING      │              │              │                 │
     │              │              │              │                 │
     │ ALTER SYSTEM ADD COMPUTE NODE 'host:9050' TO WAREHOUSE 'refresh_wh'
     │─────────────────────────────>│              │                 │
     │              │              │ adds CN to   │                 │
     │              │              │ refresh_wh   │                 │
     │              │              │              │                 │
     │ REFRESH MATERIALIZED VIEW mv_name          │                 │
     │─────────────────────────────>│              │                 │
     │              │              │ MV props=    │                 │
     │              │              │ refresh_wh → │                 │
     │              │              │ dispatch task│                 │
     │              │              │─────────────>│                 │
     │              │              │              │ GET latest      │
     │              │              │              │ snapshot        │
     │              │              │              │────────────────>│
     │              │              │              │ yesterday's     │
     │              │              │              │ manifest files  │
     │              │              │              │<────────────────│
     │              │              │              │ scan S3 Parquet │
     │              │              │              │ GROUP BY → MV   │
     │              │              │              │ write daily部分  │
     │              │              │<─────────────│ task done       │
     │ poll last_refresh_state      │              │                 │
     │<─────────────────────────────│ ACTIVE       │                 │
     │              │              │              │                 │
     │ ALTER SYSTEM DROP COMPUTE NODE 'host:9050'  │                 │
     │─────────────────────────────>│              │                 │
     │ DELETE /cluster/terminate/{id}              │                 │
     │─────────────>│              │              │                 │
     │              │ terminate EC2│              │                 │
```

**各层职责**：

| 层 | 职责 |
|----|------|
| **CronJob** | 01:50 UTC 启动 → 调 dcluster 启 spot CN → 轮询 RUNNING → 注册 CN 到 refresh_wh → 触发 REFRESH → 轮询 `last_refresh_state` 直到 ACTIVE → 反注册 + 销毁 |
| **dcluster** | 拉起 spot EC2 → 启动 CN 进程 → 返回 hostname:port |
| **StarRocks FE** | 收到 REFRESH 命令 → 查 MV DDL 中 `warehouse=refresh_wh` → 分发 refresh task 到 refresh_wh CN |
| **StarRocks CN** | 执行 MV refresh（本质是 INSERT INTO SELECT）：**访问 Iceberg REST Catalog 读昨日新分区的 manifest → 扫 S3 Parquet → 计算 GROUP BY 聚合 → 写 MV daily 分区**（几百行/天，几 KB）；refresh 期间 100% CPU，完全不影响 query_wh |

**响应机制**：MV refresh 是异步 Task，`SHOW MATERIALIZED VIEWS` 可查 `last_refresh_state`（REFRESHING → ACTIVE/FAILED）。CN 读 Iceberg 昨日分区的路径：

```
CN 收到 refresh task
  → 访问 iceberg-rest-catalog:8181
      → 读最新 snapshot，找昨日新增 manifest
      → 获取昨日 Parquet 文件列表（约 1000 万行/天/tenant）
  → 扫 S3 Parquet
  → GROUP BY (dimension × measure)
  → 写 MV daily 分区（几百行，几 KB）
  → 通知 FE：refresh task 完成
```

CronJob 轮询 `last_refresh_state`，ACTIVE = 成功，FAILED = 告警并重试。refresh_wh 与 query_wh CN 物理隔离，3AM 用户查询打到 query_wh always-on CN，不受 refresh 影响。

**Why warehouse isolation is the complete solution**: query_wh and refresh_wh have separate CN pools. Refresh CN runs 100% CPU doing S3 scans — this has ZERO impact on query_wh. A 3AM query hits the always-on query_wh CN at normal 50ms latency.

---

## Decision Summary: Unified dcluster

| Scenario | Status | Mechanism | Trigger Signal | dcluster Role |
|----------|--------|-----------|---------------|---------------|
| MV burst | **DEFERRED** | dcluster (fp-async counter) | `inFlightCount > threshold` | Launch burst CN for query_wh |
| Ad-hoc | **Active** | dcluster (fp-async proactive) | `cube_mv.status != ACTIVE` | Launch dedicated spot CN for adhoc_wh |
| Refresh | **Active** | CronJob + dcluster | Cron schedule 01:50 UTC | Launch spot CN for refresh_wh |

当前活跃场景：Scenario 2 & 3。fp-async 触发 Scenario 2，CronJob 触发 Scenario 3。Scenario 1 等出现真实压力时再实现。

---

## dcluster Changes Required

dcluster 目前支持 `spark` 和 `flink` 两种 cluster type，新增 `starrocks-cn` 是一次标准的 additive 扩展，不修改现有逻辑。

### 新增 API Endpoints

**Controller**: `ClusterController.java`

```java
// 启动 spot CN
@PostMapping("/launch/starrocks-cn/cluster")
public Integer launchStarRocksCNCluster(@RequestBody ClusterEntity config)

// 查询状态
@GetMapping("/status/starrocks-cn/cluster/{clusterId}")
public String getStarRocksCNClusterStatus(@PathVariable int clusterId)

// 销毁
@DeleteMapping("/terminate/starrocks-cn/{clusterId}")
public String terminateStarRocksCNCluster(@PathVariable int clusterId)
```

### 新增 Service 方法

**Interface**: `ClusterService.java` + **Implementation**: `ClusterServiceImpl.java`

| 方法 | 参考 | 说明 |
|------|------|------|
| `launchStarRocksCNCluster(ClusterEntity)` | `launchFlinkCluster()` | provision spot EC2 → helm install → 返回 cluster id |
| `destroyStarRocksCNCluster(int clusterId)` | `destroyFlinkCluster()` | helm uninstall → 删 namespace → 更新 DB status |
| `getStarRocksCNClusterStatus(int clusterId)` | `getFlinkClusterStatus()` | 查 DB status，轮询用 |
| `checkIfStarRocksCNClusterRunning(ClusterEntity, boolean)` | `checkIfFlinkClusterRunning()` | 检查 CN pod 是否 Running；**无 master pod**，只检查 worker pod |

CN 与 Flink 的关键差异：
- **无 master node**：CN 是单角色 worker，不需要检查 jobmanager pod
- **无 task 状态**：不需要调 REST API 检查运行中的 task（不像 Flink）
- **健康检查**：只需确认 CN pod Running + 向 FE 心跳成功（可通过 FE SQL `SHOW COMPUTE NODES` 验证）

### Monitor.java 改造

#### Monitor 入口点

StarRocks CN 健康检查有 3 个入口，逻辑一致：

| Method | Interval | Scope |
|--------|----------|-------|
| `monitorStarRocksCNCluster` | **5 min** | 专查 StarRocks CN (RUNNING/LAUNCHING/RESCALING) |
| `checkClusterJob` | 20 min | 通用，查所有 cluster 类型 (externalNamespace) |
| `ClusterCronMonitorHelper.processClusterNamespace` | 20 min | 通用，按 namespace 查 |

所有入口共享同一判断：`pod count < requested → rescale (< 3次) / destroy (>= 3次)`

#### 核心逻辑：rescale 优先，destroy 兜底

`checkClusterJob()` 方法新增 `starrocks-cn` 分支。**关键变化：不再直接 destroy，而是先 rescale（最多 3 次），超过才 destroy**：

```java
if (entity.getType().equalsIgnoreCase("spark")) {
    if (!clusterService.checkIfSpark3ClusterRunning(entity, true))
        clusterService.terminateSparkCluster2(entity.getId());
} else if (entity.getType().equalsIgnoreCase("starrocks-cn")) {
    if (!clusterService.checkIfStarRocksCNClusterRunning(entity, true)) {
        if (entity.getRescaleAttempts() < MAX_RESCALE_ATTEMPTS) {  // MAX = 3
            clusterService.rescaleStarRocksCNCluster(entity);
            // rescale: status=RESCALING, rescaleAttempts++,
            // cancelSpotFleet → launchK8sNodes → 新 spot → K8s 自动调度
        } else {
            clusterService.destroyStarRocksCNCluster(entity.getId());
            // 超过 3 次 → TERMINATED
        }
    }
} else {  // flink
    if (!clusterService.checkIfFlinkClusterRunning(entity, true))
        clusterService.destroyFlinkCluster(entity.getId());
}
```

同样的 rescale 优先逻辑也在 `ClusterCronMonitorHelper.processClusterNamespace()` 和 `monitorStarRocksCNCluster()` 中实现。

#### 约束

- **30min grace period**：`checkClusterJob` 跳过创建不足 30min 的 cluster（避免启动阶段误判），对 `starrocks-cn` 同样适用
- **rescaleAttempts 成功后不归零**：如果 rescale 后 CN 恢复正常，再次 spot 回收仍会消耗剩余次数
- fp-async 会在查询完成后主动销毁，Monitor 的 30min 只是泄漏 CN 的兜底

### 新增 Helm Chart

**Path**: `/helm/starrocks-cn/`

```
helm/starrocks-cn/
├── Chart.yaml
├── values.yaml           # useDedicated, cn.taint, cn.image, cn.replicas, cn.feAddress, cn.cacheSizeLimit
└── templates/
    ├── _helpers.tpl       # fullnameOverride logic
    ├── configmap.yaml     # cn.conf + fe_address
    ├── deployment.yaml    # CN Deployment + nodeAffinity/toleration
    └── service.yaml       # ClusterIP:9050 (heartbeat)
```

关键 values（对应 `ClusterEntity` 字段）：
- `cn.replicas` ← `workers`
- `cn.image` ← StarRocks CN 镜像版本
- `cn.feAddress` ← FE service 地址（写入 `cn.conf`）
- `cn.cacheSizeLimit` ← CN 本地缓存大小
- `useDedicated` ← 是否使用 taint 绑定（模式 A=true，模式 B=false）
- `cn.taint` ← cluster name（模式 A 下 nodeAffinity 匹配用）

### 需要改造的文件汇总

| 文件 | 改动类型 | 说明 |
|------|---------|------|
| `ClusterController.java` | 新增 3 个 endpoints | launch / status / terminate |
| `ClusterService.java` | 新增 5 个接口方法 | launch / destroy / status / check / rescale + getAllActive |
| `ClusterServiceImpl.java` | 实现 5 个方法 | 支持模式 A（拉 spot EC2）和模式 B（已有 node） |
| `ClusterStatus.java` | 新增状态 | +RESCALING |
| `ClusterEntity.java` | 新增字段 | +rescaleAttempts |
| `ClusterRepository.java` | 新增查询 | +findAllActiveStarRocksCNClusters |
| `Monitor.java` | 新增 cron + 修改分支 | +monitorStarRocksCNCluster (5min), checkClusterJob 中 rescale 优先 |
| `ClusterCronMonitorHelper.java` | 修改 if/else 分支 | rescale 优先逻辑 |
| `AppConfig.java` | 新增配置 | +starRocksCNImage |
| `/helm/starrocks-cn/` | 新建 Helm chart | CN deployment + configmap + service，无 master |
| `application.properties` | 新增配置项 | StarRocks CN 镜像 repo/tag 默认值 |
| `db.20250707_cluster_rescale_attempts.xml` | 新增 Liquibase migration | `ALTER TABLE clusters ADD COLUMN rescale_attempts INT NOT NULL DEFAULT 0` |
| `db.master_changelog.xml` | 引入新 migration | include 新 changeset |

---

## fp-async Code Changes

**New classes** (following existing patterns in `com.datavisor.replay.cluster`):

| Class | Based on | Status | Purpose |
|-------|----------|--------|---------|
| `QueryClassifier` | New | **Active** | Check cube_mv status, classify MV vs ad-hoc |
| `StarRocksCnScaler` | `ClusterManager` | **Active** | dcluster lifecycle for ad-hoc/refresh CN |
| `StarRocksCnCluster` | `FlinkCluster` | **Active** | CN cluster model |
| `QueryPoolScaler` | New | **DEFERRED** | Tracks in-flight MV query count, triggers dcluster for query_wh burst CN |

**Modified files**:

| File | Change |
|------|--------|
| `InfraService.java` | Add starrocks-cn launch/status/destroy methods |
| `InfraServiceRestImpl.java` | Implement REST calls to dcluster |
| `32-starrocks-init.yaml` | Add `CREATE WAREHOUSE query_wh/refresh_wh/adhoc_wh` |
| `starrocks-cn.yaml` (Helm) | Split into query/adhoc CN pool templates |

---

## Resource Group (defense-in-depth, all scenarios)

Regardless of warehouse isolation, add resource groups as safety net:

```sql
-- MV queries: high priority, guaranteed resources
CREATE RESOURCE GROUP rg_mv
  TO (user = 'fp_async_mv')
  WITH (cpu_weight=10, concurrency_limit=50);

-- Ad-hoc queries: limited, prevent CN explosion
CREATE RESOURCE GROUP rg_adhoc
  TO (user = 'fp_async_adhoc')
  WITH (cpu_weight=1, concurrency_limit=3, big_query_cpu_second_limit=120);
```

---

## Implementation Phases

1. **Warehouse isolation** (prerequisite): Create 3 warehouses in StarRocks init, configure fp-async JDBC defaults, resource groups
2. **dcluster `starrocks-cn` type**: Add new cluster type to dcluster infra service (coordinate with infra team)
3. **CronJob + dcluster for refresh_wh**: Implement CronJob script that calls dcluster for spot CN
4. **fp-async proactive dcluster for adhoc_wh**: Implement QueryClassifier + StarRocksCnScaler
5. ~~**fp-async dcluster for query_wh burst**~~ **[DEFERRED]**: Implement QueryPoolScaler when real MV concurrency pressure is observed

Phase 1 is independent of dcluster changes. Phase 2 is the critical dependency — blocks Phases 3-4. If dcluster team is slow, Phase 1 still delivers warehouse isolation value, and refresh can use CronJob `kubectl scale` as interim.

---

## Risks

| Risk | Mitigation |
|------|------------|
| dcluster team doesn't prioritize `starrocks-cn` type | Phase 1 proceeds independently; refresh uses CronJob `kubectl scale` as interim |
| CN registration latency after scale-up | StarRocks Operator handles auto-registration; readiness probe checks FE |
| fp-async crashes during ad-hoc, leaking dcluster CN | Monitor 30min timeout as safety net；monitorStarRocksCNCluster 每 5min 检查；daily audit job |
| dcluster Monitor reclaims CN during long ad-hoc query | 30min grace period + fp-async 主动销毁；rescale 机制不会直接 destroy，给 CN 恢复机会 |
| spot 回收导致查询中断 | rescale 机制自动恢复（最多 3 次）；fp-async 需实现 query 重试逻辑 |
| 连续 3 次 rescale 失败 → cluster TERMINATED | fp-async 需处理 TERMINATED 状态：捕获异常 → 重新 launch 新 cluster（而非依赖已 TERMINATED 的） |
| QueryPoolScaler bridge logic adds complexity | Keep simple: single counter + threshold. No complex metrics or state machines |
| spot CN 无法访问 iceberg-rest-catalog:8181 | 验证 dcluster 启动的 EC2 与 K8s service 网络可达；可能需要配置 VPC peering 或 NodePort |

---

## Background: Why Unified dcluster (vs Mixed Approach)

The presentation doc (Section 13.5) argued against dcluster for CN scaling due to three issues:
1. **Trigger mechanism missing** — solved: fp-async is the trigger (knows query type + in-flight count)
2. **Platform re-release risk** — accepted: new `starrocks-cn` type is additive, not modifying existing Spark/Flink behavior
3. **Monitor conflict** — solved: configurable idle timeout per cluster type (30min for starrocks-cn)；且已实现 rescale 优先机制（不直接 destroy，先尝试恢复）

CTO preference: unified system, fp-async as intelligent trigger layer. Trade-off: Scenario 1 (MV burst) uses application-level autoscaling instead of HPA, which is more complex but keeps the architecture consistent.


---

# 附录：dcluster StarRocks CN 改动记录

## 改动概览

在 dcluster 中新增 `starrocks-cn` cluster type，复用 Flink 的模式 A（拉 spot EC2 → kubeadm join → taint 绑定 → helm install）。
与 Flink 的关键差异：**无 master node**，只有 worker pods。

## 修改的文件

### dcluster Java 代码

| 文件 | 改动 |
|------|------|
| `ClusterController.java` | +3 endpoints: POST `/launch/starrocks-cn/cluster`, GET `/status/starrocks-cn/cluster/{id}`, DELETE `/terminate/starrocks-cn/{id}` |
| `ClusterStatus.java` | +RESCALING 状态 |
| `ClusterEntity.java` | +rescaleAttempts 字段 |
| `ClusterService.java` | +5 接口方法: launch, destroy, status, check, **rescale** + getAllActiveStarRocksCNClusters |
| `ClusterServiceImpl.java` | +5 实现，支持模式 A（拉 EC2）和模式 B（已有 node）；rescale 含旧 fleet 清理 |
| `ClusterRepository.java` | +findAllActiveStarRocksCNClusters query |
| `Monitor.java` | +`monitorStarRocksCNCluster` (5min cron)；`checkClusterJob` 中 destroy → **rescale 优先** |
| `ClusterCronMonitorHelper.java` | `processClusterNamespace()` 中 destroy → **rescale 优先** |
| `AppConfig.java` | +1 field: `starRocksCNImage` |

### DB Migration

| 文件 | 说明 |
|------|------|
| `db.20250707_cluster_rescale_attempts.xml` | `ALTER TABLE clusters ADD COLUMN rescale_attempts INT NOT NULL DEFAULT 0` |
| `db.master_changelog.xml` | 引入新 migration |

### Helm Chart（新建）

```
helm/starrocks-cn/
├── Chart.yaml
├── values.yaml           # useDedicated, cn.taint, cn.image, cn.replicas, cn.feAddress, cn.cacheSizeLimit
└── templates/
    ├── _helpers.tpl       # fullnameOverride logic
    ├── configmap.yaml     # cn.conf + fe_address
    ├── deployment.yaml    # CN Deployment + nodeAffinity/toleration
    └── service.yaml       # ClusterIP:9050 (heartbeat)
```

### 测试用配置

| 文件 | 说明 |
|------|------|
| `application-localtest.properties` | 本地测试 profile，用 MySQL on localhost:13306 |

## 两种启动模式

### 模式 A：拉 spot EC2 + taint 绑定（默认）

```
launchStarRocksCNCluster(entity)
  ├─ launchNewNode=true (默认)
  └─ launchStarRocksCNWithNewNodes()
       ├─ nodeService.launchK8sNodes()
       │   config: use_on_demand_master=false  ← 关键：跳过 master EC2
       │   → AwsClusterManager.launchSpotFleetToK8s()
       │   → EC2 userdata: kubeadm join + taint=clustername:NoSchedule
       └─ asyncLaunchStarRocksCN(config, entity)
            ├─ createNamespace
            └─ helm install --set useDedicated=true,cn.taint=starrocks-xxx
                 → pod nodeAffinity 匹配 taint → 调度到 spot EC2
```

### 模式 B：已有 node，直接 helm install

```
launchStarRocksCNCluster(entity)
  ├─ launchNewNode=false
  └─ launchStarRocksCNWithExistingNode()
       └─ asyncLaunchStarRocksCN(null, entity)
            ├─ 跳过 nodeService.launchK8sNodes()
            └─ helm install --set useDedicated=false
                 → K8s scheduler 自由调度
```

## 销毁流程

```
destroyStarRocksCNCluster(clusterId)
  └─ asyncDestroyStarRocksCNCluster(entity)
       ├─ helm uninstall / delete namespace
       └─ if launchNewNode=true:
            nodeService.destroyK8sNodes()  ← 清理 spot EC2
```

## Monitor 兜底 + Spot Rescale

三个 monitor 入口（5min 专用 + 2×20min 通用），共享同一判断逻辑：

```
pod count < requested?
  YES → rescaleAttempts < 3?
    YES → rescaleStarRocksCNCluster (取消旧 fleet → 申请新 spot → K8s 自动调度)
    NO  → destroyStarRocksCNCluster → TERMINATED
  NO  → 正常，不操作
```

- 30 分钟保护期：cluster 创建后 30min 内不触发 rescale（避免启动阶段误判）
- rescale 成功后 status 回到 RUNNING，pod 恢复正常
- fp-async 主动销毁是正常路径，Monitor 的 30min 只是泄漏 CN 的兜底

## API 示例

```bash
# Launch (Mode A, 默认拉 spot EC2)
curl -X POST http://dcluster:8080/cluster/launch/starrocks-cn/cluster \
  -H "Content-Type: application/json" \
  -d '{
    "tenant": "client_abc",
    "workers": 1,
    "workerCpu": "8",
    "workerMemory": "32",
    "extraConfigs": "{\"feAddress\":\"starrocks-fe.duckdb.svc:9030\",\"cacheSizeLimit\":\"20Gi\"}"
  }'
# → 返回 cluster ID (int)

# Launch (Mode B, 不拉 EC2)
curl -X POST http://dcluster:8080/cluster/launch/starrocks-cn/cluster \
  -H "Content-Type: application/json" \
  -d '{
    "tenant": "client_abc",
    "workers": 1,
    "workerCpu": "8",
    "workerMemory": "32",
    "launchNewNode": false,
    "extraConfigs": "{\"feAddress\":\"starrocks-fe.duckdb.svc:9030\"}"
  }'

# Status
curl http://dcluster:8080/cluster/status/starrocks-cn/cluster/{id}
# → JSON with status, name, serviceAddress, etc.

# Terminate
curl -X DELETE http://dcluster:8080/cluster/terminate/starrocks-cn/{id}
# → "0" on success

# 集群内部地址
# http://cluster.duckdb.svc.cluster.local:8080/cluster/...
```

## 集群名格式

```
starrocks-{env}-{tenant}-{id}
例: starrocks-duckdb-client_abc-42
```

## 部署 Checklist

1. **先跑 Liquibase migration** — `ALTER TABLE clusters ADD COLUMN rescale_attempts INT NOT NULL DEFAULT 0`
2. Build + push Docker image
3. Update deployment image
4. 验证: `MONITOR_STARROCKS_CN_CLUSTER cronjob triggered` 出现在日志中（确认 5min cron 生效）

## 部署前状态快照

见 `docs/dcluster-current-state.md`

- Image: `docker-registry.dv-api.com/cloud/dcluster-deployment:DV.202509C.External_DAPP73-8b81ca4`
- Helm release: `dcluster-deployment` revision 37
- 回滚: `helm rollback dcluster-deployment 37 -n duckdb`
