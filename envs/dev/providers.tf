provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { project = "point-platform", env = "dev", managed-by = "terraform" }
  }
}
# 11단계 — ArgoCD 를 helm_release 로 설치하기 위한 provider
# exec: 토큰을 state 에 저장하지 않고 매번 aws eks get-token 으로 발급
# (helm provider 3.x 는 kubernetes = { ... } 속성 문법. 2.x 는 kubernetes { ... } 블록)
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", "ap-northeast-2"]
    }
  }
}
