resource "aws_security_group" "rds" {
  name   = "${var.name}-rds"
  vpc_id = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_allowed" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = each.value # CIDR 이 아니라 SG 참조 → 노드 IP 가 바뀌어도 OK
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "point"
  username                    = "point_admin"
  manage_master_user_password = true # 비밀번호를 Terraform 이 모름 → Secrets Manager 에 자동 저장·회전

  db_subnet_group_name   = var.db_subnet_group_name # 2단계 VPC 모듈이 만든 Private-Data 서브넷 그룹
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # 운영 설계는 Multi-AZ

  backup_retention_period = 1
  skip_final_snapshot     = true # 학습용: destroy 시 스냅샷 안 남김
  deletion_protection     = false
  apply_immediately       = true
}