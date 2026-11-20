# 단계별 실습 가이드

[ROADMAP.md](../../ROADMAP.md)의 각 단계를 **실제로 진행한 방식 그대로** 정리한 문서.
ROADMAP이 "무엇을"이라면, 여기는 "어떻게 + 왜 + 어디서 막혔나"다.

| 단계 | 문서 | 핵심 결과물 |
|---|---|---|
| 0 | [00-prep.md](00-prep.md) | 도구, Git 연동, 디렉터리 구조 |
| 1 | [01-tfstate.md](01-tfstate.md) | `bootstrap/` — state용 S3 버킷, `envs/dev` backend |
| 2 | [02-vpc.md](02-vpc.md) | `modules/vpc` — 3-Tier VPC, NAT 1개, S3 엔드포인트 |
| 3 | [03-eks.md](03-eks.md) | `modules/eks` — EKS 1.37, core 노드그룹 2대 |
| 4 | [04-smoke-app.md](04-smoke-app.md) | `k8s/smoke/` — nginx Deployment/Service, probe·resources 실험 |
| 5 | [05-lbc-gateway.md](05-lbc-gateway.md) | AWS LB Controller + Gateway API → 인터넷에서 ALB로 접속 |

## 이 실습에서 고정한 버전 (2026-11-20 기준)

| 항목 | 버전 | 비고 |
|---|---|---|
| Terraform | 1.17.2 | `>= 1.10` 이어야 S3 네이티브 락(`use_lockfile`) 가능 |
| AWS provider | 6.x (`envs/dev`), 5.x (`bootstrap`) | EKS 모듈 v21 이 provider 6 이상 요구 |
| terraform-aws-modules/vpc | 6.8.0 (`~> 6.0`) | |
| terraform-aws-modules/eks | `~> 21.0` | v20 과 입력 이름이 다름 (03 문서 참고) |
| EKS (Kubernetes) | 1.37 | |
| kubectl | 1.37.2 (`~/.local/bin`) | snap 에는 1.37 채널이 없음 (00 문서 참고) |
| helm | v4.3.2 | |
| AWS Load Balancer Controller | v3.6.3 (chart 3.6.3) | |
| Gateway API CRD | v1.6.0 standard | |

## 공통 규칙
- 리전 `ap-northeast-2` 고정, 모든 리소스 태그 `project=point-platform, env=dev, managed-by=terraform` (provider `default_tags`)
- `*.tfstate`, `*.tfvars`, `kubeconfig*` 는 커밋하지 않는다 (`.gitignore`)
- 하루 실습이 끝나면 **역순 정리** → [05 문서의 정리 순서](05-lbc-gateway.md#정리-순서-중요) + ROADMAP 맨 아래
