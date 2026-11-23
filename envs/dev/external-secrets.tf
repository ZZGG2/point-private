# 8단계 — External Secrets Operator 가 Secrets Manager 를 읽기 위한 IAM (Pod Identity)
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "eso" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    # point-dev/* 만 → RDS 마스터 비밀(rds!db-...)은 못 읽는다 (최소 권한)
    resources = [
      "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:point-dev/*"
    ]
  }
  # 11단계 db-init Job (ADR-0013): RDS 마스터 비밀 "하나만" 추가. rds!db-* 와일드카드는 쓰지 않는다
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.rds.master_secret_arn]
  }
}

resource "aws_iam_policy" "eso" {
  name   = "${local.name}-external-secrets"
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_iam_role" "eso" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json # aws-lbc.tf 재사용
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}
