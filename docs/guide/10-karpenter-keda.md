# 10단계. Karpenter + KEDA (자동 확장)

## 목표
ADR-0002 의 핵심을 눈으로 본다: **이벤트 피크에 파드(KEDA)와 노드(Karpenter)가 빠르게 늘고, 끝나면 줄어든다.**

```
KEDA ScaledObject (Cron 사전 확장 + CPU)
   │  replicas ↑  (HPA keda-hpa-event-service 를 KEDA 가 만들고 관리)
   ▼
event-service 파드 Pending  (core 노드엔 nodeSelector 불일치 / event 노드는 자리 없음)
   │
   ▼
Karpenter: Pending 파드의 requests·nodeSelector·toleration 을 보고
           NodePool "event" 조건에 맞는 가장 싼 인스턴스(Spot 우선)를 EC2 Fleet 으로 생성
   │
   ▼  부하 종료 → replicas ↓ → 빈 노드 → consolidation 으로 회수
```

> 2026-11-23 실제로 진행한 결과를 반영한 문서. Karpenter **1.15.3**, KEDA **2.21.1**, metrics-server EKS 애드온 **v0.9.1**.

## 시작 전 확인
- **Karpenter ↔ Kubernetes 호환표** (karpenter.sh/docs/upgrading/compatibility): K8s 1.36 은 `>= 1.13`, **1.37 은 `1.15.x`**. → 1.15.3 사용.
  ```bash
  helm show chart oci://public.ecr.aws/karpenter/karpenter | grep -E '^version|^appVersion'   # 1.15.3
  ```
- Spot 서비스 연결 역할 (계정에 처음이면 생성. 이번엔 이미 있었다):
  ```bash
  aws iam get-role --role-name AWSServiceRoleForEC2Spot --query Role.Arn --output text \
    || aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
  ```

## 10-1. Karpenter AWS 리소스 — [`envs/dev/karpenter.tf`](../../envs/dev/karpenter.tf)
EKS 모듈의 Karpenter 서브모듈: 컨트롤러 IAM 역할(Pod Identity), **노드 IAM 역할 + Access Entry**, 중단 알림 SQS 큐, EventBridge 규칙 5개.
```hcl
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # 노드 역할 이름 고정 → EC2NodeClass.spec.role 에 그대로 적는다
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "KarpenterNodeRole-${local.cluster_name}"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"   # SSM 접속용(선택)
  }

  # 기본값: namespace = kube-system, service_account = karpenter
  create_pod_identity_association = true

  # 컨트롤러 정책이 관리형 정책 한도(6,144자)를 넘음 → 인라인 정책(10,240자)
  enable_inline_policy = true
}

output "karpenter_queue_name" { value = module.karpenter.queue_name }
output "karpenter_node_role_name" { value = module.karpenter.node_iam_role_name }
```
```bash
cd ~/point/point-private/envs/dev
terraform init                 # 새 module 블록 → 필수 (eks 21.30.2 의 서브모듈을 받음)
terraform plan -out=tfplan     # Plan: 22 to add
terraform apply tfplan
```
- 서브넷 태그 `karpenter.sh/discovery=point-dev-eks` (2단계, Private-App 3개), 노드 SG 태그 (3단계) 는 이미 붙어 있다 → 새 노드가 어디에 어떤 SG 로 뜰지 찾는 데 쓴다.
  ```bash
  aws ec2 describe-subnets --filters Name=tag:karpenter.sh/discovery,Values=point-dev-eks --query 'Subnets[].CidrBlock'
  aws ec2 describe-security-groups --filters Name=tag:karpenter.sh/discovery,Values=point-dev-eks --query 'SecurityGroups[].GroupName'
  ```

