variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-north-1"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "d4c2"
}

variable "aws_tags" {
  description = "Default tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}

variable "instance_type" {
  description = "EC2 instance type for K8s nodes"
  type        = string
  default     = "t3.medium"
}
