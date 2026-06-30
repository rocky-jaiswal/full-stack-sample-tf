variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig for the DevOps cluster. Run scripts/get-kubeconfig.sh first."
}

variable "woodpecker_github_client_id" {
  type      = string
  sensitive = true
}

variable "woodpecker_github_client_secret" {
  type      = string
  sensitive = true
}

variable "woodpecker_agent_secret" {
  type      = string
  sensitive = true
}