### 문제 ① — `LimitExceeded: Cannot exceed quota for PolicySize: 6144`
```
Error: creating IAM Policy (KarpenterController-...): ... LimitExceeded: Cannot exceed quota for PolicySize: 6144
```
- 원인: Karpenter 컨트롤러 권한(EC2 Fleet, 인스턴스 프로파일, SQS, Pricing ...)이 길어서 **관리형 IAM 정책 한도 6,144자**를 넘었다.
- 해결: 모듈 변수 `enable_inline_policy = true` (변수 설명에 이 에러 메시지가 그대로 적혀 있다) → 역할에 직접 붙는 **인라인 정책(한도 10,240자)** 으로 만든다.
- 실패한 apply 에서 나머지 21개는 이미 만들어졌으므로, 다시 plan 하면 `1 to add` 만 나온다 (Terraform 은 부분 성공을 state 에 기록한다).

## 10-2. Karpenter 설치 (Helm, OCI) — [`k8s/platform/karpenter/values.yaml`](../../k8s/platform/karpenter/values.yaml)
```yaml
settings:
  clusterName: point-dev-eks
  interruptionQueue: Karpenter-point-dev-eks   # terraform output -raw karpenter_queue_name
replicas: 1                                    # 실습: core 노드 2대 용량 절약 (운영은 기본값 2 = HA)
controller:
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits:   { memory: 512Mi }
```
```bash
cd ~/point/point-private
helm install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.3 \
  -n kube-system -f k8s/platform/karpenter/values.yaml --wait
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl logs -n kube-system deploy/karpenter | grep '"level":"ERROR"'      # 없어야 함
```
- 값을 파일로 빼 둔 이유: 11단계에서 ArgoCD Application 으로 옮길 때 그대로 쓴다.
- Karpenter 컨트롤러는 **자기가 만든 노드 위에 뜨면 안 된다** (닭과 달걀) → 차트 기본 affinity 가 `karpenter.sh/nodepool` 라벨이 있는 노드를 피한다 → core 노드그룹에 뜬다.

## 10-3. NodePool + EC2NodeClass — [`k8s/platform/karpenter/nodepool-event.yaml`](../../k8s/platform/karpenter/nodepool-event.yaml)
point-infra 의 것을 dev 에 맞게: 클러스터 이름, `instance-size` 제한, `limits.cpu: 16`.
```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: event
spec:
  template:
    metadata:
      labels: { workload: event }
    spec:
      taints:
        - { key: workload, value: event, effect: NoSchedule }   # event-service 외엔 못 옴
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["spot", "on-demand"] }
        - { key: karpenter.k8s.aws/instance-category, operator: In, values: ["c", "m"] }
        - { key: karpenter.k8s.aws/instance-generation, operator: Gt, values: ["5"] }
        - { key: karpenter.k8s.aws/instance-size, operator: In, values: ["large", "xlarge"] }  # 실습: 큰 인스턴스 방지
        - { key: kubernetes.io/arch, operator: In, values: ["amd64"] }
  limits:
    cpu: "16"                     # 실습 비용 상한 (point-infra 는 400)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest        # 운영은 버전 고정 (al2023@v2026xxxx) — latest 는 AMI 가 바뀌면 드리프트로 노드 교체
  role: KarpenterNodeRole-point-dev-eks
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: point-dev-eks }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: point-dev-eks }
```
```bash
kubectl apply -f k8s/platform/karpenter/nodepool-event.yaml
kubectl get nodepool,ec2nodeclass          # 둘 다 READY True (15초 이내)
```

## 10-4. event-service 를 Karpenter 노드로
`k8s/apps/overlays/dev/kustomization.yaml` 맨 아래에 패치 추가:
```yaml
patches:
  - target: { kind: Deployment, name: event-service }
    patch: |-
      - op: add
        path: /spec/template/spec/nodeSelector
        value: { workload: event }
      - op: add
        path: /spec/template/spec/tolerations
        value: [{ key: workload, value: event, effect: NoSchedule }]
```
- 9단계 base 에서 event-service 에 **`replicas` 를 처음부터 안 적었으므로** `op: remove /spec/replicas` 는 필요 없다 (있으면 KEDA 가 늘린 파드 수를 apply 가 되돌린다).
```bash
kubectl apply -k k8s/apps/overlays/dev
kubectl get nodeclaims -o wide             # 새 NodeClaim → Launched → Registered → Initialized
kubectl get nodes -L workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
kubectl get pods -n point -o wide          # event-service 가 새 노드에
```
시간 측정 (NodeClaim condition 시각 + 파드 이벤트):
```bash
kubectl get nodeclaim -o jsonpath='{range .items[0]}created {.metadata.creationTimestamp}{"\n"}{range .status.conditions[*]}{.type} {.lastTransitionTime}{"\n"}{end}{end}'
kubectl get events -n point --field-selector involvedObject.name=<파드> -o custom-columns=T:.firstTimestamp,R:.reason,M:.message
```

