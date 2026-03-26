# CRE-6630 QA Security Deployment Record

This note records what was deployed, why it was changed from the original plan, how data flows through the system, what was verified, and how to inspect the running components.

## Goal

Deploy a testable CRE-6630 Iceberg pipeline in `qa-security` using plain YAML, with minimal impact to shared FP resources.

## Final architecture

### Namespaces and shared dependencies

- Deployment namespace: `qa-security`
- Shared FP MySQL used read-only for SMT metadata lookup: `fp-mysql.qa-security:3306`
- Shared Kafka finally used for the sink worker and source topic: `kafka3.duckdb:9092`
- Shared S3 bucket used for Iceberg data: `datavisor-dev-us-west-2-iceberg`
- Iceberg warehouse prefix used for isolation: `s3://datavisor-dev-us-west-2-iceberg/cre-6630/qa-security/`

### Deployed components

- `iceberg-catalog-mysql` in `qa-security`
  - Dedicated MySQL for Iceberg catalog metadata
  - Service: `iceberg-catalog-mysql`
  - StatefulSet: `iceberg-catalog-mysql`
- `iceberg-rest-catalog` in `qa-security`
  - Iceberg REST catalog backed by the dedicated MySQL and S3
  - Service: `iceberg-rest-catalog`
  - Deployment: `iceberg-rest-catalog`
- `iceberg-kafka-connect` in `qa-security`
  - Kafka Connect worker with Iceberg sink plugin + custom SMT
  - Service: `iceberg-kafka-connect`
  - Deployment: `iceberg-kafka-connect`
- `cre-6630-starrocks` in `qa-security`
  - Standalone StarRocks `allin1` deployment for QA validation
  - Service: `cre-6630-starrocks`
  - Deployment: `cre-6630-starrocks`
- `cre-6630-starrocks-init-sql` in `qa-security`
  - One-shot Job to register the Iceberg external catalog in StarRocks

## Why the architecture changed during deployment

### 1. No Helm

The original manual folder was chart-driven. It was converted to static YAML so the deployment could be applied directly with `kubectl`.

### 2. Dedicated Iceberg catalog MySQL added

The demo reuses one MySQL database for both:

- Iceberg catalog metadata
- feature metadata lookup for the SMT

For QA, these were separated to reduce coupling:

- FP MySQL remains read-only for SMT metadata lookup
- Iceberg catalog metadata goes to a dedicated MySQL created by this deployment

### 3. StarRocks operator plan replaced with standalone StarRocks

The original StarRocks YAML assumed the StarRocks operator CRD existed. It did not exist in `dev-a`, so operator-based resources could not be applied. A standalone `starrocks/allin1-ubuntu:latest` deployment was used instead to validate the end-to-end path.

### 4. Private images replaced with public runtime assembly

These private images were not pullable:

- `datavisor/iceberg-rest-catalog:1.6.0`
- `datavisor/kafka-connect-iceberg:latest`

They were replaced with public-image equivalents:

- `tabulario/iceberg-rest:1.6.0` plus an init container that downloads the MySQL JDBC driver
- `confluentinc/cp-kafka-connect-base:7.7.1` plus init containers that:
  - install `iceberg/iceberg-kafka-connect:1.9.2`
  - build the custom SMT JAR from source inside the Pod

### 5. Kafka changed from `qa-security` to `duckdb`

The first attempt used `kafka3.qa-security:9092`. That cluster is single-broker and the Iceberg sink failed because Kafka transactions could not initialize:

- connector registered successfully
- tasks failed with `Timeout expired while awaiting InitProducerId`

Root cause: the `qa-security` Kafka transaction state topic configuration is incompatible with single-broker transactional writes.

To unblock testing, Kafka Connect was moved to `kafka3.duckdb:9092`, which is a 3-broker cluster.

## Final data flow

1. Producer writes JSON events into Kafka topic `cre6630_fp_velocity.yysecurity` on `kafka3.duckdb:9092`
2. Kafka Connect consumes from that topic
3. The custom SMT `com.datavisor.demo.smt.FeatureResolverTransform` looks up feature metadata from `fp-mysql.qa-security:3306/yysecurity`
4. The Iceberg sink writes records into Iceberg table `yysecurity.event_result`
5. Iceberg REST catalog stores metadata in:
   - MySQL: `iceberg-catalog-mysql.qa-security:3306/iceberg_catalog`
   - S3: `s3://datavisor-dev-us-west-2-iceberg/cre-6630/qa-security/`
6. StarRocks reads the Iceberg table through external catalog `iceberg_catalog`

## Concrete runtime configuration

### Kafka Connect

- Bootstrap servers: `kafka3.duckdb:9092`
- Source topic: `cre6630_fp_velocity.yysecurity`
- Connector name: `iceberg-sink-yysecurity`
- Iceberg table: `yysecurity.event_result`
- SMT metadata JDBC URL: `jdbc:mysql://fp-mysql.qa-security:3306/yysecurity`
- SMT metadata user: `dv.ro`

### Iceberg REST catalog

- Warehouse: `s3://datavisor-dev-us-west-2-iceberg/cre-6630/qa-security/`
- JDBC URL: `jdbc:mysql://iceberg-catalog-mysql.qa-security:3306/iceberg_catalog`
- JDBC user: `iceberg`

