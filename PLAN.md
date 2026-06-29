# Full Stack — End-to-End Architecture

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

## Decisions Made

| Decision | Choice | Why |
|----------|--------|-----|
| Cluster topology | Hub-spoke: DevOps cluster + App cluster | Resource isolation, real enterprise pattern, ArgoCD designed for this |
| Kubernetes | K3s on t3.medium EC2 (private subnets) | No $73/mo control plane fee, lightweight, fully K8s-conformant |
| CI | Woodpecker CI (on DevOps cluster) | OSS, Git-native `.woodpecker.yml`, no per-minute billing |
| CD | ArgoCD (on DevOps cluster) | GitOps reconciliation, hub-spoke multi-cluster native |
| App packaging | Helm charts | Standard K8s packaging — ArgoCD deploys Helm charts from Git |
| Logs | Loki (on DevOps cluster) + Fluent Bit DaemonSet on App cluster | Free, OSS, runs on your cluster — no $50+/mo managed OpenSearch |
| Metrics | Prometheus + Grafana (on DevOps cluster) | Free, OSS, scrapes App cluster remotely |
| Encryption | KMS CMK per env | One key for all services, $1/mo |
| Storage | S3 (KMS-encrypted, versioned) | Locked down, HTTPS-only |
| Cache | ElastiCache Redis (managed) | Cache + sessions, isolated subnet, no ops burden |
| DB connection pooling | RDS Proxy (managed) | Pools connections between pods and Aurora, handles failover; apps point at Proxy endpoint |
| Queue | SQS (managed) | Async jobs, serverless, no ops burden |
| IAM (local → AWS) | STS role assumption via `deployer` user | No long-lived infra keys for Terraform |
| IAM (CI → AWS) | EC2 instance profile on DevOps cluster nodes | No credentials stored; Woodpecker inherits role automatically |
| IAM (apps → AWS) | EC2 instance profile on App cluster nodes | ECR pull, Secrets Manager read, SQS, S3 |
| Secret delivery | External Secrets Operator + AWS Secrets Manager | Apps see plain K8s Secrets; ESO syncs from AWS |
| kubectl access | AWS SSM Session Manager | No SSH, no open ports, free; port-forward K3s API locally |
| UI access (Woodpecker, ArgoCD, Grafana) | Tailscale on DevOps cluster | Always-on access to private IPs via tailnet; no open ports, free for personal use |
| Woodpecker auth | GitHub OAuth | Users whitelist via GitHub OAuth app; baked into Woodpecker |
| ArgoCD auth | GitHub SSO (OIDC) + RBAC | Read-only vs admin roles; no anonymous access |
| Grafana auth | GitHub OAuth (built-in) | Same pattern; restrict to your GitHub org/users |
| IaC | Terraform/Terragrunt (OpenTofu) | Multi-module, multi-env, DRY |

## Access & Security

All DevOps tooling runs in private subnets — never exposed to the internet. Access is two-layered:

```
You (laptop)
   │  Tailscale (network layer — who can reach the cluster)
   ▼
DevOps cluster private IPs
   ├── Woodpecker CI  → GitHub OAuth      (who can use it)
   ├── ArgoCD         → GitHub SSO + RBAC (read-only vs admin roles)
   └── Grafana        → GitHub OAuth      (logs, metrics, dashboards)

kubectl (occasional)
   │  SSM Session Manager port-forward → K3s API
   ▼
App cluster or DevOps cluster
```

**Why Tailscale for UIs and SSM for kubectl?**
SSM port-forwarding is fine for occasional terminal commands but clunky for web UIs (need to run a command and keep the tunnel open every session). Tailscale gives always-on access to private IPs — open a browser, done. Both approaches have zero open ports.

**Grafana access** (logs + metrics) follows the same pattern:
- Tailscale gets you to the cluster network
- Grafana GitHub OAuth ensures only authorised users can view dashboards, query Loki logs, or explore Prometheus metrics
- Sensitive data (DB query patterns, error details in logs) stays inside the tailnet

## Still Undecided

