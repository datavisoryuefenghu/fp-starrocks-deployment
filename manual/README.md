# CRE-6630 Manual Deploy

This directory keeps a trimmed manual deploy path for the three runtime components only:

- Iceberg REST Catalog
- Kafka Connect with Iceberg sink connector
- StarRocks

It intentionally excludes demo-only steps such as sample event production, benchmarking, and local mock data flow scripts.

## Files

- `00-namespace.yaml`: namespace manifest
- `05-iceberg-catalog-mysql-secret.example.yaml`: example secret for the dedicated Iceberg catalog MySQL
- `06-iceberg-catalog-mysql.yaml`: dedicated MySQL for Iceberg catalog metadata
- `deploy-qa-security.sh`: ready-to-run deploy script using the `dev_a` kubeconfig by default
- `10-iceberg-rest-catalog-secret.example.yaml`: example secret for Iceberg REST Catalog JDBC credentials
- `11-iceberg-rest-catalog.yaml`: static manifests for Iceberg REST Catalog
- `20-iceberg-kafka-connect.yaml`: static manifests for Kafka Connect
- `21-iceberg-kafka-connect-register-job.yaml`: one-shot connector registration job
- `30-starrocks.yaml`: standalone StarRocks for QA-style testing
- `31-starrocks-ops.yaml`: init SQL job for StarRocks external catalog registration
- `secrets.example.yaml`: example secret manifest for the SMT MySQL password, copy to `secrets.yaml` before deploy
- `iceberg-rest-catalog-values.yaml`: source values kept for reference
- `iceberg-kafka-connect-values.yaml`: source values kept for reference
- `starrocks-values.yaml`: source values kept for reference
- `deploy.sh`: legacy Helm-based deploy script, kept for reference only

## Prerequisites

- `kubectl` points to the target cluster
- The S3 bucket already exists: `datavisor-dev-us-west-2-iceberg`
- The cluster nodes or service accounts already have AWS credentials that can read and write the target S3 bucket
- `fp-mysql.qa-security:3306` is reachable from this namespace
- `kafka3.qa-security:9092` is reachable from this namespace

## QA Security defaults baked into these YAMLs

- Namespace: `qa-security`
- Iceberg S3 bucket: `datavisor-dev-us-west-2-iceberg`
- Iceberg warehouse prefix: `s3://datavisor-dev-us-west-2-iceberg/cre-6630/qa-security/`
- AWS auth mode: node IAM, no extra IRSA added in this QA version
- Dedicated Iceberg catalog MySQL: `iceberg-catalog-mysql.qa-security:3306`, database `iceberg_catalog`
- FP metadata MySQL for SMT: `fp-mysql.qa-security:3306`, database `yysecurity`, user `dv.ro`
- FP metadata MySQL password for SMT in QA: `password`
- Kafka bootstrap: `kafka3.duckdb:9092`
- Source topic: `cre6630_fp_velocity.yysecurity`
- Iceberg table: `yysecurity.event_result`
- Kafka Connect internal topic replication factor: `1` because QA currently has a single Kafka broker
- StarRocks mode: standalone `allin1` image for QA, because this cluster does not have the StarRocks operator CRD installed

## What this deployment will write to

- FP MySQL: read-only access only through `dv.ro` to query `yysecurity.feature`; this flow does not write to FP MySQL
- Source Kafka topic `qa-security_fp_velocity.yysecurity`: consume only, no writes to that topic
- Kafka: Kafka Connect will create and write its own internal topics for configs, offsets, and status
- Dedicated Iceberg catalog MySQL: yes, this deployment will create and update Iceberg catalog metadata there
- S3 bucket `datavisor-dev-us-west-2-iceberg`: yes, this deployment will create and update Iceberg data and metadata files under `cre-6630/qa-security/`
- Standalone StarRocks: yes, it will create its own local metadata inside the StarRocks pod and register the external Iceberg catalog via init job

This means the only reads against the shared QA FP environment are:

- reading `yysecurity.feature` from `fp-mysql`
- consuming messages from `qa-security_fp_velocity.yysecurity`

The risky shared side effect is S3 data growth under the Iceberg warehouse path. The FP MySQL side is read-only in this setup.

## Usage

1. Copy `secrets.example.yaml` to `secrets.yaml`
2. Copy `05-iceberg-catalog-mysql-secret.example.yaml` to `05-iceberg-catalog-mysql-secret.yaml`
3. Copy `10-iceberg-rest-catalog-secret.example.yaml` to `10-iceberg-rest-catalog-secret.yaml`
4. Fill in the passwords and any environment-specific placeholders in these files:
   - `secrets.yaml` (`password` for QA Security because SMT reads `fp-mysql` as `dv.ro`)
   - `05-iceberg-catalog-mysql-secret.yaml`
   - `10-iceberg-rest-catalog-secret.yaml`
