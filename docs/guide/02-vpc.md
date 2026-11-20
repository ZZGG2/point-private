# 2단계. VPC 네트워크

## 목표
EKS 가 올라갈 3-Tier 네트워크를 `point-infra` 설계(`network-design.md`) 그대로 만든다.

| 계층 | 2a | 2b | 2c | 용도 |
|---|---|---|---|---|
| VPC | `10.10.0.0/16` | | | |
| Public | 10.10.0.0/24 | 10.10.1.0/24 | 10.10.2.0/24 | ALB, NAT |
| Private-App | 10.10.32.0/19 | 10.10.64.0/19 | 10.10.96.0/19 | EKS 노드/파드 |
| Private-Data | 10.10.128.0/24 | 10.10.129.0/24 | 10.10.130.0/24 | RDS, Redis, Kafka |

## 2-0. AWS provider 를 6 으로 올리기
3단계에서 쓸 **EKS 모듈 v21 이 AWS provider 6 이상을 요구**한다. 나중에 올리면 VPC 쪽도 다시 맞춰야 하므로 지금 올린다.
`envs/dev/versions.tf`:
```hcl
aws = { source = "hashicorp/aws", version = "~> 6.0" }
```
(`bootstrap` 은 독립 루트라 5 그대로 둬도 됨)

## 구조 — 왜 모듈을 한 겹 감싸나
```
modules/vpc/          ← 커뮤니티 모듈을 감싼 "우리 모듈" : 어떻게 (태그·NAT 규칙)
  main.tf  variables.tf  outputs.tf
envs/dev/             ← 모듈 호출 : 무엇을 (CIDR 값)
  versions.tf  providers.tf  main.tf  outputs.tf
```
`envs/prod` 를 만들 때 값만 바꾸면 되고, 서브넷 태그 같은 규칙을 빼먹을 일이 없다.

## 2-1. `modules/vpc/variables.tf`
```hcl
variable "name" { type = string }
variable "cluster_name" { type = string }
variable "cidr" { type = string }
variable "azs" { type = list(string) }
variable "public_subnets" { type = list(string) }
variable "app_subnets" { type = list(string) }
variable "data_subnets" { type = list(string) }
variable "single_nat_gateway" {
  type    = bool
  default = true
}
```

## 2-2. `modules/vpc/main.tf`
```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.name}-vpc"
  cidr = var.cidr
  azs  = var.azs

  public_subnets   = var.public_subnets
  private_subnets  = var.app_subnets  # Private-App
  database_subnets = var.data_subnets # Private-Data

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames         = true # EKS 필수
  create_database_subnet_group = true # 7단계 RDS용

  # 이 태그가 없으면 5단계에서 LB Controller가 서브넷을 못 찾음
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }
}

# S3 Gateway 엔드포인트 (무료): 노드 → S3(ECR 이미지 레이어 등) 트래픽이 NAT를 안 거침
data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    module.vpc.private_route_table_ids,
    module.vpc.database_route_table_ids,
  )
  tags = { Name = "${var.name}-s3-gw" }
}
```

| 설정 | 의미 |
|---|---|
| `private_subnets` | 커뮤니티 모듈 용어. 우리 설계의 Private-App |
| `database_subnets` | Private-Data. `create_database_subnet_group` 로 RDS 서브넷 그룹도 생성 |
| `single_nat_gateway = true` | NAT 1개(2a)만. 학습 비용 절감. 2a 장애 시 2b/2c private 도 인터넷 끊김 → 운영은 AZ별 |
| `kubernetes.io/role/elb = 1` | LB Controller 가 **인터넷용 ALB 를 둘 서브넷**을 찾는 태그 |
| `kubernetes.io/role/internal-elb = 1` | 내부 ALB/NLB 용 서브넷 |
| `karpenter.sh/discovery` | 10단계 Karpenter 가 새 노드를 띄울 서브넷을 찾는 태그 |
| S3 Gateway 엔드포인트 | 라우트 테이블에 S3 prefix list 경로 추가. 무료 + NAT 데이터 처리비 절감 |

