# 7단계. 데이터 계층 (RDS, ElastiCache Valkey)

## 목표
로컬 docker-compose 의 Postgres 16 / Redis 7 을 AWS 로 옮긴다.

| 로컬 | 실습 대상 | 사양 | 배치 |
|---|---|---|---|
| postgres:16 | **RDS for PostgreSQL 16.15** (ADR-0013) | `db.t4g.micro`(Graviton), 단일 AZ, gp3 20GB | Private-Data |
| redis:7 | **ElastiCache Valkey 7.2** (복제 그룹) | `cache.t4g.micro` × 2 — primary + replica, **Multi-AZ + 자동 장애 조치** | Private-Data |

> 🔄 **2026-11-26 변경 — Kafka 제거 (point-infra ADR-0019).** 원장 반영은 Kafka 대신 **ElastiCache 의 Redis Stream** 으로 한다.
> - event-service 의 Lua 가 판정과 같은 스크립트에서 `XADD event:{id}:rewards` → core-service 가 consumer group `point-ledger` 로 읽어 원장에 반영 → `XACK`
> - 그래서 ElastiCache 가 "캐시"가 아니라 **원장 반영 버퍼**가 됐다 → 1노드였던 Redis 를 point-infra 설계대로 **Valkey 복제 그룹(Multi-AZ)** 으로 바꿨다 (7-3)
> - Strimzi Kafka(이전 7-5)는 삭제. 당시 진행 기록(Strimzi 1.3.1 → Kafka 4.3.2, `kafka.strimzi.io/v1` 문제 등)은 git 이력에 있다: `git log -p -- docs/guide/07-data.md`
>
> 이 문서는 **2026-11-23 실제 진행 결과**를 바탕으로 하고, 7-3·7-5 는 11-26 설계로 다시 썼다 (아직 AWS 에 적용 전).

## 사전 준비
- `jq` 가 필요하다 (Secrets Manager JSON 파싱). WSL 에 없어서 공식 바이너리로 설치했다 (sudo 불필요):
  ```bash
  curl -fsSLO https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
  curl -fsSLO https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt
  grep ' jq-linux-amd64$' sha256sum.txt | sha256sum --check
  install -m 0755 jq-linux-amd64 ~/.local/bin/jq && jq --version     # jq-1.7.1
  ```
- 노드 용량: 7단계 시점(t3.medium 2대, LB Controller)까지는 여유가 충분했다 (11-23 에는 Strimzi + Kafka 1Gi 도 올라가 있었다 — 지금은 없음). **9단계**에서 core-service(768Mi×2) + event-service + web 이 올라가면 빠듯해지므로 그때 노드 추가를 검토.
  ```bash
  kubectl describe nodes | grep -A6 'Allocated resources' | grep -E 'cpu|memory'
  ```

## 7-1. 보안그룹 원칙 — "EKS 노드 SG 에서만"
RDS·ElastiCache SG 인바운드는 CIDR 이 아니라 **노드 SG 를 참조**한다 (`referenced_security_group_id`).
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

## 7-3. ElastiCache — `modules/elasticache/` (Valkey 복제 그룹)

point-infra [data-architecture §1](../../../point-infra/docs/01-architecture/data-architecture.md): **Valkey 7.2, Primary + Replica, Multi-AZ + 자동 장애 조치 필수 (Cluster mode 비활성)**.
원장 반영 Stream 이 여기에 있으므로 학습용이어도 이 부분은 설계대로 한다 (1노드면 노드 장애 = 아직 원장에 안 들어간 당첨 유실).

엔진 버전 확인:
```bash
aws elasticache describe-cache-engine-versions --engine valkey --query 'CacheEngineVersions[].EngineVersion' --output text
```

**`modules/elasticache/variables.tf`**
```hcl
variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }                 # Private-Data 서브넷 3개
variable "allowed_security_group_ids" { type = list(string) } # 6379 허용할 SG (EKS 노드 SG)
variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}
```

