# 7단계 — RDS PostgreSQL, ElastiCache Redis, Strimzi Kafka, app_rw
step 07 "데이터 계층 (RDS · Redis · Kafka)"

NODE_SG=$(tfo node_security_group_id)
DB=$(aws rds describe-db-instances --db-instance-identifier point-dev-pg --output json 2>/dev/null | jq '.DBInstances[0]')
if [ -n "$DB" ] && [ "$DB" != null ]; then
  eq "RDS 상태" "$(echo "$DB" | jq -r .DBInstanceStatus)" "available"
  eq "RDS 엔진 버전" "$(echo "$DB" | jq -r .EngineVersion)" "16.15"
  eq "RDS 인스턴스 클래스" "$(echo "$DB" | jq -r .DBInstanceClass)" "db.t4g.micro"
  eq "RDS 퍼블릭 접근 불가" "$(echo "$DB" | jq -r .PubliclyAccessible)" "false"
  eq "RDS 스토리지 암호화" "$(echo "$DB" | jq -r .StorageEncrypted)" "true"
  match "RDS 마스터 비밀번호 = Secrets Manager 관리" "$(echo "$DB" | jq -r '.MasterUserSecret.SecretArn // "없음"')" 'secret:rds!db-'
  PG=$(echo "$DB" | jq -r '.DBParameterGroups[0].DBParameterGroupName')
  eq "rds.force_ssl = 1 (파라미터 그룹 $PG)" "$(aws rds describe-db-parameters --db-parameter-group-name "$PG" --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue" --output text 2>/dev/null)" "1"
  RSG=$(echo "$DB" | jq -r '.VpcSecurityGroups[0].VpcSecurityGroupId')
  RULES=$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$RSG" --output json | jq -c '[.SecurityGroupRules[] | select(.IsEgress|not)]')
  eq "RDS SG 인바운드 = 노드 SG 에서 5432 만" "$(echo "$RULES" | jq -r 'map("\(.ReferencedGroupInfo.GroupId // .CidrIpv4):\(.FromPort)") | join(",")')" "$NODE_SG:5432"
else ng "RDS point-dev-pg 존재"; fi

RC=$(aws elasticache describe-cache-clusters --cache-cluster-id point-dev-redis --output json 2>/dev/null | jq '.CacheClusters[0]')
if [ -n "$RC" ] && [ "$RC" != null ]; then
  eq "Redis 상태" "$(echo "$RC" | jq -r .CacheClusterStatus)" "available"
  match "Redis 엔진 버전 7.1.x" "$(echo "$RC" | jq -r .EngineVersion)" '^7\.1'
  eq "Redis 노드 타입" "$(echo "$RC" | jq -r .CacheNodeType)" "cache.t4g.micro"
  XSG=$(echo "$RC" | jq -r '.SecurityGroups[0].SecurityGroupId')
  eq "Redis SG 인바운드 = 노드 SG 에서 6379 만" "$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$XSG" --output json | jq -r '[.SecurityGroupRules[] | select(.IsEgress|not) | "\(.ReferencedGroupInfo.GroupId // .CidrIpv4):\(.FromPort)"] | join(",")')" "$NODE_SG:6379"
else ng "ElastiCache point-dev-redis 존재"; fi

requires_cluster "클러스터 안 접속 테스트" || return
RDS=$(tfo rds_endpoint); REDIS=$(tfo redis_endpoint)
APP_PW=$(kubectl get secret monolith-db -n point -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d)
if [ -n "$APP_PW" ]; then
  if kpod pg-app postgres:16 90 --env PGPASSWORD="$APP_PW" -- psql "host=$RDS user=app_rw dbname=point sslmode=require" -tAc \
     "select current_user||','||has_database_privilege('point','CREATE')||','||has_schema_privilege('public','CREATE')||','||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"; then
    eq "app_rw 접속 → user, DB CREATE, public 스키마 CREATE, SSL" "$KPOD_OUT" "app_rw,true,true,true"
  else ng "app_rw 접속 (sslmode=require)" "$KPOD_OUT"; fi
  if kpod pg-nossl postgres:16 60 --env PGPASSWORD="$APP_PW" -- psql "host=$RDS user=app_rw dbname=point sslmode=disable" -c 'select 1'; then
    ng "SSL 없이 접속은 거부돼야 함" "접속됨!"; else match "SSL 없이 접속 거부 (rds.force_ssl)" "$KPOD_OUT" 'no pg_hba.conf entry|no encryption'; fi
  if kpod pg-flyway postgres:16 60 --env PGPASSWORD="$APP_PW" -- psql "host=$RDS user=app_rw dbname=point sslmode=require" -tAc \
     "select count(*)||','||bool_and(success) from flyway_schema_history"; then
    match "Flyway 마이그레이션 이력 (개수,전부 성공)" "$KPOD_OUT" '^[0-9]+,(t|true)$'; else ng "Flyway 이력 조회" "$KPOD_OUT"; fi
else ng "app_rw 비밀번호 (Secret monolith-db.DB_PASSWORD)" "없음 — 8단계 확인"; fi

if kpod redis redis:7-alpine 40 -- redis-cli -h "$REDIS" ping; then eq "Redis PING (노드 SG 경유)" "$KPOD_OUT" "PONG"; else ng "Redis PING" "$KPOD_OUT"; fi
if kpod redis-ver redis:7-alpine 40 -- sh -c "redis-cli -h $REDIS info server | grep redis_version"; then match "Redis 서버 버전" "$KPOD_OUT" 'redis_version:7\.1'; else ng "Redis INFO" "$KPOD_OUT"; fi

check_deploy kafka strimzi-cluster-operator 1
eq "Kafka point Ready" "$(kubectl get kafka point -n kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"
eq "Kafka 버전" "$(kubectl get kafka point -n kafka -o jsonpath='{.status.kafkaVersion}')" "4.3.2"
eq "KafkaNodePool dual (KRaft controller+broker) 1개" "$(kubectl get kafkanodepool dual -n kafka -o jsonpath='{.status.replicas}')" "1"
check_deploy kafka point-entity-operator 1
KB=point-kafka-bootstrap.kafka.svc:9092
if kpod kafka-topics apache/kafka:3.8.0 120 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server $KB --list; then
  match "토픽 point.reward.requested 존재 (event-service → monolith)" "$KPOD_OUT" '^point\.reward\.requested$'
else ng "Kafka 토픽 목록" "$(echo "$KPOD_OUT" | tail -2)"; fi
if kpod kafka-lag apache/kafka:3.8.0 120 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server $KB --describe --group point-ledger; then
  LAG=$(echo "$KPOD_OUT" | awk '$2=="point.reward.requested" {s+=$6} END {print s+0}')
  CONS=$(echo "$KPOD_OUT" | awk '$2=="point.reward.requested" && $7!="-" {c++} END {print c+0}')
  eq "consumer group point-ledger LAG = 0 (monolith 가 다 소비)" "$LAG" "0"
  ge "consumer group point-ledger 활성 consumer" "$CONS" 1
else ng "consumer group point-ledger 조회" "$(echo "$KPOD_OUT" | tail -2)"; fi