### 📏 첫 측정 — 노드 0대에서 1대 (UTC)
| 시각 | 사건 | 경과 |
|---|---|---|
| 04:46:59 | 새 파드 생성 → `FailedScheduling` (core 노드는 nodeSelector 불일치) | 0s |
| 04:47:00 | `Nominated` — Karpenter 가 NodeClaim `event-5llgm` 생성 | +1s |
| 04:47:03 | **Launched** — EC2 Fleet 으로 **c7i.large Spot** (ap-northeast-2b) | +4s |
| 04:47:20 | **Registered** — kubelet 이 클러스터에 join | +21s |
| 04:47:30 | 파드 Scheduled → 이미지 pull 시작 | +31s |
| 04:47:32 | **Initialized** (노드 Ready) | +33s |
| 04:47:34 | 이미지 pull 완료 (181MB, 4초) → 컨테이너 시작 | +35s |
| 04:47:45 | 파드 **Ready** (Spring 기동 ≈ 11초) | **+46s** |
- 가장 긴 구간은 EC2 부팅 → join (17초) + 노드 초기화 (12초). Karpenter 자체 결정은 1초.
- 파드 이벤트에 `TaintManagerEviction: Cancelling deletion` 이 한 번 보이는데, 노드 초기화 중 `not-ready` taint 가 풀리는 과정이라 무시해도 된다.

## 10-5. metrics-server + KEDA
CPU 트리거(HPA Resource 메트릭)와 `kubectl top` 에 **metrics-server** 가 필요하다. EKS 엔 기본으로 없었다:
```bash
kubectl get apiservice v1beta1.metrics.k8s.io     # NotFound
aws eks describe-addon-versions --kubernetes-version 1.37 --addon-name metrics-server \
  --query 'addons[0].addonVersions[0].addonVersion' --output text     # v0.9.1-eksbuild.2
```
→ Helm 대신 **EKS 애드온으로, 3단계 Terraform 에** 넣었다 (클러스터와 수명이 같고, 재시작 시 자동 설치):
```hcl
# modules/eks/main.tf → addons
    metrics-server         = {} # 10단계: HPA/KEDA CPU 트리거, kubectl top
```
```bash
cd envs/dev && terraform plan     # Plan: 1 to add (aws_eks_addon.this["metrics-server"])
terraform apply
kubectl get apiservice v1beta1.metrics.k8s.io      # AVAILABLE True
kubectl top nodes
```

KEDA — [`k8s/platform/keda/values.yaml`](../../k8s/platform/keda/values.yaml) (기본값 그대로, 11단계 이전용 자리):
```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda --version 2.21.1 -n keda --create-namespace -f k8s/platform/keda/values.yaml --wait
kubectl get pods -n keda                                # operator, metrics-apiserver, admission-webhooks
kubectl get apiservice v1beta1.external.metrics.k8s.io  # AVAILABLE True
```
- keda-operator 가 처음에 `RESTARTS 1` — 웹훅 인증서 준비 전에 한 번 재시작하는 흔한 동작, 이후 정상.

