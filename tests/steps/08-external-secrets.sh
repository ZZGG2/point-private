# 8단계 — Secrets Manager → External Secrets Operator → K8s Secret
step 08 "External Secrets (Secrets Manager → K8s Secret)"

ACC=$(aws sts get-caller-identity --query Account --output text)
for s in point-dev/core-service point-dev/event-service; do
  check "Secrets Manager 비밀 $s 존재" aws secretsmanager describe-secret --secret-id "$s"
done
KEYS=$(aws secretsmanager get-secret-value --secret-id point-dev/core-service --query SecretString --output text 2>/dev/null | jq -r 'keys|join(",")')
eq "point-dev/core-service JSON 키" "$KEYS" "DB_PASSWORD,DB_URL,DB_USERNAME,JWT_PRIVATE_KEY"
EKEYS=$(aws secretsmanager get-secret-value --secret-id point-dev/event-service --query SecretString --output text 2>/dev/null | jq -r 'keys|join(",")')
eq "point-dev/event-service JSON 키 (이벤트 생성 API 토큰 포함)" "$EKEYS" "ADMIN_API_TOKEN,JWT_PUBLIC_KEY"

# 최소 권한 — IAM 정책 시뮬레이터 (실제 호출 없이 허용/거부 판정)
ROLE=arn:aws:iam::$ACC:role/point-dev-external-secrets
sim() { aws iam simulate-principal-policy --policy-source-arn "$ROLE" --action-names secretsmanager:GetSecretValue --resource-arns "$1" --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null; }
SM=arn:aws:secretsmanager:$REGION:$ACC:secret
eq "ESO 역할: point-dev/core-service 읽기 허용" "$(sim "$SM:point-dev/core-service-AbCdEf")" "allowed"
eq "ESO 역할: RDS 마스터 비밀(db-init 용 1개) 읽기 허용" "$(sim "$(tfo rds_master_secret_arn)")" "allowed"
eq "ESO 역할: 다른 RDS 마스터 비밀 거부 (와일드카드 아님)" "$(sim "$SM:rds!db-00000000-0000-0000-0000-000000000000-AbCdEf")" "implicitDeny"
eq "ESO 역할: 다른 접두사 비밀 거부" "$(sim "$SM:prod/anything-AbCdEf")" "implicitDeny"

requires_cluster "ESO 클러스터 검사" || return
for d in external-secrets external-secrets-webhook external-secrets-cert-controller; do check_deploy external-secrets $d 1; done
eq "ESO 이미지 v2.15.0" "$(kubectl get deploy -n external-secrets external-secrets -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -o 'v[0-9.]*$')" "v2.15.0"
match "Pod Identity association (external-secrets/external-secrets)" "$(aws eks list-pod-identity-associations --cluster-name point-dev-eks --namespace external-secrets --service-account external-secrets --query 'associations[0].associationId' --output text)" '^a-'
eq "ClusterSecretStore aws-sm Ready" "$(kubectl get clustersecretstore aws-sm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"
for e in core-service-db event-secrets db-master; do
  eq "ExternalSecret point/$e SecretSynced" "$(kubectl get externalsecret -n point $e -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)" "SecretSynced"
done

SEC=$(kubectl get secret core-service-db -n point -o json 2>/dev/null)
sk() { echo "$SEC" | jq -r --arg k "$1" '.data[$k] // empty' | base64 -d; }
eq "Secret core-service-db 키 목록" "$(echo "$SEC" | jq -r '.data|keys|join(",")')" "DB_PASSWORD,DB_URL,DB_USERNAME,JWT_PRIVATE_KEY"
eq "DB_USERNAME" "$(sk DB_USERNAME)" "app_rw"
match "DB_URL 이 sslmode=require" "$(sk DB_URL)" '^jdbc:postgresql://[^/]+:5432/point\?sslmode=require$'
eq "DB_URL 호스트 = terraform output rds_endpoint" "$(sk DB_URL | sed -E 's#jdbc:postgresql://([^:]+):.*#\1#')" "$(tfo rds_endpoint)"
EADM=$(kubectl get secret event-secrets -n point -o jsonpath='{.data.ADMIN_API_TOKEN}' 2>/dev/null | base64 -d | wc -c)
ge "event-secrets ADMIN_API_TOKEN 길이 (이벤트 생성 API, 값은 출력 안 함)" "$EADM" 24
SMPW=$(aws secretsmanager get-secret-value --secret-id point-dev/core-service --query SecretString --output text | jq -j .DB_PASSWORD | sha256sum)
[ "$(sk DB_PASSWORD | sha256sum)" = "$SMPW" ] && ok "K8s Secret 값 == Secrets Manager 값 (DB_PASSWORD 해시 비교)" || ng "K8s Secret 값 == Secrets Manager 값" "동기화 안 됨"

# JWT 키쌍 — 값은 출력하지 않고 파이프 안에서만 비교
match "JWT_PRIVATE_KEY 가 PKCS#8 (BEGIN PRIVATE KEY)" "$(sk JWT_PRIVATE_KEY | head -1)" '^-----BEGIN PRIVATE KEY-----$'
DER_PUB=$(sk JWT_PRIVATE_KEY | openssl pkey -pubout 2>/dev/null | sha256sum)
EV_PUB=$(kubectl get secret event-secrets -n point -o jsonpath='{.data.JWT_PUBLIC_KEY}' | base64 -d | openssl pkey -pubin 2>/dev/null | sha256sum)
[ -n "$EV_PUB" ] && [ "$DER_PUB" = "$EV_PUB" ] && ok "core-service 개인키 ↔ event-service 공개키 같은 쌍" || ng "JWT 키쌍 일치" "개인키에서 뽑은 공개키 ≠ event-secrets"
BITS=$(sk JWT_PRIVATE_KEY | openssl pkey -text -noout 2>/dev/null | grep -oP 'Private-Key: \(\K[0-9]+')
eq "JWT 키 길이 RSA 2048" "$BITS" "2048"

# 앱 파드가 실제로 같은 값을 쓰고 있는지 (envFrom 은 기동 시 1회 주입 → 회전 후 재시작 필요)
POD=$(kubectl get pods -n point -l app=core-service -o jsonpath='{.items[0].metadata.name}')
PSTART=$(kubectl get pod -n point "$POD" -o jsonpath='{.status.startTime}')
SREF=$(kubectl get externalsecret -n point core-service-db -o jsonpath='{.status.refreshTime}')
info "core-service 파드 기동 $PSTART / ExternalSecret 마지막 동기화 $SREF (Secret 이 파드보다 나중에 바뀌었으면 재시작 필요)"
