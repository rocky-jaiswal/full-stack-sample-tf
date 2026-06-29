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

variable "repository_names" {
  type        = list(string)
  description = "One ECR repo per app image (e.g. api, web, worker)"
  default     = ["api", "web", "worker"]
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK used to encrypt images at rest"
}

variable "image_retention_count" {
  type        = number
  description = "Number of tagged images to keep per repo; older ones are pruned"
  default     = 10
}
