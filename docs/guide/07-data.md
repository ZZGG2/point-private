# 7단계. 데이터 계층 (RDS, ElastiCache, Kafka)

## 목표
로컬 docker-compose 의 Postgres 16 / Redis 7 / Kafka 3.8 을 AWS 로 옮긴다.

| 로컬 | 실습 대상 | 사양 | 배치 |
|---|---|---|---|
| postgres:16 | **RDS for PostgreSQL 16** (ADR-0013) | `db.t4g.micro`, 단일 AZ, gp3 20GB | Private-Data |
| redis:7 | **ElastiCache Redis** | `cache.t4g.micro` 1노드 | Private-Data |
| kafka 3.8 | **Strimzi** (클러스터 내 파드) | 브로커+컨트롤러 1개, ephemeral | Private-App (EKS) |

> MSK 는 최소 구성도 시간당 비용이 커서 학습엔 Strimzi 를 쓴다. 운영 설계(MSK)와 다른 점은 log 에 기록.

> 이 문서는 아직 실습 전 작성한 가이드. "⚠️ 확인" 은 진행 시 실제 값으로 갱신.

## 💡 노드 용량부터 확인
t3.medium 2대 = 대략 vCPU 4 / 메모리 ~6.5Gi 가용. 9단계에서 monolith(1Gi×2) + event-service(1Gi) + web + Kafka(≈1~2Gi) + LB Controller + (8단계) ESO 가 올라간다.
→ 7단계부터 **노드그룹을 3대로** 또는 **t3.large** 로 올리는 걸 권장. `modules/eks` 에서:
```hcl
# 방법 1: 대수 (desired_size 는 모듈이 최초 생성 후 무시하므로 min_size 를 올리는 게 확실)
min_size = 3, max_size = 4, desired_size = 3
# 방법 2: 타입 — envs/dev 에서 core_instance_types = ["t3.large"] (노드 교체 발생)
```

## 7-1. 보안그룹 — "EKS 노드에서만"
`envs/dev/outputs.tf` 에 `modules/eks` 의 `node_security_group_id` 를 쓸 수 있게 이미 output 이 있다.

**`modules/data/` 를 하나 만들거나**, 간단히 `modules/rds`, `modules/elasticache` 각각에 SG 를 둔다. 여기선 각각 둔다.

## 7-2. RDS — `modules/rds/`

엔진 버전 확인:
```bash
aws rds describe-db-engine-versions --engine postgres \
  --query "DBEngineVersions[?starts_with(EngineVersion,'16')].EngineVersion" --output text
```

**`modules/rds/variables.tf`**
```hcl
variable "name" { type = string }
variable "vpc_id" { type = string }
variable "db_subnet_group_name" { type = string }
variable "allowed_security_group_ids" { type = list(string) }
variable "engine_version" { type = string }      # 예: "16.x"
variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}
```

**`modules/rds/main.tf`**
```hcl
resource "aws_security_group" "rds" {
  name   = "${var.name}-rds"
  vpc_id = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_allowed" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = each.value         # CIDR 이 아니라 SG 참조 → 노드 IP 가 바뀌어도 OK
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "point"
  username = "point_admin"
  manage_master_user_password = true    # 비밀번호를 Terraform 이 모름 → Secrets Manager 에 자동 저장·회전

  db_subnet_group_name   = var.db_subnet_group_name   # 2단계 VPC 모듈이 만든 Private-Data 서브넷 그룹
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false                      # 운영 설계는 Multi-AZ

  backup_retention_period = 1
  skip_final_snapshot     = true      # 학습용: destroy 시 스냅샷 안 남김
  deletion_protection     = false
  apply_immediately       = true
}
```

**`modules/rds/outputs.tf`**
```hcl
output "endpoint" { value = aws_db_instance.this.address }
output "master_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
output "security_group_id" { value = aws_security_group.rds.id }
```

