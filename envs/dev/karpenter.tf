# 10단계 — Karpenter AWS 리소스
# 컨트롤러 IAM 역할(Pod Identity) + 노드 IAM 역할 + Access Entry + 중단 알림 SQS + EventBridge 규칙
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # 노드 역할 이름 고정 → EC2NodeClass.spec.role 에 그대로 적는다
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "KarpenterNodeRole-${local.cluster_name}"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # SSM 접속용(선택)
  }

  # 기본값: namespace = kube-system, service_account = karpenter
  create_pod_identity_association = true

  # 컨트롤러 정책이 관리형 정책 한도(6,144자)를 넘어 apply 실패 →
  # "LimitExceeded: Cannot exceed quota for PolicySize: 6144". 인라인 정책 한도는 10,240자
  enable_inline_policy = true
}

output "karpenter_queue_name" { value = module.karpenter.queue_name }
output "karpenter_node_role_name" { value = module.karpenter.node_iam_role_name }
