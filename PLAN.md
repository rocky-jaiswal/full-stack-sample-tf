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

## Next Session (2026-07-02) — decided, not deferred

The dev env was fully destroyed on 2026-07-01 (intentional, to re-test the build-from-scratch flow — see DESIGN.md). Rebuilding, but with two architecture changes decided during the 2026-07-01 session, both confirmed for this rebuild rather than deferred further:

1. **Split into one VPC per purpose, not one per environment.** A single "dev" VPC sharing DevOps + App cluster was fine for one environment, but doesn't scale once staging/prod show up. Target: one shared DevOps VPC (hub) + one VPC per app environment (dev app VPC now; staging/prod VPCs out of scope for now, just needs to support the pattern later). **Breaking change**: today's cross-cluster SG rules reference the peer's security-group ID directly (Fluent Bit→Loki, Prometheus→app metrics, ArgoCD→App cluster API) — that only works within one VPC. Splitting means those rules become CIDR-block-based, the VPCs need peering (Transit Gateway can wait until a 3rd/4th VPC makes a peering mesh unwieldy), and `modules/vpc/` likely needs a `purpose`/`role` variable since it'll be instantiated more than once per env with non-overlapping CIDRs. Each new VPC needs its own NAT instance (~$3/mo each).
2. **Replace SSM-tunnel access with the Tailscale operator.** Manual `tunnel.sh`/`api-tunnel*.sh` juggling (one local port 6443, constant target-switching, port-forwards dying on pod restarts) was a real practical pain. Tailscale's free tier (up to 3 users/100 devices) covers this project at $0/mo — chosen over ALB (~$20/mo + domain, and a separate decision since it also fixes Woodpecker webhooks, which Tailscale alone doesn't). Decide whether the SSM scripts stay as a fallback or get removed once Tailscale works.

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
| **Non-root containers** | Low | Helm chart authoring — API pods should run as non-root with read-only filesystems; set in Helm chart `securityContext` |
| **CI → Git push-back for image tags** | Medium | Woodpecker's `github_token` secret (`from_secret` in step `environment`) never reaches the step — resolves empty even after recreating the secret and broadening it to all events. Root cause not found. For now, update `helm/hello-fastify/values-dev.yaml`'s `image.tag` by hand after a Woodpecker build. Consider **ArgoCD Image Updater** instead of a hand-rolled git-push step — purpose-built for this, no CI-side git credentials needed at all |
| **Woodpecker webhook is one-time, not durable** | Low | Repo activation (webhook creation) was done via a temporary `cloudflared` quick-tunnel since GitHub rejects `localhost` webhook URLs. `WOODPECKER_HOST` is back to `localhost:8081` and the tunnel is closed — the webhook exists on GitHub's side but points at a dead URL, so automatic push-triggered builds still won't fire until the ALB step gives Woodpecker a real public URL. Manual triggers work fine regardless |

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
6. **App cluster** ✅ done (2 x t4g.medium, K3s v1.36.2+k3s1, both nodes Ready, SSM registered; `app-cluster-{env}` instance profile applied; registered with ArgoCD as part of step 7)
7. **hello-fastify on App cluster** ✅ done (2026-07-01) — Helm chart + `.woodpecker.yml` in the app repo, ArgoCD Application synced and running, deployed via a real Woodpecker CI build (`80c7d97` tag, lint/test/Kaniko-push all passed). CI trigger is manual (no working webhook) and the image-tag bump into Git is manual too (CI→Git push-back is broken); see Known Gaps
8. **Observability wiring** ✅ done (2026-07-01) — Fluent Bit + node-exporter on App cluster → Loki + Prometheus on DevOps cluster; hello-fastify logs and metrics confirmed visible in Grafana
9. **External Secrets Operator** ← next (Helm on App cluster; connects to Secrets Manager)
10. **RDS Aurora + ElastiCache Redis + SQS** (data layer, isolated subnets)
11. **ALB + DNS** (route internet → App cluster ingress; ACM cert + HTTPS listener)

---

See [DESIGN.md](DESIGN.md) for how hello-fastify's Helm chart, ArgoCD registration, and the cross-cluster observability wiring actually work — steps 7 and 8 are done.

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
