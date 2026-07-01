# Full Stack — End-to-End Architecture

> **Docs convention:** this file tracks what's left to build. Once a step ships, move its rationale and implementation notes into [DESIGN.md](DESIGN.md) and shrink this file to a checklist line. PLAN.md should get smaller over time; DESIGN.md gets more detailed.

```
YOU (developer)
 |
 |  git push
 v
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub                                                             │
│  - Application code + Dockerfile                                    │
│  - Helm charts (app repo or separate)                               │
│  - Terraform/Terragrunt infra code (this repo)                      │
└────────────┬────────────────────────────────┬───────────────────────┘
             │ webhook triggers               │ ArgoCD watches
             v                                v
┌─────────────────────────────────────────────────────────────────────┐
│  VPC (eu-central-1)                                                 │
│                                                                     │
│  ┌─── Public Subnets ────────────────────────────────────────────┐  │
│  │  ALB  ←── internet traffic                                    │  │
│  │  NAT Gateway                                                  │  │
│  └───────────────────────────┬───────────────────────────────────┘  │
│                              │                                      │
│  ┌─── Private Subnets ──────┴───────────────────────────────────┐  │
│  │                                                               │  │
│  │  ┌─ DevOps Cluster (2 x t3.medium) ──────────────────────┐   │  │
│  │  │  Woodpecker CI   ← builds images, pushes to ECR        │   │  │
│  │  │  ArgoCD          ← deploys Helm charts to App Cluster  │   │  │
│  │  │  Prometheus      ← scrapes metrics from App Cluster    │   │  │
│  │  │  Loki            ← receives logs from App Cluster      │   │  │
│  │  │  Grafana         ← dashboards for all of the above     │   │  │
│  │  └────────────────────────────┬──────────────────────────-┘   │  │
│  │                               │ ArgoCD deploys to              │  │
│  │                               │ Fluent Bit + OTel ship back    │  │
│  │                               v                                │  │
│  │  ┌─ App Cluster (2 x t3.medium) ─────────────────────────┐   │  │
│  │  │  Your apps (web, API, workers)                         │   │  │
│  │  │  Fluent Bit DaemonSet  → Loki (DevOps cluster)        │   │  │
│  │  │  OTel collector        → Prometheus (DevOps cluster)   │   │  │
│  │  └────────────────────────────────────────────────────────┘   │  │
│  │                                                               │  │
│  │  ┌── Data Layer (isolated subnets) ───────────────────────┐  │  │
│  │  │ RDS Aurora PostgreSQL  (encrypted, CMK)                │  │  │
│  │  │ ElastiCache Redis      (cache + sessions)              │  │  │
│  │  │ SQS                    (async job queues)              │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌── Shared Services ───────────────────────────────────────────┐  │
│  │ ECR (container images)          KMS CMK per env              │  │
│  │ S3 (artifacts / data)           Secrets Manager              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## The Full Lifecycle

| Step | What happens | Tool |
|------|-------------|------|
| 1. Write code | Push to GitHub | Git |
| 2. Build & test | Woodpecker CI runs tests, builds Docker image | Woodpecker CI |
| 3. Store image | Image pushed to ECR with new tag | ECR |
| 4. Update manifests | Woodpecker commits new image tag into Helm `values.yaml` | Git |
| 5. Deploy | ArgoCD detects Helm chart change, runs `helm upgrade` on App Cluster | ArgoCD |
| 6. Route traffic | ALB → K3s ingress → your pods | ALB + K3s |
| 7. App runs | Pods talk to RDS, Redis, SQS, S3 — all private | K3s |
| 8. Something breaks | Logs → Loki, Metrics → Prometheus | Grafana (DevOps cluster) |
| 9. You debug | Grafana dashboards, `kubectl` against App Cluster | Grafana / kubectl |
| 10. You fix | Push fix → steps 2-6 repeat automatically | The whole pipeline |

See [DESIGN.md](DESIGN.md) for decisions already made (topology, CI/CD, IAM, VPC, access patterns) and open design questions.

## Future Enhancements (Deferred by Design)

| Enhancement | Why deferred | Approach when revisited |
|-------------|--------------|--------------------------|
| **EC2 node autoscaling (App cluster)** | Pod-level HPA already scales replicas within existing node capacity. Manual node count in Terraform (bump + `terragrunt apply`) is enough for a cost-conscious reference setup — no need for the extra moving parts yet. | Move App cluster agent nodes into an ASG, run **Cluster Autoscaler** with ASG tag-based auto-discovery (works with self-managed K8s, not just EKS). K3s join needs to run unattended via `user_data` instead of the SSM Run Command workaround. Karpenter is skipped — it's effectively EKS-only in practice. |

## Known Gaps (address at the relevant build step)

| Gap | Severity | Address at |
|-----|----------|-----------|
| **TLS / HTTPS** | Critical | ALB + DNS step — need ACM certificate + HTTPS listener on ALB (port 443), ALB forwards HTTP internally to K3s |
| **ALB → K3s routing mechanism** | Critical | ALB + DNS step — NodePort vs AWS LBC, see [Open Questions](DESIGN.md#open-questions) |
| **Secret rotation + pod restart** | High | ESO step — install Reloader (watches K8s Secrets, triggers rolling restarts when values change; one Helm install on App cluster) |
| **Network policies / CNI** | High | K3s cluster Terraform — default Flannel doesn't support NetworkPolicy (any pod can reach RDS/Redis); replace with **Calico** or **Cilium** for proper pod-to-pod isolation |
| **VPC endpoints** | Medium | After clusters running — add endpoints for ECR, S3, Secrets Manager, SQS; traffic stays off NAT Gateway (cheaper + more secure) |
| **Rollback process** | Medium | After first deployment — ArgoCD can roll back Helm release; document the process (git revert image tag → ArgoCD auto-syncs) |
| **Image tag strategy** | Medium | Woodpecker setup — define tagging convention: `<short-sha>` for all builds, semver (`v1.2.3`) for releases |
| **K3s etcd backup** | Medium | After DevOps cluster is up — back up K3s etcd regularly; ArgoCD app definitions are in Git but cluster state is not |
| **Alerting** | Medium | After Grafana is running — configure Grafana alert rules + notification channel (Slack / email) for error rate spikes, pod crashes, high latency |
| **Woodpecker → GitHub write access** | Medium | Before first CI run — GitHub token with repo write access; stored in Secrets Manager → ESO → K8s Secret → Woodpecker pipeline secret |
| **Non-root containers** | Low | Helm chart authoring — API pods should run as non-root with read-only filesystems; set in Helm chart `securityContext` |

## Estimated Monthly Cost

| Component | Detail | Cost |
|-----------|--------|------|
| DevOps cluster | 2 x t4g.medium (ARM) | ~$24 |
| App cluster | 2 x t4g.medium (ARM) | ~$24 |
| RDS Aurora | Smallest instance | ~$35 |
| RDS Proxy | Per vCPU of Aurora | ~$15 |
| ElastiCache Redis | cache.t3.micro | ~$15 |
| ECR + S3 + KMS | Minimal usage | ~$5 |
| NAT instance | t4g.nano (replaces NAT GW) | ~$3 |
| **Total** | | **~$121/mo** |

> Down from ~$210/mo — NAT instance saves ~$32/mo, ARM nodes save ~$72/mo vs t3.medium. Can bump nodes to t3.medium if the DevOps stack needs more memory.

See [DESIGN.md](DESIGN.md) for the CI pipeline stage breakdown and how observability (Fluent Bit/OTel → Loki/Prometheus → Grafana) fits together.

## Build Order

1. **VPC** ✅ done (NAT instance t4g.nano instead of NAT Gateway — ~$3/mo vs ~$35/mo)
2. **KMS + S3** ✅ done
3. **ECR** ✅ done (3 repos: api, web, worker; KMS-encrypted; lifecycle policy)
4. **DevOps cluster** ✅ done (2 x t4g.medium, K3s v1.36.2+k3s1, both nodes Ready, SSM registered)
5. **DevOps cluster apps** ✅ done (ArgoCD, Woodpecker CI, Loki, Prometheus, Grafana via `modules/devops-cluster-apps/`)
6. **App cluster** ← next (2 x t4g.medium, K3s, `app-cluster-{env}` instance profile, registered with ArgoCD)
7. **hello-fastify on App cluster** (Helm chart + `.woodpecker.yml` + ArgoCD Application)
8. **Observability wiring** (Fluent Bit + node-exporter on App cluster → Loki + Prometheus on DevOps cluster → Grafana shows app logs and metrics)
9. **External Secrets Operator** (Helm on App cluster; connects to Secrets Manager)
10. **RDS Aurora + ElastiCache Redis + SQS** (data layer, isolated subnets)
11. **ALB + DNS** (route internet → App cluster ingress; ACM cert + HTTPS listener)

---

## Step 6 — App Cluster (next session)

### New files to create

```
modules/app-cluster/
  versions.tf       # AWS provider (same as devops-cluster)
  variables.tf      # environment, region, vpc_private_subnet_ids, kms_key_arn, ...
  main.tf           # EC2 instances (server + agent), security groups
  iam.tf            # app-cluster-{env} instance profile
  outputs.tf        # server_instance_id, server_private_ip

