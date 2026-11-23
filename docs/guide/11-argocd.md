# 11단계. ArgoCD (GitOps)

## 목표
`kubectl apply` / `helm install` 을 그만하고, **Git 에 push 하면 클러스터가 따라오게** 한다.

ADR-0009 의 경계:
| Terraform 이 관리 | ArgoCD 가 관리 |
|---|---|
| VPC, EKS(+애드온), IAM(Pod Identity), RDS, ElastiCache, ECR, SQS | 클러스터 안의 모든 것 |
| **ArgoCD 자체 + root Application 1개** | LB Controller, ESO, KEDA, Karpenter, Strimzi, 모니터링, 플랫폼 설정, point 앱 |

> 2026-11-23 실제로 진행한 결과를 반영한 문서. ArgoCD **v3.6.2** (chart `argo-cd` 10.18.2), `argocd-apps` 2.0.8, helm provider **3.3.0**.

## 전체 구조 (App of Apps)
```
Terraform ── helm_release argocd        (envs/dev/argocd.tf)
          └─ helm_release argocd_root   → Application root  (path: k8s/argocd/apps)
                 │
                 ├─ aws-lbc          wave -2  Helm  eks/aws-load-balancer-controller 3.6.3 + values 파일
                 ├─ external-secrets wave -2  Helm  external-secrets 2.15.0
                 ├─ keda             wave -2  Helm  kedacore/keda 2.21.1 + values 파일
                 ├─ karpenter        wave -2  Helm  OCI public.ecr.aws/karpenter 1.15.3 + values 파일
                 ├─ strimzi          wave -2  Helm  strimzi-kafka-operator 1.3.1
                 ├─ monitoring       wave -2  Helm  kube-prometheus-stack 93.9.0 (12단계)
                 ├─ platform-config  wave -1  Git   k8s/platform/{gateway,karpenter,external-secrets,kafka,monitoring/dashboards}
                 └─ point-dev        wave  1  Git   k8s/apps/overlays/dev (Kustomize) + db-init PreSync hook
```
root 하나만 Terraform 이 만들고, 나머지는 **Git 의 YAML 이 Application 을 정의**한다 → 앱 추가 = YAML 추가 + push.

## 11-1. 레포 접근
처음 설계는 private 레포 + 읽기 전용 자격증명(Fine-grained token 또는 Deploy key)이었다.
이번 실습에서는 **레포를 public 으로 바꿔서** 자격증명 없이 진행했다.

public 으로 바꾸기 전에 **히스토리 전체**에 비밀값이 없는지 먼저 확인:
```bash
cd ~/point/point-private
git log --all --name-only --format= | sort -u | grep -E -i 'tfstate|tfvars|\.env|kubeconfig|\.pem'     # 없어야 함
git grep -n -I -E 'BEGIN (RSA |EC |)PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_|github_pat_' $(git rev-list --all) -- ':!docs'   # 없어야 함
git grep -n -E '<계정ID>|<내IP>'      # 공개돼도 되는지 판단 (ECR 주소의 계정 ID, ALB sourceRanges 의 내 IP)
```
- 결과: 비밀값 없음. 공개되는 건 AWS 계정 ID(ECR 주소)와 집 공인 IP(ALB 허용 대역) — 감수하기로 함.
- 확인: `GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote https://github.com/<계정>/point-private.git master` 가 자격증명 없이 성공.
- private 을 유지한다면: Deploy key(읽기 전용 SSH) 또는 Fine-grained token(`Contents: Read-only`)을 ArgoCD repository Secret 으로 등록 (`argocd.argoproj.io/secret-type=repository` 라벨).
  ⚠️ 로컬 Git 의 자격증명(Windows Git Credential Manager 토큰)을 재사용하지 말 것 — 계정 전체 권한이다.

