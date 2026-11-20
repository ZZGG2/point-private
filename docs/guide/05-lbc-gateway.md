# 5단계. AWS Load Balancer Controller + Gateway API

## 목표
인터넷(내 IP)에서 **ALB → nginx 파드**로 접속한다. ADR-0014 에 따라 Ingress 대신 **Gateway API** 를 쓴다.

## 전체 그림
```
내 PC ──HTTP:80──▶ ALB (public 서브넷, SG: 내 IP만)
                    │ 리스너 규칙 = HTTPRoute
                    ▼
               Target Group (ip 타입) ──▶ nginx 파드 IP 직접 (10.10.x.x)

LB Controller (kube-system 파드)
  ├ Gateway / HTTPRoute 를 watch → AWS API 로 ALB·TG·SG 생성/수정
  └ AWS 권한: Pod Identity → IAM 역할 (point-dev-aws-lbc)
```

### Ingress 대신 Gateway API 를 쓰는 이유
| | Ingress | Gateway API |
|---|---|---|
| 역할 분리 | 한 리소스에 인프라+라우팅 | GatewayClass(플랫폼) / Gateway(인프라) / HTTPRoute(앱팀) |
| 확장 | 컨트롤러별 annotation 남발 | 표준 필드 + 구조화된 CRD (LoadBalancerConfiguration 등) |
| 기능 | path/host 정도 | 헤더 매칭, 가중치 분배, 리다이렉트 등 표준화 |

## 확인한 최신 정보 (2026-11-20, LB Controller 공식 문서)
- LB Controller **v3.6.3** / Helm chart **3.6.3** (`eks/aws-load-balancer-controller`)
- Gateway API **v1.6.0 standard** CRD 필요
- ALB(L7) Gateway 기능은 별도 플래그 없이 **Gateway CRD 가 있으면 자동 활성화** (끌 때만 `--feature-gates=ALBGatewayAPI=false`)
- ALB 의 GatewayClass `controllerName` = `gateway.k8s.aws/alb`
- `LoadBalancerConfiguration` 의 `scheme` 기본값은 **`internal`** → 인터넷 공개하려면 명시 필요
- `TargetGroupConfiguration` 의 `targetType` 기본값은 **`instance`** (NodePort 필요)

---

## 5-1. IAM 역할 + Pod Identity (Terraform)

### 정책 파일 (버전 고정)
```bash
cd ~/point/point-private/envs/dev
mkdir -p policies
curl -fsSL -o policies/aws-lbc-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.3/docs/install/iam_policy.json
```
컨트롤러 버전을 올리면 정책도 같은 버전으로 다시 받는다 (새 기능은 새 권한이 필요할 수 있음).

### `envs/dev/aws-lbc.tf`
```hcl
# Pod Identity: "이 클러스터의 kube-system/aws-load-balancer-controller SA = 이 IAM 역할"
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "aws_lbc" {
  name   = "${local.name}-aws-lbc"
  policy = file("${path.module}/policies/aws-lbc-iam-policy.json")
}

resource "aws_iam_role" "aws_lbc" {
  name               = "${local.name}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "aws_lbc" {
  role       = aws_iam_role.aws_lbc.name
  policy_arn = aws_iam_policy.aws_lbc.arn
}

resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lbc.arn
}
```
```bash
terraform plan     # 4 to add (policy, role, attachment, association)
terraform apply
aws eks list-pod-identity-associations --cluster-name point-dev-eks --output table
```

### Pod Identity vs IRSA
| | IRSA | Pod Identity |
|---|---|---|
| 신뢰 주체 | 클러스터별 OIDC provider | `pods.eks.amazonaws.com` (모든 클러스터 공통) |
| 연결 방법 | SA 에 `eks.amazonaws.com/role-arn` annotation | EKS API `pod_identity_association` |
| 클러스터 재생성 시 | 신뢰 정책의 OIDC URL 수정 필요 | 역할 그대로 재사용 |
| 필요 애드온 | 없음 | `eks-pod-identity-agent` (3단계에서 설치) |

⚠️ 자격증명은 **파드 생성 시점**에 주입된다 → association 을 Helm 설치보다 **먼저**. 순서가 바뀌었으면 `kubectl rollout restart`.

## 5-2. CRD 설치 (Helm 보다 먼저)
컨트롤러는 **시작할 때** Gateway CRD 존재 여부를 보고 Gateway 컨트롤러를 켠다.
```bash
# Gateway API 표준 CRD
kubectl apply --server-side=true -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml

# AWS 전용 CRD (LoadBalancerConfiguration, TargetGroupConfiguration, ListenerRuleConfiguration)
kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.3/config/crd/gateway/gateway-crds.yaml

kubectl get crd | grep gateway       # 13개 (networking.k8s.io 10 + k8s.aws 3)
```
- `--server-side=true` : Gateway API CRD 는 커서 client-side apply 의 annotation 크기 제한(256KB)에 걸릴 수 있다.
- 공식 문서는 AWS CRD 를 `main` 브랜치 URL 로 안내하지만, 버전 고정을 위해 태그(`v3.6.3`)로 받았다.

