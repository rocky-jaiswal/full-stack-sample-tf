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
| Queue | SQS (managed) | Async jobs, serverless, no ops burden |
| IAM (local → AWS) | STS role assumption via `deployer` user | No long-lived infra keys for Terraform |
| IAM (CI → AWS) | EC2 instance profile on DevOps cluster nodes | No credentials stored; Woodpecker inherits role automatically |
| IAM (apps → AWS) | EC2 instance profile on App cluster nodes | ECR pull, Secrets Manager read, SQS, S3 |
| Secret delivery | External Secrets Operator + AWS Secrets Manager | Apps see plain K8s Secrets; ESO syncs from AWS |
| Cluster access | AWS SSM Session Manager | No SSH, no open ports, free; port-forward K3s API locally |
| IaC | Terraform/Terragrunt (OpenTofu) | Multi-module, multi-env, DRY |

## Still Undecided

| Decision | Options | Notes |
|----------|---------|-------|
| Ingress controller | Traefik (K3s default) vs nginx | Traefik requires no extra install — default unless we hit a limit |
| ALB → K3s routing | NodePort (simple) vs AWS Load Balancer Controller on K3s (SOTA) | NodePort: ALB target group points to Traefik NodePort on each node. LBC: same controller EKS uses, creates ALBs from Ingress annotations but needs extra IAM. Decide at ALB step. |
| Queue implementation | SQS vs donkeyq on ElastiCache | Decide when building apps; donkeyq avoids an extra AWS service |

## Known Gaps (address at the relevant build step)

| Gap | Severity | Address at |
|-----|----------|-----------|
| **TLS / HTTPS** | Critical | ALB + DNS step — need ACM certificate + HTTPS listener on ALB (port 443), ALB forwards HTTP internally to K3s |
| **ALB → K3s routing mechanism** | Critical | ALB + DNS step — NodePort vs AWS LBC decision above |
| **Secret rotation + pod restart** | High | ESO step — install Reloader (watches K8s Secrets, triggers rolling restarts when values change; one Helm install on App cluster) |
| **Multi-AZ node placement** | High | K3s cluster Terraform — pin one node per AZ via subnet assignment so a single AZ failure doesn't kill the cluster |
| **Alerting** | Medium | After Grafana is running — configure Grafana alert rules + notification channel (Slack / email) for error rate spikes, pod crashes, high latency |
| **Woodpecker → GitHub write access** | Medium | Before first CI run — GitHub token with repo write access; stored in Secrets Manager → ESO → K8s Secret → Woodpecker pipeline secret |

## Estimated Monthly Cost

| Component | Detail | Cost |
|-----------|--------|------|
| DevOps cluster | 2 x t3.medium | ~$60 |
| App cluster | 2 x t3.medium | ~$60 |
| RDS Aurora | Smallest instance | ~$35 |
| ElastiCache Redis | cache.t3.micro | ~$15 |
| ECR + S3 + KMS | Minimal usage | ~$5 |
| NAT Gateway | Single (dev) | ~$35 |
| **Total** | | **~$210/mo** |

> NAT Gateway is the surprise cost. Can reduce by using VPC endpoints for ECR/S3 (free tier after initial setup).

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

1. **VPC** ✅ done
2. **KMS + S3** ✅ done
3. **ECR** ← next (container registry; needed before any cluster can pull images)
4. **DevOps cluster** (2 x t3.medium, K3s, SSM agent via user_data, `devops-cluster-{env}` instance profile)
5. **Woodpecker CI + ArgoCD** (Helm on DevOps cluster)
6. **App cluster** (2 x t3.medium, K3s, `app-cluster-{env}` instance profile, registered with ArgoCD)
7. **External Secrets Operator** (Helm on App cluster; connects to Secrets Manager)
8. **RDS Aurora + ElastiCache Redis + SQS** (data layer, isolated subnets)
9. **Loki + Prometheus + Grafana** (Helm on DevOps cluster)
10. **ALB + DNS** (route internet → App cluster ingress)
