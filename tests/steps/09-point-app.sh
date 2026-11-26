# 9단계 — point 앱 (core-service · event-service · web) + Gateway/ALB + E2E 시나리오
step 09 "point 앱 · ALB · E2E"
requires_cluster "앱 검사" || return

check_deploy point core-service 2
check_deploy point event-service 1
check_deploy point web 2
for d in core-service event-service web; do
  T=$(kubectl get deploy -n point $d -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
  info "$d 이미지 태그 $T"
done
ML=$(kubectl logs -n point deploy/core-service --tail=-1 2>/dev/null)
match "core-service 프로필 local (데모 시드)" "$ML" 'profile.? (is )?active.*"?local"?'
match "core-service 기동 완료 로그" "$ML" 'Started CoreServiceApplication'
nomatch "core-service Redis Stream 읽기 오류 없음 (REDIS_HOST)" "$ML" 'reward stream read failed'
for d in core-service event-service; do
  eq "$d securityContext runAsNonRoot" "$(kubectl get deploy -n point $d -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}')" "true"
  eq "$d startupProbe 설정" "$(kubectl get deploy -n point $d -o jsonpath='{.spec.template.spec.containers[0].startupProbe.httpGet.path}')" "/actuator/health/liveness"
done

eq "Gateway point-gw Programmed" "$(kubectl get gateway -n point point-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" "True"
eq "HTTPRoute point Accepted/ResolvedRefs" "$(kubectl get httproute -n point point -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}/{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')" "True/True"
ALB=$(alb_host point point-gw); info "point ALB: $ALB"
LBARN=$(aws elbv2 describe-load-balancers --output json | jq -r --arg h "$ALB" '.LoadBalancers[] | select(.DNSName==$h) | .LoadBalancerArn')
for tg in $(aws elbv2 describe-target-groups --load-balancer-arn "$LBARN" --query 'TargetGroups[].TargetGroupArn' --output text); do
  TH=$(aws elbv2 describe-target-health --target-group-arn "$tg" --output json)
  N=$(aws elbv2 describe-target-groups --target-group-arns "$tg" --query 'TargetGroups[0].[HealthCheckPath,TargetType]' --output text | tr '\t' ' ')
  H=$(echo "$TH" | jq -r '[.TargetHealthDescriptions[].TargetHealth.State] | group_by(.) | map("\(.[0])×\(length)") | join(" ")')
  if echo "$TH" | jq -e '[.TargetHealthDescriptions[].TargetHealth.State] | length>0 and all(.=="healthy")' >/dev/null; then ok "타겟그룹 전부 healthy ($N)" "$H"; else ng "타겟그룹 전부 healthy ($N)" "$H"; fi
done
SGS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LBARN" --query 'LoadBalancers[0].SecurityGroups' --output text)
CIDRS=$(for g in $SGS; do aws ec2 describe-security-groups --group-ids "$g" --query 'SecurityGroups[].IpPermissions[].IpRanges[].CidrIp' --output text; done | tr '\t' '\n' | sort -u | tr '\n' ' ')
nomatch "point ALB SG 에 0.0.0.0/0 없음" "$CIDRS" '0\.0\.0\.0/0'

# 라우팅 (HTTPRoute 3분기)
eq "GET /healthz → web" "$(curl -s --max-time 10 "http://$ALB/healthz")" "ok"
match "GET / → web (SPA index)" "$(curl -s --max-time 10 "http://$ALB/")" '<title>Point Platform</title>'
eq "GET /admin → web SPA 라우팅 200" "$(http_code "http://$ALB/admin")" "200"
match "GET /actuator/health → web 으로 감 (앱 actuator 비노출)" "$(curl -s --max-time 10 -o /dev/null -w '%{content_type}' "http://$ALB/actuator/health")" '^text/html'
match "GET /api/events/evt-local/status → event-service" "$(curl -s --max-time 10 "http://$ALB/api/events/evt-local/status")" '"eventId":"evt-local"'
eq "GET /api/points/balance 토큰 없음 → 401 (core-service)" "$(http_code "http://$ALB/api/points/balance")" "401"
eq "POST /api/events/.../answers 토큰 없음 → 401 (event-service)" "$(http_code -X POST "http://$ALB/api/events/evt-local/answers" -H 'Content-Type: application/json' -d '{"answer":"A"}')" "401"
eq "위조 토큰 → 401" "$(http_code "http://$ALB/api/points/balance" -H 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.AAAA')" "401"
eq "잘못된 비밀번호 로그인 → 401" "$(http_code -X POST "http://$ALB/api/auth/login" -H 'Content-Type: application/json' -d '{"email":"demo1@point.local","password":"wrong"}')" "401"
# 일괄 정산 API 는 제거됐다 (point-infra ADR-0018). /api/admin/** 는 공통 SecurityConfig 에 공개 경로로 남아 있어 401 이 아니라 404
eq "정산 API 제거됨 (/api/admin/** → 404)" "$(http_code "http://$ALB/api/admin/events/evt-local/settlement")" "404"
# 운영용 이벤트 생성 API (event-service, X-Admin-Token) — 토큰이 없거나 틀리면 403
EVBODY='{"stock":1,"amount":100,"endsAt":"2099-01-01T00:00:00+09:00"}'
eq "이벤트 생성 API 토큰 없음 → 403" "$(http_code -X POST "http://$ALB/api/events/admin/evt-noauth" -H 'Content-Type: application/json' -d "$EVBODY")" "403"
eq "이벤트 생성 API 틀린 토큰 → 403" "$(http_code -X POST "http://$ALB/api/events/admin/evt-noauth" -H 'X-Admin-Token: wrong' -H 'Content-Type: application/json' -d "$EVBODY")" "403"

# 로그인 / JWT
HDRS=$(curl -s --max-time 10 -D - -o /tmp/point-tests-login.json -X POST "http://$ALB/api/auth/login" -H 'Content-Type: application/json' -d '{"email":"demo1@point.local","password":"demo1234!"}')
T1=$(jq -r '.data.accessToken // empty' /tmp/point-tests-login.json)
if [ -n "$T1" ]; then ok "demo1 로그인 → access token"; else ng "demo1 로그인" "$(head -c 200 /tmp/point-tests-login.json)"; fi
PAY=$(echo "$T1" | cut -d. -f2 | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' | base64 -d 2>/dev/null)
eq "JWT alg RS256" "$(echo "$T1" | cut -d. -f1 | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' | base64 -d 2>/dev/null | jq -r .alg)" "RS256"
eq "JWT iss" "$(echo "$PAY" | jq -r .iss)" "point-core"
eq "JWT 유효기간 15분 (exp-iat)" "$(echo "$PAY" | jq -r '.exp-.iat')" "900"
RC=$(echo "$HDRS" | grep -i '^set-cookie:' | head -1)
if [ -n "$RC" ]; then nomatch "refresh 쿠키에 Secure 없음 (ALB 가 HTTP, AUTH_COOKIE_SECURE=false)" "$RC" '[Ss]ecure'; match "refresh 쿠키 HttpOnly" "$RC" 'HttpOnly'; else warn "refresh 쿠키" "Set-Cookie 없음"; fi
match "demo1 잔액 조회" "$(curl -s --max-time 10 "http://$ALB/api/points/balance" -H "Authorization: Bearer $T1")" '"balance":[0-9]+'
# 여러 파드가 같은 키로 서명/검증하는지 — 같은 토큰으로 여러 번 (요청이 core-service 2개에 분산)
CODES=$(for i in $(seq 1 10); do http_code "http://$ALB/api/points/balance" -H "Authorization: Bearer $T1"; echo; done | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
eq "같은 토큰 10회 → 전부 200 (core-service 2파드 키 공유)" "$CODES" " 10 200 "

# E2E: 운영용 생성 API 로 테스트 이벤트 (stock 2, 100P) → 당첨 → Redis Stream → 원장 즉시 반영 → 잔액 (ADR-0018·0019)
if [ "${E2E:-1}" != 1 ]; then skip "E2E 시나리오" "--no-e2e"; return; fi
EV="evt-test-$(date +%m%d%H%M%S)"; info "E2E 이벤트 $EV (데이터 변경: demo2·3 잔액 +100P)"
bal() { curl -s --max-time 10 "http://$ALB/api/points/balance" -H "Authorization: Bearer $1" | jq -r .data.balance; }
ans() { http_code -X POST "http://$ALB/api/events/$EV/answers" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"answer":"A"}'; }
T2=$(login_token "$ALB" demo2@point.local); T3=$(login_token "$ALB" demo3@point.local); T4=$(login_token "$ALB" demo4@point.local)
B2=$(bal "$T2"); B3=$(bal "$T3"); B4=$(bal "$T4")
eq "열기 전 참여 → 410 (CLOSED)" "$(ans "$T2")" "410"
ADM=$(aws secretsmanager get-secret-value --secret-id point-dev/event-service --query SecretString --output text 2>/dev/null | jq -r '.ADMIN_API_TOKEN // empty')
ENDS=$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ)
CREATE=$(curl -s --max-time 10 -X POST "http://$ALB/api/events/admin/$EV" -H "X-Admin-Token: $ADM" -H 'Content-Type: application/json' \
  -d "{\"stock\":2,\"amount\":100,\"endsAt\":\"$ENDS\"}")
match "이벤트 생성 (관리자 API, stock 2, 100P, 30분 뒤 마감)" "$CREATE" '"code":"CREATED"'
eq "같은 id 로 다시 생성 → 409" "$(http_code -X POST "http://$ALB/api/events/admin/$EV" -H "X-Admin-Token: $ADM" -H 'Content-Type: application/json' -d "{\"stock\":2,\"amount\":100,\"endsAt\":\"$ENDS\"}")" "409"
t0=$(date +%s%N)
eq "demo2 참여 → 202 당첨" "$(ans "$T2")" "202"
eq "demo2 재참여 → 409 중복" "$(ans "$T2")" "409"
eq "demo3 참여 → 202 당첨" "$(ans "$T3")" "202"
eq "demo4 참여 → 200 낙첨 (재고 소진)" "$(ans "$T4")" "200"
ST=$(curl -s --max-time 10 "http://$ALB/api/events/$EV/status" | jq -c '.data | {participants,winners,remainingStock}')
eq "이벤트 상태" "$ST" '{"participants":3,"winners":2,"remainingStock":0}'
# 당첨 → Redis Stream(event:{id}:rewards) → core-service consumer group point-ledger → 원장. 별도 정산 없이 자동으로 잔액에 반영돼야 한다
N2=""; N3=""; for i in $(seq 1 30); do N2=$(bal "$T2"); N3=$(bal "$T3"); [ "$N2" = "$((B2+100))" ] && [ "$N3" = "$((B3+100))" ] && break; sleep 1; done
t1=$(date +%s%N)
eq "demo2 잔액 +100 (자동 반영)" "$N2" "$((B2+100))"
eq "demo3 잔액 +100 (자동 반영)" "$N3" "$((B3+100))"
info "당첨 → 잔액 반영까지 $(( (t1-t0)/1000000 ))ms (HTTP 4회 포함)"
eq "demo4 잔액 그대로 (낙첨)" "$(bal "$T4")" "$B4"
# 멱등: 이벤트당 원장 1건. 잠시 뒤에도 잔액이 더 늘지 않는다 (재전달돼도 idempotency_key 로 1회만)
hist() { curl -s --max-time 10 "http://$ALB/api/points/history" -H "Authorization: Bearer $1" | jq --arg ev "$EV" '[.data[] | select(.referenceId == $ev)] | length'; }
eq "demo2 원장에 이 이벤트 1건" "$(hist "$T2")" "1"
sleep 3
eq "3초 뒤에도 demo2 잔액 +100 (중복 지급 없음)" "$(bal "$T2")" "$((B2+100))"