## 11-2. 용량 — core 노드 2 → 3대
ArgoCD(≈1Gi) + 12단계 kube-prometheus-stack(≈2~3Gi)을 올리기엔 core 2대(메모리 requests 66%)가 빠듯했다.
```bash
NG=$(aws eks list-nodegroups --cluster-name point-dev-eks --query 'nodegroups[0]' --output text)
aws eks update-nodegroup-config --cluster-name point-dev-eks --nodegroup-name $NG \
  --scaling-config minSize=3,maxSize=4,desiredSize=3
```
그리고 `modules/eks/main.tf` 를 `min_size = 3, max_size = 4, desired_size = 3` 으로 맞춰 둔다 (plan 에 변경 없음).
- **왜 CLI 를 먼저?** EKS 모듈의 노드그룹은 `lifecycle { ignore_changes = [scaling_config[0].desired_size] }` — 오토스케일러와 싸우지 않으려고 desired 변경을 무시한다.
  Terraform 으로 min 만 3 으로 올리면 "desired(2) < min(3)" 이라 AWS API 가 거부한다.
- 처음부터 새로 만들 때(다음 재시작)는 Terraform 값(3/4/3)으로 바로 3대가 뜬다.

## 11-3. ArgoCD 설치 (Terraform `helm_release`)
**`envs/dev/versions.tf`** `required_providers` 에 추가:
```hcl
helm = { source = "hashicorp/helm", version = "~> 3.0" } # 11단계: ArgoCD
```
**`envs/dev/providers.tf`** 에 추가 — helm provider **3.x 는 `kubernetes = { ... }` 속성** 문법 (2.x 는 블록):
```hcl
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", "ap-northeast-2"]
    }
  }
}
```
- `exec`: 토큰을 state 에 저장하지 않고 매번 `aws eks get-token` 으로 발급.

**[`envs/dev/argocd.tf`](../../envs/dev/argocd.tf)**
```hcl
locals {
  gitops_repo   = "https://github.com/<계정>/point-private.git"
  gitops_branch = "master"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.2" # ArgoCD v3.6.2
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    configs = {
      params = { "server.insecure" = true } # 실습: port-forward 로 HTTP 접속
      # Karpenter 차트는 OCI 레지스트리 → helm 타입 + enableOCI 로 등록 (공개라 자격증명 없음)
      repositories = {
        karpenter = { name = "karpenter", type = "helm", url = "public.ecr.aws/karpenter", enableOCI = "true" }
      }
    }
    dex           = { enabled = false } # SSO 안 씀
    notifications = { enabled = false }
  })]
}

resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.8"
  namespace  = "argocd"
  depends_on = [helm_release.argocd] # Application CRD 가 먼저

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = local.gitops_repo
          targetRevision = local.gitops_branch
          path           = "k8s/argocd/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
}
```
- root Application 을 `kubernetes_manifest` 로 만들면 CRD 가 plan 시점에 있어야 해서 첫 apply 가 실패한다 → `argocd-apps` 차트로 우회.
```bash
cd envs/dev
terraform init -upgrade     # helm provider 3.3.0 설치 (lock 파일에 helm 만 추가됐는지 git diff 로 확인)
terraform plan -out=tfplan  # Plan: 2 to add
terraform apply tfplan
kubectl get pods -n argocd  # application-controller, applicationset-controller, redis, repo-server, server
```

### CLI / UI
```bash
# CLI (체크섬 확인 후 ~/.local/bin)
V=v3.6.2
curl -fsSLo argocd https://github.com/argoproj/argo-cd/releases/download/$V/argocd-linux-amd64
curl -fsSLO https://github.com/argoproj/argo-cd/releases/download/$V/cli_checksums.txt
grep ' argocd-linux-amd64$' cli_checksums.txt | sed 's/argocd-linux-amd64/argocd/' | sha256sum --check   # argocd: OK
install -m 0755 argocd ~/.local/bin/argocd

# --core: argocd-server 를 거치지 않고 kubeconfig 로 직접 (로그인 불필요). 현재 context 의 namespace 가 argocd 여야 함
kubectl config set-context --current --namespace=argocd
argocd app list --core
kubectl config set-context --current --namespace=default     # 끝나면 되돌리기

# UI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward -n argocd svc/argocd-server 8080:80      # http://localhost:8080 (admin)
```

