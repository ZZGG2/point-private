# 앱은 항상 primary 엔드포인트로 붙는다 (장애 조치 시 DNS 가 새 primary 로 바뀐다)
output "endpoint" { value = aws_elasticache_replication_group.this.primary_endpoint_address }
