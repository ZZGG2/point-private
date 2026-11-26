# 3단계. EKS 클러스터 + 기본 노드그룹

## 목표
`point-dev-eks` 클러스터를 만들고 `kubectl get nodes` 에서 노드 2대 Ready 까지.

## ⚠️ 참고 코드와 모듈 버전이 다르다
`../point-infra/infra/terraform/modules/aws/eks/main.tf` 는 **EKS 모듈 v20** 문법.
우리는 provider 6 → **v21** 이고, 입력 이름이 바뀌었다. 그대로 복사하면 `Unsupported argument`.

| v20 (참고 코드) | v21 (우리) |
|---|---|
| `cluster_name` | `name` |
| `cluster_version` | `kubernetes_version` |
| `cluster_endpoint_public_access` | `endpoint_public_access` |
| `cluster_endpoint_public_access_cidrs` | `endpoint_public_access_cidrs` |
| `cluster_addons` | `addons` |

## 3-0. 준비 — 내 IP, EKS 버전
```bash
curl -s https://checkip.amazonaws.com          # 내 공인 IP (WSL 도 Windows 와 같은 IP)
aws eks describe-cluster-versions --region ap-northeast-2 \
  --query 'clusterVersions[?versionStatus==`STANDARD_SUPPORT`].clusterVersion' --output text
```
- STANDARD_SUPPORT 중 최신을 고른다. **extended support 버전은 시간당 $0.10 → $0.60** (6배).
- 이번 실습: **1.37**.
- ⚠️ **kubectl 이 그 버전 ±1 로 맞춰지는지 먼저 확인** — snap 은 1.36 까지만 있어서 따로 설치해야 했다 ([00-prep.md](00-prep.md#kubectl-버전-맞추기-3단계-이후-실제로-겪은-문제)).

## 3-1. `modules/eks/variables.tf`
```hcl
variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "public_access_cidrs" { type = list(string) }
variable "core_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}
```

## 3-2. `modules/eks/main.tf`
```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids # Private-App 3개 (노드 + 컨트롤플레인 ENI)

  # API 서버: 인터넷에서 접근 가능하되 내 IP만
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_access_cidrs

  # 권한: aws-auth ConfigMap 대신 Access Entry
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni = {
      before_compute = true # 노드보다 먼저 → 첫 노드부터 설정 적용
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true" }
      })
    }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
  }

  eks_managed_node_groups = {
    core = {
      instance_types = var.core_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { workload = "core" }
    }
  }

  # 10단계 Karpenter가 이 SG를 찾아서 새 노드에 붙임
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
```

| 설정 | 의미 |
|---|---|
| `endpoint_public_access_cidrs` | API 서버(kubectl 접속 대상)를 **내 IP 에서만** 접근 가능. 학습 편의 + 최소 보안 |
| `authentication_mode = "API"` | 권한을 EKS Access Entry API 로만 관리. 클러스터 안 `aws-auth` ConfigMap 안 씀 |
| `enable_cluster_creator_admin_permissions` | terraform 을 실행한 IAM 주체 = cluster-admin Access Entry |
| `vpc-cni` + `ENABLE_PREFIX_DELEGATION` | ENI 슬롯마다 IP 1개가 아니라 /28(16개) 블록 → 노드당 파드 수 증가 |
| `before_compute = true` | 노드그룹보다 애드온을 먼저 설치. 노드가 뜬 뒤 바꾸면 기존 노드엔 반영 안 됨 |
| `eks-pod-identity-agent` | 5단계 이후 Pod Identity(파드 → IAM 역할)에 필요 |
| `eks_managed_node_groups.core` | On-Demand t3.medium 2대. core-service 등 상시 워크로드용. 이벤트 피크는 10단계 Karpenter |

## 3-3. `modules/eks/outputs.tf`
```hcl
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_certificate_authority_data" { value = module.eks.cluster_certificate_authority_data }
output "node_security_group_id" { value = module.eks.node_security_group_id }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
```

## 3-4. `envs/dev` 연결
`envs/dev/variables.tf`:
```hcl
variable "kubernetes_version" { type = string }
variable "my_ip_cidr" { type = string }
```
`envs/dev/terraform.tfvars` (커밋 안 됨):
```hcl
kubernetes_version = "1.37"
my_ip_cidr         = "<내IP>/32"
```
`envs/dev/main.tf` 에 추가:
```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.app_subnet_ids
  public_access_cidrs = [var.my_ip_cidr]
}
```
`envs/dev/outputs.tf` 에 추가:
```hcl
output "cluster_name" { value = module.eks.cluster_name }
```
- 다른 모듈의 output 을 참조(`module.vpc.app_subnet_ids`)하면 Terraform 이 **의존 순서(VPC → EKS)를 알아서** 정한다.

## 3-5. 실행
```bash
cd ~/point/point-private/envs/dev
terraform init                 # 새 모듈(eks) 다운로드
terraform fmt -recursive ../..
terraform validate
terraform plan
terraform apply                # 15~20분
```
**plan 에서 볼 것**
- VPC 쪽은 **변경·삭제 없음**
- 추가: `aws_eks_cluster`, IAM 역할(클러스터·노드), 보안그룹(cluster/node) + 규칙, `aws_eks_node_group`, `aws_eks_addon` ×4, `aws_eks_access_entry`/policy association

💸 + EKS 컨트롤 플레인 $0.10/h + t3.medium 2대.

## ✅ 확인
```bash
aws eks update-kubeconfig --name point-dev-eks --region ap-northeast-2   # ~/.kube/config 에 추가
kubectl version                     # Client/Server 버전 차이 ±1 이내
kubectl get nodes -o wide           # 2대 Ready, INTERNAL-IP 10.10.32~127 대역
kubectl get pods -A                 # aws-node, kube-proxy, coredns, eks-pod-identity-agent Running

kubectl get nodes -L topology.kubernetes.io/zone,workload
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.allocatable.pods
aws eks list-access-entries --cluster-name point-dev-eks
aws eks list-addons --cluster-name point-dev-eks
```

### 이번 실습 결과
| 항목 | 값 |
|---|---|
| 서버 버전 | v1.37.1-eks |
| 노드 | 2대, `ap-northeast-2a` (10.10.61.x) / `ap-northeast-2b` (10.10.79.x) |
| allocatable pods | **110** — Prefix Delegation 이 max-pods 에 반영됨 (기본 방식이면 t3.medium 은 17) |

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| kubectl 타임아웃 | 공인 IP 변경 → tfvars `my_ip_cidr` 수정 → `terraform apply` |
| `Unauthorized` | terraform 실행 주체와 현재 프로필이 다름 → `aws sts get-caller-identity` 비교 |
| 노드그룹 `CREATE_FAILED` (join 실패) | 노드가 NAT 로 못 나감 → 2단계 private 라우트 테이블 확인 |
| apply 중단 | 다시 `terraform apply` — state 기준으로 이어서 진행 |
| `Unsupported argument "cluster_name"` 등 | v20 문법을 v21 에 사용 → 위 이름 변경표 |
| kubectl 경고 / 이상 동작 | 클라이언트·서버 버전 차이 2 이상 → kubectl 재설치 |

## 📘 이해할 것
- **컨트롤 플레인 vs 데이터 플레인**: API 서버·etcd 는 AWS 관리 계정에 있고, 우리 VPC 엔 통신용 ENI 만 생긴다 (`aws ec2 describe-network-interfaces` 에서 "Amazon EKS" 설명). 노드 EC2 는 우리 계정.
- **Access Entry**: "IAM 주체 X → 클러스터 권한 Y" 를 EKS API 로 관리. 예전 `aws-auth` ConfigMap 은 잘못 고치면 전원 잠금 위험이 있었다.
- **VPC CNI**: 파드가 오버레이 IP 가 아니라 **VPC 실제 IP**를 받는다 → ALB 가 파드 IP 로 직접 트래픽 전달 가능 (5단계 `targetType: ip` 의 전제).

## 🧹 정리
하루 실습 종료 시 `terraform destroy` (EKS 삭제 ≈ 10~15분). 5단계 이후라면 **ALB 먼저** 지운다 → [05 문서](05-lbc-gateway.md#정리-순서-중요).