## 11-4. 하위 Application ([`k8s/argocd/apps/`](../../k8s/argocd/apps/))
**Helm 차트 + Git 의 values 파일 (multi-source)** — [`aws-lbc.yaml`](../../k8s/argocd/apps/aws-lbc.yaml):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aws-lbc
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  sources:
    - repoURL: https://aws.github.io/eks-charts
      chart: aws-load-balancer-controller
      targetRevision: 3.6.3
      helm:
        releaseName: aws-load-balancer-controller     # 기존 Helm 릴리스와 같은 이름 → 리소스 이름 동일 → 그대로 매칭
        valueFiles: [$values/k8s/platform/aws-lbc/values.yaml]
    - repoURL: https://github.com/<계정>/point-private.git
      targetRevision: master
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  # 차트가 렌더링할 때마다 웹훅 TLS 인증서를 새로 만든다 (helm 의 lookup 을 ArgoCD 는 못 씀) → 무시
  ignoreDifferences:
    - { kind: Secret, name: aws-load-balancer-tls, jsonPointers: [/data] }
    - { group: admissionregistration.k8s.io, kind: MutatingWebhookConfiguration, jqPathExpressions: [".webhooks[]?.clientConfig.caBundle"] }
    - { group: admissionregistration.k8s.io, kind: ValidatingWebhookConfiguration, jqPathExpressions: [".webhooks[]?.clientConfig.caBundle"] }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true, RespectIgnoreDifferences=true]
```
같은 패턴:
| Application | 차트 | 특이사항 |
|---|---|---|
| `external-secrets` | charts.external-secrets.io / 2.15.0 | cert-controller 가 CRD 변환 웹훅·검증 웹훅 caBundle 을 채움 → `ignoreDifferences` |
| `keda` | kedacore / 2.21.1 | operator 가 APIService·웹훅 caBundle 을 채움 → `ignoreDifferences` |
| `karpenter` | `public.ecr.aws/karpenter` (OCI) / 1.15.3 | repoURL 에 `oci://` 없이. argocd.tf 의 `enableOCI` 등록 필요 |
| `strimzi` | strimzi.io/charts / 1.3.1 | |
| `monitoring` | prometheus-community / 93.9.0 | 12단계 |
- **CRD 가 큰 차트는 `ServerSideApply=true`** — client-side apply 는 `last-applied-configuration` annotation 크기(256KB)를 넘을 수 있다.

**Git 경로** — [`platform-config.yaml`](../../k8s/argocd/apps/platform-config.yaml): `k8s/platform` 아래엔 Helm `values.yaml` 도 섞여 있어서 매니페스트만 고른다:
```yaml
  source:
    path: k8s/platform
    directory:
      recurse: true
      include: "{gateway/*.yaml,karpenter/nodepool-*.yaml,external-secrets/*.yaml,kafka/*.yaml,monitoring/dashboards/*.yaml}"
```
**Kustomize** — [`point-dev.yaml`](../../k8s/argocd/apps/point-dev.yaml):
```yaml
  source:
    path: k8s/apps/overlays/dev
  ignoreDifferences:                       # KEDA(HPA) 가 바꾸는 replicas 는 무시
    - { group: apps, kind: Deployment, name: event-service, jsonPointers: [/spec/replicas] }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, RespectIgnoreDifferences=true]
```

### Sync 순서 (sync-wave)
Application 에 `argocd.argoproj.io/sync-wave` — 낮을수록 먼저: 컨트롤러(-2) → 그 CRD 를 쓰는 설정(-1) → 앱(1).
- wave 는 **root 가 하위 Application 을 sync 할 때**의 순서다. 12단계에서 monitoring 과 point-dev 의 `ServiceMonitor` 를 한 커밋에 넣었더니,
  point-dev 의 첫 시도가 CRD 없이 실패했다가(`Retrying operation. Attempt #2`) 자동 재시도로 해결됐다.

