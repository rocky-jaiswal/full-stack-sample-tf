variable "environment" {
  type = string
}

variable "project_name" {
  type    = string
  default = "app-eks"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Two private subnet IDs (one per AZ) for server and agent nodes"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for EBS volume encryption"
}

variable "artifacts_bucket_arn" {
  type        = string
  description = "ARN of the S3 artifacts bucket Woodpecker CI reads/writes"
}

variable "instance_type" {
  type    = string
  default = "t4g.medium"
}
