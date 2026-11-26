# 6단계. ECR + point 이미지 올리기

## 목표
point 백엔드 2개(core-service, event-service)와 프론트(web) 이미지를 ECR 에 올리고, 클러스터 노드가 당겨올 수 있는지 확인한다.

> 🔄 **2026-11-26 변경** — 모듈 이름 `monolith` → **`core-service`** (point-backend #6), Spring Boot 4.1 (ADR-0021), Kafka 제거 (ADR-0019).
> ECR 레포 이름이 `point/core-service` 로 바뀌고, 세 이미지 모두 **`v0.2.0`** 으로 다시 빌드한다. 아래 "실제 결과"·확인 기록 중 `monolith`·`v0.1.x` 는 당시 기록.

> 이 문서는 5단계까지 진행한 뒤 **아직 실습하지 않은 상태에서** 작성한 가이드다.
> "⚠️ 확인" 표시는 진행할 때 실제 값/동작을 확인하고 이 문서를 고쳐 둘 곳.

## 사전 상태
- 1~3단계 apply 완료 (VPC, EKS). 6단계 자체는 EKS 없이도 진행 가능 (ECR 은 VPC 와 무관).
- 로컬 docker 동작 (`docker version`).

## 6-1. `modules/ecr/` 작성

**`modules/ecr/variables.tf`**
```hcl
variable "repositories" { type = set(string) }   # ["point/core-service", "point/event-service", "point/web"]
variable "keep_last" {
  type    = number
  default = 10
}
```

**`modules/ecr/main.tf`**
```hcl
resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"   # 같은 태그 덮어쓰기 금지 → "v0.1 이 뭐였지?" 사고 방지
  force_delete         = true          # 실습용: 이미지가 남아 있어도 destroy 가능

  image_scanning_configuration {
    scan_on_push = true                # 기본 스캔(무료)으로 CVE 확인
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last ${var.keep_last} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_last
      }
      action = { type = "expire" }
    }]
  })
}
```

**`modules/ecr/outputs.tf`**
```hcl
output "repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
```

| 설정 | 이유 |
|---|---|
| `for_each = set` | 레포 3개를 한 블록으로. 추가/삭제 시 다른 레포에 영향 없음 (`count` 는 인덱스가 밀려서 위험) |
| `IMMUTABLE` | 태그 = 특정 이미지 1개로 고정. 11단계 GitOps 에서 "태그 바꿈 = 배포" 가 성립하려면 필수 |
| lifecycle 10개 | 스토리지 $0.10/GB-월. 오래된 이미지 자동 삭제 |
| `force_delete` | 운영에선 빼는 게 맞다. 실습은 하루 쓰고 지우므로 |

## 6-2. `envs/dev` 연결
`envs/dev/main.tf` 에 추가:
```hcl
module "ecr" {
  source       = "../../modules/ecr"
  repositories = ["point/core-service", "point/event-service", "point/web"]
}
```
`envs/dev/outputs.tf` 에 추가:
```hcl
output "ecr_repository_urls" { value = module.ecr.repository_urls }
```
```bash
cd ~/point/point-private/envs/dev
terraform init          # 새 로컬 모듈 인식
terraform plan          # repository 3 + lifecycle_policy 3 = 6 to add
terraform apply
terraform output ecr_repository_urls
```

## 6-3. 빌드 & 푸시

### Dockerfile 구조 확인 (point-backend)
- `core-service/Dockerfile`, `event-service/Dockerfile` 은 **빌드 컨텍스트가 `point-backend` 루트**다 (`COPY . .` 후 `./gradlew :${MODULE}:bootJar`).
- `ARG MODULE` 로 어떤 모듈을 빌드할지 받는다 → `--build-arg MODULE=core-service` 필수.
- 런타임: `eclipse-temurin:21-jre`, uid 10001(non-root), `-XX:MaxRAMPercentage=75` (컨테이너 메모리 limit 의 75% 를 힙으로).
- 포트: core-service 8080, event-service 8081.

### point-frontend
- `Dockerfile` 은 `node:20-alpine` 빌드 → `nginxinc/nginx-unprivileged:1.27-alpine` 런타임, 포트 **8080**, `/healthz` 헬스체크 경로.
- `/api/**` 프록시는 없다 → 클러스터에서 Gateway(HTTPRoute)가 경로별로 나눈다 (9단계).

### 명령
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
TAG=v0.2.0            # IMMUTABLE 이므로 다시 올릴 땐 새 태그 (git short sha 도 좋음). v0.1.x = monolith·Kafka 시절

aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REG

cd ~/point/point-backend
docker build -f core-service/Dockerfile  --build-arg MODULE=core-service  -t $REG/point/core-service:$TAG .
docker build -f event-service/Dockerfile --build-arg MODULE=event-service -t $REG/point/event-service:$TAG .

cd ~/point/point-frontend
docker build -t $REG/point/web:$TAG .

docker push $REG/point/core-service:$TAG
docker push $REG/point/event-service:$TAG
docker push $REG/point/web:$TAG
```
- 첫 빌드는 Gradle 의존성 다운로드로 수 분 걸린다.
- 노드는 `t3` = **amd64**. WSL(x86_64) 빌드는 그대로 OK. Apple Silicon 이면 `--platform linux/amd64` 필요.
- `docker login` 토큰은 12시간 유효.

## 6-4. 노드의 ECR pull 권한 확인
EKS 관리형 노드그룹 역할에는 보통 ECR 읽기 정책이 기본으로 붙는다. 확인:
```bash
NODE_ROLE=$(aws eks describe-nodegroup --cluster-name point-dev-eks \
  --nodegroup-name $(aws eks list-nodegroups --cluster-name point-dev-eks --query 'nodegroups[0]' --output text) \
  --query 'nodegroup.nodeRole' --output text | awk -F/ '{print $NF}')
aws iam list-attached-role-policies --role-name $NODE_ROLE --query 'AttachedPolicies[].PolicyName'
# AmazonEC2ContainerRegistryReadOnly 또는 AmazonEC2ContainerRegistryPullOnly 가 있어야 함
```
⚠️ 확인: EKS 모듈 v21 이 어느 정책을 붙이는지 실제 출력으로 기록.

## ✅ 확인
```bash
aws ecr list-images --repository-name point/core-service
aws ecr describe-image-scan-findings --repository-name point/core-service --image-id imageTag=$TAG \
  --query 'imageScanFindings.findingSeverityCounts'

# 클러스터에서 실제로 pull 되는지 (기동 실패해도 OK — Pulled 이벤트만 보면 됨)
kubectl run pulltest --image=$REG/point/web:$TAG --restart=Never
kubectl describe pod pulltest | grep -E 'Pulled|Failed'
kubectl delete pod pulltest
```

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| `no basic auth credentials` (push) | docker login 안 됨/만료 → 다시 login |
| `tag invalid: ... already exists` | IMMUTABLE → 새 태그로 |
| 파드 `ErrImagePull ... 403` | 노드 역할에 ECR 읽기 정책 없음 |
| 파드 `exec format error` | arm64 로 빌드됨 → `--platform linux/amd64` |
| Gradle 빌드 중 메모리 부족 | Docker Desktop/WSL 메모리 할당 늘리기 |

## 📘 이해할 것
- ECR 레지스트리 주소 = `<계정>.dkr.ecr.<리전>.amazonaws.com`, 레포 = 그 아래 경로.
- 노드는 ECR API(인증) + **S3(이미지 레이어)** 를 쓴다 → 2단계 S3 Gateway 엔드포인트 덕분에 레이어 다운로드가 NAT 를 안 탄다.
- 멀티스테이지 빌드: JDK/Node 는 빌드 단계에만, 런타임 이미지는 JRE/nginx 만 → 이미지 작고 공격 면적 작음.

## 🧹 정리
- `force_delete = true` 라 `terraform destroy` 로 이미지째 삭제된다.
- 다음 날 다시 할 거면 **이미지를 다시 빌드·푸시**해야 한다 (로컬 docker 이미지가 남아 있으면 태그만 붙여 push).

💸 스토리지 ≈ $0.10/GB-월 (이미지 3개 ≈ 1GB 미만), 같은 리전 pull 은 무료.
