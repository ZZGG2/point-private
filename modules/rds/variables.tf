variable "name" { type = string }
variable "vpc_id" { type = string }
variable "db_subnet_group_name" { type = string }
variable "allowed_security_group_ids" { type = list(string) }
variable "engine_version" { type = string } # 예: "16.x"
variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}