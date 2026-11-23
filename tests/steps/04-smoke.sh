# 4단계 — smoke 앱 (Deployment / Service / probe / resources)
step 04 "smoke 앱"
requires_cluster "smoke 검사" || return
if ! kubectl get ns smoke >/dev/null 2>&1; then skip "smoke namespace" "없음 (정리했다면 정상)"; return; fi
check_deploy smoke nginx 2
D=$(kubectl get deploy nginx -n smoke -o json)
eq "readinessProbe 설정" "$(echo "$D" | jq -r '.spec.template.spec.containers[0].readinessProbe.httpGet.path // "없음"')" "/"
eq "livenessProbe 설정" "$(echo "$D" | jq -r '.spec.template.spec.containers[0].livenessProbe.httpGet.path // "없음"')" "/"
eq "requests.memory 설정" "$(echo "$D" | jq -r '.spec.template.spec.containers[0].resources.requests.memory // "없음"')" "32Mi"
eq "limits.memory 설정" "$(echo "$D" | jq -r '.spec.template.spec.containers[0].resources.limits.memory // "없음"')" "128Mi"
eq "Service 엔드포인트 = Ready 파드 수" "$(kubectl get endpointslices -n smoke -l kubernetes.io/service-name=nginx -o json | jq '[.items[].endpoints[]? | select(.conditions.ready)] | length')" "2"
# 각 nginx 파드에 "같은 노드"에서 / "다른 노드"에서 접속 — 노드 SG 가 포트 80 노드 간 통신을 막는지 드러난다
for row in $(kubectl get pods -n smoke -l app=nginx -o jsonpath='{range .items[*]}{.status.podIP},{.spec.nodeName}{"\n"}{end}'); do
  ip=${row%,*}; node=${row#*,}
  other=$(kubectl get nodes -l workload=core -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "$node" | head -1)
  for where in same:$node other:$other; do
    kubectl run "$TEST_POD_PREFIX-sm-${where%%:*}" -n "$NS_TEST" --restart=Never --image=curlimages/curl:8.10.1 --labels=app.kubernetes.io/part-of=point-tests \
      --overrides="{\"spec\":{\"nodeName\":\"${where#*:}\"}}" --command -- curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip/" >/dev/null 2>&1
  done
  sleep 12
  S1=$(kubectl logs -n "$NS_TEST" "$TEST_POD_PREFIX-sm-same" 2>/dev/null); S2=$(kubectl logs -n "$NS_TEST" "$TEST_POD_PREFIX-sm-other" 2>/dev/null)
  kubectl delete pod -n "$NS_TEST" "$TEST_POD_PREFIX-sm-same" "$TEST_POD_PREFIX-sm-other" --wait=false >/dev/null 2>&1; sleep 3
  eq "nginx 파드 $ip:80 — 같은 노드에서" "$S1" "200"
  if [ "$S2" = 200 ]; then ok "nginx 파드 $ip:80 — 다른 노드에서" "200"; else
    warn "nginx 파드 $ip:80 — 다른 노드에서" "${S2:-타임아웃} — 노드 SG 가 노드 간 1025 미만 포트를 막음 (EKS 모듈 기본: 1025-65535 + 53). point 앱(8080/8081)은 영향 없음"; fi
  break   # 파드 하나로 충분
done
