variable "repositories" {
  type = set(string)
}
variable "keep_last" {
  type    = number
  default = 10
}