## 11-5. 수동 설치한 것을 ArgoCD 로 이전 (실제 절차)
1. 하위 Application 을 **`automated` 없이** push (커밋 `feat(argocd): ... (manual sync)`)
2. 전부 `OutOfSync / Healthy` — Healthy = 기존 리소스를 같은 것으로 인식했다는 뜻. OutOfSync 는 ArgoCD 3.x 의 **추적 annotation**(`argocd.argoproj.io/tracking-id`)이 아직 없어서.
3. **실제 필드 차이 확인** — 추적 annotation 을 빼고 남는 게 있는지:
   ```bash
   argocd app diff aws-lbc --core | grep -E '^[<>] ' | grep -v tracking-id
   ```
   → 7개 앱 전부 **annotation 추가 외 차이 없음** (aws-lbc 인증서는 ignoreDifferences 로 제외됨)
4. wave 순서대로 수동 Sync → 전부 `Synced / Healthy`, 재생성된 리소스 없음
   ```bash
   for a in aws-lbc external-secrets karpenter keda strimzi platform-config point-dev; do argocd app sync $a --core; done
   ```
5. `automated: { prune: true, selfHeal: true }` 를 켜서 push
6. `helm uninstall` 은 **하지 않는다** (리소스가 지워짐). Helm 릴리스 기록만 정리 — ArgoCD 는 Helm 릴리스를 만들지 않고 `helm template` 결과만 apply 하므로, 기록이 남아 있으면 누군가 `helm upgrade` 해서 충돌할 수 있다:
   ```bash
   kubectl delete secret -n kube-system      -l owner=helm,name=aws-load-balancer-controller
   kubectl delete secret -n kube-system      -l owner=helm,name=karpenter
   kubectl delete secret -n external-secrets -l owner=helm,name=external-secrets
   kubectl delete secret -n keda             -l owner=helm,name=keda
   kubectl delete secret -n kafka            -l owner=helm,name=strimzi
   helm list -A     # argocd, argocd-root (Terraform 소유) 만 남음
   ```
- Gateway API CRD(5단계 `kubectl apply`)는 이번에 옮기지 않았다 — 클러스터 기반 CRD 라 ArgoCD 보다 먼저 있어야 하고, 잘못 prune 되면 모든 Gateway 가 사라진다.

## 11-6. DB 초기화 Job (ADR-0013 `db-init`) — [`k8s/apps/overlays/dev/db-init.yaml`](../../k8s/apps/overlays/dev/db-init.yaml)
7단계에서 손으로 만든 `app_rw` 를 ArgoCD **PreSync hook** 으로.

ESO 정책에 **RDS 마스터 비밀 하나만** 추가 ([`external-secrets.tf`](../../envs/dev/external-secrets.tf)):
```hcl
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.rds.master_secret_arn]      # rds!db-* 와일드카드 X
  }
```
- 트레이드오프: ClusterSecretStore 는 클러스터 전역이라 **어느 namespace 의 ExternalSecret 이든** 이 비밀을 읽을 수 있게 된다. 운영이라면 db-init 전용 namespace + namespaced SecretStore + 별도 IAM 역할로 좁힌다.

