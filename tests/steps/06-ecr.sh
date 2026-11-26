# 6단계 — ECR 레포 + 이미지
step 06 "ECR"
IMG_TAG=${IMG_TAG:-v0.2.0}   # Kafka 제거·core-service·Boot 4 반영 이미지 (이전 v0.1.x 는 monolith 레포)
for r in core-service event-service web; do
  R=$(aws ecr describe-repositories --repository-names point/$r --output json 2>/dev/null)
  if [ -z "$R" ]; then ng "레포 point/$r 존재"; continue; fi
  eq "point/$r 태그 IMMUTABLE" "$(echo "$R" | jq -r '.repositories[0].imageTagMutability')" "IMMUTABLE"
  eq "point/$r scan on push" "$(echo "$R" | jq -r '.repositories[0].imageScanningConfiguration.scanOnPush')" "true"
  check "point/$r lifecycle 정책 (최근 10개 보관)" aws ecr get-lifecycle-policy --repository-name point/$r
  check "point/$r:$IMG_TAG 이미지 존재" aws ecr describe-images --repository-name point/$r --image-ids imageTag=$IMG_TAG
  CRIT=$(aws ecr describe-image-scan-findings --repository-name point/$r --image-id imageTag=$IMG_TAG --query 'imageScanFindings.findingSeverityCounts.CRITICAL' --output text 2>/dev/null)
  case "$CRIT" in None|""|0) ok "point/$r:$IMG_TAG CRITICAL 취약점 0" "${CRIT:-0}";; *) warn "point/$r:$IMG_TAG CRITICAL 취약점" "$CRIT 건 (기본 스캔)";; esac
done
# 클러스터가 실제로 쓰는 태그가 ECR 에 있는지 (overlay 의 images)
OV="$REPO/k8s/apps/overlays/dev/kustomization.yaml"
for r in core-service event-service web; do
  T=$(awk -v n="point/$r" '$0 ~ n"$" {getline; print $2}' "$OV")
  check "overlay 의 point/$r:$T 가 ECR 에 존재" aws ecr describe-images --repository-name point/$r --image-ids imageTag="$T"
done
if requires_cluster "노드 이미지 pull"; then
  BADPULL=$(kubectl get pods -A -o json | jq -r '.items[].status.containerStatuses[]? | select(.state.waiting.reason=="ImagePullBackOff" or .state.waiting.reason=="ErrImagePull") | .image' | sort -u)
  eq "ImagePullBackOff 없음 (노드 → ECR pull)" "${BADPULL:-없음}" "없음"
fi
