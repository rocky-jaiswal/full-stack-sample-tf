variable "bucket_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of the KMS key for server-side encryption"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}