environments/dev/app-cluster/
  terragrunt.hcl    # depends on vpc, kms
```

### IAM — `iam.tf`

`app-cluster-{env}` instance profile permissions (different from devops-cluster which has ECR push):

- ECR: `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` (pull only)
- Secrets Manager: `secretsmanager:GetSecretValue` (scoped to `app/*`)
- SQS: `sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage` (scoped to account queues)
- S3: `s3:GetObject`, `s3:PutObject` (scoped to app bucket)
- SSM: `ssm:*`, `ec2messages:*`, `ssmmessages:*` (same as devops-cluster — required for SSM agent)

### K3s install — fix the user_data timing problem

The DevOps cluster hit this: `user_data` ran before the NAT instance was ready, so the K3s install `curl` failed silently and K3s had to be installed manually via SSM afterwards. The App cluster module must not repeat this.

**Solution:** split `user_data` into two parts:
1. `user_data` only installs the SSM agent (no internet needed — uses VPC endpoint or instance metadata). This always works.
2. K3s install runs via a Terraform `null_resource` + `local-exec` that uses SSM `send-command` **after** both the NAT instance and the new EC2 nodes are confirmed running. Terraform dependency ordering (`depends_on` the NAT instance resource) ensures NAT is up before the send-command fires.

```hcl
resource "null_resource" "install_k3s_server" {
  depends_on = [aws_instance.server, aws_instance.nat]   # NAT must be up first

  provisioner "local-exec" {
    command = <<-EOT
      aws ssm send-command \
        --instance-ids ${aws_instance.server.id} \
        --document-name AWS-RunShellScript \
        --parameters 'commands=["curl -sfL https://get.k3s.io | sh -"]' \
        --profile tf-dev --region eu-central-1
    EOT
  }
}
```

This removes the manual SSM hack entirely — `terragrunt apply` handles everything.

### main.tf — what's different vs devops-cluster

- Tags: `Cluster=app` (not `Cluster=devops`) — tunnel and kubeconfig scripts use tag-based lookup
- Security group: add inbound rule allowing the DevOps cluster security group to reach port 6443 (K3s API) — ArgoCD needs to talk to the App cluster API server
- User data: same K3s install pattern via SSM Run Command (user_data only installs SSM agent; K3s is installed separately via `scripts/install-k3s.sh` after NAT is verified)
- K3s server flag: `--disable traefik` is optional — keep Traefik for now (it handles ingress for the app)

### After apply

```bash
# Fetch kubeconfig for app cluster (same script, different env tag)
./scripts/get-kubeconfig.sh app-dev
# saves to ~/.kube/app-cluster-dev
```

### Register App cluster with ArgoCD

ArgoCD on the DevOps cluster needs a `Secret` in the `argocd` namespace describing the App cluster's API endpoint. The simplest approach — add a `helm_release` or `kubernetes_secret` resource to `modules/devops-cluster-apps/` that creates this secret using the App cluster's kubeconfig data as input variables.

ArgoCD cluster secret format:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-cluster-dev
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: app-cluster-dev
  server: https://<app-cluster-server-private-ip>:6443
  config: |
    {
      "bearerToken": "<k3s-node-token>",
      "tlsClientConfig": { "insecure": true }
    }
```

`insecure: true` is fine for internal private-subnet traffic. The K3s node token lives at `/var/lib/rancher/k3s/server/node-token` on the server node — fetch it via SSM send-command the same way the kubeconfig script works.

---

## Step 7 — hello-fastify on App cluster

Three things needed, all created in the **hello-fastify repo** (not this repo):

### 7a. Helm chart (`helm/hello-fastify/`)

```
helm/hello-fastify/
  Chart.yaml
  values.yaml          # image.repository, image.tag, replicaCount, resources
  values-dev.yaml      # dev overrides (1 replica, smaller resources)
  templates/
    deployment.yaml
    service.yaml       # ClusterIP — ALB will route to it later
    _helpers.tpl
```

Key points:
- `image.tag` starts as `latest` in values.yaml; Woodpecker CI overwrites it with the git SHA on each build
- Resource requests: `cpu: 100m, memory: 128Mi` — t4g.medium has 4GB total, shared with K3s system pods
- `imagePullPolicy: Always` for dev (no tag pinning yet)
- No ingress resource yet — ALB comes later (step 10)

### 7b. `.woodpecker.yml`

```yaml
steps:
  - name: lint-and-typecheck
    image: node:22-alpine
    commands:
      - npm ci
      - npm run lint
      - npm run typecheck

  - name: build-and-push
    image: gcr.io/kaniko-project/executor:latest
    environment:
      AWS_REGION: eu-central-1
    settings:
      dockerfile: Dockerfile
      context: .
      destination: <account-id>.dkr.ecr.eu-central-1.amazonaws.com/api:${CI_COMMIT_SHA}
    # Kaniko reads ECR credentials from the EC2 instance profile automatically
    # No docker socket needed — no privileged mode

  - name: update-image-tag
    image: alpine/git
    commands:
      - git config user.email "ci@woodpecker"
      - git config user.name "Woodpecker CI"
      - sed -i "s/tag:.*/tag: ${CI_COMMIT_SHA}/" helm/hello-fastify/values-dev.yaml
      - git commit -am "ci: update image tag to ${CI_COMMIT_SHA}"
      - git push
    secrets: [github_token]
    # github_token stored in Woodpecker pipeline secrets (UI → repo → secrets)
