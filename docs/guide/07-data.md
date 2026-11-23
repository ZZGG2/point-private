# 7단계. 데이터 계층 (RDS, ElastiCache, Kafka)

## 목표
로컬 docker-compose 의 Postgres 16 / Redis 7 / Kafka 3.8 을 AWS 로 옮긴다.

| 로컬 | 실습 대상 | 사양 | 배치 |
|---|---|---|---|
| postgres:16 | **RDS for PostgreSQL 16.15** (ADR-0013) | `db.t4g.micro`(Graviton), 단일 AZ, gp3 20GB | Private-Data |
| redis:7 | **ElastiCache Redis 7.1.0** | `cache.t4g.micro` 1노드 | Private-Data |
| kafka 3.8 | **Strimzi 1.3.1 → Kafka 4.3.2** (클러스터 내 파드) | 브로커+컨트롤러 1개(KRaft), ephemeral | Private-App (EKS) |

> MSK 는 최소 구성도 시간당 비용이 커서 학습엔 Strimzi 를 쓴다. 운영 설계(MSK)와 다른 점은 log 에 기록.
> 이 문서는 **2026-11-23 실제 진행 결과**를 반영했다.

## 사전 준비
- `jq` 가 필요하다 (Secrets Manager JSON 파싱). WSL 에 없어서 공식 바이너리로 설치했다 (sudo 불필요):
  ```bash
  curl -fsSLO https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
  curl -fsSLO https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt
  grep ' jq-linux-amd64$' sha256sum.txt | sha256sum --check
  install -m 0755 jq-linux-amd64 ~/.local/bin/jq && jq --version     # jq-1.7.1
  ```
- 노드 용량: 7단계 시점(t3.medium 2대, LB Controller + Strimzi + Kafka)까지는 여유가 충분했다. **9단계**에서 monolith(768Mi×2) + event-service + web 이 올라가면 빠듯해지므로 그때 노드 추가를 검토.
  ```bash
  kubectl describe nodes | grep -A6 'Allocated resources' | grep -E 'cpu|memory'
  ```

## 7-1. 보안그룹 원칙 — "EKS 노드 SG 에서만"
RDS·Redis SG 인바운드는 CIDR 이 아니라 **노드 SG 를 참조**한다 (`referenced_security_group_id`).
노드 IP 가 바뀌거나 Karpenter 노드가 추가돼도 같은 SG 를 쓰므로 규칙을 고칠 필요가 없다.
파드도 VPC CNI 기본 설정에서는 노드의 SG 를 쓴다.

## 7-2. RDS — `modules/rds/`

엔진 버전 확인 (이번 실습: **16.15**):
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
variable "engine_version" { type = string } # 예: "16.x"
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
  referenced_security_group_id = each.value # CIDR 이 아니라 SG 참조 → 노드 IP 가 바뀌어도 OK
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

  db_name                     = "point"
  username                    = "point_admin"
  manage_master_user_password = true # 비밀번호를 Terraform 이 모름 → Secrets Manager 에 자동 저장·회전

  db_subnet_group_name   = var.db_subnet_group_name # 2단계 VPC 모듈이 만든 Private-Data 서브넷 그룹
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # 운영 설계는 Multi-AZ

  backup_retention_period = 1
  skip_final_snapshot     = true # 학습용: destroy 시 스냅샷 안 남김
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
| `manage_master_user_password` | 마스터 비밀번호가 tfvars/state 에 안 남는다. Secrets Manager 에 `rds!db-<uuid>` 이름으로 JSON(`username`, `password`) 저장 |
| `referenced_security_group_id` | 노드 SG 를 가진 ENI 에서만 5432 허용 |
| `skip_final_snapshot` | 없으면 destroy 시 `final_snapshot_identifier` 요구로 실패 |
| `backup_retention_period = 1` | 0 이면 자동 백업 끔 — 생성은 빨라지지만 PITR 실습 불가 |

