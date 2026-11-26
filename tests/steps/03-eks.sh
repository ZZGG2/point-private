# 3단계 — EKS 클러스터, 애드온, core 노드그룹
step 03 "EKS 클러스터"

C=$(aws eks describe-cluster --name point-dev-eks --output json 2>/dev/null)
if [ -z "$C" ]; then ng "클러스터 point-dev-eks 존재" "없음"; return; fi
eq "클러스터 상태" "$(echo "$C" | jq -r .cluster.status)" "ACTIVE"
eq "Kubernetes 버전" "$(echo "$C" | jq -r .cluster.version)" "1.37"
eq "인증 모드 API (Access Entry, aws-auth 안 씀)" "$(echo "$C" | jq -r .cluster.accessConfig.authenticationMode)" "API"
eq "API 엔드포인트 public 접근" "$(echo "$C" | jq -r .cluster.resourcesVpcConfig.endpointPublicAccess)" "true"
MYIP=$(grep -oP 'my_ip_cidr\s*=\s*"\K[^"]+' "$REPO/envs/dev/terraform.tfvars" 2>/dev/null)
eq "API 엔드포인트 허용 CIDR = 내 IP 만" "$(echo "$C" | jq -r '.cluster.resourcesVpcConfig.publicAccessCidrs | join(",")')" "$MYIP"
NOW_IP="$(curl -s --max-time 5 https://checkip.amazonaws.com)/32"
eq_warn "현재 공인 IP 가 tfvars 의 my_ip_cidr 와 같음" "$NOW_IP" "$MYIP"
eq "컨트롤플레인 서브넷 = Private-App 3개" "$(echo "$C" | jq '.cluster.resourcesVpcConfig.subnetIds | length')" "3"

for a in vpc-cni eks-pod-identity-agent kube-proxy coredns metrics-server; do
  eq "애드온 $a ACTIVE" "$(aws eks describe-addon --cluster-name point-dev-eks --addon-name $a --query addon.status --output text 2>/dev/null)" "ACTIVE"
done

NG=$(aws eks list-nodegroups --cluster-name point-dev-eks --query 'nodegroups[0]' --output text)
NGJ=$(aws eks describe-nodegroup --cluster-name point-dev-eks --nodegroup-name "$NG" --output json)
eq "core 노드그룹 상태" "$(echo "$NGJ" | jq -r .nodegroup.status)" "ACTIVE"
eq "core 노드그룹 크기 min/max/desired" "$(echo "$NGJ" | jq -r '.nodegroup.scalingConfig | "\(.minSize)/\(.maxSize)/\(.desiredSize)"')" "3/4/3"
eq "core 노드그룹 ON_DEMAND" "$(echo "$NGJ" | jq -r .nodegroup.capacityType)" "ON_DEMAND"
eq "core 노드그룹 health 이슈 없음" "$(echo "$NGJ" | jq '.nodegroup.health.issues | length')" "0"

requires_cluster "kubectl 검사" || return
ok "kubectl → API 서버 /readyz"
KV=$(kubectl version -o json 2>/dev/null); CM=$(echo "$KV" | jq -r .clientVersion.minor); SM=$(echo "$KV" | jq -r .serverVersion.minor | tr -dc 0-9)
VD=$(( CM - SM )); VD=${VD#-}; if [ "$VD" -le 1 ]; then ok "kubectl ↔ 서버 마이너 버전 차이 ≤ 1" "client 1.$CM / server 1.$SM"; else ng "kubectl 버전 차이" "client 1.$CM / server 1.$SM"; fi
CORE=$(kubectl get nodes -l workload=core --no-headers 2>/dev/null)
eq "core 노드 3대 모두 Ready" "$(echo "$CORE" | grep -c ' Ready ')" "3"
eq "노드당 최대 파드 110 (VPC CNI prefix delegation)" "$(kubectl get nodes -l workload=core -o jsonpath='{.items[0].status.capacity.pods}')" "110"
eq "aws-node ENABLE_PREFIX_DELEGATION=true" "$(kubectl get ds aws-node -n kube-system -o json | jq -r '.spec.template.spec.containers[] | select(.name=="aws-node") | .env[] | select(.name=="ENABLE_PREFIX_DELEGATION") | .value')" "true"
for ds in aws-node kube-proxy eks-pod-identity-agent; do
  r=$(kubectl get ds -n kube-system $ds -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}')
  [ "${r%/*}" = "${r#*/}" ] && ok "DaemonSet $ds 전 노드 Ready" "$r" || ng "DaemonSet $ds 전 노드 Ready" "$r"
done
NSG=$(tfo node_security_group_id)
NR=$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$NSG" --output json | jq -c '[.SecurityGroupRules[] | select((.IsEgress|not) and .ReferencedGroupInfo.GroupId=="'"$NSG"'") | "\(.IpProtocol):\(.FromPort)-\(.ToPort)"] | sort')
eq "노드 SG: 노드 간 허용 = DNS 53 + 1025-65535" "$NR" '["tcp:1025-65535","tcp:53-53","udp:53-53"]'
APP_PORTS=$(kubectl get pods -A -o json | jq -r '[.items[] | select(.metadata.namespace|test("^(point|monitoring|argocd|keda|external-secrets)$")) | select(.spec.hostNetwork|not) | .spec.containers[].ports[]?.containerPort | select(. < 1025)] | unique | join(",")')
eq "앱 파드(point·모니터링 등) 컨테이너 포트 전부 ≥ 1025 (노드 간 통신 가능)" "${APP_PORTS:-없음}" "없음"
check_deploy kube-system coredns 2
check_deploy kube-system metrics-server 1
check "metrics API 동작 (kubectl top nodes)" kubectl top nodes
check "Access Entry: 현재 주체가 cluster-admin" kubectl auth can-i '*' '*' --all-namespaces
BAD=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v -E ' Running | Completed ' | awk '{print $1"/"$2" "$4}')
eq_warn "클러스터 전체에 비정상 파드 없음" "${BAD:-없음}" "없음"
RS=$(kubectl get pods -A -o json | jq -r '[.items[] | {n:"\(.metadata.namespace)/\(.metadata.name)", r:([.status.containerStatuses[]?.restartCount]|add // 0)}] | map(select(.r>=5)) | map("\(.n)=\(.r)") | join(" ")')
eq_warn "재시작 5회 이상인 파드 없음" "${RS:-없음}" "없음"