| Decision | Options | Notes |
|----------|---------|-------|
| Ingress controller | Traefik (K3s default) vs nginx | Traefik requires no extra install — default unless we hit a limit |
| ALB → K3s routing | NodePort (simple) vs AWS Load Balancer Controller on K3s (SOTA) | NodePort: ALB target group points to Traefik NodePort on each node. LBC: same controller EKS uses, creates ALBs from Ingress annotations but needs extra IAM. Decide at ALB step. |
| Queue implementation | SQS vs donkeyq on ElastiCache | Decide when building apps; donkeyq avoids an extra AWS service |

## Known Gaps (address at the relevant build step)

| Gap | Severity | Address at |
|-----|----------|-----------|
| **IAM cluster instance profiles** | High | DevOps + App cluster Terraform — two EC2 instance profiles must be created inside the cluster modules: `devops-cluster-{env}` (Woodpecker needs ECR push/pull + S3 read/write) and `app-cluster-{env}` (pods need ECR pull, Secrets Manager read, SQS send/receive, S3 read/write); these are not created by the bootstrap script |
| **TLS / HTTPS** | Critical | ALB + DNS step — need ACM certificate + HTTPS listener on ALB (port 443), ALB forwards HTTP internally to K3s |
| **ALB → K3s routing mechanism** | Critical | ALB + DNS step — NodePort vs AWS LBC decision above |
| **Secret rotation + pod restart** | High | ESO step — install Reloader (watches K8s Secrets, triggers rolling restarts when values change; one Helm install on App cluster) |
| **Multi-AZ node placement** | High | K3s cluster Terraform — pin one node per AZ via subnet assignment so a single AZ failure doesn't kill the cluster |
| **DB migrations** | Resolved | App runs migrations on startup before serving traffic. Migrations must be backward-compatible (expand-then-contract) since old + new pods overlap briefly during rolling updates |
| **Docker build in Woodpecker** | High | Woodpecker setup — Docker-in-Docker (DinD) needs privileged pods (security risk); prefer **Kaniko** which builds images without Docker daemon, no privileged mode needed |
| **RDS connection pooling** | Resolved | **RDS Proxy** (managed, ~$15/mo) — sits between app pods and Aurora, pools connections, handles failover transparently. Apps connect to the Proxy endpoint instead of Aurora directly |
| **Log + metrics retention** | Resolved | 90 days for both Loki and Prometheus, configurable via Helm values. Set at Loki + Prometheus setup step |
| **Network policies / CNI** | High | K3s cluster Terraform — default Flannel doesn't support NetworkPolicy (any pod can reach RDS/Redis); replace with **Calico** or **Cilium** for proper pod-to-pod isolation |
| **VPC endpoints** | Medium | After clusters running — add endpoints for ECR, S3, Secrets Manager, SQS; traffic stays off NAT Gateway (cheaper + more secure) |
| **Rollback process** | Medium | After first deployment — ArgoCD can roll back Helm release; document the process (git revert image tag → ArgoCD auto-syncs) |
| **Image tag strategy** | Medium | Woodpecker setup — define tagging convention: `<short-sha>` for all builds, semver (`v1.2.3`) for releases |
| **K3s etcd backup** | Medium | After DevOps cluster is up — back up K3s etcd regularly; ArgoCD app definitions are in Git but cluster state is not |
| **Alerting** | Medium | After Grafana is running — configure Grafana alert rules + notification channel (Slack / email) for error rate spikes, pod crashes, high latency |
| **Woodpecker → GitHub write access** | Medium | Before first CI run — GitHub token with repo write access; stored in Secrets Manager → ESO → K8s Secret → Woodpecker pipeline secret |
| **OS / AMI for K3s nodes** | Low | K3s cluster Terraform — choose Amazon Linux 2023 or Ubuntu 24.04; affects patching strategy and K3s install scripts |
| **Non-root containers** | Low | Helm chart authoring — API pods should run as non-root with read-only filesystems; set in Helm chart `securityContext` |

## Estimated Monthly Cost

| Component | Detail | Cost |
|-----------|--------|------|
| DevOps cluster | 2 x t4g.small (ARM) | ~$24 |
| App cluster | 2 x t4g.small (ARM) | ~$24 |
| RDS Aurora | Smallest instance | ~$35 |
| RDS Proxy | Per vCPU of Aurora | ~$15 |
| ElastiCache Redis | cache.t3.micro | ~$15 |
| ECR + S3 + KMS | Minimal usage | ~$5 |
| NAT instance | t4g.nano (replaces NAT GW) | ~$3 |
| **Total** | | **~$121/mo** |

