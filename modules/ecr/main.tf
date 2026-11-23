resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # 같은 태그 덮어쓰기 금지 → "v0.1 이 뭐였지?" 사고 방지
  force_delete         = true        # 실습용: 이미지가 남아 있어도 destroy 가능

  image_scanning_configuration {
    scan_on_push = true # 기본 스캔(무료)으로 CVE 확인
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