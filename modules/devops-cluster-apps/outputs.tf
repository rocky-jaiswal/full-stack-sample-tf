output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "woodpecker_namespace" {
  value = helm_release.woodpecker.namespace
}