매니페스트 — **ExternalSecret 도 hook 이어야 한다.** PreSync 는 "본 리소스 sync 전에" 실행되므로 일반 리소스로 두면 Job 이 기다리는 Secret 이 hook 이 끝날 때까지 안 생긴다 (교착):
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-master
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"          # hook 안에서도 Job 보다 먼저
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-sm }
  target:
    name: db-master
    template:
      data:                                     # psql 이 그대로 읽는 PG* 이름으로 변환
        PGHOST: '{{ .DB_URL | regexFind "//[^:/]+" | trimPrefix "//" }}'
        PGUSER: '{{ .username }}'
        PGPASSWORD: '{{ .password }}'
        APP_PW: '{{ .DB_PASSWORD }}'
  data:
    - { secretKey: username,    remoteRef: { key: "rds!db-<...>", property: username } }   # ⚠️ RDS 재생성 시 이름 바뀜
    - { secretKey: password,    remoteRef: { key: "rds!db-<...>", property: password } }
    - { secretKey: DB_URL,      remoteRef: { key: point-dev/monolith, property: DB_URL } }
    - { secretKey: DB_PASSWORD, remoteRef: { key: point-dev/monolith, property: DB_PASSWORD } }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16
          envFrom: [{ secretRef: { name: db-master } }]
          env:
            - { name: PGDATABASE, value: point }
            - { name: PGSSLMODE, value: require }
          command: ["sh", "-c"]
          args:
            - |
              psql -v ON_ERROR_STOP=1 <<SQL
              DO \$do\$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_rw') THEN
                  CREATE ROLE app_rw LOGIN PASSWORD '$APP_PW';
                ELSE
                  ALTER ROLE app_rw LOGIN PASSWORD '$APP_PW';
                END IF;
              END \$do\$;
              GRANT CONNECT, CREATE ON DATABASE point TO app_rw;
              GRANT USAGE, CREATE ON SCHEMA public TO app_rw;
              SQL
```
- 앱 계정 비밀번호의 원본은 Secrets Manager `point-dev/monolith` 의 `DB_PASSWORD` 하나 → Job 과 앱이 같은 값을 쓴다.
- ESO 템플릿(sprig 함수)으로 `DB_URL` 에서 호스트만 뽑았다 → 엔드포인트를 Git 에 따로 적지 않아도 됨.
- **`$$` 를 쓰지 않는다** (K8s 가 `$` 로 바꿈) → `$do$`. heredoc 의 `\$do\$` 는 shell 이 `$do$` 로, `$APP_PW` 는 값으로 바꾼다.
- `PGSSLMODE=require` (RDS `rds.force_ssl`).
- overlay 를 `kubectl apply -k` 로 직접 적용하면 hook annotation 은 무시되고 일반 리소스로 생긴다 (그래도 동작은 같음).

### 문제 — 처음 push 했을 땐 db-init 이 안 돌았다
- 현상: push 후 point-dev 가 `Synced` 그대로, Job 없음.
- 원인: **hook 은 sync "작업"이 있을 때만 실행된다.** 이 커밋은 hook 리소스만 추가해서, hook 을 제외한 비교로는 Git == 클러스터 → OutOfSync 가 안 됨 → automated sync 가 안 돔.
- 해결: 수동 Sync 한 번 (`argocd app sync point-dev --core`). 이후에는 point-dev 가 sync 될 때마다 매번 먼저 실행된다.
- 결과 (12초):
  ```
  ExternalSecret db-master  PreSync  secret synced
  Job db-init               PreSync  Reached expected number of succeeded pods
  $ kubectl logs -n point job/db-init
  DO
  GRANT
  GRANT
  ```
  → `app_rw` 가 이미 있어서 ELSE(비밀번호 갱신) 경로 — **여러 번 실행해도 안전**함을 확인.
- 의미: 다음 재시작 때는 7단계 7-6 을 손으로 할 필요가 없다 (RDS 마스터 비밀 이름만 갱신).

## ✅ 확인
```bash
kubectl get applications -n argocd        # 9개 (root + 8) 전부 Synced / Healthy
```
| 실험 | 방법 | 결과 |
|---|---|---|
| **selfHeal** | `kubectl scale deploy/web -n point --replicas=5` | **3초** 만에 `spec.replicas` 2 로 되돌림 |
| **Git → 배포** | ECR 에 `web:v0.1.1` 태그 추가 → overlay `newTag: v0.1.1` → commit → push (14:44:29) | **2분 14초** 뒤 Deployment 이미지 변경 (14:46:43), 롤링 즉시 완료 |
| **prune** | 테스트 ConfigMap 을 Git 에서 삭제 → push (14:56:36) | **1분 37초** 뒤 클러스터에서 삭제 |
| **PreSync hook** | db-init | 위 11-6 |

- Git 감지 지연: ArgoCD 기본 폴링 `timeout.reconciliation: 120s` (+ jitter). 즉시 반영하려면 UI 의 Refresh, `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite`, 또는 GitHub webhook.
- `web:v0.1.1` 은 새로 빌드하지 않고 **같은 이미지에 태그만 추가**했다 (IMMUTABLE 은 같은 태그 덮어쓰기만 막는다):
  ```bash
  M=$(aws ecr batch-get-image --repository-name point/web --image-ids imageTag=v0.1.0 \
       --accepted-media-types application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json \
       --query 'images[0].imageManifest' --output text)
  aws ecr put-image --repository-name point/web --image-tag v0.1.1 --image-manifest "$M"
  ```
  → digest 가 같아도 Deployment 의 image 문자열이 바뀌므로 롤링은 일어난다. 실제 CI 라면 빌드 → 푸시 → 이 `newTag` 를 바꾸는 커밋까지 파이프라인이 한다.
- 이 실험들 동안 **손으로 `kubectl apply` 한 것은 없다** — 전부 commit + push.

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| 전부 OutOfSync (Healthy) — 이전 직후 | 추적 annotation 이 없어서. `argocd app diff` 로 실제 차이 확인 후 Sync |
| aws-lbc / ESO / KEDA 가 계속 OutOfSync | 렌더링·런타임에 채워지는 인증서/caBundle → `ignoreDifferences` + `RespectIgnoreDifferences=true` |
| `metadata.annotations: Too long` | CRD 큼 → `ServerSideApply=true` |
| `no matches for kind ServiceMonitor` (첫 sync) | CRD 를 만드는 앱이 아직 → wave 순서. 자동 재시도로 해결됨 |
| Karpenter 차트를 못 받음 | OCI repoURL 에 `oci://` 붙이지 않기 + `enableOCI` repository 등록 |
| PreSync Job 이 안 돎 | hook 만 바뀐 커밋은 OutOfSync 가 아님 → 수동 Sync |
| PreSync Job 이 Secret 을 못 찾고 멈춤 | Secret 을 만드는 ExternalSecret 도 PreSync hook 으로 |
| `argocd app ... --core` 가 namespace 에러 | `kubectl config set-context --current --namespace=argocd` |
| `kubectl apply/scale` 한 게 바로 되돌아감 | 정상 (selfHeal) — Git 을 고쳐야 한다 |
| `repository not found` / `authentication required` | private 레포면 repository Secret (url·토큰·`secret-type=repository` 라벨) |
| terraform apply 시 helm provider 인증 실패 | `exec` 의 aws CLI 프로필 / EKS 가 아직 없음 → EKS 먼저 apply |

