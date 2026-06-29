include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/ecr"
}

dependency "kms" {
  config_path = "../kms"
}

inputs = {
  environment      = "dev"
  project_name     = "app-eks"
  kms_key_arn      = dependency.kms.outputs.key_arn
  repository_names = ["api", "web", "worker"]
}
