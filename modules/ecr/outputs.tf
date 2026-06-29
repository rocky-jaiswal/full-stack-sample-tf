output "repository_urls" {
  description = "Map of repo name to full ECR URL (used by Woodpecker CI to push images)"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "registry_id" {
  description = "ECR registry ID (AWS account ID) — needed for docker login"
  value       = data.aws_caller_identity.current.account_id
}