| 설정 | 이유 |
|---|---|
| `manage_master_user_password` | 마스터 비밀번호가 tfvars/state 에 안 남는다. Secrets Manager 에 JSON(`username`, `password`) 으로 저장 |
| `referenced_security_group_id` | "노드 SG 를 가진 ENI 에서만" 허용. 파드도 VPC CNI 기본 설정에선 노드 SG 를 쓴다 |
| `skip_final_snapshot` | 없으면 destroy 시 `final_snapshot_identifier` 요구로 실패 |
| `backup_retention_period = 1` | 0 이면 자동 백업 끔 — 생성은 빨라지지만 PITR 실습 불가. 취향 |

⚠️ PostgreSQL 16 on RDS 는 파라미터 `rds.force_ssl` 기본값이 **1** → 클라이언트는 SSL 필수. JDBC URL 에 `?sslmode=require` 를 붙인다 (9단계). psql 은 기본 `sslmode=prefer` 라 그냥 된다.

## 7-3. ElastiCache — `modules/elasticache/`

**`modules/elasticache/main.tf`** (변수·output 은 RDS 와 같은 패턴)
```hcl
resource "aws_security_group" "redis" {
  name   = "${var.name}-redis"
  vpc_id = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_allowed" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-redis"
  subnet_ids = var.subnet_ids          # Private-Data 3개
}

resource "aws_elasticache_cluster" "this" {
  cluster_id         = "${var.name}-redis"
  engine             = "redis"
  engine_version     = "7.1"           # ⚠️ 확인: aws elasticache describe-cache-engine-versions --engine redis
  node_type          = "cache.t4g.micro"
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]
}

output "endpoint" { value = aws_elasticache_cluster.this.cache_nodes[0].address }
```
- event-service 설정(`spring.data.redis.host/port`)이 TLS·AUTH 없이 붙는 구조라 전송 암호화는 끈 단일 노드로 시작. 운영 설계(ADR-0007: Cluster mode, Multi-AZ, 암호화)와 다른 점을 기록.
- (선택) `engine = "valkey"` 가 더 싸다. Redis 7 호환.

## 7-4. `envs/dev` 연결
```hcl
module "rds" {
  source                     = "../../modules/rds"
  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  db_subnet_group_name       = module.vpc.database_subnet_group
  allowed_security_group_ids = [module.eks.node_security_group_id]
  engine_version             = "<7-2에서 확인한 16.x>"
}

module "redis" {
  source                     = "../../modules/elasticache"
  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.data_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
}
```
- `module.vpc.database_subnet_group`, `data_subnet_ids` 는 2단계 `modules/vpc/outputs.tf` 에 있지만 **`envs/dev` 가 아니라 모듈 output** 이므로 위처럼 바로 참조 가능.
- `envs/dev/outputs.tf` 에 `rds_endpoint`, `rds_master_secret_arn`, `redis_endpoint` 추가.

```bash
terraform init && terraform plan && terraform apply     # RDS 생성 ≈ 5~10분, ElastiCache ≈ 5~10분
```

## 7-5. Kafka — Strimzi

```bash
helm repo add strimzi https://strimzi.io/charts/ && helm repo update
helm search repo strimzi/strimzi-kafka-operator | head -3     # 최신 버전 확인
kubectl create namespace kafka
helm install strimzi strimzi/strimzi-kafka-operator -n kafka
kubectl api-resources | grep kafka.strimzi.io                  # ⚠️ 확인: 제공되는 apiVersion (v1beta2 / v1)
```
⚠️ 확인: Strimzi 버전별 지원 Kafka 버전과 K8s 1.37 호환은 Strimzi 릴리스 노트에서 확인.

**`k8s/platform/kafka/kafka.yaml`** (KRaft, 노드 1개)
```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual
  namespace: kafka
  labels:
    strimzi.io/cluster: point
spec:
  replicas: 1
  roles: [controller, broker]
  storage:
    type: ephemeral                 # 파드 재시작 시 데이터 유실 — 학습용
  resources:
    requests: { cpu: 250m, memory: 1Gi }
    limits:   { memory: 1Gi }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: point
  namespace: kafka
spec:
  kafka:
    # version: 생략하면 operator 기본 버전
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
      auto.create.topics.enable: "true"     # 로컬 compose 와 동일
  entityOperator:
    topicOperator: {}
```
⚠️ 확인: 구버전 Strimzi 는 `metadata.annotations` 에 `strimzi.io/node-pools: enabled`, `strimzi.io/kraft: enabled` 가 필요. 설치한 버전 예제(`helm show readme` 또는 Strimzi quickstart)와 맞출 것.