**SSL 강제 (실제 확인함):** RDS PostgreSQL 16 은 `rds.force_ssl` 기본값이 1 이다. `sslmode=disable` 로 접속하면
`FATAL: no pg_hba.conf entry for host "...", user "app_rw", database "point", no encryption` 으로 거부된다.
→ psql 은 `sslmode=require`, 9단계 JDBC URL 은 `?sslmode=require` 를 붙인다.

## 7-3. ElastiCache — `modules/elasticache/`

엔진 버전 확인 (서울 리전 지원: `4.0.10 5.0.6 6.0 6.2 7.0 7.1`):
```bash
aws elasticache describe-cache-engine-versions --engine redis --query 'CacheEngineVersions[].EngineVersion' --output text
```

**`modules/elasticache/variables.tf`**
```hcl
variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }                 # Private-Data 서브넷 3개
variable "allowed_security_group_ids" { type = list(string) } # 6379 허용할 SG (EKS 노드 SG)
```

**`modules/elasticache/main.tf`**
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
  subnet_ids = var.subnet_ids # Private-Data 3개
}

resource "aws_elasticache_cluster" "this" {
  cluster_id         = "${var.name}-redis"
  engine             = "redis"
  engine_version     = "7.1"
  node_type          = "cache.t4g.micro"
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]
}
```

**`modules/elasticache/outputs.tf`**
```hcl
output "endpoint" { value = aws_elasticache_cluster.this.cache_nodes[0].address }
```
- event-service 설정(`spring.data.redis.host/port`)이 TLS·AUTH 없이 붙는 구조라 전송 암호화를 끈 단일 노드로 시작. 운영 설계(ADR-0007: Cluster mode, Multi-AZ, 암호화)와 다른 점을 기록.
- (선택) `engine = "valkey"` 가 더 싸다. Redis 7 호환.

## 7-4. `envs/dev` 연결

**`envs/dev/main.tf`** 에 추가:
```hcl
module "rds" {
  source                     = "../../modules/rds"
  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  db_subnet_group_name       = module.vpc.database_subnet_group
  allowed_security_group_ids = [module.eks.node_security_group_id]
  engine_version             = "16.15"
}