## 🧹 정리
이번 구성의 Application 에는 **`resources-finalizer.argocd.argoproj.io` finalizer 가 없다** (확인함):
```bash
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,FIN:.metadata.finalizers   # 전부 <none>
```
→ Application 을 지워도 **하위 리소스는 남는다** (cascade 안 됨). 그리고 root 가 살아 있으면 지운 하위 Application 을 다시 만든다. 그래서:
```bash
cd ~/point/point-private
# 1) root 제거 → 하위 Application 을 되살리는 주체 없앰
terraform -chdir=envs/dev destroy -target=helm_release.argocd_root
# 2) 하위 Application 제거 → selfHeal/prune 주체 없앰 (리소스는 남음)
kubectl delete application --all -n argocd
# 3) 이제 손으로 지운 게 되살아나지 않는다 → 10단계 → 9단계 정리 순서대로
kubectl delete -k k8s/apps/overlays/dev                     # Gateway → ALB 삭제, ScaledObject 삭제
kubectl delete nodepool --all && kubectl get nodeclaims -w   # Karpenter 노드 회수 (0 개까지)
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=event Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].InstanceId'
# 4) 그 다음 terraform destroy (ArgoCD helm_release 포함)
terraform -chdir=envs/dev destroy
```
- 반대로 "Application 을 지우면 리소스도 같이 지워지게" 하려면 하위 Application `metadata.finalizers: [resources-finalizer.argocd.argoproj.io]` 를 추가한다. 실습에선 정리 순서를 직접 통제하려고 넣지 않았다.
