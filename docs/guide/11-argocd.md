# 11단계. ArgoCD (GitOps)

## 목표
`kubectl apply` / `helm install` 을 그만하고, **Git 에 push 하면 클러스터가 따라오게** 한다.

ADR-0009 의 경계:
| Terraform 이 관리 | ArgoCD 가 관리 |
|---|---|
| VPC, EKS, IAM(Pod Identity), RDS, ElastiCache, ECR, SQS | 클러스터 안의 모든 것 |
| **ArgoCD 자체 + root Application 1개** | LB Controller, ESO, Karpenter(Helm + NodePool), KEDA, Strimzi, point 앱 |

> 아직 실습 전 작성한 가이드. "⚠️ 확인" 은 진행 시 갱신.

## 전체 구조 (App of Apps)
```
Terraform ── helm_release argocd
          └─ root Application  (path: k8s/argocd/apps)
                 │
                 ├─ Application aws-lbc          (Helm chart eks/aws-load-balancer-controller + values 파일)
                 ├─ Application external-secrets (Helm)
                 ├─ Application keda             (Helm)
                 ├─ Application karpenter        (Helm OCI)
                 ├─ Application platform-config  (path: k8s/platform/{gateway,karpenter,external-secrets,kafka})
                 └─ Application point-dev        (path: k8s/apps/overlays/dev, Kustomize)
```
root 하나만 Terraform 이 만들고, 나머지는 **Git 의 YAML 이 Application 을 정의**한다 → 앱 추가 = YAML 추가 + push.

## 11-1. 레포 접근 (private repo)
`point-private` 는 private 이라 ArgoCD 가 읽으려면 자격증명이 필요하다.
- GitHub → Settings → Developer settings → **Fine-grained token**: 레포 `point-private` 만, `Contents: Read-only`.
- 토큰은 Git/Terraform 에 넣지 않는다. ArgoCD 설치 후 Secret 으로 직접 등록 (11-3).
- 대안: 레포에 **Deploy key**(읽기 전용 SSH 키)를 등록하고 `ssh://git@github.com/...` URL 사용.

## 11-2. ArgoCD 설치 (Terraform `helm_release`)

**`envs/dev/versions.tf`** `required_providers` 에 추가:
```hcl
helm = { source = "hashicorp/helm", version = "~> 3.0" }
```
**`envs/dev/providers.tf`** 에 추가:
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
⚠️ 확인: helm provider **3.x 는 `kubernetes = { ... }` (속성)**, 2.x 는 `kubernetes { ... }` (블록) 문법. 설치된 버전에 맞출 것.
- `exec` 방식: 토큰을 state 에 저장하지 않고 매번 `aws eks get-token` 으로 발급.

**`envs/dev/argocd.tf`**
```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "<helm search repo argo/argo-cd 로 확인>"
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    configs = { params = { "server.insecure" = true } }   # 실습: port-forward 로 HTTP 접속
  })]
}

resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "<확인>"
  namespace  = "argocd"
  depends_on = [helm_release.argocd]

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = "https://github.com/<계정>/point-private.git"
          targetRevision = "master"            # 브랜치 이름 확인 (main 으로 바꿨다면 main)
          path           = "k8s/argocd/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
}
```
- root Application 을 `kubernetes_manifest` 로 만들 수도 있지만, CRD 가 plan 시점에 있어야 해서 첫 apply 가 실패한다 → `argocd-apps` 차트가 우회책.

```bash
terraform init -upgrade && terraform plan && terraform apply
kubectl get pods -n argocd
```

## 11-3. 레포 자격증명 & UI 접속
```bash
kubectl create secret generic repo-point-private -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<계정>/point-private.git \
  --from-literal=username=<github-id> \
  --from-literal=password=<fine-grained-token>
kubectl label secret repo-point-private -n argocd argocd.argoproj.io/secret-type=repository

# UI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl port-forward -n argocd svc/argocd-server 8080:80
# → http://localhost:8080  (admin / 위 비밀번호)
```

## 11-4. 하위 Application 작성 (`k8s/argocd/apps/`)

**Helm 차트 + Git 의 values 파일** (multi-source) 예 — `aws-lbc.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aws-lbc
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://aws.github.io/eks-charts
      chart: aws-load-balancer-controller
      targetRevision: 3.6.3
      helm:
        releaseName: aws-load-balancer-controller     # 기존 Helm 릴리스와 같은 이름 → 리소스 이름 동일
        valueFiles: [$values/k8s/platform/aws-lbc/values.yaml]
    - repoURL: https://github.com/<계정>/point-private.git
      targetRevision: master
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```
같은 패턴으로 `external-secrets.yaml`, `keda.yaml`, `karpenter.yaml`(repoURL `public.ecr.aws/karpenter`, OCI) 작성.