```bash
kubectl apply -f k8s/platform/kafka/kafka.yaml
kubectl wait kafka/point -n kafka --for=condition=Ready --timeout=600s
kubectl get svc -n kafka          # point-kafka-bootstrap:9092
```
→ 앱에서 쓸 주소: `point-kafka-bootstrap.kafka.svc:9092`

## 7-6. 앱 계정 `app_rw` 만들기 (ADR-0013 `db-init` 개념)
ADR-0013: 마스터 계정은 DB 초기화에만 쓰고, 앱은 `app_rw` 로 접속. 지금은 손으로 하고, 11단계에서 Job 으로 바꾼다.

```bash
cd ~/point/point-private/envs/dev
RDS=$(terraform output -raw rds_endpoint)
MASTER_PW=$(aws secretsmanager get-secret-value --secret-id $(terraform output -raw rds_master_secret_arn) \
  --query SecretString --output text | jq -r .password)
APP_PW=$(openssl rand -base64 24 | tr -d '/+=')    # 8단계에서 Secrets Manager 에 넣을 값 → 잠깐 메모

kubectl run -it --rm pg --image=postgres:16 --restart=Never \
  --env PGPASSWORD="$MASTER_PW" -- psql -h $RDS -U point_admin -d point
```
psql 안에서:
```sql
CREATE ROLE app_rw LOGIN PASSWORD '<APP_PW>';
GRANT CONNECT, CREATE ON DATABASE point TO app_rw;   -- Flyway 가 스키마(users 등)를 직접 만든다
\q
```
- `kubectl run --env` 로 넘긴 값은 파드 spec 에 남는다 (`--rm` 으로 바로 삭제). 운영은 Secret 참조로.

## ✅ 확인 (클러스터 안 임시 파드에서)
```bash
kubectl run -it --rm pg --image=postgres:16 --restart=Never --env PGPASSWORD="$APP_PW" \
  -- psql "host=$RDS user=app_rw dbname=point sslmode=require" -c 'select current_user, version();'

REDIS=$(terraform output -raw redis_endpoint)
kubectl run -it --rm rc --image=redis:7-alpine --restart=Never -- redis-cli -h $REDIS ping     # PONG

kubectl run -it --rm kc --image=apache/kafka:3.8.0 --restart=Never -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server point-kafka-bootstrap.kafka.svc:9092 --list
```
로컬(WSL)에서 RDS 로 직접 접속은 **안 되는 게 정상** (private + SG).

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| psql 타임아웃 | RDS SG 인바운드가 노드 SG 인지, 파드가 노드 SG 를 쓰는지 |
| `no pg_hba.conf entry ... no encryption` | SSL 미사용 → `sslmode=require` |
| `permission denied for database` (Flyway) | `GRANT CREATE ON DATABASE point TO app_rw` 누락 |
| Kafka 파드 Pending | 노드 메모리 부족 → 노드 추가 |
| `InvalidParameterCombination` (RDS) | 인스턴스 클래스와 엔진 버전 조합 미지원 → `describe-orderable-db-instance-options` |

## 🧹 정리
- RDS: `skip_final_snapshot = true` 확인 후 destroy (≈ 5~10분).
- `manage_master_user_password` 가 만든 Secrets Manager 비밀은 RDS 삭제 시 함께 삭제된다.
- Strimzi: `kubectl delete -f k8s/platform/kafka/kafka.yaml` → `helm uninstall strimzi -n kafka` (클러스터 destroy 면 생략 가능, EBS 를 안 쓰는 ephemeral 이라 잔여 볼륨 없음).

💸 RDS db.t4g.micro ≈ $0.025/h + 스토리지, ElastiCache cache.t4g.micro ≈ $0.025/h (⚠️ 확인: 서울 리전 단가).