**`modules/elasticache/main.tf`** (SG·서브넷 그룹은 이전과 같음)
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

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-redis"
  description          = "point event keys + reward streams (ADR-0007, ADR-0019)"
  engine               = "valkey"
  engine_version       = "7.2"
  parameter_group_name = "default.valkey7"
  node_type            = var.node_type
  port                 = 6379

  num_cache_clusters         = 2 # primary 1 + replica 1 (서로 다른 AZ)
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # 앱(spring.data.redis)이 TLS 없이 붙는다 — 운영은 TLS 검토
  snapshot_retention_limit   = 0     # 학습용
  apply_immediately          = true
}
```

**`modules/elasticache/outputs.tf`**
```hcl
# 앱은 항상 primary 엔드포인트로 붙는다 (장애 조치 시 DNS 가 새 primary 로 바뀐다)
output "endpoint" { value = aws_elasticache_replication_group.this.primary_endpoint_address }
```

| 설정 | 이유 |
|---|---|
| `aws_elasticache_replication_group` | `aws_elasticache_cluster`(이전, 1노드)는 복제·장애 조치가 없다. 리소스 종류가 바뀌므로 **apply 하면 교체**(기존 1노드 삭제 → 새로 생성)되고 엔드포인트도 바뀐다 → 9단계 `REDIS_HOST` 갱신 |
| `num_cache_clusters = 2` + `automatic_failover_enabled` + `multi_az_enabled` | primary 가 죽으면 replica 가 승격. 복제는 **비동기**라 장애 조치 순간 마지막 쓰기 일부가 유실될 수 있다 (ADR-0019 "Redis 가용성") |
| Cluster mode 비활성 | 키는 `event:{id}:…` 해시태그로 묶여 있어 클러스터 모드로 가도 되지만, 설계는 비활성 (샤드 1개) |
| `engine = "valkey"` | Redis 7.2 호환 오픈소스 포크. 같은 노드 타입이 Redis 보다 싸다. Lua·Stream(`XADD`, `XREADGROUP`, `XCLAIM`)·`PEXPIRETIME` 그대로 동작 |
| `transit_encryption_enabled = false` | 운영 설계(전송 암호화)와 다른 점. 켜면 앱에 `spring.data.redis.ssl.enabled=true` 가 필요하다 |

💸 노드가 2개가 되므로 ElastiCache 비용이 약 2배 (t4g.micro ×2).

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
terraform plan            # 처음: rds 3 + redis 4 = 7 to add / 11-26 변경 후: aws_elasticache_cluster 1 destroy, aws_elasticache_replication_group 1 add
terraform apply           # RDS ≈ 5~10분, ElastiCache 복제 그룹 ≈ 10~15분
terraform output
```

### 이번에 겪은 문제 ① — `Module not installed`
`module "rds"`, `module "redis"` 를 추가한 뒤 `init` 없이 plan 하면 이 에러가 나고, VS Code 에도 빨간 줄이 생긴다.
- 해결: **`envs/dev` 에서** `terraform init`. 그래도 VS Code 에 빨간 줄이 남으면 `Ctrl+Shift+P` → *Developer: Reload Window*.
- ⚠️ **모듈 폴더(`modules/elasticache/`) 안에서 `terraform init` 을 하지 않는다.** 모듈은 혼자 실행하는 루트가 아니다. 실행하면 그 폴더에 `.terraform/`, `.terraform.lock.hcl` 가 생기는데 쓸모없고 헷갈리기만 한다 (이번에 생겨서 삭제함).

### 실제 결과 (2026-11-23, Redis 1노드 시절)
| 리소스 | 값 |
|---|---|
| RDS | `point-dev-pg.<id>.ap-northeast-2.rds.amazonaws.com`, `available`, 16.15 (`aarch64` — t4g 는 Graviton) |
| 마스터 비밀 | `arn:aws:secretsmanager:...:secret:rds!db-<uuid>` |
| Redis | `point-dev-redis.<id>.0001.apn2.cache.amazonaws.com`, `available`, 7.1.0 |