5. Apply the manifests in order:

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f secrets.yaml
kubectl apply -f 05-iceberg-catalog-mysql-secret.yaml
kubectl apply -f 06-iceberg-catalog-mysql.yaml
kubectl rollout status statefulset/iceberg-catalog-mysql -n qa-security --timeout=5m
kubectl apply -f 10-iceberg-rest-catalog-secret.yaml
kubectl apply -f 11-iceberg-rest-catalog.yaml
kubectl rollout status deployment/iceberg-rest-catalog -n qa-security --timeout=5m

kubectl apply -f 20-iceberg-kafka-connect.yaml
kubectl rollout status deployment/iceberg-kafka-connect -n qa-security --timeout=10m
kubectl apply -f 21-iceberg-kafka-connect-register-job.yaml
kubectl wait -n qa-security --for=condition=complete job/iceberg-kafka-connect-register --timeout=10m

kubectl apply -f 30-starrocks.yaml
kubectl apply -f 31-starrocks-ops.yaml
kubectl rollout status deployment/cre-6630-starrocks -n qa-security --timeout=10m
kubectl wait -n qa-security --for=condition=complete job/cre-6630-starrocks-init-sql --timeout=15m
```

Or run the bundled script:

```bash
cd /Users/rshao/work/code_repos/fp_learning/feature-platform/reqs/cre-6630/deploy/ansible/manual

cp secrets.example.yaml secrets.yaml
cp 05-iceberg-catalog-mysql-secret.example.yaml 05-iceberg-catalog-mysql-secret.yaml
cp 10-iceberg-rest-catalog-secret.example.yaml 10-iceberg-rest-catalog-secret.yaml

bash ./deploy-qa-security.sh
```

If you want a different kubeconfig file, override `KUBECONFIG_PATH`:

```bash
KUBECONFIG_PATH=/path/to/other.config bash ./deploy-qa-security.sh
```

## What to change for another namespace or prod

- Namespace values in every manifest
- Iceberg catalog MySQL service name, storage, and passwords
- SMT source database and topic. For another tenant in this same namespace, change both together:
  - `qa-security_fp_velocity.yysecurity` -> `qa-security_fp_velocity.<tenant>`
  - `jdbc:mysql://fp-mysql.qa-security:3306/yysecurity` -> `jdbc:mysql://fp-mysql.qa-security:3306/<tenant_db>`
- Kafka bootstrap address and replication factor
- S3 bucket name and AWS auth model
- StarRocks deployment model. For production, replace the standalone QA deployment with the operator-based topology or another managed StarRocks deployment

## Password suggestions

- `secrets.yaml`: for QA Security, use the existing read-only FP MySQL password `password`
- `05-iceberg-catalog-mysql-secret.yaml`: use fresh dedicated passwords, do not reuse `fp-mysql` root password in this shared environment
- `10-iceberg-rest-catalog-secret.yaml`: set `jdbc-password` to the same value as `05-iceberg-catalog-mysql-secret.yaml` -> `mysql-password`

Example QA-only choices:

- `05-iceberg-catalog-mysql-secret.yaml` -> `mysql-root-password`: `cre6630IcebergRootQa2026!`
- `05-iceberg-catalog-mysql-secret.yaml` -> `mysql-password`: `cre6630IcebergQa2026!`
- `10-iceberg-rest-catalog-secret.yaml` -> `jdbc-password`: `cre6630IcebergQa2026!`

## Why QA uses standalone StarRocks

- This QA cluster does not have the StarRocks operator CRD installed, so the previous operator-based manifests cannot be applied here
- `starrocks/allin1-ubuntu` lets you validate the end-to-end Iceberg read path with a single Deployment and a normal Service
- It is simpler for a shared test namespace: fewer moving parts, no CRD dependency, easier cleanup
- It is not the production shape. You lose FE/CN separation, autoscaling, warehouse isolation, and closer parity with the intended shared-data topology

## If you want to install the StarRocks operator anyway

You can install it directly from your laptop. Helm is client-side, so you do not need to SSH to the master node just to run Helm.

Official chart route:

```bash
helm repo add starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update

kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config create namespace starrocks-system

helm install starrocks-operator starrocks/operator \
  --namespace starrocks-system \
  --kubeconfig /Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config

kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config get crd starrocksclusters.starrocks.com
kubectl --kubeconfig=/Users/rshao/work/code_repos/personal/historial_operations/kubeconfig/dev_a.config get pods -n starrocks-system
```

If your Helm install does not create the CRD automatically, use the official CRD manifest from the matching operator release before retrying.

For this QA test, the standalone version is still the lower-risk path because it avoids adding a new cluster-wide operator into a shared environment.

## Remaining confirmations before first apply

- Fill the actual passwords in:
  - `secrets.yaml`
  - `05-iceberg-catalog-mysql-secret.yaml`
  - `10-iceberg-rest-catalog-secret.yaml`
- Confirm whether this dedicated S3 prefix is acceptable: `s3://datavisor-dev-us-west-2-iceberg/cre-6630/qa-security/`
- Confirm whether `yysecurity` is still the tenant you want for the first run

## Later TODO

- If cluster-external access is needed later, add explicit exposure for Kafka Connect and StarRocks. Current Services are cluster-internal only
