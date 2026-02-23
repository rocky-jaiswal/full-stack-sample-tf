include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/kms"
}

inputs = {
  environment  = "dev"
  project_name = "app-eks"
}