Valkey 복제 그룹으로 바꾼 뒤에는 엔드포인트 모양이 `master.point-dev-redis.<id>.apn2.cache.amazonaws.com` 류(primary 엔드포인트)가 된다 — ⚠️ 확인: 적용 후 `terraform output -raw redis_endpoint` 값으로 기록.

## 7-5. 원장 반영 Redis Stream (Kafka 대신, ADR-0019)

Kafka 클러스터를 따로 띄우지 않는다. 7-3 의 Valkey 하나가 이벤트 판정과 원장 반영 버퍼를 같이 맡는다. 만들 리소스는 없고, 9단계 앱이 뜨면 키가 생긴다.

```
event-service ──Lua 1회 (원자)──▶ Valkey
  판정(SADD participants / DECR stock) + 당첨이면 XADD event:{id}:rewards     ← 판정과 기록이 한 스크립트
core-service (consumer group point-ledger) ──XREADGROUP──▶ 원장 INSERT (idempotency_key UNIQUE) ──▶ XACK
```

| 키 | 타입 | 내용 |
|---|---|---|
| `event:{id}:rewards` | Stream | 퀴즈 당첨 기록. 7일 보존 (`XTRIM MINID`) — `XACK` 뒤에도 남긴다 |
| `attendance:{yyyyMMdd}:rewards` | Stream | 출석 보상 |
| `reward:streams` | Set | core-service 가 읽을 퀴즈 Stream 목록. 이벤트를 열 때 등록 |
| `reward:dlq` | Stream | 전달 5회 초과·비재시도 오류 → 운영자 재처리 |

- 재시도: 처리 안 된 항목(PEL)은 60초가 지나면 다른 core-service 파드가 `XPENDING` + `XCLAIM` 으로 가져간다
- 반영이 멱등(`idempotency_key`)이라 같은 항목이 두 번 와도 원장은 1건
- Kafka 때와 달리 **core-service 도 Redis 에 접속한다** → 9단계 core-service ConfigMap 에 `REDIS_HOST`·`REDIS_PORT`·`REWARD_STREAM_ENABLED=true`

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
         -c "$SQL" -c "GRANT CONNECT, CREATE ON DATABASE point TO app_rw;" \
            -c "GRANT USAGE, CREATE ON SCHEMA public TO app_rw;"'

kubectl wait pod/pg-init --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
kubectl logs pg-init          # DO / GRANT / GRANT
kubectl delete pod pg-init
```
- `GRANT CREATE ON DATABASE` — 새 스키마를 만들 수 있는 권한.
- `GRANT USAGE, CREATE ON SCHEMA public` — **public 스키마 안에 테이블을 만드는 권한.** core-service 의 Flyway 가 `public` 에 테이블을 만든다.
  PostgreSQL 15 부터 `public` 스키마의 CREATE 가 PUBLIC 에서 회수됐다 → 이게 없으면 9단계 core-service 가
  `ERROR: permission denied for schema public` 으로 CrashLoopBackOff (9단계에서 실제로 겪음. 처음엔 DATABASE 권한만 줬었다).
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
  -c "select current_user, has_database_privilege('point','CREATE') as can_create, has_schema_privilege('public','CREATE') as can_create_public;"

# 2) SSL 없이 접속하면 거부되는지 (Failed 가 정상)
run pg-nossl --image=postgres:16 --env PGPASSWORD="$APP_PW" --command -- \
  psql "host=$RDS user=app_rw dbname=point sslmode=disable" -c "select 1;"

# 3) Valkey — redis-cli 로 그대로 붙는다 (Redis 프로토콜 호환)
run rc --image=redis:7-alpine --command -- redis-cli -h $REDIS ping
run rrole --image=redis:7-alpine --command -- sh -c "redis-cli -h $REDIS info replication | grep -E '^(role|connected_slaves):'"   # role:master, connected_slaves:1

# 4) 복제 그룹 구성 (AWS 쪽)
aws elasticache describe-replication-groups --replication-group-id point-dev-redis \
  --query 'ReplicationGroups[0].[Status,AutomaticFailover,MultiAZ,length(MemberClusters)]' --output text   # available enabled enabled 2

# 5) (9단계 앱이 뜬 뒤) 원장 반영 Stream — consumer group point-ledger 의 pending·lag 가 0 이면 다 반영된 것
run rs --image=redis:7-alpine --command -- sh -c "for s in \$(redis-cli -h $REDIS smembers reward:streams); do echo \$s; redis-cli -h $REDIS xinfo groups \$s; done"
```

