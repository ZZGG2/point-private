# 8단계. Secret 관리 (External Secrets Operator)

## 목표
DB 비밀번호·JWT 키 같은 값을 **Git 에도, Terraform state 에도 두지 않고** AWS Secrets Manager → 쿠버네티스 Secret 으로 주입한다.

```
AWS Secrets Manager                       EKS
  point-dev/core-service   ──┐                 ┌─ ClusterSecretStore aws-sm (어디서 읽나)
  point-dev/event-service  ──┼── ESO 컨트롤러 ──┤
                             │ (Pod Identity)  └─ ExternalSecret (무엇을 → 어떤 Secret 으로)
                             └──────────────────▶  Secret core-service-db / event-secrets (ns point)
```

> 2026-11-23 실제로 진행한 결과를 반영한 문서. ESO **2.15.0**, API **`external-secrets.io/v1`**.

> 🔄 **2026-11-26 변경** (point-infra `k8s/platform/external-secrets/README.md` 기준)
> - 이름: `point-dev/monolith` → **`point-dev/core-service`**, Secret `monolith-db` → **`core-service-db`**
> - `ADMIN_API_TOKEN` 은 core-service 에서 빠지고 **event-service 비밀로** 옮겼다. 정산 API 제거(ADR-0018) 뒤 core-service 에는 관리자 API 가 없고, 새 **이벤트 생성 API**(`POST /api/events/admin/{id}`, event-service)가 이 토큰을 쓴다
> - event-service 의 `application-local.yml` 은 관리자 토큰을 덮어쓰지 않는다 → `APP_ADMIN_APITOKEN` 우회 매핑(9단계 문제 ②)도 필요 없어 지웠다
> - 아래 "실제 결과"·"회전 실험" 표는 11-23 당시(monolith·정산 API) 기록이다

## 앱이 필요로 하는 비밀값 (point-backend 코드 기준)