module "redis" {
  source                     = "../../modules/elasticache"
  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.data_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
}
```

**`envs/dev/outputs.tf`** 에 추가 (7-6, 8·9단계에서 `terraform output -raw` 로 꺼내 쓴다):
```hcl
output "rds_endpoint" { value = module.rds.endpoint }
output "rds_master_secret_arn" { value = module.rds.master_secret_arn }
output "redis_endpoint" { value = module.redis.endpoint }
output "node_security_group_id" { value = module.eks.node_security_group_id }
```

```bash
cd ~/point/point-private/envs/dev
terraform init            # ⚠️ 새 module 블록을 추가하면 반드시 다시 init
terraform fmt -recursive ../..
terraform validate
terraform plan            # rds 3 + redis 4 = 7 to add
terraform apply           # RDS ≈ 5~10분, ElastiCache ≈ 5~10분
terraform output
```

### 이번에 겪은 문제 ① — `Module not installed`
`module "rds"`, `module "redis"` 를 추가한 뒤 `init` 없이 plan 하면 이 에러가 나고, VS Code 에도 빨간 줄이 생긴다.
- 해결: **`envs/dev` 에서** `terraform init`. 그래도 VS Code 에 빨간 줄이 남으면 `Ctrl+Shift+P` → *Developer: Reload Window*.
- ⚠️ **모듈 폴더(`modules/elasticache/`) 안에서 `terraform init` 을 하지 않는다.** 모듈은 혼자 실행하는 루트가 아니다. 실행하면 그 폴더에 `.terraform/`, `.terraform.lock.hcl` 가 생기는데 쓸모없고 헷갈리기만 한다 (이번에 생겨서 삭제함).

### 실제 결과
| 리소스 | 값 |
|---|---|
| RDS | `point-dev-pg.<id>.ap-northeast-2.rds.amazonaws.com`, `available`, 16.15 (`aarch64` — t4g 는 Graviton) |
| 마스터 비밀 | `arn:aws:secretsmanager:...:secret:rds!db-<uuid>` |
| Redis | `point-dev-redis.<id>.0001.apn2.cache.amazonaws.com`, `available`, 7.1.0 |

## 7-5. Kafka — Strimzi

```bash
helm repo add strimzi https://strimzi.io/charts/ && helm repo update
helm search repo strimzi/strimzi-kafka-operator | head -3       # 이번 실습: 1.3.1
kubectl create namespace kafka
helm install strimzi strimzi/strimzi-kafka-operator -n kafka
kubectl get pods -n kafka                                        # strimzi-cluster-operator Running
kubectl api-resources | grep kafka.strimzi.io                    # ← apiVersion 반드시 확인
```

### 이번에 겪은 문제 ② — `no matches for kind "KafkaNodePool" in version "kafka.strimzi.io/v1beta2"`
- **Strimzi 1.x 는 CRD 를 `kafka.strimzi.io/v1` 로만 제공**한다 (`v1beta2` 는 0.x 시절 버전으로 제거됨).
- 인터넷 예제·블로그 대부분이 `v1beta2` 라서 그대로 쓰면 이 에러가 난다. 메시지는 "CRD 가 없다" 같지만 실제로는 **CRD 는 있는데 그 버전이 없다**는 뜻.
- 확인 방법:
  ```bash
  kubectl api-resources | grep kafka.strimzi.io       # APIVERSION 열 = kafka.strimzi.io/v1
  kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{range .spec.versions[*]}{.name} served={.served}{"\n"}{end}'
  kubectl apply --dry-run=server -f k8s/platform/kafka/kafka.yaml   # 적용 전 서버 검증
  ```
- KRaft 전용이라 예전 `strimzi.io/node-pools`, `strimzi.io/kraft` annotation 도 필요 없다.

**`k8s/platform/kafka/kafka.yaml`** (KRaft, 노드 1개)
```yaml
apiVersion: kafka.strimzi.io/v1
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
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: point
  namespace: kafka
spec:
  kafka:
    # version: 생략하면 operator 기본 버전 (Strimzi 1.3.1 → Kafka 4.3.2)
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

```bash
kubectl apply -f k8s/platform/kafka/kafka.yaml
kubectl wait kafka/point -n kafka --for=condition=Ready --timeout=600s     # 약 1분
kubectl get kafka,kafkanodepool,pods,svc -n kafka
```
실제 결과:
```
kafka.kafka.strimzi.io/point   READY True   WARNINGS True   KAFKA VERSION 4.3.2   METADATA VERSION 4.3-IV0
pod/point-dual-0                  Running     ← 브로커+컨트롤러
pod/point-entity-operator-...     Running     ← Topic Operator
service/point-kafka-bootstrap     9091/TCP,9092/TCP
```
→ 앱에서 쓸 주소: **`point-kafka-bootstrap.kafka.svc:9092`**

`WARNINGS True` 의 내용 (의도한 구성이라 무시):
```bash
kubectl get kafka point -n kafka -o jsonpath='{range .status.conditions[*]}{.type}={.status} [{.reason}] {.message}{"\n"}{end}'
# Warning=True [KafkaStorage] A Kafka cluster with a single broker node and ephemeral storage will lose topic messages after any restart or rolling update.
# Warning=True [KafkaStorage] A Kafka cluster with a single controller node and ephemeral storage will lose data after any restart or rolling update.
```
- 로컬은 Kafka 3.8, 여기는 **4.3.2**. Kafka 4 는 ZooKeeper 가 완전히 제거되고 KRaft 전용. 클라이언트(Spring Kafka, `apache/kafka:3.8.0` CLI)는 그대로 호환됐다 (아래 확인 참고).

## 7-6. 앱 계정 `app_rw` 만들기 (ADR-0013 `db-init` 개념)
ADR-0013: 마스터 계정은 DB 초기화에만 쓰고, 앱은 `app_rw` 로 접속. 지금은 손으로 하고, 11단계에서 Job 으로 바꾼다.

