# 10단계. Karpenter + KEDA (자동 확장)

## 목표
ADR-0002 의 핵심을 눈으로 본다: **이벤트 피크에 파드(KEDA)와 노드(Karpenter)가 빠르게 늘고, 끝나면 줄어든다.**

```
KEDA ScaledObject (Cron 사전 확장 + CPU)
   │  replicas ↑  (HPA 를 KEDA 가 만들고 관리)
   ▼
event-service 파드 Pending  (core 노드엔 taint 때문에 못 감 / 자리 없음)
   │
   ▼
Karpenter: Pending 파드의 requests·nodeSelector·toleration 을 보고
           NodePool "event" 조건에 맞는 가장 싼 인스턴스(Spot 우선)를 EC2 Fleet 으로 생성
   │
   ▼  부하 종료 → replicas ↓ → 빈 노드 → consolidation 으로 회수
```

> 아직 실습 전 작성한 가이드. "⚠️ 확인" 은 진행 시 갱신.

## ⚠️ 시작 전 확인
- **Karpenter 버전 ↔ Kubernetes 1.37 호환** — Karpenter 문서의 Compatibility 표에서 1.37 지원 버전을 확인. 지원 안 하면 이 단계를 진행할 수 없다.
- Spot 은 서비스 연결 역할이 필요하다 (계정에 처음이면):
  ```bash
  aws iam create-service-linked-role --aws-service-name spot.amazonaws.com   # 이미 있으면 에러 → 무시
  ```

## 10-1. Karpenter AWS 리소스 (Terraform)
EKS 모듈에 Karpenter 서브모듈이 있다: 컨트롤러 IAM 역할(Pod Identity), **노드 IAM 역할 + Access Entry**, 중단 알림 SQS 큐, EventBridge 규칙.

**`envs/dev/karpenter.tf`**
```hcl
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # 노드 역할 이름을 고정 → EC2NodeClass.spec.role 에 그대로 적는다
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "KarpenterNodeRole-${local.cluster_name}"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"   # SSM 접속용(선택)
  }

  create_pod_identity_association = true   # kube-system/karpenter SA ↔ 컨트롤러 역할
}

output "karpenter_queue_name" { value = module.karpenter.queue_name }
output "karpenter_node_role_name" { value = module.karpenter.node_iam_role_name }
```
⚠️ 확인: v21 서브모듈 입력 이름 (`create_pod_identity_association`, `namespace`, `service_account` 기본값) — 모듈 README 와 대조.

```bash
terraform init && terraform plan && terraform apply
```
- 서브넷 태그 `karpenter.sh/discovery=point-dev-eks` (2단계), 노드 SG 태그 (3단계) 는 이미 붙어 있다 → 새 노드가 어디에 어떤 SG 로 뜰지 찾는 데 쓴다.

## 10-2. Karpenter 설치 (Helm, OCI)
```bash
# 최신 버전 확인 (호환표의 1.37 지원 버전 이상)
helm show chart oci://public.ecr.aws/karpenter/karpenter | grep -E '^version|^appVersion'

helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version <버전> -n kube-system \
  --set settings.clusterName=point-dev-eks \
  --set settings.interruptionQueue=$(cd envs/dev && terraform output -raw karpenter_queue_name) \
  --set controller.resources.requests.cpu=250m \
  --set controller.resources.requests.memory=512Mi \
  --wait
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl logs -n kube-system deploy/karpenter | grep -i -E 'error|discovered'
```
- 값은 `k8s/platform/karpenter/values.yaml` 로 빼 두면 11단계 이전이 쉽다.
- Karpenter 컨트롤러는 **자기가 만든 노드 위에 뜨면 안 된다** (닭과 달걀) → core 노드그룹(관리형)에 뜬다.

## 10-3. NodePool + EC2NodeClass
`../point-infra/k8s/platform/karpenter/nodepool-event.yaml` 을 dev 에 맞게 고친다.

