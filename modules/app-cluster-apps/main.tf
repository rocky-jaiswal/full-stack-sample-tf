resource "helm_release" "fluent_bit" {
  name             = "fluent-bit"
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  namespace        = "logging"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [templatefile("${path.module}/helm-values/fluent-bit.yaml", {
    loki_host = var.loki_host
    loki_port = var.loki_port
  })]
}

resource "helm_release" "node_exporter" {
  name             = "prometheus-node-exporter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-node-exporter"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "service.nodePort"
    value = var.node_exporter_node_port
  }
}