- provider 6 부터 `data.aws_region.current.name` 은 deprecated → `.region`.
- 모듈 안에 `tags` 가 없는 이유: provider `default_tags` 가 다 붙인다.

## 2-3. `modules/vpc/outputs.tf`
```hcl
output "vpc_id" { value = module.vpc.vpc_id }
output "app_subnet_ids" { value = module.vpc.private_subnets }
output "data_subnet_ids" { value = module.vpc.database_subnets }
output "public_subnet_ids" { value = module.vpc.public_subnets }
output "database_subnet_group" { value = module.vpc.database_subnet_group_name }
```
다음 단계(EKS, RDS)가 이 값들을 받아 쓴다.

## 2-4. `envs/dev/providers.tf`
```hcl
provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { project = "point-platform", env = "dev", managed-by = "terraform" }
  }
}
```

## 2-5. `envs/dev/main.tf`
```hcl
locals {
  name         = "point-dev"
  cluster_name = "point-dev-eks"
}

module "vpc" {
  source = "../../modules/vpc"

  name         = local.name
  cluster_name = local.cluster_name
  cidr         = "10.10.0.0/16"
  azs          = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]

  public_subnets = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
  app_subnets    = ["10.10.32.0/19", "10.10.64.0/19", "10.10.96.0/19"]
  data_subnets   = ["10.10.128.0/24", "10.10.129.0/24", "10.10.130.0/24"]
}
```

## 2-6. `envs/dev/outputs.tf`
```hcl
output "vpc_id" { value = module.vpc.vpc_id }
output "app_subnet_ids" { value = module.vpc.app_subnet_ids }
```

## 2-7. 실행
```bash
cd ~/point/point-private/envs/dev
terraform init -upgrade        # provider 5→6 교체 + 모듈 다운로드. -upgrade 없으면 lock 파일의 5.x 와 충돌
terraform fmt -recursive ../..
terraform validate
terraform plan
terraform apply
```
**plan 에서 볼 것** (≈ 30개 리소스):
서브넷 9, NAT GW **1**, EIP 1, IGW 1, 라우트 테이블(public 1 / private 1 / database 1) + association, DB 서브넷 그룹, S3 엔드포인트.

💸 apply 순간부터 NAT ≈ $0.06/h + EIP(퍼블릭 IPv4) ≈ $0.005/h.

## ✅ 확인
```bash
VPC_ID=$(terraform output -raw vpc_id)

# 서브넷 9개
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].[CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table

# ELB 태그가 public 3개에만
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=tag:kubernetes.io/role/elb,Values=1 \
  --query 'Subnets[].CidrBlock'

# NAT 1개 available
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table

# 라우트: public → igw, private → nat + S3 prefix list(pl-xxx)
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[].[Tags[?Key==`Name`].Value|[0], Routes[].[DestinationCidrBlock||DestinationPrefixListId, NatGatewayId||GatewayId]]'

# state 가 S3 에 생겼는지
aws s3 ls s3://point-eks-tfstate-020208/envs/dev/
```

## 📘 이해할 것
- **Public vs Private 의 차이는 라우트 테이블의 `0.0.0.0/0` 이 IGW 냐 NAT 냐 뿐.** 서브넷 자체엔 "public" 속성이 없다.
- **App 서브넷이 /19(8,187 IP)로 큰 이유**: VPC CNI 는 파드마다 VPC IP 를 준다 → 노드 수가 아니라 파드 수만큼 IP 가 필요. Prefix Delegation(3단계)은 /28 블록 단위로 가져가서 더 빨리 소모된다.
- **CIDR 은 바꾸지 않는다**: 변경 = VPC 재생성 = 위에 올린 모든 것 재구축. 다른 VPC/온프렘과 겹치지 않게 처음에 확정.

## 🧹 정리
3단계로 바로 안 갈 거면 `terraform destroy` (NAT 가 시간당 과금).