**Git 경로 (Kustomize)** 예 — `point-dev.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: point-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<계정>/point-private.git
    targetRevision: master
    path: k8s/apps/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: point
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
  ignoreDifferences:                       # KEDA(HPA) 가 바꾸는 replicas 는 무시
    - group: apps
      kind: Deployment
      name: event-service
      jsonPointers: [/spec/replicas]
```

### Sync 순서 (sync-wave)
CRD → 컨트롤러 → 그 CRD 를 쓰는 리소스 순서가 필요하다. Application 에 annotation:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"    # 낮을수록 먼저: lbc/eso/keda/karpenter = -1, platform-config = 0, point-dev = 1
```

## 11-5. 수동 설치한 것을 ArgoCD 로 이전
1. 하위 Application 을 **`automated` 없이** 먼저 push → UI 에서 Diff 확인
2. 기존 Helm 릴리스와 같은 `releaseName`/namespace 면 리소스가 그대로 매칭된다. 차이는 주로 Helm 라벨(`app.kubernetes.io/managed-by: Helm`)
3. 수동 Sync → OutOfSync 사라지면 `automated` 켜기
4. 그 다음 `helm uninstall` 은 **하지 않는다** (리소스가 지워짐). 대신 Helm 릴리스 기록만 정리하려면 `kubectl delete secret -n <ns> -l owner=helm,name=<release>`
- CRD 가 큰 차트(Gateway API, ESO)는 `syncOptions: [ServerSideApply=true]` 가 필요할 수 있다.

## 11-6. DB 초기화 Job (ADR-0013 `db-init`)
7단계에서 손으로 만든 `app_rw` 를 ArgoCD **PreSync hook Job** 으로:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16
          envFrom: [{ secretRef: { name: db-master } }]   # ESO: RDS 마스터 비밀 → 이 Job 에만
          command: ["sh", "-c"]
          args:
            - |
              psql "host=$HOST user=$username dbname=point sslmode=require" -v ON_ERROR_STOP=1 <<SQL
              DO \$do\$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_rw') THEN
                  CREATE ROLE app_rw LOGIN PASSWORD '$APP_PW';
                ELSE
                  ALTER ROLE app_rw LOGIN PASSWORD '$APP_PW';
                END IF;
              END \$do\$;
              GRANT CONNECT, CREATE ON DATABASE point TO app_rw;
              SQL
```
- **`$$` 를 쓰지 않는다.** 쿠버네티스는 `args`/`command`/`env` 값의 `$$` 를 `$` 로 바꾼다 → PostgreSQL `DO $$` 가 깨짐 (7단계에서 실제로 겪음). 이름 붙은 달러 인용 `$do$` 사용.
- SQL 은 7단계 7-6 에서 손으로 실행한 것과 같다 (ELSE 로 비밀번호 갱신까지 → 여러 번 실행해도 안전).

⚠️ 확인: ESO 정책에 RDS 마스터 비밀 ARN(`rds!db-*`) 읽기 권한을 추가해야 함, 멱등성(여러 번 실행해도 OK) 확인.

## ✅ 확인
```bash
kubectl get applications -n argocd        # 모두 Synced / Healthy
```
**GitOps 실험:**
1. 6단계 방식으로 새 이미지 태그 `v0.1.1` 푸시
2. `k8s/apps/overlays/dev/kustomization.yaml` 의 `newTag: v0.1.1` 로 수정 → commit → push
3. ArgoCD 가 기본 3분 내 감지 → 자동 Sync → 새 파드 롤링 (UI 에서 Refresh 하면 즉시)
4. **selfHeal 확인**: `kubectl scale deploy/web -n point --replicas=5` → 잠시 뒤 2 로 되돌아감
5. **prune 확인**: Git 에서 리소스 하나 삭제 → push → 클러스터에서도 삭제

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| `repository not found` / `authentication required` | 레포 Secret 의 url·토큰, `secret-type=repository` 라벨 |
| CRD 리소스 `no matches for kind` | sync-wave 순서 / 컨트롤러 Application 먼저 |
| 계속 OutOfSync | 컨트롤러가 채우는 필드 → `ignoreDifferences` |
| `metadata.annotations: Too long` | CRD 큼 → `ServerSideApply=true` |
| terraform apply 시 helm provider 인증 실패 | `exec` 의 aws CLI 프로필, 클러스터 생성 전 provider 평가 → EKS 먼저 apply 후 argocd |

## 🧹 정리
ArgoCD 가 **prune + selfHeal** 이면, 손으로 지운 리소스를 다시 만든다. 정리 시:
1. root Application 의 automated 끄기 (또는 `terraform destroy -target=helm_release.argocd_root`)
2. `point-dev` Application 삭제 (cascade) → Gateway → ALB 삭제 확인
3. NodePool 삭제 → Karpenter 노드 회수 확인
4. 그 다음 `terraform destroy`

⚠️ Application 에 `resources-finalizer.argocd.argoproj.io` finalizer 가 있으면 삭제 시 하위 리소스도 지운다 (없으면 Application 만 사라지고 리소스는 남음). 어느 쪽인지 확인하고 진행.
