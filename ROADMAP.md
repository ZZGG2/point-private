# point-eks — EKS 단계별 구축 로드맵

`point-infra`에 정리된 설계(ADR, 네트워크 설계, Terraform 스캐폴딩)를 **실제로 AWS에 올려 보며 검증**하는 실습 레포.
한 번에 다 만들지 않고, **각 단계마다 "만들기 → 확인 → (필요하면) 부수기"** 를 반복한다.

> 기준 설계 문서 (먼저 훑어볼 것)
> - 네트워크: `../point-infra/docs/01-architecture/network-design.md`
> - EKS + Karpenter: `../point-infra/docs/02-adr/0002-eks-karpenter-over-lambda-asg.md`
> - Gateway API: `../point-infra/docs/02-adr/0014-gateway-api.md`
> - RDS: `../point-infra/docs/02-adr/0013-rds-postgresql.md`
> - Terraform/GitOps 분리: `../point-infra/docs/02-adr/0009-terraform-gitops-split.md`
> - 비용: `../point-infra/docs/05-operations/finops.md`
> - 참고 코드: `../point-infra/infra/terraform/` (vpc, eks 모듈은 초안 있음)

---

## 전체 흐름 한눈에 보기

| 단계 | 내용 | 결과물 | 시간당 비용(대략) |
|---|---|---|---|
| 0 | 준비 (도구, IAM, 예산 알림, 레포) | 로컬 환경 | 0 |
| 1 | Terraform state 저장소 (S3) | `bootstrap/` | ≈ 0 |
| 2 | VPC 네트워크 | `envs/dev` + `modules/vpc` | NAT 1개 ≈ $0.06 |
| 3 | EKS 클러스터 + 기본 노드그룹 | `modules/eks` | + EKS $0.10 + 노드 2대 |
| 4 | 테스트 앱 배포 (kubectl) | `k8s/smoke/` | 동일 |
| 5 | AWS Load Balancer Controller + Gateway API | 외부에서 접속 | + ALB ≈ $0.03 |
| 6 | ECR + 실제 point 이미지 올리기 | `modules/ecr` | ≈ 0 |
| 7 | 데이터 계층 (RDS, Redis, Kafka) | `modules/rds` 등 | + DB/캐시 |
| 8 | Secret 관리 (External Secrets) | Secrets Manager 연동 | ≈ 0 |
| 9 | point 앱 배포 (monolith, event-service, web) | 전체 흐름 동작 | 동일 |
| 10 | Karpenter + KEDA (자동 확장) | 이벤트 피크 대응 | Spot 사용분 |
| 11 | ArgoCD (GitOps) | Git push = 배포 | 동일 |
| 12 | 관측성 (로그, 메트릭) | 대시보드 | 소량 |

> 💸 **가장 중요한 규칙:** 2단계부터는 켜 두는 동안 계속 돈이 나간다. **실습이 끝나면 `terraform destroy`** 를 습관으로 한다.
> 단계 3까지 켜 두면 대략 하루 $6~8 수준 (EKS $2.4 + NAT $1.4 + 노드 2대 + 기타). 정확한 단가는 AWS 가격 계산기로 확인.

---

## 0단계. 준비

### 0-1. 도구 설치 확인
| 도구 | 용도 | 현재 상태 (WSL) |
|---|---|---|
| aws CLI v2 | AWS 인증·조회 | ✅ 설치됨 (`~/.local/bin/aws`) |
| terraform **≥ 1.10** | 인프라 코드 | ✅ 1.17.2 (`~/.local/bin/terraform`) — S3 네이티브 락 `use_lockfile` 사용 가능 |
| kubectl | 클러스터 조작 | ✅ snap 설치됨 (1.35) |
| helm | 컨트롤러 설치 | ✅ v4.3.2 (`~/.local/bin/helm`) — 일부 문서는 helm 3 기준이지만 명령은 대부분 동일 |
| docker | 이미지 빌드 | ✅ |

확인 명령:
```bash
aws --version && terraform version && kubectl version --client && helm version
```

