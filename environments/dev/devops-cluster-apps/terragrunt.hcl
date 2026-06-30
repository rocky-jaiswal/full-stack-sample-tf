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
  source = "../../../modules/devops-cluster-apps"
}

dependency "devops_cluster" {
  config_path = "../devops-cluster"
}

inputs = {
  environment     = "dev"
  kubeconfig_path = pathexpand("~/.kube/devops-cluster-dev")

  # Secrets via TF_VAR_ env vars — never hardcoded here:
  #   TF_VAR_woodpecker_github_client_id
  #   TF_VAR_woodpecker_github_client_secret
  #   TF_VAR_woodpecker_agent_secret
}