### 비밀번호 보관
8단계에서 Secrets Manager 에 넣어야 하므로 **레포 밖, 권한 600 파일**에 만들어 둔다:
```bash
mkdir -p ~/.config/point-dev && chmod 700 ~/.config/point-dev
(umask 077; openssl rand -base64 24 | tr -d '/+=' > ~/.config/point-dev/app_rw_password)
ls -l ~/.config/point-dev/app_rw_password          # -rw-------
```
8단계에서 Secrets Manager 에 넣은 뒤 이 파일은 지운다.

### 이번에 겪은 문제 ③ — `syntax error at or near "$"`
처음엔 `DO $$ ... $$` 블록을 `kubectl run ... -- psql -c "..."` 로 넘겼는데 이렇게 실패했다:
```
ERROR:  syntax error at or near "$"
LINE 1: DO $ BEGIN IF NOT EXISTS ...
```
- 원인: **쿠버네티스는 컨테이너 `command`/`args`/`env` 값의 `$$` 를 `$` 로 바꾼다.** `$(VAR_NAME)` 치환 문법의 이스케이프 규칙이다. 그래서 PostgreSQL 의 `$$` 가 `$` 로 깨졌다.
- 해결: 이름 붙은 달러 인용 **`$do$ ... $do$`** 를 쓴다. `$` 바로 뒤가 `(` 가 아니면 쿠버네티스가 건드리지 않는다.
- 이 규칙은 Job/Deployment YAML 의 `args` 에도 똑같이 적용된다 → 11단계 `db-init` Job 에서도 `$do$` 사용.

### 실행
```bash
cd ~/point/point-private/envs/dev
RDS=$(terraform output -raw rds_endpoint)
MASTER_PW=$(aws secretsmanager get-secret-value --secret-id "$(terraform output -raw rds_master_secret_arn)" \
  --query SecretString --output text | jq -r .password)
APP_PW=$(cat ~/.config/point-dev/app_rw_password)

# 여러 번 실행해도 안전 (있으면 비밀번호만 갱신)
SQL="DO \$do\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_rw') THEN
    CREATE ROLE app_rw LOGIN PASSWORD '$APP_PW';
  ELSE
    ALTER ROLE app_rw LOGIN PASSWORD '$APP_PW';
  END IF;
END \$do\$;"

kubectl run pg-init -n default --restart=Never --image=postgres:16 \
  --env PGPASSWORD="$MASTER_PW" --env SQL="$SQL" --command -- \
  sh -c 'psql "host='"$RDS"' user=point_admin dbname=point sslmode=require" -v ON_ERROR_STOP=1 \
         -c "$SQL" -c "GRANT CONNECT, CREATE ON DATABASE point TO app_rw;"'

kubectl wait pod/pg-init --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
kubectl logs pg-init          # DO / GRANT
kubectl delete pod pg-init
```
- `GRANT CREATE ON DATABASE` — monolith 의 Flyway 가 스키마(`users` 등)를 직접 만들기 때문에 필요.
- 비밀번호를 `--env` 로 넘기면 파드 spec 에 남는다 → 끝나면 바로 파드 삭제. 운영은 Secret 참조로 (11단계).

### 팁 — `kubectl run -i --rm` 대신 "실행 → wait → logs"
`kubectl run -it --rm ... -- psql ...` 은 컨테이너가 금방 끝나면 attach 전에 종료돼서 **에러 메시지 없이 `pod ... terminated (Error)`** 만 보일 때가 있다.
짧은 명령은 `--restart=Never` 로 띄우고 `kubectl wait` → `kubectl logs` → `kubectl delete` 순서가 확실하다.
```bash
run() { n=$1; shift; kubectl run $n --restart=Never "$@" >/dev/null
        kubectl wait pod/$n --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1
        echo "== $n: $(kubectl get pod $n -o jsonpath='{.status.phase}')"; kubectl logs $n; kubectl delete pod $n --wait=false >/dev/null; }
```