### 0-2. AWS 계정/권한
- 현재 `default` 프로필 = IAM 사용자 `kdt6`. EKS·VPC·IAM 역할 생성 권한이 있는지 먼저 확인한다.
  ```bash
  aws sts get-caller-identity
  aws iam list-attached-user-policies --user-name kdt6
  ```
- 실습 전용 프로필을 따로 쓰는 것을 권장: `aws configure --profile point` → `export AWS_PROFILE=point`
- 리전은 `ap-northeast-2` (서울) 고정.

### 0-3. 비용 안전장치 (먼저 할 것!)
- AWS Budgets에서 **월 예산 알림** 생성 (예: $30, 50%/80%/100% 이메일 알림)
- 모든 리소스에 태그: `project=point-platform`, `env=dev`, `managed-by=terraform`

### 0-4. (선택) Git으로 관리할 경우
지금은 git 없이 진행한다. 나중에 GitHub에 올리거나 11단계(ArgoCD — Git 저장소 필요)에 들어갈 때 `git init` 하면 된다.
그때 `.gitignore` 에 반드시 포함 (state·tfvars에 계정 정보·비밀값이 들어갈 수 있음):
```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars        # 예시 파일(*.tfvars.example)만 커밋
.terraform.lock.hcl 은 커밋한다 (provider 버전 고정)
kubeconfig*
```

### 권장 디렉터리 구조
```
point-eks/
├── ROADMAP.md               ← 이 문서
├── bootstrap/               ← 1단계: state 저장용 S3 (1회)
├── modules/
│   ├── vpc/                 ← 2단계
│   ├── eks/                 ← 3단계
│   ├── ecr/                 ← 6단계
│   ├── rds/ elasticache/    ← 7단계
│   └── karpenter/           ← 10단계
├── envs/
│   └── dev/                 ← 실제 apply 하는 곳 (모듈 조립)
├── k8s/
│   ├── smoke/               ← 4단계 테스트 앱
│   ├── platform/            ← LB Controller, External Secrets, Karpenter, KEDA
│   └── apps/                ← point 앱 매니페스트 (9단계)
└── docs/
    └── log/                 ← 단계별 실습 기록 (에러·해결 방법)
```

✅ **완료 기준:** 위 도구 명령이 모두 동작, 예산 알림 설정됨.

---

## 1단계. Terraform state 저장소

**목표:** Terraform 상태 파일을 로컬이 아니라 S3에 안전하게 보관한다.

할 일:
1. `bootstrap/main.tf` — S3 버킷 (버전관리 ON, 암호화, 퍼블릭 차단, `prevent_destroy`)
   - 참고: `../point-infra/infra/terraform/bootstrap/aws/main.tf`
   - 버킷 이름 예: `point-eks-tfstate-<계정ID>` (전 세계에서 유일해야 함)
2. bootstrap 자체는 local state로 `terraform init && terraform apply`
3. `envs/dev/versions.tf` 에 backend 설정:
   ```hcl
   backend "s3" {
     bucket       = "point-eks-tfstate-<계정ID>"
     key          = "envs/dev/terraform.tfstate"
     region       = "ap-northeast-2"
     encrypt      = true
     use_lockfile = true   # DynamoDB 없이 S3 락 (terraform >= 1.10)
   }
   ```

✅ **확인:** `aws s3 ls` 에 버킷이 보이고, `envs/dev` 에서 `terraform init` 이 S3 backend로 성공.
🧹 **정리:** 이 버킷은 **부수지 않는다** (전 단계 공용).

---

## 2단계. VPC 네트워크

**목표:** EKS가 올라갈 네트워크를 설계대로 만든다.

설계값 (`network-design.md` 기준, 바꾸지 않기):
| 계층 | 2a | 2b | 2c | 용도 |
|---|---|---|---|---|
| VPC | `10.10.0.0/16` | | | |
| Public | 10.10.0.0/24 | 10.10.1.0/24 | 10.10.2.0/24 | ALB, NAT |
| Private-App | 10.10.32.0/19 | 10.10.64.0/19 | 10.10.96.0/19 | EKS 노드/파드 |
| Private-Data | 10.10.128.0/24 | 10.10.129.0/24 | 10.10.130.0/24 | RDS, Redis, Kafka |

