locals {
  name         = "point-dev"
  cluster_name = "point-dev-eks"
}

module "vpc" {
  source = "../../modules/vpc"

  name         = local.name
  cluster_name = local.cluster_name
  cidr         = "10.10.0.0/16"
  azs          = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]

  public_subnets = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
  app_subnets    = ["10.10.32.0/19", "10.10.64.0/19", "10.10.96.0/19"]
  data_subnets   = ["10.10.128.0/24", "10.10.129.0/24", "10.10.130.0/24"]
}

module "eks" {
  source = "../../modules/eks"

  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.app_subnet_ids
  public_access_cidrs = [var.my_ip_cidr]
}

module "ecr" {
  source       = "../../modules/ecr"
  repositories = ["point/monolith", "point/event-service", "point/web"]
}

module "rds" {
  source                     = "../../modules/rds"
  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  db_subnet_group_name       = module.vpc.database_subnet_group
  allowed_security_group_ids = [module.eks.node_security_group_id]
  engine_version             = "16.15"
}

module "redis" {
  source                     = "../../modules/elasticache"
  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.data_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
}