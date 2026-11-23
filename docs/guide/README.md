# 단계별 실습 가이드

[ROADMAP.md](../../ROADMAP.md)의 각 단계를 **실제로 진행한 방식 그대로** 정리한 문서.
ROADMAP이 "무엇을"이라면, 여기는 "어떻게 + 왜 + 어디서 막혔나"다.

| 단계 | 문서 | 핵심 결과물 |
|---|---|---|
| 0 | [00-prep.md](00-prep.md) | 도구, Git 연동, 디렉터리 구조 |
| 1 | [01-tfstate.md](01-tfstate.md) | `bootstrap/` — state용 S3 버킷, `envs/dev` backend |
| 2 | [02-vpc.md](02-vpc.md) | `modules/vpc` — 3-Tier VPC, NAT 1개, S3 엔드포인트 |
| 3 | [03-eks.md](03-eks.md) | `modules/eks` — EKS 1.37, core 노드그룹 2대 (11단계에서 3대로) |
| 4 | [04-smoke-app.md](04-smoke-app.md) | `k8s/smoke/` — nginx Deployment/Service, probe·resources 실험 |
| 5 | [05-lbc-gateway.md](05-lbc-gateway.md) | AWS LB Controller + Gateway API → 인터넷에서 ALB로 접속 |
| 6 | [06-ecr.md](06-ecr.md) | `modules/ecr` — 레포 3개, 이미지 빌드·푸시 |
| 7 | [07-data.md](07-data.md) | `modules/rds`, `modules/elasticache`, Strimzi Kafka, `app_rw` |
| 8 | [08-external-secrets.md](08-external-secrets.md) | Secrets Manager → ESO → K8s Secret (DB, JWT 키) |
| 9 | [09-point-app.md](09-point-app.md) | `k8s/apps` Kustomize, HTTPRoute 3분기, 데모 시나리오 |
| 10 | [10-karpenter-keda.md](10-karpenter-keda.md) | Spot NodePool, ScaledObject, 부하 테스트·확장 시간 측정 |
| 11 | [11-argocd.md](11-argocd.md) | Terraform 으로 ArgoCD + root, App of Apps, 수동 설치분 이전, db-init PreSync Job |
| 12 | [12-observability.md](12-observability.md) | kube-prometheus-stack (ArgoCD) + ServiceMonitor + 대시보드 ConfigMap |
| 13 | [13-tests.md](13-tests.md) | `tests/run.sh` — 0~12단계 전체 검증 스위트 (≈340개 검사, E2E·부하·selfHeal 포함) |

