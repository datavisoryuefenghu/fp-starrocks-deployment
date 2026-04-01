# charts-iceberg — Part 1: Iceberg Storage Pipeline

Helm chart that deploys the shared Iceberg storage infrastructure for the Feature Platform.

**Deploy once per cluster.** All tenants share the same Kafka Connect workers and Iceberg REST Catalog. Per-tenant connectors are registered dynamically by FP Java, not by this chart.

## What This Chart Deploys

| Resource | Description |
|----------|-------------|
| `iceberg-catalog-init` Job | One-time post-install Job: creates `iceberg_catalog` DB in FP MySQL |
| `iceberg-rest-catalog` Deployment | Iceberg REST Catalog server backed by FP MySQL |
| `iceberg-rest-catalog` Service | ClusterIP on port 8181 |
| `iceberg-kafka-connect` Deployment | Kafka Connect workers with Iceberg connector + SMT installed |
| `iceberg-kafka-connect` Service | ClusterIP on port 8083 |

**Pre-existing Secret required (create before install):**

| Secret name | Keys | Used by |
|-------------|------|---------|
| `iceberg-rest-jdbc` (configurable) | `jdbc-user`, `jdbc-password` | REST catalog pod, catalog-init Job |

### SMT Build

The `FeatureResolverTransform` SMT (`files/FeatureResolverTransform.java`) is compiled at pod startup by an init container using Maven. It resolves integer feature IDs in the Kafka message's `featureMap` field into named columns by querying the per-tenant FP MySQL DB.

## Prerequisites

- FP MySQL is reachable from the cluster (the `iceberg_catalog` DB will be created by the init Job)
- Kafka bootstrap servers are reachable
- The K8s node IAM role (or pod IAM role) has S3 read/write access to the warehouse bucket
- Helm 3.x: `brew install helm`
- The `iceberg-rest-jdbc` Secret (or whatever name you set in `iceberg.restCatalog.jdbcSecret.name`) must exist in the cluster before installing:
  ```bash
  kubectl create secret generic iceberg-rest-jdbc \
    --from-literal=jdbc-user=iceberg \
    --from-literal=jdbc-password=<password>
  ```

## Deploy

```bash
# 1. Create the pre-existing secret (once per cluster)
kubectl create secret generic iceberg-rest-jdbc \
  --from-literal=jdbc-user=iceberg \
  --from-literal=jdbc-password=<password>

# 2. Validate the chart
helm lint ./charts-iceberg

# 3. Dry run — inspect all generated manifests
helm template fp-iceberg ./charts-iceberg \
  --set fpMysql.host=fp-mysql.production \
  --set kafkaConnect.bootstrapServers=kafka:9092 \
  --set iceberg.restCatalog.s3.bucket=datavisor-prod-iceberg \
  --set iceberg.restCatalog.s3.warehousePrefix=s3://datavisor-prod-iceberg/cre-6630/

# 4. Install
helm upgrade --install fp-iceberg ./charts-iceberg \
  --set fpMysql.host=fp-mysql.production \
  --set kafkaConnect.bootstrapServers=kafka:9092 \
  --set iceberg.restCatalog.s3.bucket=datavisor-prod-iceberg \
  --set iceberg.restCatalog.s3.warehousePrefix=s3://datavisor-prod-iceberg/cre-6630/
```

Or use a per-environment values file (see per-environment directories for examples):

```bash
helm upgrade --install fp-iceberg ./charts-iceberg -f awsuswest2proda/values.yaml
```

## Values Reference

```yaml
fpMysql:
  host: ""                        # Required — FP MySQL K8s hostname (e.g. fp-mysql.production)
  port: 3306
  icebergCatalogDb: iceberg_catalog

iceberg:
  restCatalog:
    image: tabulario/iceberg-rest:1.6.0
    replicas: 1
    jdbcSecret:
      name: iceberg-rest-jdbc     # Name of the pre-existing K8s Secret (jdbc-user, jdbc-password)
    s3:
      bucket: ""                  # Required — S3 bucket name
      region: us-west-2
      warehousePrefix: ""         # Required — full S3 URI (e.g. s3://bucket/path/)
    resources: ...

kafkaConnect:
  image: confluentinc/cp-kafka-connect:7.7.1
  bootstrapServers: ""            # Required — Kafka brokers (e.g. kafka:9092)
  replicationFactor: 3
  icebergConnectorVersion: "1.9.2"
  connector:
    tasksMax: 2
    commitIntervalMs: 600000      # 10 minutes (production default)
    smtRefreshIntervalMs: 60000   # How often SMT reloads feature metadata from MySQL
  # SMT credentials not in values — managed by FP Java via application.yaml
  resources: ...
```

## Design Decisions

**FP MySQL instead of a dedicated MySQL pod.** The Iceberg REST Catalog stores its metadata in a new `iceberg_catalog` database on the existing FP MySQL instance. No separate MySQL StatefulSet is needed.

**Per-tenant connectors registered by FP Java, not Helm.** This chart only deploys the shared Kafka Connect workers. Each tenant's connector (`iceberg-sink-<tenant>`) is registered by `IcebergService.registerConnector()` when a tenant is provisioned via `APTenantService.createTenant()`. To backfill existing tenants, call:

```bash
curl -X POST https://<fp-api>/iceberg/connector/batch \
  -H "Content-Type: application/json" \
  -d '{"tenants": ["tenant-a", "tenant-b", ...]}'
```

**SMT JDBC URL is derived at runtime.** The `FeatureResolverTransform` queries `jdbc:mysql://<fpMysql.host>/<tenantName>` — one URL per tenant, injected into each connector config by `IcebergService`. SMT credentials (user + password) are managed entirely by FP Java via `application.yaml` and do not appear in this chart.

## After Deploy

1. Confirm pods are running: `kubectl get pods | grep iceberg`
2. Enable Iceberg in FP application config and set the Kafka Connect + catalog URLs:
   ```yaml
   isEnableIceberg: true
   icebergKafkaConnectUrl: "http://iceberg-kafka-connect:8083"
   icebergCatalogUrl: "http://iceberg-rest-catalog:8181"
   ```
3. Run the backfill API call to register connectors for all existing tenants
4. After one commit interval (~10 min), verify Parquet files appear in S3 under `<warehousePrefix>/<tenantName>/`
