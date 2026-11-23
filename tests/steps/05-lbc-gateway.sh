# 5단계 — AWS Load Balancer Controller + Gateway API → ALB
step 05 "LB Controller + Gateway API"
requires_cluster "LBC 검사" || return
check_deploy kube-system aws-load-balancer-controller 2
eq "LBC 이미지 v3.6.3" "$(kubectl get deploy -n kube-system aws-load-balancer-controller -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -o 'v[0-9.]*$')" "v3.6.3"
PIA=$(aws eks list-pod-identity-associations --cluster-name point-dev-eks --namespace kube-system --service-account aws-load-balancer-controller --query 'associations[0].associationId' --output text 2>/dev/null)
match "Pod Identity association (kube-system/aws-load-balancer-controller)" "$PIA" '^a-'
eq "LBC values.yaml 의 vpcId = 실제 VPC" "$(grep -oP 'vpcId:\s*\K\S+' "$REPO/k8s/platform/aws-lbc/values.yaml")" "$(tfo vpc_id)"
for c in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io; do check "CRD $c" kubectl get crd $c; done
eq "Gateway API CRD 버전 v1.6.0" "$(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')" "v1.6.0"
eq "GatewayClass aws-alb Accepted" "$(kubectl get gatewayclass aws-alb -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')" "True"
LOGERR=$(kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=30m 2>/dev/null | grep -c '"level":"error"')
if [ "$LOGERR" = 0 ]; then ok "LBC 최근 30분 error 로그 0건"; else
  warn "LBC 최근 30분 error 로그 $LOGERR건" "$(kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=30m 2>/dev/null | grep '"level":"error"' | grep -oE '"object":\{[^}]*\}' | sort | uniq -c | tr -s ' ' | tr '\n' ';') — Gateway 삭제 직후의 재시도 오류면 정상"; fi

if kubectl get gateway -n smoke smoke-gw >/dev/null 2>&1; then
  eq "smoke-gw Programmed" "$(kubectl get gateway -n smoke smoke-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" "True"
  H=$(alb_host smoke smoke-gw); info "smoke ALB: $H"
  eq "인터넷(내 IP) → smoke ALB → nginx" "$(http_code "http://$H/")" "200"
  LB=$(aws elbv2 describe-load-balancers --output json | jq -r --arg h "$H" '.LoadBalancers[] | select(.DNSName==$h)')
  eq "ALB scheme internet-facing" "$(echo "$LB" | jq -r .Scheme)" "internet-facing"
  SGS=$(echo "$LB" | jq -r '.SecurityGroups[]')
  CIDRS=$(for g in $SGS; do aws ec2 describe-security-groups --group-ids "$g" --query 'SecurityGroups[].IpPermissions[].IpRanges[].CidrIp' --output text; done | tr '\t' '\n' | sort -u | tr '\n' ' ')
  nomatch "ALB SG 인바운드에 0.0.0.0/0 없음 (sourceRanges = 내 IP)" "$CIDRS" '0\.0\.0\.0/0'
else skip "smoke-gw" "없음"; fi
