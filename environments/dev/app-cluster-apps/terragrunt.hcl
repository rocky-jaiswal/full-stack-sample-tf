include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Root generates provider.tf (AWS). This adds Helm + Kubernetes providers alongside it.
generate "k8s_providers" {
  path      = "k8s-providers.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}
EOF
}

terraform {
  source = "../../../modules/app-cluster-apps"
}

dependency "devops_cluster" {
  config_path = "../devops-cluster"
}

dependency "devops_cluster_apps" {
  config_path = "../devops-cluster-apps"
}

inputs = {
  environment     = "dev"
  kubeconfig_path = pathexpand("~/.kube/app-cluster-dev")

  loki_host = dependency.devops_cluster.outputs.server_private_ip
  loki_port = dependency.devops_cluster_apps.outputs.loki_node_port
}
