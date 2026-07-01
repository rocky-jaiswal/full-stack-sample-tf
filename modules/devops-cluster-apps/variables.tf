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

variable "app_cluster_server_ip" {
  type        = string
  description = "Private IP of the App cluster's K3s server"
}

variable "app_cluster_ca_data" {
  type        = string
  sensitive   = true
  description = "Base64 CA cert from the App cluster's kubeconfig (certificate-authority-data)"
}

variable "app_cluster_cert_data" {
  type        = string
  sensitive   = true
  description = "Base64 client cert from the App cluster's kubeconfig (client-certificate-data)"
}

variable "app_cluster_key_data" {
  type        = string
  sensitive   = true
  description = "Base64 client key from the App cluster's kubeconfig (client-key-data)"
}

variable "hello_fastify_repo_url" {
  type    = string
  default = "https://github.com/rocky-jaiswal/hello-fastify"
}

variable "devops_cluster_sg_id" {
  type        = string
  description = "DevOps cluster security group ID — Fluent Bit on the App cluster needs inbound to reach Loki's NodePort"
}

variable "app_cluster_sg_id" {
  type        = string
  description = "App cluster security group ID — source of the Fluent Bit -> Loki traffic"
}
