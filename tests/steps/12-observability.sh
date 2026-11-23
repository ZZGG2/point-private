# 12단계 — kube-prometheus-stack (Prometheus · Grafana) + 앱 지표
step 12 "관측성 (Prometheus · Grafana)"
requires_cluster "모니터링 검사" || return

for d in kps-kube-prometheus-stack-operator kps-grafana kps-kube-state-metrics; do check_deploy monitoring $d 1; done
eq "Prometheus StatefulSet Ready" "$(kubectl get sts -n monitoring prometheus-kps-kube-prometheus-stack-prometheus -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')" "1/1"
r=$(kubectl get ds -n monitoring kps-prometheus-node-exporter -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}')
[ "${r%/*}" = "${r#*/}" ] && ok "node-exporter 전 노드 (Karpenter 노드 포함)" "$r" || ng "node-exporter 전 노드" "$r"
eq "Alertmanager 비활성 (실습)" "$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | wc -l)" "0"
eq "Prometheus retention 1d" "$(kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.retention}')" "1d"
eq "ServiceMonitor point/point-backend 존재" "$(kubectl get servicemonitor -n point point-backend -o name 2>/dev/null)" "servicemonitor.monitoring.coreos.com/point-backend"

if pf_start monitoring svc/kps-kube-prometheus-stack-prometheus 19090:9090; then
  P=http://127.0.0.1:19090
  pq() { curl -s --max-time 10 --get "$P/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "없음"'; }
  TG=$(curl -s --max-time 10 "$P/api/v1/targets?state=active")
  eq "Prometheus DOWN 타겟 0개" "$(echo "$TG" | jq '[.data.activeTargets[] | select(.health!="up")] | length')" "0"
  info "활성 타겟 $(echo "$TG" | jq '.data.activeTargets | length')개: $(echo "$TG" | jq -r '[.data.activeTargets[].labels.job] | group_by(.) | map("\(.[0])×\(length)") | join(" ")')"
  NM=$(kubectl get pods -n point -l app=monolith --no-headers | wc -l); NE=$(kubectl get pods -n point -l app=event-service --field-selector=status.phase=Running --no-headers | wc -l)
  eq "monolith 타겟 up 수 = 파드 수" "$(pq 'sum(up{namespace="point",job="monolith"})')" "$NM"
  eq "event-service 타겟 up 수 = 파드 수" "$(pq 'sum(up{namespace="point",job="event-service"})')" "$NE"
  ge "http_server_requests 히스토그램 버킷 (p95 계산 가능)" "$(pq 'count(http_server_requests_seconds_bucket{namespace="point"})')" 10
  match "event-service p95 계산됨 (최근 5분, 초)" "$(pq 'histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="point",service="event-service"}[5m])))')" '^[0-9.e+-]+$|^NaN$'
  ge "JVM 지표 수집 (jvm_memory_used_bytes 시리즈)" "$(pq 'count(jvm_memory_used_bytes{namespace="point"})')" 1
  ge "Kafka consumer 지표 (monolith spring-kafka)" "$(pq 'count({namespace="point",__name__=~"kafka_consumer_.*"})')" 1
  eq "kube_node_labels{label_workload=event} = event 노드 수 (allowlist)" "$(pq 'count(kube_node_labels{label_workload="event"}) or vector(0)')" "$(kubectl get nodes -l workload=event --no-headers | wc -l)"
  ge "HPA 지표 (kube-state-metrics)" "$(pq 'count(kube_horizontalpodautoscaler_status_desired_replicas{namespace="point"})')" 1
  ge "컨테이너 CPU 지표 (cAdvisor)" "$(pq 'count(container_cpu_usage_seconds_total{namespace="point",container="event-service"})')" 1
  pf_stop
else ng "Prometheus port-forward"; fi

GP=$(kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
eq "grafana-admin 비밀번호에 줄바꿈 없음 (24자)" "${#GP}" "24"
if pf_start monitoring svc/kps-grafana 13000:80; then
  GF=http://127.0.0.1:13000
  eq "Grafana 인증 없이 API → 401" "$(http_code "$GF/api/search")" "401"
  eq "Grafana admin 로그인 (existingSecret)" "$(http_code -u "admin:$GP" "$GF/api/user")" "200"
  eq "Prometheus 데이터소스 health" "$(curl -s --max-time 15 -u "admin:$GP" "$GF/api/datasources/uid/prometheus/health" | jq -r .status)" "OK"
  D=$(curl -s --max-time 10 -u "admin:$GP" "$GF/api/dashboards/uid/point-scaling")
  eq "대시보드 point-scaling 로드됨 (ConfigMap 사이드카)" "$(echo "$D" | jq -r '.dashboard.uid // "없음"')" "point-scaling"
  eq "대시보드 패널 6개" "$(echo "$D" | jq '.dashboard.panels | length')" "6"
  # 대시보드의 모든 쿼리가 실제로 데이터를 돌려주는지 (Grafana 경유)
  NOW=$(date +%s)000; FROM=$(( $(date +%s) - 900 ))000
  for i in $(seq 0 5); do
    T=$(echo "$D" | jq -r ".dashboard.panels[$i].title"); E=$(echo "$D" | jq -c ".dashboard.panels[$i].targets[0].expr")
    BODY=$(jq -n --argjson e "$E" --arg f "$FROM" --arg t "$NOW" '{queries:[{refId:"A",datasource:{uid:"prometheus"},expr:$e,intervalMs:30000,maxDataPoints:50}],from:$f,to:$t}')
    NF=$(curl -s --max-time 20 -u "admin:$GP" -H 'Content-Type: application/json' -X POST "$GF/api/ds/query" -d "$BODY" | jq '[.results.A.frames[]?.data.values[1]? // [] | length] | add // 0')
    ge "대시보드 패널 \"$T\" 데이터 있음" "$NF" 1
  done
  pf_stop
else ng "Grafana port-forward"; fi