**`k8s/platform/karpenter/nodepool-event.yaml`**
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
    cpu: "16"                     # 실습 안전장치: 이 이상 노드 안 만듦 (point-infra 는 400)
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
    - alias: al2023@latest        # ⚠️ 운영은 버전 고정 (al2023@v2026xxxx) — latest 는 AMI 가 바뀌면 드리프트로 노드 교체
  role: KarpenterNodeRole-point-dev-eks
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: point-dev-eks }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: point-dev-eks }
```
```bash
kubectl apply -f k8s/platform/karpenter/nodepool-event.yaml
kubectl get nodepool,ec2nodeclass          # READY True
```

## 10-4. event-service 를 Karpenter 노드로
`k8s/apps/overlays/dev/kustomization.yaml` 에 패치 추가:
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
      - op: remove
        path: /spec/replicas          # KEDA(HPA) 가 관리 → 매니페스트에 replicas 있으면 apply 때마다 되돌림
```
⚠️ base 에 `replicas` 가 없으면 `remove` 가 실패한다 → base 내용에 맞춰 조정.

```bash
kubectl apply -k k8s/apps/overlays/dev
kubectl get nodeclaims -w                  # 새 NodeClaim → Launched → Registered → Initialized
kubectl get nodes -L workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
kubectl get pods -n point -o wide          # event-service 가 새 노드에
```
📏 여기서 첫 측정: **"파드 Pending → 새 노드 Ready → 파드 Ready"** 시간 (`kubectl get events -n point --sort-by=.lastTimestamp`, NodeClaim 의 condition 시각).

## 10-5. KEDA
```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda -n keda --create-namespace --version <최신>
kubectl get pods -n keda
```

**`k8s/apps/overlays/dev/scaledobject.yaml`** (kustomization `resources` 에 추가)
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
    # 실습: "지금부터 몇 분 뒤" 로 바꿔서 사전 확장을 관찰
    - type: cron
      metadata:
        timezone: Asia/Seoul
        start: "<분> <시> * * *"       # 예: 지금 14:20 이면 "25 14 * * *"
        end:   "<분> <시> * * *"       # 예: "40 14 * * *"
        desiredReplicas: "8"
    - type: cpu
      metricType: Utilization
      metadata:
        value: "60"                  # requests.cpu(250m) 의 60%
