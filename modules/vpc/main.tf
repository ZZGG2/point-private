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
  # Data 서브넷 전용 라우트 테이블 (기본 경로 0.0.0.0/0 없음 → DB 계층 인터넷 격리)
  # 없으면 모듈이 Data 서브넷을 private(App) 라우트 테이블에 붙여서 NAT 경로가 생긴다 (13단계 테스트에서 발견)
  create_database_subnet_route_table = true

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