> Down from ~$210/mo — NAT instance saves ~$32/mo, ARM nodes save ~$72/mo vs t3.medium. Can bump nodes to t3.medium if the DevOps stack needs more memory.

## CI Pipeline Stages (Woodpecker)

Each app repo has a `.woodpecker.yml` defining the pipeline. Stages run in order — build/push only happens if all checks and tests pass.

```
git push
   │
   ├── 1. Code checks       lint + format check + type check + security scan
   │                        (fast, no dependencies, catches issues early)
   │
   ├── 2. Unit tests        no external dependencies, pure logic
   │
   ├── 3. Integration tests Woodpecker spins up services (Postgres, Redis)
   │                        alongside the pipeline — tests connect to them
   │                        as if they were real. No mocking.
   │
   ├── 4. docker build      builds the production image
   │
   ├── 5. Push → ECR        tags with git SHA, pushes to registry
   │
   └── 6. Update Helm       commits new image tag into values.yaml
                            ArgoCD picks it up and deploys
```

**Woodpecker services** — declared in `.woodpecker.yml`, run as Docker containers alongside pipeline steps:

```yaml
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: testdb
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
  redis:
    image: redis:7

steps:
  - name: integration-tests
    image: python:3.14        # or node, go, etc.
    environment:
      DATABASE_URL: postgres://test:test@postgres:5432/testdb
      REDIS_URL: redis://redis:6379
    commands:
      - pytest tests/integration
```

Tests talk to real Postgres and Redis — no mocks, no test doubles for the DB layer. This catches the class of bugs that mocked tests miss.

**Code checks (step 1) — language dependent, but typically:**

| Check | What it catches |
|-------|----------------|
| Linter (ruff, eslint, etc.) | Style issues, obvious bugs |
| Formatter check (black, prettier) | Inconsistent formatting — fails if unformatted |
| Type checker (mypy, tsc) | Type errors caught before runtime |
| Security scan (trivy, bandit) | Known CVEs in dependencies, insecure patterns |

## Observability — How It Fits Together

```
App Cluster pods
   │
   ├── Fluent Bit (DaemonSet)  ──────→  Loki        ─→ Grafana
   │     ships stdout/stderr logs                         (DevOps cluster)
   │
   └── OTel collector (DaemonSet) ──→  Prometheus   ─→ Grafana
         ships metrics + traces
```

| Tool | Role |
|------|------|
| **Fluent Bit** | Tiny log shipper (~50MB/node), reads pod stdout, forwards to Loki |
| **OTel collector** | Collects metrics + traces from apps, forwards to Prometheus |
| **Loki** | Log storage + query engine (like Prometheus but for log lines) |
| **Prometheus** | Time-series metrics database, also scrapes K3s node metrics |
| **Grafana** | Single UI: dashboards over both Prometheus and Loki |

## Build Order

1. **VPC** ✅ done (NAT instance t4g.nano instead of NAT Gateway — ~$3/mo vs ~$35/mo)
2. **KMS + S3** ✅ done
3. **ECR** ✅ done (3 repos: api, web, worker; KMS-encrypted; lifecycle policy)
4. **DevOps cluster** ← next (2 x t4g.small, K3s, SSM agent via user_data, `devops-cluster-{env}` instance profile)
5. **Tailscale** (Kubernetes operator on DevOps cluster; join tailnet for UI access)
6. **Woodpecker CI + ArgoCD** (Helm on DevOps cluster; GitHub OAuth/SSO configured)
7. **App cluster** (2 x t4g.small, K3s, `app-cluster-{env}` instance profile, registered with ArgoCD)
8. **External Secrets Operator** (Helm on App cluster; connects to Secrets Manager)
9. **RDS Aurora + ElastiCache Redis + SQS** (data layer, isolated subnets)
10. **Loki + Prometheus + Grafana** (Helm on DevOps cluster; GitHub OAuth on Grafana)
11. **ALB + DNS** (route internet → App cluster ingress; ACM cert + HTTPS listener)
