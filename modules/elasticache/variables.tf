variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }                 # Private-Data 서브넷 3개
variable "allowed_security_group_ids" { type = list(string) } # 6379 허용할 SG (EKS 노드 SG)
variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}