### StarRocks

- Service: `cre-6630-starrocks`
- MySQL protocol port: `9030`
- HTTP port: `8030`
- Registered catalog name: `iceberg_catalog`

## What was applied

### Static manifests

- `00-namespace.yaml`
- `05-iceberg-catalog-mysql-secret.yaml`
- `06-iceberg-catalog-mysql.yaml`
- `10-iceberg-rest-catalog-secret.yaml`
- `11-iceberg-rest-catalog.yaml`
- `20-iceberg-kafka-connect.yaml`
- `30-starrocks.yaml`
- `31-starrocks-ops.yaml`

### Supporting runtime resources created during deployment

- Secret `iceberg-smt-mysql`
- ConfigMap `fp-feature-smt-source`
- Kafka topic `cre6630_fp_velocity.yysecurity` in namespace `duckdb`
- Connector `iceberg-sink-yysecurity` registered via Kafka Connect REST API

## Test procedure used

### 1. Infrastructure validation

Verified these became healthy:

- `iceberg-catalog-mysql-0`
- `iceberg-rest-catalog-*`
- `iceberg-kafka-connect-*`
- `cre-6630-starrocks-*`

### 2. Connector validation

Checked connector runtime state through Kafka Connect REST:

```bash
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config \
  exec -n qa-security deploy/iceberg-kafka-connect -- \
  curl -s http://localhost:8083/connectors/iceberg-sink-yysecurity/status
```

Confirmed:

- connector state: `RUNNING`
- task 0: `RUNNING`
- task 1: `RUNNING`

### 3. Produced test data

Produced sample events into `cre6630_fp_velocity.yysecurity` from the `duckdb` Kafka Pod.

One event intentionally used a bad type for a feature mapped to `Long`, which showed up as an SMT warning and produced nulls for that field. A second event used compatible types and populated the mapped columns as expected.

### 4. Queried StarRocks

Verified the Iceberg catalog and table existed, then queried the data from StarRocks.

Final verification query:

```sql
SET CATALOG iceberg_catalog;
SELECT count(*) AS cnt FROM yysecurity.event_result;
SELECT event_id, event_type, user_id, amount, card_number FROM yysecurity.event_result LIMIT 10;
```

Observed result:

- row count: `2`
- rows included `cre6630-e1` and `cre6630-e2`
- the second row had `amount=123.45` and `card_number=4111111111111111`

## How to inspect the running system

### Pods and Services

```bash
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config get pods -n qa-security | grep -E 'iceberg|starrocks'
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config get svc -n qa-security | grep -E 'iceberg|starrocks'
```

### Iceberg REST catalog logs

```bash
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config logs -n qa-security deployment/iceberg-rest-catalog
```

### Kafka Connect logs

```bash
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config logs -n qa-security deployment/iceberg-kafka-connect
```

### StarRocks FE: how to look at it

There are two useful FE entry points exposed by Service `cre-6630-starrocks`:

- MySQL protocol: `9030`
- HTTP UI/API: `8030`

#### Query FE over MySQL protocol from inside the cluster

```bash
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config \
  exec -n qa-security deploy/cre-6630-starrocks -- \
  mysql -h 127.0.0.1 -P 9030 -u root --table
```

#### Port-forward FE to your laptop

```bash
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config \
  -n qa-security port-forward service/cre-6630-starrocks 19030:9030 18030:8030
```

Then:

- SQL: `mysql -h 127.0.0.1 -P 19030 -u root`
- HTTP: open `http://127.0.0.1:18030`

Useful FE checks:

```sql
SHOW CATALOGS;
SET CATALOG iceberg_catalog;
SHOW DATABASES;
SHOW TABLES FROM yysecurity;
SELECT count(*) FROM yysecurity.event_result;
```

## Shared-environment impact summary

### Read-only access to shared FP resources

- Read from `fp-mysql.qa-security:3306/yysecurity`
- Read from topic `cre6630_fp_velocity.yysecurity` on `duckdb` Kafka

### Writes performed by this deployment

- Kafka Connect internal topics in `duckdb` Kafka
- Topic `cre6630_fp_velocity.yysecurity` used for test data
- Iceberg catalog metadata in dedicated MySQL `iceberg-catalog-mysql`
- Iceberg data and metadata under S3 prefix `cre-6630/qa-security/`
- StarRocks internal metadata inside the standalone FE Pod

### No direct writes to shared FP data stores

- No writes to `fp-mysql`
- No writes to the original `qa-security_fp_velocity.yysecurity` topic

## Known caveats

- The current StarRocks deployment is QA-only standalone mode, not the desired production shape
- Kafka is borrowed from `duckdb`, so topic naming must stay isolated
- The register Job YAML still exists, but connector registration was finalized through direct Kafka Connect REST calls during debugging
- The first test event intentionally used mismatched feature types, so some mapped columns became null; this was expected after reading the SMT warning logs

## Recommended next steps

- Convert the final successful runtime config back into Helm values for repeatable deploys
- Decide whether to keep reusing `duckdb` Kafka or create a dedicated 3-broker Kafka namespace
- If this needs long-term use, replace standalone StarRocks with operator-based or managed topology
