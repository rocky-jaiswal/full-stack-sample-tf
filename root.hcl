# Role assumption is handled via AWS CLI profiles (AWS_PROFILE=tf-{env}).
# See scripts/bootstrap_iam.py for role setup.
remote_state {
  backend = "s3"
  config = {
    bucket         = "tf-state-750324395434-dev-80c0cf" # replace after running: uv run bootstrap_iam.py create-state-bucket --env dev
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    use_lockfile   = true
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

inputs = {
  region = "eu-central-1"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = var.region
}
EOF
}
