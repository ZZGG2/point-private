# 9단계 — point 앱 (monolith · event-service · web) + Gateway/ALB + E2E 시나리오
step 09 "point 앱 · ALB · E2E"
requires_cluster "앱 검사" || return

check_deploy point monolith 2
check_deploy point event-service 1
check_deploy point web 2
for d in monolith event-service web; do
  T=$(kubectl get deploy -n point $d -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
  info "$d 이미지 태그 $T"
done
ML=$(kubectl logs -n point deploy/monolith --tail=-1 2>/dev/null)
match "monolith 프로필 local (데모 시드)" "$ML" 'profile.? (is )?active.*"?local"?'
match "monolith 기동 완료 로그" "$ML" 'Started MonolithApplication'
for d in monolith event-service; do
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
eq "GET /api/points/balance 토큰 없음 → 401 (monolith)" "$(http_code "http://$ALB/api/points/balance")" "401"
eq "POST /api/events/.../answers 토큰 없음 → 401 (event-service)" "$(http_code -X POST "http://$ALB/api/events/evt-local/answers" -H 'Content-Type: application/json' -d '{"answer":"A"}')" "401"
eq "위조 토큰 → 401" "$(http_code "http://$ALB/api/points/balance" -H 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.AAAA')" "401"
eq "잘못된 비밀번호 로그인 → 401" "$(http_code -X POST "http://$ALB/api/auth/login" -H 'Content-Type: application/json' -d '{"email":"demo1@point.local","password":"wrong"}')" "401"
eq "관리자 API 잘못된 토큰 → 403" "$(http_code "http://$ALB/api/admin/events/evt-local/settlement" -H 'X-Admin-Token: local-admin-token')" "403"
ADMIN=$(kubectl get secret monolith-db -n point -o jsonpath='{.data.ADMIN_API_TOKEN}' | base64 -d)
eq "관리자 API Secret 토큰 → 200" "$(http_code "http://$ALB/api/admin/events/evt-local/settlement" -H "X-Admin-Token: $ADMIN")" "200"

# 로그인 / JWT
HDRS=$(curl -s --max-time 10 -D - -o /tmp/point-tests-login.json -X POST "http://$ALB/api/auth/login" -H 'Content-Type: application/json' -d '{"email":"demo1@point.local","password":"demo1234!"}')
T1=$(jq -r '.data.accessToken // empty' /tmp/point-tests-login.json)
if [ -n "$T1" ]; then ok "demo1 로그인 → access token"; else ng "demo1 로그인" "$(head -c 200 /tmp/point-tests-login.json)"; fi
PAY=$(echo "$T1" | cut -d. -f2 | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' | base64 -d 2>/dev/null)
eq "JWT alg RS256" "$(echo "$T1" | cut -d. -f1 | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' | base64 -d 2>/dev/null | jq -r .alg)" "RS256"
eq "JWT iss" "$(echo "$PAY" | jq -r .iss)" "point-monolith"
eq "JWT 유효기간 15분 (exp-iat)" "$(echo "$PAY" | jq -r '.exp-.iat')" "900"
RC=$(echo "$HDRS" | grep -i '^set-cookie:' | head -1)
if [ -n "$RC" ]; then nomatch "refresh 쿠키에 Secure 없음 (ALB 가 HTTP, AUTH_COOKIE_SECURE=false)" "$RC" '[Ss]ecure'; match "refresh 쿠키 HttpOnly" "$RC" 'HttpOnly'; else warn "refresh 쿠키" "Set-Cookie 없음"; fi
match "demo1 잔액 조회" "$(curl -s --max-time 10 "http://$ALB/api/points/balance" -H "Authorization: Bearer $T1")" '"balance":[0-9]+'
# 여러 파드가 같은 키로 서명/검증하는지 — 같은 토큰으로 여러 번 (요청이 monolith 2개에 분산)
CODES=$(for i in $(seq 1 10); do http_code "http://$ALB/api/points/balance" -H "Authorization: Bearer $T1"; echo; done | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
eq "같은 토큰 10회 → 전부 200 (monolith 2파드 키 공유)" "$CODES" " 10 200 "

# E2E: 테스트 전용 이벤트 (stock 2, 100P) → 당첨 → Kafka → 정산 대기 → 정산 → 잔액
if [ "${E2E:-1}" != 1 ]; then skip "E2E 시나리오" "--no-e2e"; return; fi
EV="evt-test-$(date +%m%d%H%M%S)"; info "E2E 이벤트 $EV (데이터 변경: demo2·3 잔액 +100P)"
bal() { curl -s --max-time 10 "http://$ALB/api/points/balance" -H "Authorization: Bearer $1" | jq -r .data.balance; }
ans() { http_code -X POST "http://$ALB/api/events/$EV/answers" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"answer":"A"}'; }
T2=$(login_token "$ALB" demo2@point.local); T3=$(login_token "$ALB" demo3@point.local); T4=$(login_token "$ALB" demo4@point.local)
B2=$(bal "$T2"); B3=$(bal "$T3"); B4=$(bal "$T4")
eq "열기 전 참여 → 410 (CLOSED)" "$(ans "$T2")" "410"
OPEN=$(curl -s --max-time 10 -X POST "http://$ALB/api/events/$EV/open?stock=2&amount=100")
match "이벤트 열기 (stock 2, 100P)" "$OPEN" '"open":true.*|"remainingStock":2'
t0=$(date +%s%N)
eq "demo2 참여 → 202 당첨" "$(ans "$T2")" "202"
eq "demo2 재참여 → 409 중복" "$(ans "$T2")" "409"
eq "demo3 참여 → 202 당첨" "$(ans "$T3")" "202"
eq "demo4 참여 → 200 낙첨 (재고 소진)" "$(ans "$T4")" "200"
ST=$(curl -s --max-time 10 "http://$ALB/api/events/$EV/status" | jq -c '.data | {participants,winners,remainingStock}')
eq "이벤트 상태" "$ST" '{"participants":3,"winners":2,"remainingStock":0}'
P=""; for i in $(seq 1 30); do P=$(curl -s --max-time 5 "http://$ALB/api/admin/events/$EV/settlement" -H "X-Admin-Token: $ADMIN" | jq -r '.data.pendingCount // 0'); [ "$P" = 2 ] && break; sleep 1; done
t1=$(date +%s%N)
eq "Kafka → monolith 정산 대기 2건" "$P" "2"
info "당첨 → 정산 대기 반영까지 $(( (t1-t0)/1000000 ))ms (HTTP 4회 포함)"
eq "정산 전 잔액 변화 없음 (demo2)" "$(bal "$T2")" "$B2"
SET=$(curl -s --max-time 15 -X POST "http://$ALB/api/admin/events/$EV/settlement" -H "X-Admin-Token: $ADMIN" -H 'Content-Type: application/json' -d '{"expectedCount":2}' | jq -c '.data | {rowCount,totalAmount,appliedNow}')
eq "정산 실행" "$SET" '{"rowCount":2,"totalAmount":200,"appliedNow":2}'
eq "demo2 잔액 +100" "$(bal "$T2")" "$((B2+100))"
eq "demo3 잔액 +100" "$(bal "$T3")" "$((B3+100))"
eq "demo4 잔액 그대로 (낙첨)" "$(bal "$T4")" "$B4"
RE=$(curl -s --max-time 15 -X POST "http://$ALB/api/admin/events/$EV/settlement" -H "X-Admin-Token: $ADMIN" -H 'Content-Type: application/json' -d '{"expectedCount":2}' | jq -c '.data | {appliedNow,repaired}')
eq "재정산 → 중복 지급 없음 (멱등)" "$RE" '{"appliedNow":0,"repaired":true}'
eq "정산 상태 COMPLETE, 미반영 0" "$(curl -s --max-time 10 "http://$ALB/api/admin/events/$EV/settlement" -H "X-Admin-Token: $ADMIN" | jq -c '.data | {state,unappliedCount,ledgerCount}')" '{"state":"COMPLETE","unappliedCount":0,"ledgerCount":2}'
