output "vpc_id" { value = module.vpc.vpc_id }
output "app_subnet_ids" { value = module.vpc.app_subnet_ids }
output "cluster_name" { value = module.eks.cluster_name }
output "ecr_repository_urls" { value = module.ecr.repository_urls }