## ✅ 확인 (클러스터 안 임시 파드에서)
```bash
REDIS=$(terraform output -raw redis_endpoint)

# 1) app_rw 접속 + CREATE 권한
run pg-app --image=postgres:16 --env PGPASSWORD="$APP_PW" --command -- \
  psql "host=$RDS user=app_rw dbname=point sslmode=require" \
  -c "select current_user, has_database_privilege('point','CREATE') as can_create;"

# 2) SSL 없이 접속하면 거부되는지 (Failed 가 정상)
run pg-nossl --image=postgres:16 --env PGPASSWORD="$APP_PW" --command -- \
  psql "host=$RDS user=app_rw dbname=point sslmode=disable" -c "select 1;"

# 3) Redis
run rc --image=redis:7-alpine --command -- redis-cli -h $REDIS ping

# 4) Kafka (토픽 생성 + 목록)
run kc --image=apache/kafka:3.8.0 --command -- sh -c \
  '/opt/kafka/bin/kafka-topics.sh --bootstrap-server point-kafka-bootstrap.kafka.svc:9092 --create --if-not-exists --topic smoke-test --partitions 1 --replication-factor 1 &&
   /opt/kafka/bin/kafka-topics.sh --bootstrap-server point-kafka-bootstrap.kafka.svc:9092 --list'
```

### 실제 결과
| 확인 | 결과 |
|---|---|
| app_rw 접속 | `Succeeded` — `current_user = app_rw`, `can_create = t` |
| SSL 없이 접속 | `Failed` — `no pg_hba.conf entry ... no encryption` (SSL 강제 동작) |
| Redis | `PONG` |
| Kafka | `Created topic smoke-test.` → 목록에 `smoke-test` (3.8 CLI ↔ 4.3.2 브로커 호환) |

로컬(WSL)에서 RDS·Redis 로 직접 접속은 **안 되는 게 정상** (private 서브넷 + SG).

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| `Module not installed` / VS Code 빨간 줄 | 새 module 추가 후 `envs/dev` 에서 `terraform init` |
| `no matches for kind ... kafka.strimzi.io/v1beta2` | Strimzi 1.x → `apiVersion: kafka.strimzi.io/v1` |
| `syntax error at or near "$"` | K8s 가 `$$` → `$` 치환 → `$do$` 사용 |
| `jq: command not found` → 비밀번호가 빈 값 → 인증 실패 | jq 설치 (위 사전 준비). `set -o pipefail` 로 실패를 바로 잡기 |
| `pod ... terminated (Error)` 메시지 없음 | `-i --rm` 대신 wait → logs 패턴 |
| psql 타임아웃 | RDS SG 인바운드가 노드 SG 인지, 파드가 노드 SG 를 쓰는지 |
| `no pg_hba.conf entry ... no encryption` | `sslmode=require` |
| `permission denied for database` (Flyway) | `GRANT CREATE ON DATABASE point TO app_rw` 누락 |
| Kafka 파드 Pending | 노드 메모리 부족 → 노드 추가 |
| `InvalidParameterCombination` (RDS) | 인스턴스 클래스와 엔진 버전 조합 미지원 → `describe-orderable-db-instance-options` |

## 🧹 정리
```bash
kubectl delete -f k8s/platform/kafka/kafka.yaml      # Kafka 파드 (ephemeral 이라 EBS 잔여 없음)
helm uninstall strimzi -n kafka
kubectl delete ns kafka
# RDS·Redis 는 envs/dev terraform destroy 에 포함 (skip_final_snapshot = true 확인)
rm -f ~/.config/point-dev/app_rw_password            # 8단계에서 Secrets Manager 에 넣은 뒤
```
- `manage_master_user_password` 가 만든 마스터 비밀(`rds!db-...`)은 RDS 삭제 시 함께 삭제된다.
- 클러스터째 destroy 할 거면 Strimzi 정리는 생략 가능.

💸 RDS db.t4g.micro + ElastiCache cache.t4g.micro ≈ 각각 시간당 $0.02~0.03 수준 (정확한 서울 단가는 가격 계산기로).
