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

# Loki's Service is NodePort (see helm-values/loki.yaml) so Fluent Bit on the
# App cluster can reach it cross-cluster. The chart doesn't support pinning
# the nodePort, so read back whatever Kubernetes assigned.
data "kubernetes_service_v1" "loki" {
  metadata {
    name      = "loki"
    namespace = "logging"
  }

  depends_on = [helm_release.loki]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [templatefile("${path.module}/helm-values/kube-prometheus-stack.yaml", {
    app_cluster_server_ip = var.app_cluster_server_ip
  })]
}

# -----------------------------------------------------------------------------
# App cluster registration — lets ArgoCD deploy to the App cluster
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "app_cluster" {
  metadata {
    name      = "app-cluster-dev"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = "app-cluster-dev"
    server = "https://${var.app_cluster_server_ip}:6443"
    config = jsonencode({
      tlsClientConfig = {
        insecure = false
        caData   = var.app_cluster_ca_data
        certData = var.app_cluster_cert_data
        keyData  = var.app_cluster_key_data
      }
    })
  }

  depends_on = [helm_release.argocd]
}

resource "aws_security_group_rule" "app_cluster_to_loki" {
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = var.devops_cluster_sg_id
  source_security_group_id = var.app_cluster_sg_id
  description              = "NodePort range - Fluent Bit on the App cluster ships logs to Loki here"
}

resource "kubernetes_manifest" "hello_fastify" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "hello-fastify-dev"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.hello_fastify_repo_url
        targetRevision = "main"
        path           = "helm/hello-fastify"
        helm = {
          valueFiles = ["values-dev.yaml"]
        }
      }
      destination = {
        server    = "https://${var.app_cluster_server_ip}:6443"
        namespace = "hello-fastify"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }

  depends_on = [kubernetes_secret.app_cluster]
}
