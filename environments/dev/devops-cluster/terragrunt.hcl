include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/devops-cluster"
}

dependency "vpc" {
  config_path = "../vpc"
}

dependency "kms" {
  config_path = "../kms"
}

dependency "s3" {
  config_path = "../s3"
}

inputs = {
  environment          = "dev"
  project_name         = "app-eks"
  vpc_id               = dependency.vpc.outputs.vpc_id
  vpc_cidr             = dependency.vpc.outputs.vpc_cidr
  private_subnet_ids   = dependency.vpc.outputs.private_subnet_ids
  kms_key_arn          = dependency.kms.outputs.key_arn
  artifacts_bucket_arn = dependency.s3.outputs.bucket_arn
}
