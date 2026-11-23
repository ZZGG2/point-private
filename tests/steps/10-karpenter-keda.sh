# 10단계 — Karpenter (노드) + KEDA (파드) 자동 확장
step 10 "Karpenter + KEDA"

ACC=$(aws sts get-caller-identity --query Account --output text)
Q=$(tfo karpenter_queue_name)
check "중단 알림 SQS 큐 $Q" aws sqs get-queue-url --queue-name "$Q"
RULES=$(aws events list-rule-names-by-target --target-arn "arn:aws:sqs:$REGION:$ACC:$Q" --query 'length(RuleNames)' --output text 2>/dev/null)
eq "EventBridge 규칙 → SQS (spot 중단·리밸런스·상태변경·health·용량예약)" "$RULES" "5"
eq "노드 역할 Access Entry (EC2_LINUX)" "$(aws eks describe-access-entry --cluster-name point-dev-eks --principal-arn "arn:aws:iam::$ACC:role/$(tfo karpenter_node_role_name)" --query accessEntry.type --output text 2>/dev/null)" "EC2_LINUX"
check "Spot 서비스 연결 역할" aws iam get-role --role-name AWSServiceRoleForEC2Spot
match "Pod Identity association (kube-system/karpenter)" "$(aws eks list-pod-identity-associations --cluster-name point-dev-eks --namespace kube-system --service-account karpenter --query 'associations[0].associationId' --output text)" '^a-'

requires_cluster "Karpenter/KEDA 클러스터 검사" || return
check_deploy kube-system karpenter 1
eq "Karpenter 버전 1.15.3" "$(kubectl get deploy -n kube-system karpenter -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oP 'controller:\K[0-9.]+')" "1.15.3"
KPN=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].spec.nodeName}')
eq "Karpenter 컨트롤러는 core 노드에 (자기 노드 위 X)" "$(kubectl get node "$KPN" -o jsonpath='{.metadata.labels.workload}')" "core"
KERR=$(kubectl logs -n kube-system deploy/karpenter --since=30m 2>/dev/null | grep -c '"level":"ERROR"')
eq_warn "Karpenter 최근 30분 ERROR 로그 0건" "$KERR" "0"
eq "NodePool event Ready" "$(kubectl get nodepool event -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"
eq "NodePool 비용 상한 limits.cpu" "$(kubectl get nodepool event -o jsonpath='{.spec.limits.cpu}')" "16"
eq "NodePool taint workload=event:NoSchedule" "$(kubectl get nodepool event -o jsonpath='{.spec.template.spec.taints[0].key}={.spec.template.spec.taints[0].value}:{.spec.template.spec.taints[0].effect}')" "workload=event:NoSchedule"
NC=$(kubectl get ec2nodeclass default -o json)
eq "EC2NodeClass default Ready" "$(echo "$NC" | jq -r '.status.conditions[] | select(.type=="Ready") | .status')" "True"
eq "EC2NodeClass 가 찾은 서브넷 3개 (discovery 태그)" "$(echo "$NC" | jq '.status.subnets | length')" "3"
eq "EC2NodeClass 가 찾은 SG = 노드 SG" "$(echo "$NC" | jq -r '[.status.securityGroups[].id] | join(",")')" "$(tfo node_security_group_id)"
ge "EC2NodeClass AMI 해석됨 (al2023@latest)" "$(echo "$NC" | jq '.status.amis | length')" 1

EN=$(kubectl get nodes -l workload=event -o json)
NEN=$(echo "$EN" | jq '.items | length'); NNC=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
eq "event 노드 수 == NodeClaim 수" "$NEN" "$NNC"
if [ "$NEN" -gt 0 ]; then
  eq "event 노드 전부 Ready" "$(echo "$EN" | jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')" "$NEN"
  eq "event 노드 전부 taint 있음" "$(echo "$EN" | jq '[.items[] | select(any(.spec.taints[]?; .key=="workload" and .value=="event"))] | length')" "$NEN"
  info "event 노드: $(echo "$EN" | jq -r '[.items[] | "\(.metadata.labels["node.kubernetes.io/instance-type"])/\(.metadata.labels["karpenter.sh/capacity-type"])/\(.metadata.labels["topology.kubernetes.io/zone"])"] | join(" ")')"
  eq_warn "event 노드가 Spot (Spot 우선 requirements)" "$(echo "$EN" | jq -r '[.items[].metadata.labels["karpenter.sh/capacity-type"]] | unique | join(",")')" "spot"
  OTHER=$(kubectl get pods -A -o json | jq -r --argjson n "$(echo "$EN" | jq '[.items[].metadata.name]')" '.items[] | select(.spec.nodeName as $x | $n | index($x)) | select((.metadata.ownerReferences[0].kind // "")!="DaemonSet") | select(.metadata.labels.app!="event-service") | "\(.metadata.namespace)/\(.metadata.name)"' | tr '\n' ' ')
  eq "event 노드에는 event-service 와 DaemonSet 만" "${OTHER:-없음}" "없음"
