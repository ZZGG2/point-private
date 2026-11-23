# 0단계 — 도구, AWS 자격증명, Git, 비밀값 유출 방지
step 00 "준비 (도구 · Git · 비밀값)"

for t in aws terraform kubectl helm jq docker curl openssl argocd; do
  if have "$t"; then ok "도구 설치: $t" "$(command -v "$t")"; else
    case $t in argocd|docker) warn "도구 설치: $t" "없음 (11단계 diff / 10단계 k6 에 필요)";; *) ng "도구 설치: $t" "없음";; esac; fi
done

TFV=$(terraform version -json 2>/dev/null | jq -r .terraform_version)
if ver_ge "$TFV" 1.10.0; then ok "Terraform ≥ 1.10 (S3 use_lockfile)" "$TFV"; else ng "Terraform ≥ 1.10" "$TFV"; fi
info "aws $(aws --version 2>&1 | cut -d' ' -f1 | cut -d/ -f2) · helm $(helm version --short 2>/dev/null) · jq $(jq --version 2>/dev/null)"

ID=$(aws sts get-caller-identity --output json 2>/dev/null)
if [ -n "$ID" ]; then ok "AWS 자격증명 유효" "$(echo "$ID" | jq -r .Arn | sed 's/:[0-9]\{12\}:/:<계정>:/')"; else ng "AWS 자격증명 유효" "sts get-caller-identity 실패"; fi
eq "AWS 리전 설정" "$(aws configure get region 2>/dev/null || echo "${AWS_REGION:-}")" "$REGION"

# Git
cd "$REPO" || return
eq "Git 원격 origin" "$(git remote get-url origin 2>/dev/null | sed 's#.*github.com[:/]##')" "ZZGG2/point-private.git"
git fetch -q origin 2>/dev/null
eq_warn "로컬 master == origin/master (ArgoCD 가 보는 커밋)" "$(git rev-parse HEAD)" "$(git rev-parse origin/master 2>/dev/null)"
DIRTY=$(git status --porcelain | grep -v '^?? tests/reports/' | wc -l)
eq_warn "작업 트리 깨끗함 (커밋 안 된 변경 없음)" "$DIRTY" "0"

for p in '.terraform/' '*.tfstate' '*.tfvars' 'kubeconfig*' '.env'; do
  if grep -qxF "$p" .gitignore; then ok ".gitignore 에 $p"; else ng ".gitignore 에 $p" "누락"; fi
done
TRACKED=$(git ls-files | grep -E '\.tfstate|\.tfvars$|kubeconfig|\.pem$|\.env$' | tr '\n' ' ')
eq "추적 중인 민감 파일 없음 (tfstate/tfvars/pem/env)" "${TRACKED:-없음}" "없음"
if git ls-files | grep -q '\.terraform\.lock\.hcl$'; then ok ".terraform.lock.hcl 커밋됨 (provider 버전 고정)"; else warn ".terraform.lock.hcl 커밋됨" "없음"; fi
LEAK=$(git grep -n -I -E 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|aws_secret_access_key|ghp_[A-Za-z0-9]{20,}|github_pat_' $(git rev-list --all) -- ':!docs' ':!tests' 2>/dev/null | head -3)
eq "Git 히스토리 전체에 비밀값 패턴 없음 (개인키·AWS키·GitHub토큰)" "${LEAK:-없음}" "없음"
for f in ~/.config/point-dev/app_rw_password ~/.config/point-dev/grafana_admin_password; do
  if [ -f "$f" ]; then eq "로컬 비밀 파일 권한 600: $(basename "$f")" "$(stat -c %a "$f")" "600"; else warn "로컬 비밀 파일 존재: $(basename "$f")" "없음"; fi
done
