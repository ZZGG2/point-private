resource "aws_security_group" "redis" {
  name   = "${var.name}-redis"
  vpc_id = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_allowed" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-redis"
  subnet_ids = var.subnet_ids # Private-Data 3개
}

# point-infra data-architecture: Valkey 7.2, Primary + Replica, Multi-AZ + 자동 장애 조치 필수 (Cluster mode 비활성)
# 원장 반영 Redis Stream(ADR-0019)이 여기에 있으므로 노드 1개로 두면 노드 장애 = 미반영 당첨 유실
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-redis"
  description          = "point event keys + reward streams (ADR-0007, ADR-0019)"
  engine               = "valkey"
  engine_version       = "7.2" # ⚠️ 확인: aws elasticache describe-cache-engine-versions --engine valkey
  parameter_group_name = "default.valkey7"
  node_type            = var.node_type
  port                 = 6379

  num_cache_clusters         = 2 # primary 1 + replica 1 (서로 다른 AZ)
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # 앱(spring.data.redis)이 TLS 없이 붙는다 — 운영은 TLS 검토
  snapshot_retention_limit   = 0     # 학습용. Stream 은 7일 보존이지만 스냅샷 백업은 생략
  apply_immediately          = true
}