fi
EVN=$(kubectl get pods -n point -l app=event-service -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
CORE_EV=$(for n in $EVN; do kubectl get node "$n" -o jsonpath='{.metadata.labels.workload}{"\n"}'; done | grep -c core)
eq "event-service 파드가 core 노드에 없음 (nodeSelector)" "$CORE_EV" "0"
ORPH=$(aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=event Name=instance-state-name,Values=running,pending --query 'length(Reservations[].Instances[])' --output text)
eq "Karpenter EC2 수 == event 노드 수 (고아 인스턴스 없음)" "$ORPH" "$NEN"

# Git 렌더링에 replicas 가 없어야 HPA 와 싸우지 않음
R=$(kubectl kustomize "$REPO/k8s/apps/overlays/dev" 2>/dev/null | awk '/^kind: Deployment/{d=1} d&&/^  name: event-service/{e=1} e&&/^  replicas:/{print "있음"; exit} /^---/{d=0;e=0}')
eq "Git 의 event-service Deployment 에 replicas 없음" "${R:-없음}" "없음"

for d in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do check_deploy keda $d 1; done
eq "external.metrics API (KEDA) Available" "$(kubectl get apiservice v1beta1.external.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" "True"
eq "metrics.k8s.io API (metrics-server) Available" "$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" "True"
eq "ScaledObject event-service Ready" "$(kubectl get scaledobject -n point event-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" "True"
eq "ScaledObject 트리거 (cron, cpu)" "$(kubectl get scaledobject -n point event-service -o jsonpath='{.spec.triggers[*].type}')" "cron cpu"
HPA=$(kubectl get hpa -n point keda-hpa-event-service -o json)
eq "HPA min/max" "$(echo "$HPA" | jq -r '"\(.spec.minReplicas)/\(.spec.maxReplicas)"')" "1/20"
CPU=$(echo "$HPA" | jq -r '.status.currentMetrics[]? | select(.type=="Resource") | .resource.current.averageUtilization // empty')
match "HPA CPU 메트릭 수집됨 (unknown 아님)" "${CPU:-unknown}" '^[0-9]+$'
eq "HPA ScalingActive" "$(echo "$HPA" | jq -r '.status.conditions[] | select(.type=="ScalingActive") | .status')" "True"
info "HPA 현재 replicas $(echo "$HPA" | jq -r .status.currentReplicas) / desired $(echo "$HPA" | jq -r .status.desiredReplicas), CPU ${CPU:-?}%"

if [ "${HEAVY:-0}" != 1 ]; then skip "부하 → HPA 확장 실험" "--heavy 로 실행"; return; fi
ALB=$(alb_host point point-gw); TOKEN=$(login_token "$ALB" demo5@point.local)
BEFORE=$(kubectl get hpa -n point keda-hpa-event-service -o jsonpath='{.status.desiredReplicas}'); NC0=$NNC
info "부하 시작: 250 RPS × 90초 (현재 desired $BEFORE, NodeClaim $NC0)"
docker run --rm -i -e BASE_URL="http://$ALB" -e EVENT_ID=evt-local -e TOKEN="$TOKEN" -e RATE=250 -e HOLD=90s \
  grafana/k6 run --quiet - < "$REPO/load-test/s2-event-spike-dev.js" > /tmp/point-tests-k6.log 2>&1 &
K6=$!; t0=$(date +%s); UP=""; MAXD=$BEFORE; MAXN=$NC0
while kill -0 $K6 2>/dev/null; do
  d=$(kubectl get hpa -n point keda-hpa-event-service -o jsonpath='{.status.desiredReplicas}'); n=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
  [ "$d" -gt "$MAXD" ] && MAXD=$d; [ "$n" -gt "$MAXN" ] && MAXN=$n
  [ -z "$UP" ] && [ "$d" -gt "$BEFORE" ] && UP=$(( $(date +%s)-t0 ))
  sleep 5
done
wait $K6; KRC=$?
eq "k6 임계값 통과 (p95<500ms, 실패율<1%)" "$KRC" "0"
info "k6: $(grep -oE 'p\(95\)=[0-9.]+m?s' /tmp/point-tests-k6.log | head -1), $(grep -E 'http_reqs' /tmp/point-tests-k6.log | awk '{print $2" req"}' | head -1)"
if [ -n "$UP" ]; then ok "부하 → HPA 확장" "$BEFORE → 최대 $MAXD, 첫 증가 ${UP}초"; else ng "부하 → HPA 확장" "desired $BEFORE 그대로"; fi
if [ "$MAXN" -gt "$NC0" ]; then ok "Karpenter 노드 추가" "NodeClaim $NC0 → $MAXN"; else info "노드 추가 없음 (기존 노드에 자리가 있었음, 최대 desired $MAXD)"; fi
info "축소/노드 회수는 5분(scaleDown 안정화) + 1분(consolidateAfter) 뒤 — 이 테스트는 기다리지 않는다"