할 일:
1. `terraform-aws-modules/vpc/aws` 모듈 사용 (직접 다 짜는 것보다 실수 적음)
2. **NAT Gateway는 1개만** (`single_nat_gateway = true`) — 학습 비용 절감
3. 서브넷 태그 (이게 없으면 5단계에서 ALB가 안 만들어진다):
   - Public: `kubernetes.io/role/elb = 1`
   - Private-App: `kubernetes.io/role/internal-elb = 1`, `karpenter.sh/discovery = <클러스터명>`
4. (선택) VPC Endpoint: S3 Gateway 엔드포인트는 무료라 바로 추가

✅ **확인:**
```bash
terraform plan    # 생성될 리소스 목록을 읽어보며 이해하기
terraform apply
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> --query 'Subnets[].[CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table
```
🧹 **정리:** 오늘 3단계까지 안 갈 거면 `terraform destroy` (NAT가 시간당 과금).

---

## 3단계. EKS 클러스터 + 기본 노드그룹

**목표:** 클러스터를 만들고 `kubectl get nodes` 까지 성공한다.

할 일 (참고: `../point-infra/infra/terraform/modules/aws/eks/main.tf`):
1. `terraform-aws-modules/eks/aws` 모듈 사용
2. 핵심 설정:
   | 항목 | 값 | 이유 |
   |---|---|---|
   | 클러스터 이름 | `point-dev-eks` | |
   | 버전 | EKS 지원 최신 버전 | |
   | 서브넷 | Private-App 3개 | 노드는 private에 |
   | 엔드포인트 | public 허용 + **내 IP만** (`cluster_endpoint_public_access_cidrs`) | 학습 편의 + 최소 보안 |
   | 접근 권한 | `enable_cluster_creator_admin_permissions = true` (Access Entry 방식) | aws-auth ConfigMap 안 씀 |
   | 애드온 | vpc-cni(Prefix Delegation ON), coredns, kube-proxy, eks-pod-identity-agent | `before_compute = true` 로 노드보다 먼저 |
   | 노드그룹 `core` | On-Demand, `t3.medium` 2대 (min 2 / max 3) | monolith 등 상시 워크로드 |
3. apply는 **15~20분** 걸린다.

✅ **확인:**
```bash
aws eks update-kubeconfig --name point-dev-eks --region ap-northeast-2
kubectl get nodes -o wide          # 노드 2대 Ready
kubectl get pods -A                # coredns, aws-node, kube-proxy Running
```
📘 **이 단계에서 이해할 것:** 컨트롤 플레인 vs 데이터 플레인, Access Entry, VPC CNI가 파드에 VPC IP를 주는 방식, Prefix Delegation.
🧹 **정리:** 하루 실습이 끝나면 `terraform destroy`.

---

## 4단계. 테스트 앱 배포 (kubectl로 손으로)

**목표:** 쿠버네티스 기본 리소스를 직접 만들어 보며 감을 잡는다.

할 일 (`k8s/smoke/`):
1. `Namespace` → `Deployment`(nginx, replicas 2) → `Service`(ClusterIP)
2. `kubectl port-forward svc/nginx 8080:80` 로 로컬에서 접속
3. 일부러 망가뜨려 보기: 파드 삭제 → 자동 재생성 확인, 이미지 태그 오타 → `ImagePullBackOff` 확인
4. `resources.requests/limits`, `readinessProbe`, `livenessProbe` 넣어 보기

✅ **확인:** `curl localhost:8080` 응답, `kubectl describe pod` / `kubectl logs` 로 상태 읽기 가능.

---

## 5단계. AWS Load Balancer Controller + Gateway API

**목표:** 인터넷에서 ALB를 통해 클러스터 서비스에 접속한다. (ADR-0014: Ingress 대신 Gateway API)

할 일:
1. **Pod Identity** 로 LB Controller용 IAM 역할 부여 (Terraform: `aws_eks_pod_identity_association`)
2. Gateway API 표준 CRD 설치
3. Helm으로 `aws-load-balancer-controller` 설치 (Gateway API 기능 활성화 옵션 확인)
4. `GatewayClass`(ALB) → `Gateway`(리스너 80) → `HTTPRoute`(`/` → nginx)
5. 보안그룹: ALB 인바운드는 내 IP만 허용 (`alb_ingress_cidrs` 개념)