### 실제 결과 (2026-11-23 — Redis 1노드·Kafka 시절)
| 확인 | 결과 |
|---|---|
| app_rw 접속 | `Succeeded` — `current_user = app_rw`, `can_create = t` |
| SSL 없이 접속 | `Failed` — `no pg_hba.conf entry ... no encryption` (SSL 강제 동작) |
| Redis | `PONG` |
| Kafka (삭제됨) | `Created topic smoke-test.` → 목록에 `smoke-test` (3.8 CLI ↔ 4.3.2 브로커 호환) |

Valkey 복제 그룹 확인(3·4·5번)은 다시 올린 뒤 기록한다 — 자동 검사는 `tests/run.sh 07`.

로컬(WSL)에서 RDS·ElastiCache 로 직접 접속은 **안 되는 게 정상** (private 서브넷 + SG).

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| `Module not installed` / VS Code 빨간 줄 | 새 module 추가 후 `envs/dev` 에서 `terraform init` |
| core-service 로그 `reward stream read failed` | core-service ConfigMap 의 `REDIS_HOST` 가 비었거나 예전(1노드) 엔드포인트 → `terraform output -raw redis_endpoint` |
| 당첨인데 잔액이 안 바뀜 | `xinfo groups` 의 pending 이 쌓임 → core-service 로그의 `reward apply failed`, DLQ `xlen reward:dlq` |
| `syntax error at or near "$"` | K8s 가 `$$` → `$` 치환 → `$do$` 사용 |
| `jq: command not found` → 비밀번호가 빈 값 → 인증 실패 | jq 설치 (위 사전 준비). `set -o pipefail` 로 실패를 바로 잡기 |
| `pod ... terminated (Error)` 메시지 없음 | `-i --rm` 대신 wait → logs 패턴 |
| psql 타임아웃 | RDS SG 인바운드가 노드 SG 인지, 파드가 노드 SG 를 쓰는지 |
| `no pg_hba.conf entry ... no encryption` | `sslmode=require` |
| `permission denied for database` (Flyway) | `GRANT CREATE ON DATABASE point TO app_rw` 누락 |
| `permission denied for schema public` (Flyway) | PG15+ → `GRANT USAGE, CREATE ON SCHEMA public TO app_rw` 누락 |
| `InvalidParameterCombination` (ElastiCache) | 노드 타입이 Multi-AZ·자동 장애 조치를 지원하는지 / `num_cache_clusters` ≥ 2 인지 |
| `InvalidParameterCombination` (RDS) | 인스턴스 클래스와 엔진 버전 조합 미지원 → `describe-orderable-db-instance-options` |

## 🧹 정리
```bash
# RDS·ElastiCache 는 envs/dev terraform destroy 에 포함 (skip_final_snapshot = true 확인)
# (이전 Kafka 실습을 했던 클러스터라면) kubectl delete ns kafka — Strimzi Application 은 11단계 Git 에서 지웠다
rm -f ~/.config/point-dev/app_rw_password            # 8단계에서 Secrets Manager 에 넣은 뒤
```
- `manage_master_user_password` 가 만든 마스터 비밀(`rds!db-...`)은 RDS 삭제 시 함께 삭제된다.

💸 RDS db.t4g.micro ≈ 시간당 $0.02~0.03, ElastiCache cache.t4g.micro **× 2** ≈ 그 2배 (정확한 서울 단가는 가격 계산기로). 대신 Strimzi Kafka 가 쓰던 노드 메모리 1Gi 는 빠진다.
