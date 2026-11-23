# 비용 · 고아 리소스 점검 (모든 단계 공통) — 정리를 잊으면 과금되는 것들
step 99 "비용 · 고아 리소스"
info "EC2 실행 중: $(aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].[InstanceType,InstanceLifecycle]' --output text | awk '{print $1"/"($2==""||$2=="None"?"on-demand":$2)}' | sort | uniq -c | awk '{print $2"×"$1}' | tr '\n' ' ')"
info "ALB: $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text | tr '\t' ' ')"
info "NAT $(aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'length(NatGateways)' --output text)개 · RDS $(aws rds describe-db-instances --query 'length(DBInstances)' --output text)개 · ElastiCache $(aws elasticache describe-cache-clusters --query 'length(CacheClusters)' --output text)개 · 비밀 $(aws secretsmanager list-secrets --query 'length(SecretList)' --output text)개"
eq "연결 안 된 EBS 볼륨 없음 (available)" "$(aws ec2 describe-volumes --filters Name=status,Values=available --query 'length(Volumes)' --output text)" "0"
eq "연결 안 된 Elastic IP 없음" "$(aws ec2 describe-addresses --query 'length(Addresses[?AssociationId==null])' --output text)" "0"
ALBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].DNSName' --output text | tr '\t' '\n')
if requires_cluster "ALB ↔ Gateway 대응"; then
  GWS=$(kubectl get gateway -A -o jsonpath='{range .items[*]}{.status.addresses[0].value}{"\n"}{end}')
  ORPH=$(comm -23 <(echo "$ALBS" | sort -u) <(echo "$GWS" | sort -u) | grep -v '^$' | tr '\n' ' ')
  eq "Gateway 없는 고아 ALB 없음" "${ORPH:-없음}" "없음"
  # LBC 가 만든 ALB 보안그룹(태그 gateway.k8s.aws.alb/stack=<ns>/<gateway>) 중 Gateway 가 없는 것
  SGORPH=$(for st in $(aws ec2 describe-security-groups --filters Name=tag-key,Values=gateway.k8s.aws.alb/stack --query 'SecurityGroups[].Tags[?Key==`gateway.k8s.aws.alb/stack`].Value[]' --output text); do
    kubectl get gateway -n "${st%/*}" "${st#*/}" >/dev/null 2>&1 || echo "$st"; done | tr '\n' ' ')
  eq "Gateway 없는 고아 ALB 보안그룹 없음" "${SGORPH:-없음}" "없음"
fi
if [ "$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text)" -gt 0 ]; then
  warn "리소스가 떠 있음 — 과금 중" "끝나면 11단계 정리 순서대로 (root → Application → 앱/노드 → terraform destroy)"
fi