```

**Why Kaniko?** Docker-in-Docker (DinD) needs `privileged: true` on the pod — a significant security risk. Kaniko builds OCI images from a Dockerfile without a Docker daemon, no privileged mode needed. It reads ECR auth from the EC2 instance profile automatically.

### 7c. ArgoCD Application

Create an ArgoCD `Application` resource (either via `kubectl apply` or a Terraform `kubernetes_manifest` in `modules/devops-cluster-apps/`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-fastify-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/rocky-jaiswal/hello-fastify
    targetRevision: main
    path: helm/hello-fastify
    helm:
      valueFiles:
        - values-dev.yaml
  destination:
    server: https://<app-cluster-server-private-ip>:6443
    namespace: hello-fastify
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

ArgoCD polls Git every 3 minutes by default. When Woodpecker commits the new image tag, ArgoCD detects it and runs `helm upgrade` on the App cluster automatically.

### End-to-end verification

After step 7 is done, the full loop works:

```
git push hello-fastify
  → Woodpecker builds image → pushes to ECR → commits new tag to Git
  → ArgoCD detects tag change → helm upgrade on App cluster
  → kubectl port-forward to App cluster → curl http://localhost:3001/v1/health
```

No ALB yet — access the app via `kubectl port-forward` against the App cluster kubeconfig. That's enough to prove the pipeline works end-to-end before paying for an ALB.

---

## Step 8 — Observability Wiring (App cluster → DevOps cluster)

Both clusters are in the same VPC (different private subnets) so they can reach each other directly — no VPN, no extra networking. Two data flows:

```
App cluster                          DevOps cluster
───────────                          ──────────────
Fluent Bit (DaemonSet)  ──push──►  Loki :3100        ──► Grafana
node-exporter (DaemonSet)           Prometheus
kube-state-metrics       ◄──scrape──  (pulls metrics)  ──► Grafana
hello-fastify /metrics
```

### New module: `modules/app-cluster-apps/`

```
modules/app-cluster-apps/
  versions.tf
  variables.tf          # loki_endpoint, prometheus_scrape_targets, ...
  main.tf               # helm_release for fluent-bit + kube-prometheus-stack (agents only)
  helm-values/
    fluent-bit.yaml
    prometheus-node-exporter.yaml
