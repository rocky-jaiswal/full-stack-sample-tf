resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [file("${path.module}/helm-values/argocd.yaml")]
}

resource "helm_release" "woodpecker" {
  name             = "woodpecker"
  chart            = "oci://ghcr.io/woodpecker-ci/helm/woodpecker"
  version          = "3.5.0"
  namespace        = "woodpecker"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [file("${path.module}/helm-values/woodpecker.yaml")]

  set_sensitive {
    name  = "server.env.WOODPECKER_GITHUB_CLIENT"
    value = var.woodpecker_github_client_id
  }
  set_sensitive {
    name  = "server.env.WOODPECKER_GITHUB_SECRET"
    value = var.woodpecker_github_client_secret
  }
  set_sensitive {
    name  = "server.env.WOODPECKER_AGENT_SECRET"
    value = var.woodpecker_agent_secret
  }
  set_sensitive {
    name  = "agent.env.WOODPECKER_AGENT_SECRET"
    value = var.woodpecker_agent_secret
  }
}

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  namespace        = "logging"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [file("${path.module}/helm-values/loki.yaml")]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [file("${path.module}/helm-values/kube-prometheus-stack.yaml")]
}
