# Full Stack — End-to-End Architecture

```
YOU (developer)
 |
 |  git push
 v
┌─────────────────────────────────────────────────────────────────────┐
│  GIT REPO (GitHub / CodeCommit)                                     │
│  - Application code + Dockerfile                                    │
│  - K8s manifests / Helm charts (could be same or separate repo)     │
│  - Terraform/Terragrunt infra code (this repo)                      │
└────────────┬────────────────────────────────┬───────────────────────┘
             │ webhook triggers               │ ArgoCD watches
             v                                v
┌────────────────────────┐     ┌─────────────────────────────────────┐
│  AWS CodeBuild (CI)    │     │  Managed ArgoCD — EKS Capability(CD)│
│                        │     │                                     │
│  1. Pull source code   │     │  1. Polls Git for manifest changes  │
│  2. Run tests          │     │  2. Compares Git vs cluster state   │
│  3. docker build       │     │  3. Syncs: applies diff to EKS     │
│  4. Push image → ECR   │────>│  4. Continuous reconciliation loop  │
│  5. Update manifests   │     │     (self-heals drift)              │
│     in Git (new tag)   │     │                                     │
└────────────────────────┘     └──────────────┬──────────────────────┘
                                              │ deploys to
                                              v
┌─────────────────────────────────────────────────────────────────────┐
│  VPC (eu-central-1)                                                 │
│                                                                     │
│  ┌─── Public Subnets ────────────────────────────────────────────┐  │
│  │  ALB (Application Load Balancer)  ←── internet traffic        │  │
│  │  NAT Gateway (outbound for private subnets)                   │  │
│  └───────────────────────────┬───────────────────────────────────┘  │
│                              │                                      │
│  ┌─── Private Subnets ──────┴───────────────────────────────────┐  │
│  │                                                               │  │
│  │  ┌─ EKS Cluster ──────────────────────────────────────────┐  │  │
│  │  │                                                         │  │  │
│  │  │  ┌── Your Apps ──────┐  ┌── Observability Stack ─────┐ │  │  │
│  │  │  │ web frontend      │  │ Grafana (dashboards + logs)│ │  │  │
│  │  │  │ API services      │  │ Prometheus (metrics)       │ │  │  │
│  │  │  │ background workers│  │ Loki (log aggregation)     │ │  │  │
│  │  │  └──────────────────-┘  │ OTel collector (traces)    │ │  │  │
│  │  │                         └────────────────────────────-┘ │  │  │
│  │  └─────────────────────────────────────────────────────────┘  │  │
│  │                                                               │  │
│  │  ┌── Data Layer ──────────────────────────────────────────┐  │  │
│  │  │ RDS Aurora (PostgreSQL, encrypted with CMK)            │  │  │
│  │  │ ElastiCache Redis                                      │  │  │
│  │  │ SQS queues                                             │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌── Shared Services ───────────────────────────────────────────┐  │
│  │ ECR (container images)          KMS (CMK per env)            │  │
│  │ S3 (artifacts/data)             Secrets Manager               │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## The Full Lifecycle

| Step | What happens | Tool |
|------|-------------|------|
| 1. Write code | You push to Git | Git |
| 2. Build & test | CodeBuild runs tests, builds Docker image | CodeBuild |
| 3. Store image | Image pushed to ECR with new tag | ECR |
| 4. Update manifests | CodeBuild commits new image tag to manifests repo | Git |
| 5. Deploy | ArgoCD detects change, syncs to EKS | Managed ArgoCD |
| 6. Route traffic | ALB routes internet → your pods in private subnets | ALB + EKS |
| 7. App runs | Pods talk to RDS, Redis, SQS, S3 — all in private subnets | EKS |
| 8. Something breaks | Logs → Loki, Metrics → Prometheus, Traces → OTel | Grafana dashboards |
| 9. You debug | `kubectl logs/exec` via EKS, Grafana dashboards, or SSM to nodes | kubectl / Grafana |
| 10. You fix | Push fix → steps 2-6 repeat automatically | The whole pipeline |

## Decisions Made

| Decision | Choice | Why |
|----------|--------|-----|
| Kubernetes | EKS (managed) | AWS-native integrations, managed control plane, enables managed ArgoCD |
| CI | AWS CodeBuild | AWS-native, no infra to manage, pay per build-minute |
| CD | Managed ArgoCD (EKS Capability) | GitOps with continuous reconciliation, runs in AWS control plane |
| Encryption | KMS CMK per env | One key for all services, $1/mo, simple |
| Storage | S3 (KMS-encrypted) | Versioned, locked down, HTTPS-only |
| IAM | STS role assumption | No long-lived infra keys, deployer user can only assume roles |
| IaC | Terraform/Terragrunt (OpenTofu) | Multi-module, multi-env, DRY config |

## Still Undecided

| Decision | Options | Notes |
|----------|---------|-------|
| VPC layout | AZ count, single vs multi NAT | Next to build — unlocks everything |
| Bastion/access | SSM vs Tailscale | SSM = AWS-native, Tailscale = no open ports |
| Observability | Loki+Grafana vs CloudWatch | Leaning Loki+Grafana (free, runs on EKS) |
| Git hosting | GitHub vs CodeCommit | Affects CodeBuild webhook + ArgoCD source config |

## Build Order

1. **VPC** ← next
2. ECR
3. EKS
4. RDS Aurora + ElastiCache + SQS
5. CodeBuild
6. Managed ArgoCD
7. Observability (Loki + Prometheus + Grafana + OTel)
8. ALB + DNS
