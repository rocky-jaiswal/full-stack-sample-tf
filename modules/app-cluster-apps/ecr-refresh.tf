data "aws_caller_identity" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

# This K3s isn't the EKS-optimized AMI, so containerd has no built-in ECR
# credential helper — unlike EKS worker nodes. A CronJob refreshes a
# docker-registry Secret every 6h using the node's own instance-profile
# credentials (ecr:GetAuthorizationToken, already granted on app-cluster-{env}).
# ECR tokens are valid 12h, so 6h gives headroom for a missed run.

resource "kubernetes_secret" "ecr_pull" {
  metadata {
    name      = "ecr-pull-secret"
    namespace = var.app_namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.ecr_registry) = {}
      }
    })
  }

  # The CronJob owns the real data going forward — Terraform only creates
  # the Secret so the Role below has something to reference from the start.
  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_service_account" "ecr_refresher" {
  metadata {
    name      = "ecr-pull-secret-refresher"
    namespace = var.app_namespace
  }
}

resource "kubernetes_role" "ecr_refresher" {
  metadata {
    name      = "ecr-pull-secret-refresher"
    namespace = var.app_namespace
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [kubernetes_secret.ecr_pull.metadata[0].name]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "ecr_refresher" {
  metadata {
    name      = "ecr-pull-secret-refresher"
    namespace = var.app_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ecr_refresher.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ecr_refresher.metadata[0].name
    namespace = var.app_namespace
  }
}

resource "kubernetes_cron_job_v1" "ecr_pull_secret_refresh" {
  metadata {
    name      = "ecr-pull-secret-refresh"
    namespace = var.app_namespace
  }

  spec {
    schedule                      = "0 */6 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.ecr_refresher.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name  = "refresh"
              image = "alpine/k8s:1.31.4"

              command = ["/bin/sh", "-c"]
              args = [<<-EOT
                set -euo pipefail
                TOKEN=$(aws ecr get-login-password --region ${var.region})
                kubectl create secret docker-registry ${kubernetes_secret.ecr_pull.metadata[0].name} \
                  --namespace ${var.app_namespace} \
                  --docker-server=${local.ecr_registry} \
                  --docker-username=AWS \
                  --docker-password="$TOKEN" \
                  --dry-run=client -o yaml | kubectl apply -f -
              EOT
              ]
            }
          }
        }
      }
    }
  }
}
