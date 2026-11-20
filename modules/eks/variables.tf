variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "public_access_cidrs" { type = list(string) }
variable "core_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}