```
```bash
kubectl apply -k k8s/apps/overlays/dev
kubectl get scaledobject,hpa -n point      # KEDA 가 HPA keda-hpa-event-service 생성
```
- CPU 트리거는 **metrics-server** 가 필요하다. EKS 엔 기본 설치가 아닐 수 있다:
  ```bash
  kubectl get deploy -n kube-system metrics-server || \
    aws eks create-addon --cluster-name point-dev-eks --addon-name metrics-server
  ```
  ⚠️ 확인: metrics-server 를 EKS 애드온으로 쓸지 Helm 으로 쓸지 → 3단계 Terraform `addons` 에 넣는 게 깔끔.

### 관찰 1 — Cron 사전 확장
start 시각이 되면: replicas 1 → 8 → event 파드 Pending → Karpenter 가 노드 추가 → end 후 5분(scaleDown 안정화) 뒤 1 로 → 빈 노드 1분 뒤 회수.
```bash
watch -n2 'kubectl get pods -n point -l app=event-service | tail -n +2 | wc -l; kubectl get nodes -l workload=event'
```

## 10-6. 부하 테스트 (CPU 트리거)
`../point-infra/load-test/k6/s2-event-spike.js` 는 **`X-User-Id` 헤더 기반이라 현재 JWT 인증과 맞지 않는다.** 복사해서 고친다:

**`load-test/s2-event-spike-dev.js`** (변경점만)
```js
const TOKEN = __ENV.TOKEN;          // 9단계 로그인으로 받은 access token
// ...
export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      startRate: 0, timeUnit: '1s',
      preAllocatedVUs: 200, maxVUs: 1000,
      stages: [
        { target: 300, duration: '30s' },   // 집 회선·ALB 비용 고려해 5,000 → 300 RPS
        { target: 300, duration: '5m' },
        { target: 0,   duration: '30s' },
      ],
    },
  },
};
export default function () {
  const res = http.post(`${BASE}/api/events/${EVENT}/answers`, JSON.stringify({ answer: 'A' }),
    { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` } });
  check(res, { 'accepted|ok|dup|closed': (r) => [200, 202, 409, 410].includes(r.status) });
}
```
- 같은 사용자 토큰이라 대부분 409(중복)지만, JWT 검증 + Redis 조회로 **CPU 부하는 충분히 생긴다**. 실제 사용자 분포를 흉내내려면 demo 계정 여러 개/가입 API 로 토큰 풀을 만든다 (point-infra 스크립트의 TODO).
- access token TTL 은 15분 (`JWT_ACCESS_TTL`) → 테스트 직전에 발급.

```bash
# k6 설치 없이 docker 로
docker run --rm -i -e BASE_URL=http://$ALB -e EVENT_ID=evt-local -e TOKEN=$TOKEN \
  grafana/k6 run - < load-test/s2-event-spike-dev.js
```
관찰 (다른 터미널):
```bash
kubectl get hpa -n point -w
kubectl get nodeclaims -w
kubectl top pods -n point
```

## ✅ 확인
- 부하 중 `kubectl get nodes -w` 로 event 노드 추가 → 부하 종료 후 몇 분 내 회수
- `kubectl get nodes -L karpenter.sh/capacity-type` 에 `spot` 이 보임

📏 **기록할 것** (ADR-0002 후속 과제 — `docs/log/10-karpenter-keda.md`):
| 구간 | 시간 |
|---|---|
| 부하 시작 → HPA replicas 증가 | |
| 파드 Pending → NodeClaim Launched | |
| Launched → 노드 Ready | |
| 노드 Ready → 파드 Ready (이미지 pull + Spring 기동) | |
| 부하 종료 → 노드 회수 | |
| 선택된 인스턴스 타입 / Spot 여부 / k6 p95 | |

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| NodeClaim 이 안 생김 | `kubectl logs deploy/karpenter -n kube-system` — requirements 불일치, `limits.cpu` 도달 |
| `UnauthorizedOperation` / `AccessDenied` (Karpenter 로그) | Pod Identity association, 컨트롤러 역할 |
| 노드는 떴는데 NotReady / 클러스터에 join 안 됨 | 노드 역할 Access Entry (서브모듈이 만듦), EC2NodeClass `role` 이름 |
| 파드가 core 노드에 뜸 | overlay 패치 미적용 (`kubectl get deploy event-service -o yaml` 에 nodeSelector 확인) |
| HPA `<unknown>/60%` | metrics-server 없음 / requests.cpu 없음 |
| 파드 수가 apply 할 때마다 되돌아감 | Deployment 에 `replicas` 남아 있음 |
| Spot 생성 실패 `AuthFailure.ServiceLinkedRoleCreationNotPermitted` | Spot 서비스 연결 역할 생성 |

## 🧹 정리 (중요)
Karpenter 노드는 **Terraform state 에 없다.** 클러스터를 먼저 지우면 EC2 가 고아로 남아 계속 과금된다.
```bash
kubectl delete scaledobject -n point event-service
kubectl delete nodepool --all                 # → Karpenter 가 노드 drain & terminate
kubectl get nodeclaims -w                     # 0 개 될 때까지
aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=event Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId'      # 비어야 함
helm uninstall karpenter -n kube-system
# 그 다음 terraform destroy
```
💸 Spot c/m large ≈ On-Demand 의 30~40% (변동). `limits.cpu: 16` 이 비용 상한 역할.