| 앱 | 환경변수 | 설명 |
|---|---|---|
| core-service | `DB_URL` | `jdbc:postgresql://<rds>:5432/point?sslmode=require` |
| | `DB_USERNAME` / `DB_PASSWORD` | `app_rw` / 7단계에서 만든 비밀번호 |
| | `JWT_PRIVATE_KEY` | RS256 서명 키 (PKCS#8 PEM). **local 프로필이 아니면 없을 때 기동 실패**. 파드가 2개 이상이면 반드시 같은 키여야 함 |
| event-service | `JWT_PUBLIC_KEY` | 위 키의 공개키 (X.509 PEM). `JWT_JWK_SET_URI` 와 둘 중 하나 필수, 둘 다 있으면 **공개키 우선** (`SecurityConfig`) |
| | `ADMIN_API_TOKEN` | 이벤트 생성 API `POST /api/events/admin/{id}` 의 `X-Admin-Token`. 없으면 이 API 만 항상 403 (기동은 됨). 충분히 긴 랜덤 값 |

Secret 이름 `core-service-db`·`event-secrets`, ClusterSecretStore 이름 `aws-sm` (point-infra 설계 그대로).

## 8-1. 비밀값 만들기 (CLI — Git·state 밖에서)
```bash
mkdir -p ~/tmp-secrets && cd ~/tmp-secrets && umask 077     # 레포 밖! 파일 권한 600
# JWT 키쌍
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt-private.pem   # PKCS#8 PEM
openssl pkey -in jwt-private.pem -pubout -out jwt-public.pem                         # X.509 SubjectPublicKeyInfo PEM
head -1 jwt-private.pem jwt-public.pem
#   -----BEGIN PRIVATE KEY-----   ← "RSA PRIVATE KEY" 면 PKCS#1 → 앱이 못 읽음
#   -----BEGIN PUBLIC KEY-----

RDS=$(cd ~/point/point-private/envs/dev && terraform output -raw rds_endpoint)
APP_PW=$(cat ~/.config/point-dev/app_rw_password)      # 7단계 7-6 에서 만든 파일
echo "RDS=$RDS pwlen=${#APP_PW}"                       # 비밀번호 길이가 0 이면 멈출 것

# PEM 의 줄바꿈을 JSON 문자열로 안전하게 넣기 위해 jq --rawfile 사용
jq -n --arg url "jdbc:postgresql://$RDS:5432/point?sslmode=require" \
      --arg pw "$APP_PW" --rawfile key jwt-private.pem \
  '{DB_URL:$url, DB_USERNAME:"app_rw", DB_PASSWORD:$pw, JWT_PRIVATE_KEY:$key}' > core.json
jq -n --rawfile pub jwt-public.pem --arg admin "$(openssl rand -hex 24)" \
  '{JWT_PUBLIC_KEY:$pub, ADMIN_API_TOKEN:$admin}' > event.json
jq keys core.json event.json

aws secretsmanager create-secret --name point-dev/core-service  --secret-string file://core.json
aws secretsmanager create-secret --name point-dev/event-service --secret-string file://event.json

cd ~ && rm -rf ~/tmp-secrets       # 로컬 사본 삭제 (원본은 이제 Secrets Manager)
```
- `app_rw_password` 파일은 **남겨 둔다** — 다음에 재시작할 때 7-6 을 다시 실행하려면 필요.
- 11-23 에 `point-dev/monolith` 로 만들어 둔 비밀이 남아 있으면: 값(JWT 키쌍 등)을 그대로 옮겨 `point-dev/core-service` 를 만들고, `ADMIN_API_TOKEN` 은 `point-dev/event-service` 로 옮긴 뒤 옛 비밀을 지운다 (🧹 정리의 delete 명령)
- 개인키를 다시 볼 일이 있으면 `aws secretsmanager get-secret-value --secret-id point-dev/core-service --query SecretString --output text | jq -r .JWT_PRIVATE_KEY`.

**왜 Terraform 으로 안 만드나:** `aws_secretsmanager_secret_version` 에 값을 넣으면 그 값이 **state 파일에 평문**으로 남는다. 비밀 "그릇"만 Terraform 으로 만들고 값은 CLI/콘솔로 넣는 방식도 흔하다.

## 8-2. ESO 용 IAM — [`envs/dev/external-secrets.tf`](../../envs/dev/external-secrets.tf)
5단계 LB Controller 와 같은 Pod Identity 패턴. 신뢰 정책(`pod_identity_trust`)은 `aws-lbc.tf` 의 것을 재사용.
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
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"      # Helm 차트 기본 SA 이름
  role_arn        = aws_iam_role.eso.arn
}
```
```bash
cd ~/point/point-private/envs/dev
terraform plan -out=tfplan      # Plan: 4 to add
terraform apply tfplan
```
- 권한 범위를 `point-dev/*` 로 한정 → RDS 마스터 비밀(`rds!db-...`)은 ESO 가 못 읽는다 (아래 ✅ 에서 실제 확인).
- association 을 Helm 설치 **전에** 만들었으므로 재시작이 필요 없었다. 순서가 반대면 `kubectl rollout restart deploy/external-secrets -n external-secrets`.

## 8-3. ESO 설치 (Helm)
```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm search repo external-secrets/external-secrets --versions | head -3     # 2.15.0
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --version 2.15.0 --wait
kubectl get pods -n external-secrets                  # external-secrets, -cert-controller, -webhook 3개 Running
kubectl get sa -n external-secrets external-secrets   # association 의 SA 이름과 일치
kubectl api-resources | grep external-secrets.io      # externalsecrets / clustersecretstores → v1
```

## 8-4. 매니페스트
**[`k8s/platform/external-secrets/cluster-secret-store.yaml`](../../k8s/platform/external-secrets/cluster-secret-store.yaml)** — 플랫폼 소유, 클러스터 전역
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

**[`k8s/apps/overlays/dev/external-secrets.yaml`](../../k8s/apps/overlays/dev/external-secrets.yaml)** — 앱 소유. 9단계 overlay 의 `resources` 에 들어가므로 namespace 는 kustomize 가 `point` 로 붙인다:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: core-service-db
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-sm
  target:
    name: core-service-db            # 만들어질 K8s Secret 이름 (deployment 의 secretRef 와 일치)
  dataFrom:
    - extract:
        key: point-dev/core-service  # JSON 의 키 하나하나가 Secret 의 키가 됨
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: event-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-sm
  target:
    name: event-secrets
  dataFrom:
    - extract:
        key: point-dev/event-service   # JWT_PUBLIC_KEY, ADMIN_API_TOKEN
```
- `dataFrom`(JSON 전체 펼치기)과 `data`(키 하나 골라 이름 바꾸기)는 **같이 쓸 수 있다.** (11-23 에는 `APP_ADMIN_APITOKEN` 을 `data` 로 하나 더 넣었었다 — 9단계 문제 ②, 지금은 필요 없음)

```bash
cd ~/point/point-private
kubectl apply -f k8s/platform/external-secrets/cluster-secret-store.yaml
kubectl create namespace point
kubectl apply -n point -f k8s/apps/overlays/dev/external-secrets.yaml   # 9단계 전에 먼저 확인용. 9단계부터는 apply -k 에 포함
```

## ✅ 확인
```bash
kubectl get clustersecretstore aws-sm            # STATUS Valid, READY True
kubectl get externalsecret -n point              # STATUS SecretSynced, READY True
kubectl get secret core-service-db -n point -o jsonpath='{.data}' | jq 'keys'          # DB_PASSWORD, DB_URL, DB_USERNAME, JWT_PRIVATE_KEY
kubectl get secret core-service-db -n point -o jsonpath='{.data.DB_USERNAME}' | base64 -d    # app_rw
kubectl get secret event-secrets -n point -o jsonpath='{.data}' | jq 'keys'            # ADMIN_API_TOKEN, JWT_PUBLIC_KEY
kubectl get secret event-secrets -n point -o jsonpath='{.data.JWT_PUBLIC_KEY}' | base64 -d | head -1
git grep -n "BEGIN PRIVATE KEY" -- ':!docs'      # Git 에 실제 키가 없어야 함 (출력 없음. docs 는 예시 문자열이라 제외)
```

### 최소 권한 확인 — RDS 마스터 비밀은 못 읽어야 한다
```bash
cat <<'EOF' | kubectl apply -n point -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: deny-test }
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-sm }
  target: { name: deny-test }
  dataFrom: [{ extract: { key: "rds!db-<...>" } }]     # terraform output rds_master_secret_arn 의 이름 부분
EOF
kubectl get externalsecret -n point deny-test       # SecretSyncedError (이벤트 메시지는 "could not get secret data from provider" 뿐)
kubectl logs -n external-secrets deploy/external-secrets --since=2m | grep -o 'AccessDenied[^"]\{0,200\}'
kubectl delete externalsecret -n point deny-test
```
- 이벤트에는 원인이 안 나온다 → **컨트롤러 로그**에서 확인.

### 실제 결과 (2026-11-23 — monolith 시절 이름)
| 확인 | 결과 |
|---|---|
| ClusterSecretStore | `Valid`, `ReadWrite`, READY `True` |
| ExternalSecret 2개 | `SecretSynced` (apply 후 약 10초) |
| `monolith-db` 키 | `ADMIN_API_TOKEN, DB_PASSWORD, DB_URL, DB_USERNAME, JWT_PRIVATE_KEY` (9단계 후 `APP_ADMIN_APITOKEN` 추가) |
| `DB_USERNAME` | `app_rw` |
| 최소 권한 | `AccessDeniedException: ... assumed-role/point-dev-external-secrets/... is not authorized to perform: secretsmanager:GetSecretValue` |
| Git | 실제 키 없음 |

### 회전 실험 (9단계 앱을 띄운 뒤 진행)
관리자 토큰을 바꿔서 "Secret 은 바뀌는데 파드는?" 을 확인한다. 11-26 부터 토큰은 event-service 비밀에 있고, 확인 API 는 **이벤트 생성**이다
(성공하면 이벤트가 하나 생기므로 호출마다 새 id 를 쓴다 — 같은 id 는 409):
```bash
ALB=$(kubectl get gateway -n point point-gw -o jsonpath='{.status.addresses[0].value}')
OLD=$(kubectl get secret event-secrets -n point -o jsonpath='{.data.ADMIN_API_TOKEN}' | base64 -d)
NEW=$(openssl rand -hex 24)
# 기존 JSON 에서 한 키만 바꿔 새 버전으로 저장 (파일은 쓰고 바로 지움)
aws secretsmanager get-secret-value --secret-id point-dev/event-service --query SecretString --output text \
  | jq --arg t "$NEW" '.ADMIN_API_TOKEN=$t' > /tmp/rot.json
aws secretsmanager put-secret-value --secret-id point-dev/event-service --secret-string file:///tmp/rot.json; rm -f /tmp/rot.json
kubectl annotate externalsecret event-secrets -n point force-sync=$(date +%s) --overwrite   # 1h 기다리지 않고 즉시 동기화

ENDS=$(date -u -d '+10 min' +%Y-%m-%dT%H:%M:%SZ)
code() { curl -s -o /dev/null -w '%{http_code}' -X POST "http://$ALB/api/events/admin/evt-rot-$(date +%s%N)" \
  -H "X-Admin-Token: $1" -H 'Content-Type: application/json' -d "{\"stock\":1,\"amount\":1,\"endsAt\":\"$ENDS\"}"; }
echo "old=$(code $OLD) new=$(code $NEW)"      # 재시작 전: old=201 new=403 이 예상
kubectl rollout restart -n point deploy/event-service && kubectl rollout status -n point deploy/event-service
echo "old=$(code $OLD) new=$(code $NEW)"      # 재시작 후: old=403 new=201
```
11-23 결과 (monolith 정산 API 로 했을 때):

| 시점 | K8s Secret | 옛 토큰 | 새 토큰 |
|---|---|---|---|
| force-sync 직후 | 새 값 | **200** | 403 |
| `rollout restart` 후 | 새 값 | 403 | **200** |

→ **`envFrom` 은 파드 기동 시 1회 주입**이라 Secret 이 바뀌어도 떠 있는 파드는 옛 값을 쓴다. 회전 = "Secrets Manager 갱신 → 동기화 → 재시작" 3단계.
자동화하려면 Reloader(stakater) 같은 컨트롤러나, configMapGenerator 처럼 해시를 붙이는 방식을 쓴다.

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| ClusterSecretStore `InvalidProviderConfig` / AccessDenied | association 의 ns/SA 이름, 정책 리소스 ARN 패턴 |
| ExternalSecret `SecretSyncedError`, 이벤트엔 `could not get secret data from provider` 뿐 | 컨트롤러 로그 확인 — `AccessDenied` (권한) 또는 `ResourceNotFound` (이름 오타/리전) |
| core-service `JWT_PRIVATE_KEY ... 설정되지 않았습니다` | Secret 키 이름 불일치, 또는 PEM 이 PKCS#1 |
| `no matches for kind ExternalSecret in version ...v1` | ESO 버전이 v1 미지원 (0.17 미만) → 업그레이드 |
| 비밀 바꿨는데 앱이 옛 값 | 정상 — `rollout restart` 필요 (위 회전 실험) |
| `create-secret` 이 `already scheduled for deletion` | 복구 대기 중인 같은 이름 → `restore-secret` 하거나 아래처럼 즉시 삭제 후 재생성 |

## 🧹 정리
Secrets Manager 비밀은 Terraform 밖에서 만들었으므로 **직접 지운다** (기본 7~30일 복구 대기 → 같은 이름 재생성 불가):
```bash
aws secretsmanager delete-secret --secret-id point-dev/core-service  --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id point-dev/event-service --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id point-dev/monolith      --force-delete-without-recovery   # 11-23 에 만든 옛 이름이 남아 있다면
```
ESO 자체(Helm, IAM)는 클러스터 destroy 에 같이 정리된다 (IAM 은 `envs/dev` state 에 있음).

💸 비밀 1개 $0.40/월 (일할), API 호출 $0.05/1만 건.