## 5-3. Helm 으로 컨트롤러 설치
```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm search repo eks/aws-load-balancer-controller --versions | head -4
# CHART VERSION 3.6.3 / APP VERSION v3.6.3
```

### `k8s/platform/aws-lbc/values.yaml`
```yaml
clusterName: point-dev-eks
region: ap-northeast-2
vpcId: vpc-08fbd37da787fc400        # terraform output -raw vpc_id
serviceAccount:
  create: true
  name: aws-load-balancer-controller   # ← 5-1 association 의 SA 이름과 정확히 일치
```
- `region` / `vpcId` 를 명시하는 이유: 생략하면 컨트롤러가 노드 IMDS 에서 조회하는데, 노드 설정(hop limit)에 따라 파드에서 IMDS 가 막혀 있을 수 있다.
- VPC 를 destroy 후 다시 만들면 **vpcId 가 바뀐다** → 이 값 갱신 필요.

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --version 3.6.3 -f k8s/platform/aws-lbc/values.yaml
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system
```

### 설치 확인
```bash
kubectl get deploy -n kube-system aws-load-balancer-controller        # 2/2
# Pod Identity 주입 확인 — 이 env 두 개가 보이면 성공
kubectl describe pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller | grep AWS_CONTAINER
#   AWS_CONTAINER_CREDENTIALS_FULL_URI:      http://169.254.170.23/v1/credentials
#   AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE:  /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
# Gateway 컨트롤러 활성화 확인
kubectl logs -n kube-system deploy/aws-load-balancer-controller | grep -i gateway
#   "msg":"starting gateway route reconciler"
```
- `169.254.170.23` = 노드의 eks-pod-identity-agent. AWS SDK 가 이 주소에서 임시 자격증명을 받는다.

## 5-4. Gateway 리소스 (`k8s/smoke/30-gateway.yaml`)
```yaml
# ① ALB 설정: 인터넷 공개 + 내 IP만 허용 (scheme 기본값은 internal)
apiVersion: gateway.k8s.aws/v1
kind: LoadBalancerConfiguration
metadata:
  name: smoke-alb
  namespace: smoke
spec:
  scheme: internet-facing
  sourceRanges:
    - "<내IP>/32"
---
# ② 타겟 그룹: ip 타입 (기본값 instance 는 NodePort Service 필요 → 우리는 ClusterIP)
apiVersion: gateway.k8s.aws/v1
kind: TargetGroupConfiguration
metadata:
  name: nginx-tg
  namespace: smoke
spec:
  targetReference:
    name: nginx
  defaultConfiguration:
    targetType: ip
---
# ③ GatewayClass: "ALB 컨트롤러가 처리하는 Gateway 종류" (클러스터 전역)
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: aws-alb
spec:
  controllerName: gateway.k8s.aws/alb
---
# ④ Gateway = ALB 1개 + 리스너
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: smoke-gw
  namespace: smoke
spec:
  gatewayClassName: aws-alb
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: smoke-alb
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
# ⑤ HTTPRoute = 리스너 규칙 (/ → nginx Service)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx
  namespace: smoke
spec:
  parentRefs:
    - name: smoke-gw
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: nginx
          port: 80
```

### 리소스 ↔ AWS 매핑
| 쿠버네티스 | AWS 에 생기는 것 |
|---|---|
| GatewayClass `aws-alb` | (없음) "이 종류는 LB Controller 담당" 선언 |
| Gateway `smoke-gw` | ALB `k8s-smoke-smokegw-...` + 리스너 :80 + SG 2개 |
| LoadBalancerConfiguration | ALB scheme, SG 인바운드(`sourceRanges`) |
| HTTPRoute `nginx` | 리스너 규칙 (PathPrefix `/` → TG) |
| TargetGroupConfiguration | TG 타입 `ip`, 헬스체크 설정 |
| Service `nginx` 의 Ready 파드 | TG 타겟 (파드 IP) |

### ip vs instance 타겟
| | instance | ip |
|---|---|---|
| 경로 | ALB → 노드 NodePort → kube-proxy → 파드 | ALB → **파드 IP 직접** |
| Service 타입 | NodePort 필요 | ClusterIP 로 충분 |
| 전제 | — | VPC CNI (파드가 VPC IP 를 가짐) |
| 장점 | — | 홉 1개 적음, 파드 단위 헬스체크 |

```bash
kubectl apply -f k8s/smoke/30-gateway.yaml
kubectl get gatewayclass                    # ACCEPTED True
kubectl get gateway -n smoke -w             # ADDRESS 에 xxx.elb.amazonaws.com
kubectl describe httproute -n smoke nginx   # Accepted / ResolvedRefs True
```

## ✅ 확인
```bash
ALB=$(kubectl get gateway -n smoke smoke-gw -o jsonpath='{.status.addresses[0].value}')

