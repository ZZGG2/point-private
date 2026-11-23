# 8단계. Secret 관리 (External Secrets Operator)

## 목표
DB 비밀번호·JWT 키 같은 값을 **Git 에도, Terraform state 에도 두지 않고** AWS Secrets Manager → 쿠버네티스 Secret 으로 주입한다.

```
AWS Secrets Manager                       EKS
  point-dev/monolith  ──┐                 ┌─ ClusterSecretStore aws-sm (어디서 읽나)
  point-dev/event     ──┼── ESO 컨트롤러 ──┤
                        │ (Pod Identity)  └─ ExternalSecret (무엇을 → 어떤 Secret 으로)
                        └──────────────────▶  Secret monolith-db / event-secrets
```

> 아직 실습 전 작성한 가이드. "⚠️ 확인" 은 진행 시 갱신.

## 앱이 필요로 하는 비밀값 (point-backend 코드 기준)

| 앱 | 환경변수 | 설명 |
|---|---|---|
| monolith | `DB_URL` | `jdbc:postgresql://<rds>:5432/point?sslmode=require` |
| | `DB_USERNAME` / `DB_PASSWORD` | `app_rw` / 7단계에서 만든 비밀번호 |
| | `JWT_PRIVATE_KEY` | RS256 서명 키 (PKCS#8 PEM). **local 프로필이 아니면 없을 때 기동 실패**. 파드가 2개 이상이면 반드시 같은 키여야 함 |
| | `ADMIN_API_TOKEN` | `/api/admin/**` 용 |
| event-service | `JWT_PUBLIC_KEY` | 위 키의 공개키 (X.509 PEM). `JWT_JWK_SET_URI` 와 둘 중 하나 필수 |

`point-infra/k8s/platform/external-secrets/README.md` 의 설계: Secret 이름 `monolith-db`, ClusterSecretStore 이름 `aws-sm`.

## 8-1. 비밀값 만들기 (CLI — Git·state 밖에서)
```bash
mkdir -p ~/tmp-secrets && cd ~/tmp-secrets       # 레포 밖!

# JWT 키쌍
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt-private.pem   # PKCS#8 PEM
openssl pkey -in jwt-private.pem -pubout -out jwt-public.pem                         # X.509 SubjectPublicKeyInfo PEM
head -1 jwt-private.pem jwt-public.pem
#   -----BEGIN PRIVATE KEY-----   ← "RSA PRIVATE KEY" 면 PKCS#1 → 앱이 못 읽음
#   -----BEGIN PUBLIC KEY-----

RDS=$(cd ~/point/point-private/envs/dev && terraform output -raw rds_endpoint)
APP_PW=$(cat ~/.config/point-dev/app_rw_password)      # 7단계 7-6 에서 만든 파일

# PEM 의 줄바꿈을 JSON 문자열로 안전하게 넣기 위해 jq --rawfile 사용
jq -n --arg url "jdbc:postgresql://$RDS:5432/point?sslmode=require" \
      --arg pw "$APP_PW" --arg admin "$(openssl rand -hex 16)" \
      --rawfile key jwt-private.pem \
  '{DB_URL:$url, DB_USERNAME:"app_rw", DB_PASSWORD:$pw, JWT_PRIVATE_KEY:$key, ADMIN_API_TOKEN:$admin}' > monolith.json
jq -n --rawfile pub jwt-public.pem '{JWT_PUBLIC_KEY:$pub}' > event.json

aws secretsmanager create-secret --name point-dev/monolith      --secret-string file://monolith.json
aws secretsmanager create-secret --name point-dev/event-service --secret-string file://event.json

cd ~ && rm -rf ~/tmp-secrets       # 로컬 사본 삭제
# app_rw 비밀번호 파일은 Secrets Manager 가 원본이 됐으므로 지워도 된다 (다음 날 7-6 재실행 때 쓰려면 남겨 둠)
```
**왜 Terraform 으로 안 만드나:** `aws_secretsmanager_secret_version` 에 값을 넣으면 그 값이 **state 파일에 평문**으로 남는다. 비밀 "그릇"만 Terraform 으로 만들고 값은 CLI/콘솔로 넣는 방식도 흔하다.

## 8-2. ESO 용 IAM (Terraform, 5단계와 같은 패턴)
**`envs/dev/external-secrets.tf`**
```hcl
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "eso" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:point-dev/*"
    ]
  }
}

resource "aws_iam_policy" "eso" {
  name   = "${local.name}-external-secrets"
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_iam_role" "eso" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json   # aws-lbc.tf 에 정의된 것 재사용
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}
```
- 권한 범위를 `point-dev/*` 로 한정 → RDS 마스터 비밀(`rds!db-...`)은 ESO 가 못 읽는다 (최소 권한).
```bash
terraform plan && terraform apply
```

## 8-3. ESO 설치 (Helm)
```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm search repo external-secrets/external-secrets | head -3
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --version <위에서 확인한 버전>
kubectl get pods -n external-secrets             # controller, webhook, cert-controller
kubectl get sa -n external-secrets external-secrets   # ← association 의 SA 이름과 일치하는지
kubectl api-resources | grep external-secrets.io      # ⚠️ 확인: v1 / v1beta1 중 서빙 버전
```
association 보다 Helm 을 먼저 설치했다면 `kubectl rollout restart deploy/external-secrets -n external-secrets`.

## 8-4. 매니페스트 (`k8s/platform/external-secrets/`)

**`cluster-secret-store.yaml`**
```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-sm
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-2
      # auth 생략 → 컨트롤러 파드 자신의 자격증명(Pod Identity)을 사용
```

**`k8s/apps/base/.../external-secret.yaml`** — 9단계 앱 namespace(`point`) 에 둔다:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: monolith-db
  namespace: point
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-sm
  target:
    name: monolith-db            # 만들어질 K8s Secret 이름 (deployment 의 secretRef 와 일치)
  dataFrom:
    - extract:
        key: point-dev/monolith  # JSON 의 키 하나하나가 Secret 의 키가 됨
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: event-secrets
  namespace: point
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-sm
  target:
    name: event-secrets
  dataFrom:
    - extract:
        key: point-dev/event-service
```

```bash
kubectl create namespace point
kubectl apply -f k8s/platform/external-secrets/cluster-secret-store.yaml
kubectl apply -f <external-secret.yaml>
```

## ✅ 확인
```bash
kubectl get clustersecretstore aws-sm            # STATUS Valid, READY True
kubectl get externalsecret -n point              # STATUS SecretSynced
kubectl get secret monolith-db -n point -o jsonpath='{.data}' | jq 'keys'
#   ["ADMIN_API_TOKEN","DB_PASSWORD","DB_URL","DB_USERNAME","JWT_PRIVATE_KEY"]
kubectl get secret monolith-db -n point -o jsonpath='{.data.DB_USERNAME}' | base64 -d    # app_rw
git grep -n "BEGIN PRIVATE KEY"                  # Git 에는 값이 없어야 함 (출력 없음)
```

### 회전 실험
```bash
aws secretsmanager put-secret-value --secret-id point-dev/monolith --secret-string file://<새 json>
kubectl annotate externalsecret monolith-db -n point force-sync=$(date +%s) --overwrite   # 즉시 동기화
```
→ Secret 은 바뀌지만 **이미 떠 있는 파드의 환경변수는 안 바뀐다** (envFrom 은 기동 시 1회 주입) → `kubectl rollout restart` 필요. 이걸 직접 확인하고 기록.

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| ClusterSecretStore `InvalidProviderConfig` / AccessDenied | association 의 ns/SA 이름, 정책 리소스 ARN 패턴 |
| ExternalSecret `SecretSyncedError ... not found` | Secrets Manager 이름 오타 / 리전 |
| monolith `JWT_PRIVATE_KEY ... 설정되지 않았습니다` | Secret 키 이름 불일치, 또는 PEM 이 PKCS#1 |
| `no matches for kind ExternalSecret in version ...v1` | ESO 버전이 v1 미지원 → `v1beta1` 로 |

## 🧹 정리
Secrets Manager 비밀은 Terraform 밖에서 만들었으므로 **직접 지운다** (기본 7~30일 복구 대기 → 같은 이름 재생성 불가):
```bash
aws secretsmanager delete-secret --secret-id point-dev/monolith      --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id point-dev/event-service --force-delete-without-recovery
```
💸 비밀 1개 $0.40/월 (일할), API 호출 $0.05/1만 건.
