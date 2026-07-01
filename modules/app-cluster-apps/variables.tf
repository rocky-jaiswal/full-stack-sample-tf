variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig for the App cluster. Run scripts/get-kubeconfig-app.sh first."
}

variable "loki_host" {
  type        = string
  description = "Private IP of the DevOps cluster's K3s server, where Loki's NodePort is reachable"
}

variable "loki_port" {
  type        = number
  description = "NodePort Loki is exposed on (devops-cluster-apps output loki_node_port)"
}

variable "node_exporter_node_port" {
  type        = number
  default     = 31090
  description = "Fixed NodePort for node-exporter — Prometheus on the DevOps cluster scrapes this directly"
}

variable "app_namespace" {
  type        = string
  default     = "hello-fastify"
  description = "Namespace the ECR pull-secret refresher targets — must already exist (ArgoCD creates it via CreateNamespace=true)"
}
