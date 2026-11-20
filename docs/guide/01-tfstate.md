# 1단계. Terraform state 저장소 (S3)

## 목표
Terraform 상태 파일(`terraform.tfstate`)을 로컬이 아니라 **S3 에 보관**한다.

### 왜 원격 state 인가
- state 는 "Terraform 이 만든 실제 리소스 ID 목록". 잃어버리면 Terraform 이 자기가 만든 걸 모른다 → destroy 불가, 손으로 지워야 함.
- PC 가 바뀌거나 여러 명이 작업해도 같은 state 를 본다.
- **락**: 두 곳에서 동시에 apply 하면 state 가 깨진다. Terraform 1.10+ 는 `use_lockfile = true` 로 S3 에 `.tflock` 파일을 만들어 막는다 (예전엔 DynamoDB 테이블이 필요했음).

### 닭과 달걀 문제
state 버킷을 만드는 코드의 state 는 어디에? → **bootstrap 은 local state** 로 따로 관리한다.
그래서 `bootstrap/` 과 `envs/dev/` 는 완전히 분리된 Terraform 루트다.

## 1-1. 버킷 이름 정하기
S3 버킷 이름은 **전 세계에서 유일**해야 한다. 계정 ID 나 고유 숫자를 붙인다.
```bash
aws sts get-caller-identity --query Account --output text
```
이번 실습: `point-eks-tfstate-020208`

## 1-2. `bootstrap/main.tf`

참고 코드(`../point-infra/infra/terraform/bootstrap/aws/main.tf`)는 버킷을 오래 쓰는 전제라 `prevent_destroy = true` 다.
**하루 쓰고 지울 실습**이라 두 군데를 바꿨다:

| 항목 | 참고 코드 | 실습 | 이유 |
|---|---|---|---|
| `prevent_destroy` | `true` | 제거 | 있으면 `terraform destroy` 가 거부됨 |
| `force_destroy` | 없음 | `true` | 버전관리 버킷은 옛 버전 객체가 남아 있어 그냥은 삭제 실패 |
| 암호화 | `aws:kms` | `AES256` | S3 관리형 키, 무료·설정 없음 |

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { project = "point-platform", env = "dev", managed-by = "terraform" }
  }
}

variable "bucket_name" { type = string }

resource "aws_s3_bucket" "state" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "state" {          # 실수로 덮어써도 이전 state 복구 가능
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {  # state 에는 민감 정보가 있을 수 있음
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  value = aws_s3_bucket.state.bucket
}
```
- `default_tags` : 이 provider 로 만드는 **모든 리소스에 자동 태그**. 리소스마다 `tags` 를 쓸 필요가 없어지고 Cost Explorer 에서 `project=point-platform` 으로 비용 집계 가능.
- S3 버킷 설정이 리소스 4개로 나뉜 건 AWS provider 4 이후 방식 (예전엔 `aws_s3_bucket` 하나에 다 넣었음).

`bootstrap/terraform.tfvars` (커밋 안 됨):
```hcl
bucket_name = "point-eks-tfstate-<고유값>"
```

## 1-3. 실행
```bash
cd ~/point/point-private/bootstrap
terraform init        # provider 다운로드, .terraform.lock.hcl 생성
terraform fmt         # 코드 정렬
terraform validate    # 문법 검사
terraform plan        # Plan: 4 to add
terraform apply
```
→ `bootstrap/terraform.tfstate` 가 **로컬에** 생긴다 (`.gitignore` 로 커밋 제외). 이 파일을 지우면 버킷을 Terraform 으로 못 지운다.

## 1-4. `envs/dev/versions.tf` — backend 연결
```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }   # 처음엔 5.0 → 2단계에서 6.0 으로 올림
  }
  backend "s3" {
    bucket       = "point-eks-tfstate-020208"
    key          = "envs/dev/terraform.tfstate"   # 버킷 안 경로. 환경마다 다르게
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true                           # DynamoDB 없이 S3 락
  }
}
```
- backend 블록에는 **변수를 쓸 수 없다** (init 시점에 변수 평가 전이라). 값을 직접 적는다.

```bash
cd ../envs/dev
terraform init        # "Successfully configured the backend "s3"!"
```

## ✅ 확인
```bash
aws s3 ls | grep point-eks-tfstate
aws s3 ls s3://point-eks-tfstate-020208/envs/dev/   # 2단계 apply 후에 terraform.tfstate 가 생김
```
리소스가 하나도 없으면 state 파일도 아직 안 생긴다 — 정상.

## 🧹 정리
- 이 버킷은 **맨 마지막에** 지운다.
- `envs/dev` destroy 전에 버킷을 지우면 dev 의 state 가 사라져 VPC/EKS 를 Terraform 으로 못 지운다 → 콘솔에서 수동 삭제 지옥.
```bash
cd envs/dev && terraform destroy      # 1) 먼저
cd ../../bootstrap && terraform destroy   # 2) 나중
```
