# 0단계. 준비 — 도구, Git, 디렉터리 구조

## 0-1. 도구 확인

```bash
aws --version && terraform version && kubectl version --client && helm version
```

| 도구 | 설치 위치 | 비고 |
|---|---|---|
| aws CLI v2 | `~/.local/bin/aws` | |
| terraform 1.17.2 | `~/.local/bin/terraform` | |
| kubectl 1.37.2 | `~/.local/bin/kubectl` | 아래 "kubectl 버전 맞추기" 참고 |
| helm v4.3.2 | `~/.local/bin/helm` | |
| jq 1.7.1 | `~/.local/bin/jq` | 7단계부터 필요 (Secrets Manager JSON 파싱). 설치법은 [07-data.md](07-data.md#사전-준비) |

### kubectl 버전 맞추기 (3단계 이후 실제로 겪은 문제)
- kubectl 은 **클러스터와 ±1 마이너 버전**까지만 지원한다. 클러스터를 1.37 로 만들었는데 kubectl 이 1.35 였다.
- `sudo snap refresh kubectl --channel=1.37/stable` → **실패**. snap 에는 1.36 채널까지만 있었다.
  ```bash
  snap info kubectl | grep stable     # 채널 목록 먼저 확인할 것
  ```
- 해결: 공식 바이너리를 `~/.local/bin` 에 설치 (sudo 불필요, PATH 에서 `/snap/bin` 보다 앞)
  ```bash
  V=$(curl -fsSL https://dl.k8s.io/release/stable-1.37.txt)          # 예: v1.37.2
  curl -fsSLO https://dl.k8s.io/release/$V/bin/linux/amd64/kubectl
  curl -fsSLO https://dl.k8s.io/release/$V/bin/linux/amd64/kubectl.sha256
  echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check            # kubectl: OK
  install -m 0755 kubectl ~/.local/bin/kubectl
  hash -r && which kubectl && kubectl version
  ```
- 이미 열린 터미널은 예전 경로를 캐시하므로 `hash -r` 또는 새 터미널.
- 교훈: **EKS 버전을 고르기 전에 kubectl 을 그 버전에 맞출 수 있는지 먼저 확인.**

## 0-2. AWS 권한 확인

```bash
aws sts get-caller-identity
aws iam list-attached-user-policies --user-name <IAM사용자>
```
EKS·VPC·IAM 역할 생성 권한이 있어야 한다. 3단계의 `enable_cluster_creator_admin_permissions` 는
**Terraform 을 실행한 IAM 주체**를 클러스터 admin 으로 등록하므로, 이후 kubectl 도 같은 주체로 써야 한다.

## 0-3. 비용 안전장치
- 이번 실습은 하루 쓰고 지우는 전제라 AWS Budgets 알림은 생략했다.
- 대신 **끝날 때 역순 정리**를 반드시 지킨다. 알림이 막아 주는 건 "destroy 깜빡"이므로, 장기간 쓸 거면 그때 만든다.

## 0-4. Git 연동

`point-private` 는 GitHub 에서 레포를 만들 때 README 대신 `ROADMAP.md` 로 초기 커밋을 한 상태라
`git init` / `git remote add` 는 필요 없었다. 확인:
```bash
cd ~/point/point-private
git remote -v          # origin = https://github.com/<계정>/point-private.git
git status -sb         # ## master...origin/master
```

### (선택) 기본 브랜치를 main 으로
```bash
git branch -m master main
git push -u origin main
# GitHub → Settings → Branches → Default branch 를 main 으로 변경 후
git push origin --delete master
```

### `.gitignore` — push 전에 먼저
state·tfvars 는 계정 정보·비밀값이 들어갈 수 있고, **한 번이라도 커밋되면 히스토리에 남는다.**
```gitignore
# Terraform
.terraform/
*.tfstate
*.tfstate.*
crash.log
*.tfvars
!*.tfvars.example
*.tfplan
tfplan

# Kubernetes
kubeconfig*

# 기타
.env
.DS_Store
```
- `.terraform.lock.hcl` 은 **커밋한다** — provider 정확한 버전·해시를 고정해서 다른 PC 에서도 같은 버전을 쓰게 함.
- `!*.tfvars.example` — 예시 파일만 예외로 커밋.

## 0-5. 디렉터리 구조

```bash
cd ~/point/point-private
mkdir -p bootstrap \
         modules/{vpc,eks,ecr,rds,elasticache,karpenter} \
         envs/dev \
         k8s/{smoke,platform,apps} \
         docs/{log,guide}
```
- `mkdir -p` : 중간 폴더까지 한 번에, 이미 있어도 에러 없음
- `{a,b}` : bash brace expansion → `modules/vpc modules/eks ...` 로 펼쳐짐

Git 은 **빈 폴더를 추적하지 않는다** → `.gitkeep` 을 넣어 구조를 커밋:
```bash
find . -path ./.git -prune -o -type d -empty -print -exec touch {}/.gitkeep \;
tree -a -I .git
```

| 폴더 | 역할 |
|---|---|
| `bootstrap/` | 1단계 — state 버킷 (local state) |
| `modules/*` | 재사용 단위. "어떻게" 만드는지 (규칙·태그·기본값) |
| `envs/dev/` | 실제 `terraform apply` 하는 곳. "무엇을" (CIDR, 이름, 버전) |
| `k8s/smoke/` | 4~5단계 테스트 앱 |
| `k8s/platform/` | LB Controller, External Secrets, Karpenter, KEDA 설정 |
| `k8s/apps/` | 9단계 point 앱 |
| `docs/guide/` | 이 가이드 |
| `docs/log/` | 단계별 실습 기록 (에러·해결·비용) |

```bash
git add . && git commit -m "chore: add .gitignore and directory skeleton" && git push
```

✅ **완료 기준:** 도구 명령 모두 동작, kubectl 이 클러스터 버전 ±1, `.gitignore` 와 폴더 구조가 GitHub 에 보임.
