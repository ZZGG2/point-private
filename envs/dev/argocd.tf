# 11단계 — ADR-0009: Terraform 은 "ArgoCD 자체 + root Application 1개" 까지만.
# 클러스터 안의 나머지(LBC, ESO, KEDA, Karpenter, Strimzi, 모니터링, point 앱)는 Git(k8s/argocd/apps)이 정의한다.
locals {
  gitops_repo   = "https://github.com/ZZGG2/point-private.git"
  gitops_branch = "master"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.2" # ArgoCD v3.6.2
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    configs = {
      params = { "server.insecure" = true } # 실습: port-forward 로 HTTP 접속
      # Karpenter 차트는 OCI 레지스트리(public.ecr.aws)에 있다 → helm 타입 + enableOCI 로 등록 (공개라 자격증명 없음)
      repositories = {
        karpenter = {
          name      = "karpenter"
          type      = "helm"
          url       = "public.ecr.aws/karpenter"
          enableOCI = "true"
        }
      }
    }
    dex           = { enabled = false } # SSO 안 씀 (admin 계정)
    notifications = { enabled = false }
  })]
}

resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.8"
  namespace  = "argocd"
  depends_on = [helm_release.argocd] # Application CRD 가 먼저 있어야 함

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = local.gitops_repo
          targetRevision = local.gitops_branch
          path           = "k8s/argocd/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
}