> **0~5단계, 7~12단계**는 실제로 진행한 결과를 반영했고, 6단계는 진행 전에 미리 쓴 가이드다.
> 그 문서들의 "⚠️ 확인" 표시는 버전·필드명 등 진행 시점에 검증해야 하는 부분 → 실습하면서 고쳐 둘 것.
>
> 특히 **9단계부터는 ROADMAP 과 다르다**: point-backend 가 `X-User-Id` 헤더 대신 JWT 인증으로 바뀌었고,
> 데모 계정·이벤트는 `local` 프로필에서만 생긴다 → [09 문서 상단](09-point-app.md#️-roadmap-과-달라진-점-point-backend-현재-코드-기준) 참고.

## 다음에 다시 시작할 때 (오늘 전부 정리한 상태에서)
1. `bootstrap/` `terraform apply` (state 버킷 — 같은 이름으로 재생성)
2. `envs/dev/` `terraform init` → `terraform apply` (VPC + EKS + LBC IAM, ≈ 20분)
3. `aws eks update-kubeconfig --name point-dev-eks --region ap-northeast-2`
4. 5단계: CRD 설치 → `values.yaml` 의 **vpcId 갱신** → Helm 설치 → (선택) `kubectl apply -f k8s/smoke/` — smoke 는 11월 23일에 지웠다, 확인용으로만
5. 내 공인 IP 가 바뀌었으면 `terraform.tfvars` 의 `my_ip_cidr` 와 `30-gateway.yaml` 의 `sourceRanges` 수정
6. (6단계 이후) ECR 은 `force_delete` 로 이미지째 삭제됨 → 이미지 다시 빌드·푸시
7. (7단계 이후) RDS·Redis 는 `envs/dev` apply 에 포함. Strimzi Helm 설치 → `kubectl apply -f k8s/platform/kafka/kafka.yaml` → `app_rw` 다시 생성 (7-6, 비밀번호 파일 `~/.config/point-dev/app_rw_password` 재사용. **public 스키마 GRANT 포함**)
8. (8단계 이후) ESO IAM 은 `envs/dev` apply 에 포함. Secrets Manager 비밀 2개 다시 생성 (8-1 — RDS 엔드포인트가 바뀌므로 JSON 새로 만들기) → ESO Helm → `cluster-secret-store.yaml`
9. (9단계 이후) `overlays/dev/kustomization.yaml` 의 `REDIS_HOST`, `gateway.yaml` 의 `sourceRanges` 확인 → `kubectl apply -f k8s/platform/gateway/gatewayclass.yaml` → `kubectl apply -k k8s/apps/overlays/dev`
10. (10단계 이후) Karpenter IAM·SQS·metrics-server 는 `envs/dev` apply 에 포함. Karpenter Helm (`k8s/platform/karpenter/values.yaml`) → `nodepool-event.yaml` → KEDA Helm. ScaledObject 의 cron 시각은 그날 관찰할 시각으로
11. (11단계 이후) **여기부터는 Helm/kubectl 수동 설치를 하지 않는다.** `envs/dev` apply 가 ArgoCD + root 까지 만들면, root 가 Git 의 `k8s/argocd/apps` 를 읽어 LBC·ESO·KEDA·Karpenter·Strimzi·모니터링·플랫폼 설정·point 앱을 전부 설치한다.
    - 그 전에 Git 에서 고칠 것: `k8s/platform/aws-lbc/values.yaml` vpcId, `overlays/dev` 의 `REDIS_HOST`·`sourceRanges`·이미지 태그, `db-init.yaml` 의 `rds!db-...` 이름 → commit + push
    - 순서상 Terraform 밖에 남는 것: Gateway API CRD (5단계, ArgoCD 전에 `kubectl apply`), Secrets Manager 비밀 2개 (8-1), `monitoring/grafana-admin` Secret (12-1)
    - 7-6 `app_rw` 는 db-init PreSync Job 이 대신한다
12. (12단계 이후) Grafana: `kubectl port-forward -n monitoring svc/kps-grafana 3000:80` → 대시보드 "point — 이벤트 확장"
13. **마지막으로 `tests/run.sh`** — 전부 PASS 면 복구 완료 ([13 문서](13-tests.md))

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
| External Secrets Operator | 2.15.0 (chart 2.15.0) | API `external-secrets.io/v1` |
| point 이미지 | `v0.1.0` (linux/amd64) | 9단계 `SPRING_PROFILES_ACTIVE=local` |
| Karpenter | 1.15.3 (OCI chart) | K8s 1.37 은 **1.15.x 만** 지원 (호환표). EKS 모듈 `//modules/karpenter` 21.30.2 |
| metrics-server | EKS 애드온 v0.9.1 | `modules/eks` `addons` |
| KEDA | 2.21.1 (chart 2.21.1) | |
| k6 | v2.4.0 (docker `grafana/k6`) | |
| helm provider (Terraform) | 3.3.0 (`~> 3.0`) | `kubernetes = { ... }` 속성 문법 |
| ArgoCD | v3.6.2 (chart `argo-cd` 10.18.2), `argocd-apps` 2.0.8 | CLI v3.6.2 (`~/.local/bin`) |
| kube-prometheus-stack | 93.9.0 (operator v0.95.2, Prometheus v3.16.0, Grafana 13.3.1) | ArgoCD Application |

## 공통 규칙
- 리전 `ap-northeast-2` 고정, 모든 리소스 태그 `project=point-platform, env=dev, managed-by=terraform` (provider `default_tags`)
- `*.tfstate`, `*.tfvars`, `kubeconfig*` 는 커밋하지 않는다 (`.gitignore`)
- 새 `module` 블록을 추가하면 **`envs/dev` 에서 `terraform init`** (모듈 폴더 안에서 init 하지 않기)
- 쿠버네티스 `command`/`args`/`env` 값의 `$$` 는 `$` 로 바뀐다 → SQL 달러 인용은 `$do$` 사용
- 비밀값은 Git·state 에 두지 않는다 → Secrets Manager (CLI 로 생성) → ESO → K8s Secret
- Karpenter 가 만든 EC2 는 **Terraform state 에 없다** → destroy 전에 NodePool 부터 지운다 (10 문서 정리)
- 11단계 이후 클러스터 안의 변경은 **Git commit + push** 로만 (손으로 바꾸면 selfHeal 이 되돌린다). 정리할 땐 root → Application → 리소스 순서 ([11 문서 정리](11-argocd.md#-정리))
- Spring 설정을 환경변수로 덮을 땐 relaxed binding: `.`→`_`, **하이픈은 제거**, 대문자 (`app.admin.api-token` → `APP_ADMIN_APITOKEN`)
- 하루 실습이 끝나면 **역순 정리** → [05 문서의 정리 순서](05-lbc-gateway.md#정리-순서-중요) + ROADMAP 맨 아래