**[`k8s/apps/overlays/dev/scaledobject.yaml`](../../k8s/apps/overlays/dev/scaledobject.yaml)** (kustomization `resources` 에 추가)
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: event-service
spec:
  scaleTargetRef:
    name: event-service
  minReplicaCount: 1
  maxReplicaCount: 20                # 실습 상한 (point-infra 는 100)
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:   { stabilizationWindowSeconds: 0 }
        scaleDown: { stabilizationWindowSeconds: 300 }
  triggers:
    - type: cron
      metadata:
        timezone: Asia/Seoul
        start: "53 13 * * *"         # 실습: "지금부터 몇 분 뒤" 로 바꿔서 관찰 (분 시 * * *)
        end: "00 14 * * *"
        desiredReplicas: "8"
    - type: cpu
      metricType: Utilization
      metadata:
        value: "60"                  # requests.cpu(250m) 의 60%
```
cron 시각을 "지금 + 3분 / + 10분" 으로 만드는 법:
```bash
TZ=Asia/Seoul date -d '+3 min' '+%M %H'     # → start 앞부분
TZ=Asia/Seoul date -d '+10 min' '+%M %H'    # → end 앞부분
```
```bash
kubectl apply -k k8s/apps/overlays/dev
kubectl get scaledobject,hpa -n point      # TRIGGERS cron,cpu / HPA TARGETS "0/1 (avg), cpu: 5%/60%"
```
- 트리거가 여러 개면 HPA 는 **가장 큰 값**을 채택한다 (cron 이 8 을 원하고 CPU 가 2 를 원하면 8).

### 📏 관찰 1 — Cron 사전 확장 (KST)
```bash
watch -n5 'kubectl get hpa -n point; kubectl get pods -n point -l app=event-service; kubectl get nodeclaims'
```
| 시각 | 사건 |
|---|---|
| 13:53:13 | cron start → HPA `New size: 5` (1→5) |
| 13:53:14 | 들어갈 자리 없는 파드 Pending → NodeClaim `event-kvvzc` 생성 (c7i.large Spot) |
| 13:53:28 | HPA `New size: 8` (5→8) |
| 13:53:34 | 기존 노드에 들어간 3개 Ready (**21초** — 노드가 이미 있으니 이미지 pull + 기동만) |
| 13:53:47 | 새 노드 Initialized (생성 후 33초 — 첫 측정과 같음) |
| 13:54:25 | 새 노드의 파드 4개 Ready (**확장 결정 후 72초**) |
| 14:00 | cron end |
| 14:06:10 | HPA `New size: 2` — `All metrics below target` (5분 안정화 후) |
| 14:07:40 | Karpenter `Disrupting Node: Empty` → 빈 노드 taint (2대 → 1대) |
| 14:08:10 | 노드·NodeClaim 삭제, EC2 terminate |
- **1→5→8 두 번에 나눠 늘었다**: `stabilizationWindowSeconds: 0` 이어도 HPA 기본 scaleUp 정책은 "15초마다 **4개 또는 2배** 중 큰 쪽" 까지만. 한 번에 올리려면 `policies: [{type: Pods, value: 20, periodSeconds: 15}]` 추가.
- 8 → 1 이 아니라 **8 → 2**: scaleDown 안정화는 "지난 5분 동안의 권장값 중 **최댓값**"을 쓴다. 그 사이 CPU 트리거가 2 를 권장한 순간(파드 하나가 순간 243m)이 있었다 → 다음 5분 뒤 1 로.
- 파드 8개(250m·768Mi) 중 4개는 c7i.large(2 vCPU, 4GiB) 한 대에 메모리 기준으로 꽉 찬다 → 두 번째 노드.
- 남은 노드에 대해 `Unconsolidatable: SpotToSpotConsolidation is disabled` 이벤트 — Spot 노드를 더 싼 Spot 으로 바꾸는 건 기본 비활성 (feature gate). 정상.

## 10-6. 부하 테스트 (CPU 트리거) — [`load-test/s2-event-spike-dev.js`](../../load-test/s2-event-spike-dev.js)
`../point-infra/load-test/k6/s2-event-spike.js` 는 **`X-User-Id` 헤더 기반이라 현재 JWT 인증과 맞지 않는다.** 복사해서 고쳤다 (변경점):
```js
const TOKEN = __ENV.TOKEN;          // 9단계 로그인으로 받은 access token
// stages: 0 → 300 RPS (30s) → 300 RPS 유지 (5m) → 0 (30s)   ← 원본 5,000 RPS 는 집 회선·ALB 비용·limits.cpu 16 고려해 축소
// preAllocatedVUs: 200, maxVUs: 1000
// thresholds: http_req_failed rate<0.01
export default function () {
  const res = http.post(`${BASE}/api/events/${EVENT}/answers`, JSON.stringify({ answer: 'A' }),
    { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` } });
  check(res, { 'accepted|ok|dup|closed': (r) => [200, 202, 409, 410].includes(r.status) });
}
```
- 같은 사용자 토큰이라 대부분 409(중복)지만, JWT 검증 + Redis 조회로 **CPU 부하는 생긴다**. 실제 사용자 분포를 흉내내려면 토큰 풀이 필요 (point-infra 스크립트의 TODO).
- access token TTL 15분 (`JWT_ACCESS_TTL`) → 테스트 **직전에** 발급. 테스트는 6분이라 충분.
- 이미 참여한 demo1~4 대신 **demo5** 토큰 사용 (첫 요청만 낙첨 200, 나머지 409).

```bash
ALB=$(kubectl get gateway -n point point-gw -o jsonpath='{.status.addresses[0].value}')
TOKEN=$(curl -s -X POST http://$ALB/api/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"demo5@point.local","password":"demo1234!"}' | jq -r .data.accessToken)
docker run --rm grafana/k6 inspect - < load-test/s2-event-spike-dev.js > /dev/null && echo OK   # 문법 확인
# k6 설치 없이 docker 로
docker run --rm -i -e BASE_URL=http://$ALB -e EVENT_ID=evt-local -e TOKEN=$TOKEN \
  grafana/k6 run - < load-test/s2-event-spike-dev.js
```
관찰 (다른 터미널):
```bash
kubectl get hpa -n point -w
kubectl get nodeclaims -w
kubectl top pods -n point -l app=event-service
```

### 📏 관찰 2 — 부하 테스트 결과
k6 요약 (300 RPS 목표, 6분):
| 항목 | 값 |
|---|---|
| 요청 | 98,999 건, 평균 **275 RPS** (ramp 구간 포함) |
| 실패율 | **0.00%** (200/409 만, `checks 100%`) |
| 지연 | med 9.8ms, **p95 38ms**, p90 26ms, max 5.4s (스케일아웃 순간) |
| 임계값 | `p(95)<500` ✓, `rate<0.01` ✓ |

확장 타임라인 (KST):
| 시각 | 사건 | 구간 |
|---|---|---|
| 14:08:43 | k6 시작 (그 전 상태: 파드 2, event 노드 1) | |
| 14:09:10 | HPA 2 → 4 (`cpu resource utilization above target`) | **부하 시작 → HPA 증가 27초** (metrics-server 수집 주기 + HPA 15초 주기) |
| 14:09:25 | HPA 4 → 6, 파드 Pending → NodeClaim `event-q4b2z` 생성 | Pending → NodeClaim **1초** |
| 14:09:36~40 | 기존 노드에 들어간 2개 Ready | |
| 14:09:58 | `event-q4b2z` Initialized | NodeClaim → 노드 Ready **32초** |
| 14:10:10 | HPA 6 → 10, NodeClaim `event-26xtz` 생성 | |
| 14:10:15~19 | 2번째 노드의 파드 Ready | 노드 Ready → 파드 Ready **≈ 20초** (pull 4초 + Spring 기동) |
| 14:10:44 | `event-26xtz` Initialized | 32초 |
| 14:11:08 | 마지막 파드 Ready — **파드 10, event 노드 3 (c7i.large Spot ×3)** | 부하 시작 → 최종 용량 **2분 25초** |
| 14:14:43 | k6 종료 | |
| 14:22:59 | HPA 10 → 1 | 부하 종료 → 축소 **8분 16초** |
| 14:24:55 | 빈 노드 `Disrupting Node: Empty` | |
| 14:25:27 | event 노드 1대만 남음 | 부하 종료 → 노드 회수 **10분 44초** |

- 선택된 인스턴스는 세 번 모두 **c7i.large Spot** (ap-northeast-2b) — requirements 안에서 가장 싼 조합.
- 노드 1대 추가에 드는 시간은 매번 **≈ 32~33초** (Launched 3초 + 부팅·join 17초 + 초기화 12초). 파드가 쓸 수 있게 되기까지 ≈ 70초.
  → 이벤트 시작 시각을 아는 경우 **Cron 사전 확장이 이 1분을 없애 준다** (ADR-0002 의 근거).
- 축소가 5분이 아니라 8분 걸린 이유 (추정): k6 의 마지막 30초 ramp-down 동안에도 CPU 가 목표 이상 → 그 시점부터 5분 안정화 + metrics-server 지연(≈1분) + HPA 주기. 회수는 축소 후 1분(`consolidateAfter`) + 종료 30초.
- HPA 가 10 에서 멈춘 것 (추정): 10 × 250m = 2.5 vCPU 로 CPU 가 60% 아래로 내려감. 같은 토큰이라 대부분 409(가벼운 경로)여서 maxReplicaCount 20 까지는 안 갔다.

## ✅ 확인
- [x] 부하 중 event 노드 추가 → 부하 종료 후 몇 분 내 회수
- [x] `kubectl get nodes -L karpenter.sh/capacity-type` 에 `spot`
- [x] apply 해도 KEDA 가 늘린 파드 수가 되돌아가지 않음 (base 에 `replicas` 없음)

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| `LimitExceeded: ... PolicySize: 6144` (terraform apply) | `enable_inline_policy = true` (문제 ①) |
| NodeClaim 이 안 생김 | `kubectl logs deploy/karpenter -n kube-system` — requirements 불일치, `limits.cpu` 도달 |
| `UnauthorizedOperation` / `AccessDenied` (Karpenter 로그) | Pod Identity association, 컨트롤러 역할 |
| 노드는 떴는데 NotReady / join 안 됨 | 노드 역할 Access Entry (서브모듈이 만듦), EC2NodeClass `role` 이름 |
| 파드가 core 노드에 뜸 | overlay 패치 미적용 (`kubectl get deploy event-service -o yaml` 에 nodeSelector 확인) |
| HPA `cpu: <unknown>/60%` | metrics-server 없음 / requests.cpu 없음 |
| 파드 수가 apply 할 때마다 되돌아감 | Deployment 에 `replicas` 남아 있음 |
| 한 번에 목표 수까지 안 늘어남 | HPA 기본 scaleUp 정책 (15초에 4개 또는 2배) → `behavior.scaleUp.policies` |
| 축소가 최소값까지 안 감 | scaleDown 안정화 창 안의 최댓값 → 5분 더 기다리기 |
| Spot 생성 실패 `AuthFailure.ServiceLinkedRoleCreationNotPermitted` | Spot 서비스 연결 역할 생성 |

## 🧹 정리 (중요)
Karpenter 노드는 **Terraform state 에 없다.** 클러스터를 먼저 지우면 EC2 가 고아로 남아 계속 과금된다.
```bash
kubectl delete scaledobject -n point event-service      # 또는 kubectl delete -k k8s/apps/overlays/dev (9단계 정리)
kubectl delete nodepool --all                 # → Karpenter 가 노드 drain & terminate
kubectl get nodeclaims -w                     # 0 개 될 때까지
aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=event Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].InstanceId'      # [] 이어야 함
helm uninstall keda -n keda
helm uninstall karpenter -n kube-system
# 그 다음 terraform destroy (Karpenter IAM·SQS·EventBridge, metrics-server 애드온 포함)
```
💸 c7i.large Spot ≈ On-Demand 의 30~40% (변동). `limits.cpu: 16` 이 비용 상한 역할 (c/m large 기준 최대 8대).
