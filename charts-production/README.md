# charts-production — Part 3: StarRocks Query Engine

Helm chart that deploys StarRocks FE + CN for ad-hoc SQL queries over Iceberg tables.

**Deploy after `charts-iceberg`.** This chart only contains StarRocks. The Iceberg REST Catalog and Kafka Connect pipeline are owned by `charts-iceberg` (Part 1).

## What This Chart Deploys

| Resource | Description |
|----------|-------------|
| `starrocks-fe` StatefulSet | StarRocks Frontend node (shared-data mode, S3 backend) |
| `starrocks-cn` Deployment | StarRocks Compute Node (S3 data cache) |
| `starrocks-init` Job | Post-install Job: registers CN + creates Iceberg external catalog in StarRocks |

StarRocks runs in **shared-data mode** — FE stores metadata on EBS, CN caches S3 data locally.

The `starrocks-init` Job points StarRocks at the Iceberg REST Catalog deployed by `charts-iceberg` (`http://iceberg-rest-catalog:8181`). Both charts must be in the same namespace for the service DNS to resolve.

## Prerequisites

- `charts-iceberg` is already installed in the same namespace
- EBS CSI driver installed (for StarRocks FE persistent volume)
- Node IAM role has S3 read access to the Iceberg warehouse bucket
- Helm 3.x

## Deploy

```bash
# Validate
helm lint ./charts-production

# Dry run
helm template fp-starrocks ./charts-production \
  --set starrocks.fe.s3.bucket=datavisor-prod-iceberg \
  --set starrocks.fe.s3.path=cre-6630/warehouse/starrocks-data/ \
  --set starrocks.fe.storageClass=aws-ebs-csi

# Install
helm upgrade --install fp-starrocks ./charts-production \
  --set starrocks.fe.s3.bucket=datavisor-prod-iceberg \
  --set starrocks.fe.s3.path=cre-6630/warehouse/starrocks-data/ \
  --set starrocks.fe.storageClass=aws-ebs-csi
```

Or use a per-environment values file:

```bash
helm upgrade --install fp-starrocks ./charts-production -f awsuswest2proda/values.yaml
```

## Values Reference

```yaml
iceberg:
  restCatalog:
    uri: "http://iceberg-rest-catalog:8181"  # REST catalog service from charts-iceberg

starrocks:
  fe:
    image: "starrocks/fe-ubuntu:3.3-latest"
    replicas: 1
    storageSize: 10Gi
    storageClass: aws-ebs-csi              # Required — EBS StorageClass name
    s3:
      bucket: ""                           # Required — S3 bucket where Iceberg data is stored
      region: us-west-2
      path: ""                             # Required — StarRocks internal metadata path in S3
      useInstanceProfile: true
    resources: ...
  cn:
    image: "starrocks/cn-ubuntu:3.3-latest"
    replicas: 1
    cacheSizeLimit: 10Gi
    resources: ...
```

## StarRocks Init Job

The `starrocks-init` post-install Job:

1. Waits for the FE MySQL port (9030) to be ready
2. Registers the CN node: `ALTER SYSTEM ADD COMPUTE NODE 'starrocks-cn:9050'`
3. Creates the Iceberg external catalog:
   ```sql
   CREATE EXTERNAL CATALOG IF NOT EXISTS iceberg_catalog
   PROPERTIES (
     'type' = 'iceberg',
     'iceberg.catalog.type' = 'rest',
     'iceberg.catalog.uri' = '<iceberg.restCatalog.uri>',
     'aws.s3.region' = '<starrocks.fe.s3.region>',
     'aws.s3.use_instance_profile' = 'true'
   );
   ```

Re-running `helm upgrade` re-triggers the init Job (`before-hook-creation` delete policy). It is idempotent.

## Ad-hoc Queries

```bash
kubectl exec -it <starrocks-fe-pod> -- mysql -h 127.0.0.1 -P 9030 -u root

# In StarRocks:
SET CATALOG iceberg_catalog;
SHOW DATABASES;
USE <tenant_name>;
SELECT event_type, count(*) FROM event_result GROUP BY 1 ORDER BY 2 DESC LIMIT 20;
```
