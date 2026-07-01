output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "woodpecker_namespace" {
  value = helm_release.woodpecker.namespace
}

output "loki_node_port" {
  description = "NodePort Loki's http-metrics port (3100) is exposed on, for cross-cluster Fluent Bit shipping"
  value       = [for p in data.kubernetes_service_v1.loki.spec[0].port : p.node_port if p.name == "http-metrics"][0]
}
