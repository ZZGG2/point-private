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
