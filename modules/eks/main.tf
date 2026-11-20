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