```

### Security group changes (in `modules/devops-cluster/` and `modules/app-cluster/`)

Two rules to add — both clusters are already in the same VPC CIDR:

| From | To | Port | Why |
|------|----|------|-----|
| App cluster SG | DevOps cluster SG | 3100 (TCP) | Fluent Bit → Loki |
| DevOps cluster SG | App cluster SG | 9100 (TCP) | Prometheus → node-exporter |
| DevOps cluster SG | App cluster SG | 8080 (TCP) | Prometheus → kube-state-metrics |
| DevOps cluster SG | App cluster SG | 3001 (TCP) | Prometheus → hello-fastify /metrics |

Add these as `aws_security_group_rule` resources that cross-reference each module's SG ID via Terragrunt `dependency` outputs.

### Loki — expose via NodePort on DevOps cluster

Loki's ClusterIP is only resolvable inside the DevOps cluster. Fluent Bit on the App cluster needs to reach it by IP. Cleanest approach: patch Loki service to NodePort in the helm values, then Fluent Bit points to `http://<devops-server-private-ip>:<nodeport>`.

Add to `modules/devops-cluster-apps/helm-values/loki.yaml`:
```yaml
service:
  type: NodePort
  nodePort: 31100    # fixed port, easy to reference
```

Fluent Bit config then ships to `http://10.0.86.207:31100` (DevOps server private IP). This IP is a Terragrunt output from `devops-cluster` — wire it in as a variable.

