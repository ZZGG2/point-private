# 7단계 — RDS PostgreSQL, ElastiCache Valkey(복제 그룹, Multi-AZ), 원장 반영 Redis Stream, app_rw
# Kafka(Strimzi)는 point-infra ADR-0019 로 제거됐다
step 07 "데이터 계층 (RDS · Valkey · Redis Stream)"

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

RG=$(aws elasticache describe-replication-groups --replication-group-id point-dev-redis --output json 2>/dev/null | jq '.ReplicationGroups[0]')
if [ -n "$RG" ] && [ "$RG" != null ]; then
  eq "Valkey 복제 그룹 상태" "$(echo "$RG" | jq -r .Status)" "available"
  eq "엔진 valkey" "$(echo "$RG" | jq -r .Engine)" "valkey"
  eq "노드 2개 (primary + replica)" "$(echo "$RG" | jq -r '.MemberClusters | length')" "2"
  eq "자동 장애 조치" "$(echo "$RG" | jq -r .AutomaticFailover)" "enabled"
  eq "Multi-AZ" "$(echo "$RG" | jq -r .MultiAZ)" "enabled"
  eq "Cluster mode 비활성" "$(echo "$RG" | jq -r .ClusterEnabled)" "false"
  eq "노드 타입" "$(echo "$RG" | jq -r .CacheNodeType)" "cache.t4g.micro"
  AZS=$(aws elasticache describe-cache-clusters --show-cache-node-info --output json 2>/dev/null | jq -r '[.CacheClusters[] | select(.ReplicationGroupId=="point-dev-redis") | .PreferredAvailabilityZone] | unique | length')
  eq "두 노드가 서로 다른 AZ" "$AZS" "2"
  XSG=$(aws elasticache describe-cache-clusters --cache-cluster-id "$(echo "$RG" | jq -r '.MemberClusters[0]')" --output json | jq -r '.CacheClusters[0].SecurityGroups[0].SecurityGroupId')
  eq "Valkey SG 인바운드 = 노드 SG 에서 6379 만" "$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$XSG" --output json | jq -r '[.SecurityGroupRules[] | select(.IsEgress|not) | "\(.ReferencedGroupInfo.GroupId // .CidrIpv4):\(.FromPort)"] | join(",")')" "$NODE_SG:6379"
  eq "terraform output redis_endpoint = primary 엔드포인트" "$(tfo redis_endpoint)" "$(echo "$RG" | jq -r '.NodeGroups[0].PrimaryEndpoint.Address')"
else ng "ElastiCache 복제 그룹 point-dev-redis 존재"; fi

requires_cluster "클러스터 안 접속 테스트" || return
RDS=$(tfo rds_endpoint); REDIS=$(tfo redis_endpoint)
APP_PW=$(kubectl get secret core-service-db -n point -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d)
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
else ng "app_rw 비밀번호 (Secret core-service-db.DB_PASSWORD)" "없음 — 8단계 확인"; fi

if kpod redis redis:7-alpine 40 -- redis-cli -h "$REDIS" ping; then eq "Redis PING (노드 SG 경유)" "$KPOD_OUT" "PONG"; else ng "Redis PING" "$KPOD_OUT"; fi
if kpod redis-ver redis:7-alpine 40 -- sh -c "redis-cli -h $REDIS info server | grep valkey_version"; then match "Valkey 서버 버전 7.2" "$KPOD_OUT" 'valkey_version:7\.2'; else ng "Valkey INFO" "$KPOD_OUT"; fi
if kpod redis-role redis:7-alpine 40 -- sh -c "redis-cli -h $REDIS info replication | grep -E '^(role|connected_slaves):'"; then
  match "primary 엔드포인트 = master, replica 1개 연결" "$(echo "$KPOD_OUT" | tr -d '\r' | tr '\n' ' ')" 'role:master connected_slaves:1'
else ng "Valkey INFO replication" "$KPOD_OUT"; fi

# 원장 반영 Redis Stream (ADR-0019): event-service 가 XADD → core-service consumer group point-ledger 가 읽고 XACK
# 9단계 앱이 떠 있어야 Stream·group 이 생긴다 (출석 Stream 은 출석이 있어야 생김)
if kpod reward-streams redis:7-alpine 60 -- sh -c '
  echo "registry=$(redis-cli -h '"$REDIS"' scard reward:streams)"
  for s in $(redis-cli -h '"$REDIS"' smembers reward:streams); do
    [ "$(redis-cli -h '"$REDIS"' exists "$s")" = 1 ] || continue
    redis-cli -h '"$REDIS"' xinfo groups "$s" | paste - - - - - - - - - - - - | awk -v s="$s" "{for(i=1;i<NF;i+=2) v[\$i]=\$(i+1); print \"group \" s \" \" v[\"name\"] \" pending=\" v[\"pending\"] \" lag=\" v[\"lag\"]}"
  done
  echo "dlq=$(redis-cli -h '"$REDIS"' xlen reward:dlq)"'; then
  ge "등록된 퀴즈 보상 Stream (reward:streams)" "$(echo "$KPOD_OUT" | sed -n 's/^registry=//p')" 1
  G=$(echo "$KPOD_OUT" | grep '^group ')
  if [ -n "$G" ]; then
    eq "모든 Stream 에 consumer group point-ledger" "$(echo "$G" | awk '$3!="point-ledger"' | wc -l)" "0"
    sum() { echo "$G" | grep -o "$1=[0-9]*" | awk -F= '{s+=$2} END {print s+0}'; }
    eq "pending(PEL) 합계 = 0 (core-service 가 다 XACK)" "$(sum pending)" "0"
    eq "lag 합계 = 0 (아직 안 읽은 항목 없음)" "$(sum lag)" "0"
  else warn "consumer group point-ledger" "Stream 이 아직 없음 — 9단계 E2E 뒤 다시 실행"; fi
  eq "DLQ reward:dlq 비어 있음" "$(echo "$KPOD_OUT" | sed -n 's/^dlq=//p')" "0"
else ng "Redis Stream 조회" "$(echo "$KPOD_OUT" | tail -2)"; fi
