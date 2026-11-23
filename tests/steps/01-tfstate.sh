# 1단계 — Terraform state 버킷 (bootstrap) + envs/dev backend
step 01 "Terraform state (S3 backend)"

BUCKET=$(grep -oP 'bucket\s*=\s*"\K[^"]+' "$REPO/envs/dev/versions.tf" | head -1)
info "backend 버킷: $BUCKET"
check "버킷 존재 (head-bucket)" aws s3api head-bucket --bucket "$BUCKET"
eq "버전 관리 Enabled (state 복구용)" "$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)" "Enabled"
eq "기본 암호화 AES256" "$(aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null)" "AES256"
PAB=$(aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null | jq -r '[.[]] | all')
eq "퍼블릭 액세스 차단 4개 모두 true" "$PAB" "true"
eq "버킷 리전" "$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text 2>/dev/null)" "$REGION"
check "state 객체 존재 (envs/dev/terraform.tfstate)" aws s3api head-object --bucket "$BUCKET" --key envs/dev/terraform.tfstate
if grep -q 'use_lockfile *= *true' "$REPO/envs/dev/versions.tf"; then ok "S3 네이티브 락 (use_lockfile = true)"; else ng "S3 네이티브 락" "설정 없음"; fi
LOCK=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix envs/dev/terraform.tfstate.tflock --query 'KeyCount' --output text 2>/dev/null)
case "$LOCK" in 0|None|"") ok "지금 잡힌 락 없음 (다른 apply 진행 중 아님)";; *) warn "지금 잡힌 락 없음" "lock 객체 $LOCK 개 — 다른 terraform 실행 중?";; esac
if [ -f "$REPO/bootstrap/terraform.tfstate" ]; then ok "bootstrap 은 local state (닭과 달걀)" "bootstrap/terraform.tfstate"; else warn "bootstrap local state" "파일 없음"; fi

# drift: 실제 리소스가 코드와 같은가 (변경 계획이 없어야 함)
if [ "${SKIP_PLAN:-0}" = 1 ]; then skip "terraform plan drift 없음" "SKIP_PLAN=1"; else
  terraform -chdir="$REPO/envs/dev" plan -detailed-exitcode -lock=false -input=false -no-color >/tmp/point-tests-plan.txt 2>&1; rc=$?
  case $rc in
    0) ok "envs/dev terraform plan: 변경 없음 (drift 0)";;
    2) ng "envs/dev terraform plan: 변경 없음" "$(grep -E '^Plan:|# .* will be' /tmp/point-tests-plan.txt | head -4 | tr '\n' ' ')";;
    *) ng "envs/dev terraform plan 실행" "$(grep -m2 -E 'Error' /tmp/point-tests-plan.txt)";;
  esac
fi