# ALB 가 active 될 때까지 (≈ 2~3분)
aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB'].[State.Code,Scheme]" --output text

curl -i http://$ALB           # 200 + Welcome to nginx

# 타겟 = 파드 IP, healthy
LBARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB'].LoadBalancerArn" --output text)
TG=$(aws elbv2 describe-target-groups --load-balancer-arn $LBARN --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
kubectl get pods -n smoke -o wide           # 위 Target.Id 와 파드 IP 가 같은지

# ALB 보안그룹 인바운드 = 내 IP 만
aws elbv2 describe-load-balancers --load-balancer-arns $LBARN --query 'LoadBalancers[0].SecurityGroups'
aws ec2 describe-security-groups --group-ids <sg-id> --query 'SecurityGroups[0].IpPermissions'
```

### 이번 실습 결과
| 항목 | 결과 |
|---|---|
| GatewayClass | `ACCEPTED True` (즉시) |
| ALB | `internet-facing`, 약 1~2분 만에 `active` |
| `curl http://$ALB` | **HTTP 200**, `Welcome to nginx!` |
| Target Group | `k8s-smoke-nginx-...`, 타입 `ip`, 타겟 2개(파드 IP) 모두 `healthy` |
| ALB SG | `k8s-smoke-smokegw-...` 인바운드 80 ← `<내IP>/32` 만 + `k8s-traffic-pointdeveks-...` (ALB→노드 트래픽용 공유 SG) |
| Gateway 상태 | `Accepted=True`, `Programmed=True` (메시지에 ALB ARN) |

> 💡 `kubectl get gateway` 의 PROGRAMMED 열이 한동안 `Unknown` 으로 보였지만,
> `kubectl get gateway -n smoke smoke-gw -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'`
> 로 조건을 직접 보면 `Programmed=True` 였다. 요약 열보다 **conditions 원문**을 보는 습관.

### 추가 실험
- `kubectl scale deploy/nginx -n smoke --replicas=4` → target-health 에 타겟 4개 자동 등록
- 휴대폰 LTE(다른 IP)로 접속 → **타임아웃** (sourceRanges 동작)
- readinessProbe 를 일부러 실패시키면 → TG 에서 타겟 drain → 모든 파드 실패 시 ALB 503

## 자주 막히는 곳
| 증상 | 확인 / 해결 |
|---|---|
| Gateway 에 ADDRESS 없음 | `kubectl describe gateway -n smoke smoke-gw` Events + 컨트롤러 로그 |
| 로그에 `AccessDenied` / no credentials | association 의 namespace·SA 이름 오타, 또는 Helm 이 association 보다 먼저 → `kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system` |
| 로그에 gateway 관련 내용 없음 | CRD 를 Helm 보다 늦게 설치 → 컨트롤러 rollout restart |
| apply 시 webhook 타임아웃 (9443) | 노드 SG 에 컨트롤플레인 → 노드 9443 허용 확인 |
| ALB 는 있는데 502/503 | target-health unhealthy → readinessProbe / 헬스체크 경로 |
| 서브넷을 못 찾음 | public 서브넷 `kubernetes.io/role/elb=1` 태그 (2단계) |
| ALB 가 internal 로 생김 | LoadBalancerConfiguration `scheme` 누락 또는 Gateway 의 `parametersRef` 연결 안 됨 |
| 갑자기 접속 안 됨 | 공인 IP 변경 → `sourceRanges` 수정 후 apply (EKS API 쪽은 tfvars) |

## 정리 순서 (중요)
ALB 는 Terraform 이 아니라 **컨트롤러가 만든 리소스**라 Terraform state 에 없다.
먼저 안 지우면 ALB·SG·ENI 가 VPC 를 붙잡아 `terraform destroy` 가 서브넷/VPC 에서 멈춘다.
```bash
# 1. 컨트롤러가 만든 리소스 제거 → ALB, TG, SG 삭제됨
kubectl delete -f k8s/smoke/30-gateway.yaml

# 2. 1~2분 후 남은 것 없는지
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$(cd envs/dev && terraform output -raw vpc_id) \
  --query 'SecurityGroups[?starts_with(GroupName,`k8s-`)].GroupName'

# 3. (선택) 컨트롤러 제거
helm uninstall aws-load-balancer-controller -n kube-system

# 4. 인프라 삭제
cd envs/dev && terraform destroy
cd ../../bootstrap && terraform destroy     # state 버킷은 맨 마지막
```
마지막으로 콘솔에서 NAT Gateway, Elastic IP, EBS 볼륨, 로드밸런서가 남지 않았는지 확인.

💸 ALB ≈ $0.03/h (+ LCU) 추가.
