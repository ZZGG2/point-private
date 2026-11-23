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
| 6 | [06-ecr.md](06-ecr.md) | `modules/ecr` — 레포 3개, 이미지 빌드·푸시 |
| 7 | [07-data.md](07-data.md) | `modules/rds`, `modules/elasticache`, Strimzi Kafka, `app_rw` |
| 8 | [08-external-secrets.md](08-external-secrets.md) | Secrets Manager → ESO → K8s Secret (DB, JWT 키) |
| 9 | [09-point-app.md](09-point-app.md) | `k8s/apps` Kustomize, HTTPRoute 3분기, 데모 시나리오 |
| 10 | [10-karpenter-keda.md](10-karpenter-keda.md) | Spot NodePool, ScaledObject, 부하 테스트·확장 시간 측정 |
| 11 | [11-argocd.md](11-argocd.md) | Terraform 으로 ArgoCD + root, App of Apps, 수동 설치분 이전 |
| 12 | [12-observability.md](12-observability.md) | kube-prometheus-stack + ServiceMonitor (또는 Container Insights) |

> **0~5단계, 7단계**는 실제로 진행한 결과를 반영했고, 나머지(6, 8~12)는 진행 전에 미리 쓴 가이드다.
> 그 문서들의 "⚠️ 확인" 표시는 버전·필드명 등 진행 시점에 검증해야 하는 부분 → 실습하면서 고쳐 둘 것.
>
> 특히 **9단계부터는 ROADMAP 과 다르다**: point-backend 가 `X-User-Id` 헤더 대신 JWT 인증으로 바뀌었고,
> 데모 계정·이벤트는 `local` 프로필에서만 생긴다 → [09 문서 상단](09-point-app.md#️-roadmap-과-달라진-점-point-backend-현재-코드-기준) 참고.

## 다음에 다시 시작할 때 (오늘 전부 정리한 상태에서)
1. `bootstrap/` `terraform apply` (state 버킷 — 같은 이름으로 재생성)
2. `envs/dev/` `terraform init` → `terraform apply` (VPC + EKS + LBC IAM, ≈ 20분)
3. `aws eks update-kubeconfig --name point-dev-eks --region ap-northeast-2`
4. 5단계: CRD 설치 → `values.yaml` 의 **vpcId 갱신** → Helm 설치 → `kubectl apply -f k8s/smoke/`
5. 내 공인 IP 가 바뀌었으면 `terraform.tfvars` 의 `my_ip_cidr` 와 `30-gateway.yaml` 의 `sourceRanges` 수정
6. (6단계 이후) ECR 은 `force_delete` 로 이미지째 삭제됨 → 이미지 다시 빌드·푸시
7. (7단계 이후) RDS·Redis 는 `envs/dev` apply 에 포함. Strimzi Helm 설치 → `kubectl apply -f k8s/platform/kafka/kafka.yaml` → `app_rw` 다시 생성 (7-6, 비밀번호 파일 `~/.config/point-dev/app_rw_password` 재사용)

## 이 실습에서 고정한 버전 (2026-11-20 ~ 11-23 기준)

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
| jq | 1.7.1 (`~/.local/bin`) | WSL 기본 미설치 (07 문서 참고) |
| RDS PostgreSQL | 16.15 (`db.t4g.micro`) | SSL 강제 (`sslmode=require`) |
| ElastiCache Redis | 7.1.0 (`cache.t4g.micro`) | |
| Strimzi | 1.3.1 → Kafka 4.3.2 (KRaft) | CRD 는 **`kafka.strimzi.io/v1`** 만 제공 (`v1beta2` 아님) |

## 공통 규칙
- 리전 `ap-northeast-2` 고정, 모든 리소스 태그 `project=point-platform, env=dev, managed-by=terraform` (provider `default_tags`)
- `*.tfstate`, `*.tfvars`, `kubeconfig*` 는 커밋하지 않는다 (`.gitignore`)
- 새 `module` 블록을 추가하면 **`envs/dev` 에서 `terraform init`** (모듈 폴더 안에서 init 하지 않기)
- 쿠버네티스 `command`/`args`/`env` 값의 `$$` 는 `$` 로 바뀐다 → SQL 달러 인용은 `$do$` 사용
- 하루 실습이 끝나면 **역순 정리** → [05 문서의 정리 순서](05-lbc-gateway.md#정리-순서-중요) + ROADMAP 맨 아래
