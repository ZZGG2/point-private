output "vpc_id" { value = module.vpc.vpc_id }
output "app_subnet_ids" { value = module.vpc.app_subnet_ids }
output "cluster_name" { value = module.eks.cluster_name }
output "ecr_repository_urls" { value = module.ecr.repository_urls }
output "rds_endpoint" { value = module.rds.endpoint }
output "rds_master_secret_arn" { value = module.rds.master_secret_arn }
output "redis_endpoint" { value = module.redis.endpoint }
output "node_security_group_id" { value = module.eks.node_security_group_id }