✅ **확인:** `kubectl get gateway` 에 ALB 주소가 나오고 `curl http://<alb-주소>` 응답.
⚠️ **주의:** ALB는 Terraform이 아니라 컨트롤러가 만든다 → **destroy 전에 Gateway/HTTPRoute를 먼저 지워야** ALB가 삭제된다. 순서를 지키지 않으면 VPC destroy가 멈춘다.

---

## 6단계. ECR + point 이미지 올리기

**목표:** 실제 point 백엔드/프론트 이미지를 AWS에 올린다.

할 일:
1. ECR 레포 3개: `point/monolith`, `point/event-service`, `point/web` (Terraform, 수명주기 정책: 최근 10개만 유지)
2. 빌드 & 푸시:
   ```bash
   aws ecr get-login-password | docker login --username AWS --password-stdin <계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com
   docker build -t <ecr>/point/monolith:v0.1 ../point-backend -f ../point-backend/monolith/Dockerfile
   docker push <ecr>/point/monolith:v0.1
   ```
   (Dockerfile 위치·빌드 컨텍스트는 `point-backend` 기준으로 확인)
3. 노드가 ECR을 당겨올 권한 확인 (노드 역할에 `AmazonEC2ContainerRegistryReadOnly`)

✅ **확인:** `aws ecr list-images --repository-name point/monolith` 에 태그 존재.

---

## 7단계. 데이터 계층

**목표:** 로컬 docker-compose(Postgres 16 / Redis 7 / Kafka 3.8)를 AWS 관리형으로 바꾼다.

| 로컬 | AWS | 학습용 최소 사양 | 비고 |
|---|---|---|---|
| postgres:16 | **RDS for PostgreSQL 16** (ADR-0013) | `db.t4g.micro`, 단일 AZ | 운영 설계는 Multi-AZ |
| redis:7 | ElastiCache Redis | `cache.t4g.micro` 1노드 | |
| kafka 3.8 | MSK **또는** 클러스터 내 Strimzi | — | MSK는 비싸다 → 학습은 Strimzi(파드) 권장 |

할 일:
1. Private-Data 서브넷에 배치, 보안그룹은 **EKS 노드 SG에서만** 5432/6379 허용
2. RDS 마스터 비밀번호는 `manage_master_user_password = true` (Secrets Manager 자동 저장)
3. 앱 계정 `app_rw` 생성 Job (ADR-0013 `db-init` 개념)

✅ **확인:** 클러스터 안 임시 파드에서 접속
```bash
kubectl run -it --rm pg --image=postgres:16 -- psql -h <rds-endpoint> -U <user> -d point
kubectl run -it --rm rc --image=redis:7-alpine -- redis-cli -h <redis-endpoint> ping
```
🧹 **정리:** RDS는 destroy 시 `skip_final_snapshot = true` (학습용) 확인.

---

## 8단계. Secret 관리 (External Secrets)

**목표:** DB 비밀번호 등을 매니페스트에 쓰지 않고 Secrets Manager에서 주입한다.

할 일:
1. External Secrets Operator 설치 (Helm) + Pod Identity로 Secrets Manager 읽기 권한
2. `ClusterSecretStore`(AWS Secrets Manager) → `ExternalSecret` → 쿠버네티스 `Secret` 자동 생성
3. 참고: `../point-infra/k8s/platform/external-secrets/README.md`

✅ **확인:** `kubectl get secret <이름> -o yaml` 에 값이 들어와 있음 (Git에는 값이 없음).

---

## 9단계. point 앱 배포

**목표:** LOCAL-DEV.md의 데모 시나리오를 EKS에서 그대로 재현한다.

할 일:
1. `../point-infra/k8s/base/{monolith,event-service}` 를 참고해 `k8s/apps/` 작성 (Kustomize: base + overlays/dev)
2. 환경변수: DB/Redis/Kafka 엔드포인트, Secret 참조
3. `HTTPRoute` 규칙: `/api/events` → event-service, `/api` → monolith, `/` → web
4. monolith 기동 시 Flyway 마이그레이션 성공 확인

