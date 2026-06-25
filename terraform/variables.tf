# terraform/variables.tf

variable "aws_region" {
  description = "AWS Deployment Region"
  type        = string
  default     = "ap-northeast-2" # 서울 리전
}

variable "instance_type" {
  description = "Free-tier usable instance type"
  type        = string
  default     = "t2.micro"       # 프리티어 기본 인스턴스
}

variable "environment" {
  description = "Deployment Environment Name"
  type        = string
  default     = "dev-cluster"
}