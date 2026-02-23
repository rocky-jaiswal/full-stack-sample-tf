include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/s3"
}

dependency "kms" {
  config_path = "../kms"
}

inputs = {
  bucket_name = "app-eks-dev-data"
  environment = "dev"
  kms_key_arn = dependency.kms.outputs.key_arn
}