✅ **확인 (LOCAL-DEV.md 4절 시나리오):**
```bash
curl -H "X-User-Id: 1" http://<alb>/api/points/balance          # 1000P
curl http://<alb>/api/events/evt-local/status
```
브라우저에서 퀴즈 당첨 → 1~2초 뒤 잔액 1,500P (Kafka 비동기 반영)

---

## 10단계. Karpenter + KEDA (자동 확장)

**목표:** ADR-0002의 핵심 — 이벤트 피크 때 노드/파드가 빠르게 늘고, 끝나면 줄어드는 것을 눈으로 본다.

할 일:
1. Karpenter: IAM(노드 역할, 컨트롤러 Pod Identity), SQS 중단 알림 큐, Helm 설치
2. `EC2NodeClass` + `NodePool`(event 전용, **Spot 우선**, 여러 인스턴스 타입, consolidation ON)
   - 참고: `../point-infra/k8s/platform/karpenter/nodepool-event.yaml`
3. event-service에 nodeSelector/toleration → Karpenter 노드에만 뜨게
4. KEDA 설치 → `ScaledObject`(Cron: 이벤트 5분 전 확장 + CPU 기반)
   - 참고: `../point-infra/k8s/base/event-service/scaledobject.yaml`
5. 부하 테스트: `../point-infra/load-test/k6/s2-event-spike.js`

✅ **확인:** 부하 중 `kubectl get nodes -w` 로 노드 추가 → 부하 종료 후 몇 분 내 회수.
📏 **기록할 것:** "부하 시작 → 새 노드 Ready → 목표 처리량 도달" 까지 걸린 시간 (ADR-0002 후속 과제).

---

## 11단계. ArgoCD (GitOps)

**목표:** `kubectl apply` 를 그만하고, Git에 push하면 클러스터가 따라오게 한다. (ADR-0009: Terraform은 클러스터+ArgoCD까지, 나머지는 ArgoCD)

할 일:
1. Terraform `helm_release` 로 ArgoCD 설치 + root Application 1개
2. App-of-Apps: platform(LB Controller, ESO, Karpenter, KEDA) / apps(point)
3. 지금까지 수동 설치한 것들을 하나씩 ArgoCD 관리로 이전

✅ **확인:** 이미지 태그를 Git에서 바꾸고 push → ArgoCD가 자동 Sync → 새 파드.

---

## 12단계. 관측성

할 일 (택1로 시작):
- 간단: CloudWatch Container Insights (애드온 하나로 끝)
- 심화: kube-prometheus-stack (Prometheus + Grafana) + Loki
- 참고: `../point-infra/docs/05-operations/observability.md`

✅ **확인:** 부하 테스트 중 파드 수 / CPU / 응답시간 그래프 확인.

---

## 매 실습 종료 시 정리 순서 (중요)

컨트롤러가 만든 AWS 리소스(ALB, Karpenter 노드)는 Terraform이 모른다. **역순으로** 지운다.

```bash
# 1. 컨트롤러가 만든 리소스 먼저 제거
kubectl delete httproute,gateway --all -A          # → ALB 삭제됨
kubectl delete nodepool --all                       # → Karpenter 노드 회수
# 2. 1~2분 대기 후 ALB/EC2 남았는지 확인
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId'
# 3. 인프라 삭제
cd envs/dev && terraform destroy
```
마지막으로 콘솔에서 **NAT Gateway, Elastic IP, EBS 볼륨, 로드밸런서** 가 남지 않았는지 확인.

---

## 단계별 기록 템플릿 (`docs/log/NN-단계명.md`)

```markdown
# 3단계 EKS 클러스터 — 2026-11-DD
- 한 것:
- 확인 결과 (명령어 + 출력 요약):
- 막힌 것 / 원인 / 해결:
- 비용 (Cost Explorer, 태그 project=point-platform):
- point-infra 설계와 다르게 한 점 & 이유:
```
→ 나중에 `point-infra` 문서(ADR, finops 실측값)를 갱신할 근거가 된다.
