provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { project = "point-platform", env = "dev", managed-by = "terraform" }
  }
}