### Fluent Bit values (`helm-values/fluent-bit.yaml`)

```yaml
config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On

  outputs: |
    [OUTPUT]
        Name        loki
        Match       kube.*
        Host        ${LOKI_HOST}
        Port        31100
        Labels      job=fluent-bit, cluster=app-dev

env:
  - name: LOKI_HOST
    value: "10.0.86.207"    # DevOps cluster server private IP (var in Terraform)
```

### Prometheus — scrape App cluster from DevOps cluster

No separate Prometheus on App cluster needed. DevOps cluster's Prometheus scrapes App cluster nodes directly via `additionalScrapeConfigs`. Add to `modules/devops-cluster-apps/helm-values/kube-prometheus-stack.yaml`:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: app-cluster-node-exporter
        static_configs:
          - targets:
              - "<app-server-private-ip>:9100"
              - "<app-agent-private-ip>:9100"
        relabel_configs:
          - target_label: cluster
            replacement: app-dev

      - job_name: app-cluster-kube-state-metrics
        static_configs:
          - targets: ["<app-server-private-ip>:8080"]

      - job_name: hello-fastify
        static_configs:
          - targets: ["<app-server-private-ip>:3001"]
        metrics_path: /metrics
```

App cluster private IPs come from Terragrunt dependency outputs — no hardcoding.

### Install node-exporter on App cluster

`kube-prometheus-stack` on the DevOps cluster installs node-exporter only on DevOps nodes. For App cluster nodes, install a standalone node-exporter via helm_release in `modules/app-cluster-apps/`:

```hcl
resource "helm_release" "node_exporter" {
  name       = "prometheus-node-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-node-exporter"
  namespace  = "monitoring"
  create_namespace = true
}

resource "helm_release" "kube_state_metrics" {
  name       = "kube-state-metrics"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  namespace  = "monitoring"
  create_namespace = true
}

resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  namespace  = "logging"
  create_namespace = true
  values     = [templatefile("${path.module}/helm-values/fluent-bit.yaml", {
    loki_host = var.loki_host
  })]
}
```

### Verification

After step 8 apply:

1. **Logs**: open Grafana (`localhost:8082`) → Explore → Loki datasource → `{cluster="app-dev"}` → should see hello-fastify pod logs
2. **Metrics**: Grafana → Explore → Prometheus → `up{job="app-cluster-node-exporter"}` → should return 1
3. **App metrics**: `http_requests_total{job="hello-fastify"}` — prom-client is already in hello-fastify

That's the big win — one Grafana showing logs and metrics from both clusters.

---

## Steps 9–11 — After hello-fastify is running + observable

### Step 9 — External Secrets Operator

Add to `modules/app-cluster-apps/main.tf`:
```hcl
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
}
```

Then create a `ClusterSecretStore` (points at AWS Secrets Manager using the node's instance profile) and `ExternalSecret` resources per app secret.

### Step 10 — RDS Aurora + ElastiCache Redis + SQS

- `modules/rds/` — Aurora PostgreSQL Serverless v2, isolated subnets, KMS-encrypted, RDS Proxy in front
- `modules/elasticache/` — Redis cache.t3.micro, isolated subnets, KMS-encrypted
- `modules/sqs/` — one queue per async job type
- After this step: re-enable DB/Redis in hello-fastify (uncomment the v1 stubs)
- Secrets (connection strings) go into AWS Secrets Manager → ESO pulls them into K8s Secrets → hello-fastify reads from env

### Step 11 — ALB + DNS

- `modules/alb/` — internet-facing ALB in public subnets, HTTPS listener (ACM cert), HTTP→HTTPS redirect
- Target group: NodePort on App cluster nodes pointing to Traefik
- This also enables Woodpecker GitHub webhooks (update `WOODPECKER_HOST` in `helm-values/woodpecker.yaml` to the ALB DNS name and re-apply devops-cluster-apps)
- DNS: Route 53 hosted zone or just use the ALB DNS name directly for dev
