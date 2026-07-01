# Design

The living record of decisions made on this project, why, and what's still open. This is where a build step's rationale lands once it's implemented — [PLAN.md](PLAN.md) only tracks what's left to build, so as PLAN.md shrinks, this file grows.

## Decisions Made

| Decision | Choice | Why |
|----------|--------|-----|
| Cluster topology | Hub-spoke: DevOps cluster + App cluster | Resource isolation, real enterprise pattern, ArgoCD designed for this |
| Kubernetes | K3s on t4g.medium ARM EC2 (private subnets) | No $73/mo control plane fee, lightweight, fully K8s-conformant |
| Node placement (multi-AZ) | Server in private-AZ-a, agent in private-AZ-b | Both cluster modules follow this pattern — spreads across AZs without needing 3 |
| OS / AMI (K3s + NAT nodes) | Amazon Linux 2023 ARM64 | K3s installs cleanly via curl installer; minimal image ships without `iptables`/`firewalld` — NAT instance uses `nftables` via `dnf` instead |
| CI | Woodpecker CI (on DevOps cluster) | OSS, Git-native `.woodpecker.yml`, no per-minute billing |
| CI image builds | Kaniko, not Docker-in-Docker | Builds OCI images from a Dockerfile without a Docker daemon — DinD needs `privileged: true`, a real security risk |
| CD | ArgoCD (on DevOps cluster) | GitOps reconciliation, hub-spoke multi-cluster native |
| App packaging | Helm charts | Standard K8s packaging — ArgoCD deploys Helm charts from Git |
| Logs | Loki (DevOps cluster) + Fluent Bit DaemonSet on App cluster | Free, OSS, runs on your cluster — no $50+/mo managed OpenSearch |
| Metrics | Prometheus + Grafana (DevOps cluster) | Free, OSS, scrapes App cluster remotely |
| Log + metrics retention | 90 days (Loki + Prometheus) | Configurable via Helm values; long enough to debug, bounded storage cost |
| Encryption | KMS CMK per env | One key for all services, ~$1/mo |
| Storage | S3 (KMS-encrypted, versioned) | Locked down, HTTPS-only |
| Cache | ElastiCache Redis (managed) | Cache + sessions, isolated subnet, no ops burden |
| DB connection pooling | RDS Proxy (managed) | Pools connections between pods and Aurora, handles failover; apps point at the Proxy endpoint, not Aurora directly |
| DB migrations | Run separately via `knex migrate:latest`, not on app startup | Keeps startup fast and deploys idempotent; must stay backward-compatible (expand-then-contract) since old + new pods overlap briefly during rolling updates — **flagging: PLAN.md previously said "runs on startup," which looks stale; confirm which is correct** |
| Queue | SQS (managed) | Async jobs, serverless, no ops burden |
| IAM (local → AWS) | STS role assumption via `deployer` user | No long-lived infra keys for Terraform |
| IAM (CI → AWS) | EC2 instance profile on DevOps cluster nodes | No credentials stored; Woodpecker inherits the role automatically |
| IAM (apps → AWS) | EC2 instance profile on App cluster nodes | ECR pull, Secrets Manager read, SQS, S3 |
| Secret delivery | External Secrets Operator + AWS Secrets Manager | Apps see plain K8s Secrets; ESO syncs from AWS |
| kubectl access | AWS SSM Session Manager | No SSH, no open ports, free; port-forward K3s API locally |
| UI access (Woodpecker, ArgoCD, Grafana) | SSM API tunnel + `kubectl port-forward`, one port per service | No `/etc/hosts`, no Traefik hostname routing needed |
| Woodpecker auth | GitHub OAuth | Users whitelisted via a GitHub OAuth app baked into Woodpecker |
| ArgoCD auth | GitHub SSO (OIDC) + RBAC | Read-only vs admin roles; no anonymous access |
| Grafana auth | GitHub OAuth (built-in) | Same pattern; restrict to your GitHub org/users |
| IaC | Terraform/Terragrunt (OpenTofu) | Multi-module, multi-env, DRY |
| EC2 node scaling | Manual instance count for v1 | Pod-level HPA covers most elasticity; ASG + Cluster Autoscaler deferred — see [Future Enhancements](PLAN.md#future-enhancements-deferred-by-design) |

---

## 1. IAM Roles & STS

**Decision:** Use a Python/Boto3 bootstrap script to create IAM roles. No long-lived access keys for infrastructure management.

**Architecture:**

```
~/.aws/credentials [deployer]       (long-lived keys, can ONLY do sts:AssumeRole)
        |
        v  sts:AssumeRole
~/.aws/config [profile tf-dev]      (temporary credentials, 1h expiry)
        |
        v  PowerUserAccess + IAM
   terraform-{env} role             (manages infrastructure)
```

**Resources created:**

| Resource          | Type     | Purpose                                                                      |
| ----------------- | -------- | ---------------------------------------------------------------------------- |
| `deployer`        | IAM User | Only permission: `sts:AssumeRole`. Source identity for all role assumptions. |
| `terraform-{env}` | IAM Role | PowerUserAccess + IAM management (inline). Used by Terragrunt.               |

**How role assumption actually works (the "double handshake"):**

An IAM Role has no password or access keys — you can't log in as a role. The only way to get a role's permissions is via `sts:AssumeRole`. Two things must be true for it to work:

1. **Trust policy (on the role):** "Who is allowed to assume me?" — our roles say "only the `deployer` user".
2. **Permission policy (on the caller):** "Is this caller allowed to call `sts:AssumeRole`?" — the `deployer` user has this as its only permission.

Both sides must agree. If either says no, the assumption fails.

When you run `AWS_PROFILE=tf-dev terragrunt plan`, the AWS SDK:

1. Reads the `deployer` access keys from `~/.aws/credentials`
2. Calls `sts:AssumeRole` on `arn:aws:iam::<ACCOUNT>:role/terraform-dev`
3. AWS checks both policies (double handshake) — both say yes
4. STS returns temporary credentials (access key + secret + session token, expires in 1h)
5. Terragrunt uses those temporary credentials with `PowerUserAccess + IAM` permissions

**Why a deployer user?** AWS root accounts cannot assume IAM roles (AWS security restriction). The `deployer` user has only `sts:AssumeRole` permission — even if its keys leak, an attacker can only request temporary credentials for roles that explicitly trust this user.

**Why STS?** No direct infrastructure access via long-lived keys. All actual work happens through scoped, temporary role credentials.

**Why PowerUser + inline IAM for TF?** PowerUserAccess covers all services _except_ IAM. The inline policy adds only the IAM actions Terraform needs (create/manage roles, policies, instance profiles, OIDC providers) — but not dangerous actions like creating IAM users with console access.

**Usage:**

```bash
cd scripts/

# Step 1: Create deployer user (once per AWS account, run as root)
uv run bootstrap_iam.py create-user
# -> Save the access keys to ~/.aws/credentials under [deployer]

# Step 2: Create roles for an environment
uv run bootstrap_iam.py create-roles --env dev

# Tear down
uv run bootstrap_iam.py destroy-roles --env dev
uv run bootstrap_iam.py destroy-user
```

**AWS CLI config (`~/.aws/config`):**

```ini
[profile tf-dev]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/terraform-dev
source_profile = deployer
region = eu-central-1
```

**Then use with Terragrunt:** `AWS_PROFILE=tf-dev terragrunt plan`

**CI/CD auth:** Woodpecker CI runs on the DevOps cluster EC2 nodes. Those nodes carry a dedicated IAM instance profile (`devops-cluster-{env}`) with ECR push + S3 artifact permissions. No credentials stored anywhere — the AWS SDK on the node picks up the instance profile automatically. The old `cicd-{env}` role (assumed via deployer) is retired.

**Multi-environment:** Single AWS account for now, environments separated by role names (`terraform-dev`, `terraform-prod`). Designed so it's easy to split into separate accounts later.

## 2. KMS + S3 (Encryption & Storage)

**Decision:** One Customer Managed Key (CMK) per environment. All services (S3, RDS, Secrets Manager, etc.) use this key. S3 buckets are fully locked down.

**KMS key (`modules/kms`):**

- Alias: `alias/app-eks-{env}`
- Auto-rotation: enabled (annually)
- Key policy: root account (fallback) + terraform role (admin & usage) + S3 service
- Cost: ~$1/month per key

**S3 bucket (`modules/s3`):**

- Encrypted at rest with the CMK (SSE-KMS with bucket key)
- Versioning enabled (accidental deletes are recoverable)
- All public access blocked
- Bucket policy enforces: KMS encryption on uploads + HTTPS-only access
- Depends on `kms` module via Terragrunt `dependency` block

**Why one CMK for everything?** Simplicity. One key per environment keeps costs low ($1/month) and is easy to manage. AWS services (S3, RDS, Secrets Manager) all support KMS. If you later need per-service keys for compliance, you can split.

**Why bucket policy enforcement?** The default encryption config handles _most_ uploads, but a bucket policy with `DenyUnencryptedUploads` + `DenyInsecureTransport` catches edge cases and satisfies security audits.

## 3. Access & Secret Management

**Four distinct access problems and how each is solved:**

#### Problem 1: You (locally) → AWS to run Terraform
Already solved. `deployer` user → `sts:AssumeRole` → `terraform-{env}` role. No changes.

#### Problem 2: Woodpecker CI → AWS (push to ECR, read/write S3)
**Decision:** EC2 Instance Profile on DevOps cluster nodes (`devops-cluster-{env}` role).

Woodpecker runs as a pod on the DevOps cluster EC2 nodes. The instance profile is attached to the node — the AWS SDK picks it up automatically. No credentials stored, nothing to rotate.

Permissions on `devops-cluster-{env}`:
- ECR: push images, create repositories
- S3: read/write build artifacts
- Secrets Manager: read (for pipeline secrets)

#### Problem 3: Apps → AWS services (DB credentials, API keys, SQS, S3)
**Decision:** External Secrets Operator (ESO) + AWS Secrets Manager.

ESO runs as a pod on the App cluster. It reads secrets from Secrets Manager and creates standard K8s Secrets. Your app pods just mount a K8s Secret — they never talk to AWS directly.

```
AWS Secrets Manager  →  ESO (pod on App cluster)  →  K8s Secret  →  your app pod (env var)
```

App cluster nodes carry an instance profile (`app-cluster-{env}`) with:
- Secrets Manager: read
- ECR: pull images (read-only)
- SQS: send/receive messages
- S3: scoped read/write for app data

#### Problem 4: You → kubectl against both clusters
**Decision:** AWS SSM Session Manager. No SSH, no open ports, no bastion server.

SSM agent installed on EC2 nodes via Terraform `user_data`. To access kubectl locally:

```bash
# Port-forward K3s API through SSM tunnel
aws ssm start-session --target i-<node-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'

# Then in another terminal
kubectl --server=https://localhost:6443 get pods
```

Free, AWS-native, satisfies security requirements (no inbound ports open anywhere).

**Full IAM role summary:**

| Role / Identity | Used by | Key permissions |
|----------------|---------|----------------|
| `deployer` IAM user | You, locally | `sts:AssumeRole` only |
| `terraform-{env}` role | Terragrunt (via deployer) | PowerUser + scoped IAM |
| `devops-cluster-{env}` instance profile | DevOps cluster EC2 nodes | ECR push, S3 artifacts |
| `app-cluster-{env}` instance profile | App cluster EC2 nodes | ECR pull, Secrets Manager read, SQS, S3 |

## 4. Compute & CI/CD (K3s + Woodpecker CI + ArgoCD)

**Decision:** K3s on t4g.medium ARM EC2 instances (private subnets), hub-spoke: separate DevOps cluster and App cluster. Woodpecker CI for CI pipelines. Self-hosted ArgoCD on K3s for CD/GitOps. Apps packaged as Helm charts.

**Why K3s over EKS?** EKS charges ~$73/month just for the control plane, before a single node runs. K3s is a lightweight, fully conformant Kubernetes distribution that runs on regular EC2 instances at no additional cost. Two clusters of 2 x `t4g.medium` (~$24/mo each) = ~$48/month total for both clusters' compute — still cheaper than an EKS control plane alone. Trade-off: you manage K3s upgrades yourself.

**Why Woodpecker CI?** Open-source, self-hosted on K3s, runs pipelines defined in `.woodpecker.yml` alongside your code. Native GitHub/Gitea webhooks, no per-minute billing. Runs as a pod on your cluster — no external service to pay for. Chart is OCI-based: `oci://ghcr.io/woodpecker-ci/helm/woodpecker` (the old `https://woodpecker-ci.org/helm` URL is dead).

**CI/CD pipeline architecture:**

```
Code push to GitHub
       |
       v
Woodpecker CI (on K3s)                  ArgoCD (on K3s, CD)
──────────────────────                  ──────────────────────
1. Build Docker image                   1. Watches Git repo continuously
2. Run tests                            2. Detects Helm chart/values change
3. Push image to ECR                    3. helm upgrade on K3s cluster
4. Update image tag in                  4. Self-heals if cluster drifts
   Helm values.yaml (Git commit)        ──────────────────────
──────────────────────                    Free (runs on your cluster)
  Free (runs on your cluster)
```

**Why ArgoCD for CD?** ArgoCD provides continuous GitOps reconciliation — it doesn't just deploy once, it _continuously_ compares the cluster state to Git and self-heals drift. If someone runs a manual `kubectl edit`, ArgoCD detects and reverts it. Git is always the source of truth. Self-hosted on K3s means no add-on fees.

**Why Helm charts for apps?** Helm is the standard way to package Kubernetes applications — templated YAML with environment-specific values files. ArgoCD natively understands Helm: point it at a chart + a `values.yaml`, and it handles `helm upgrade --install` on every sync.

### CI Pipeline Stages (Woodpecker)

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
   ├── 4. docker build      builds the production image via Kaniko
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

**Why Kaniko for builds?** Docker-in-Docker (DinD) needs `privileged: true` on the pod — a significant security risk. Kaniko builds OCI images from a Dockerfile without a Docker daemon, no privileged mode needed. It reads ECR auth from the EC2 instance profile automatically.

**Estimated monthly cost (cluster compute only):**

| Component | Cost |
|-----------|------|
| DevOps cluster: 2 x t4g.medium (ARM) | ~$24 |
| App cluster: 2 x t4g.medium (ARM) | ~$24 |
| Woodpecker CI + ArgoCD + PLG | $0 (runs on your nodes) |
| **Cluster total** | **~$48/mo** |

> t4g.medium (2GB RAM, ARM) is the dev choice — cheap but workable with conservative resource requests. Can bump to t3.medium (4GB) if the DevOps stack starts thrashing memory.

## 5. VPC (Networking)

**Decision:** 3-tier VPC across 2 AZs in eu-central-1. Single NAT instance (t4g.nano, ~$3/mo) instead of NAT Gateway (~$35/mo) for dev cost savings.

**VPC layout (`modules/vpc`):**

```
VPC 10.0.0.0/16 (eu-central-1)
│
├── Public subnets (10.0.0.0/19 + 10.0.32.0/19)
│   ├── Internet Gateway → full internet access
│   ├── NAT instance (t4g.nano AL2023, single, in AZ-a)
│   ├── ALBs go here
│   └── Tagged: kubernetes.io/role/elb = 1
│
├── Private subnets (10.0.64.0/19 + 10.0.96.0/19)
│   ├── Outbound only via NAT instance
│   ├── K3s nodes (DevOps + App clusters) go here
│   └── Tagged: kubernetes.io/role/internal-elb = 1
│
└── Isolated subnets (10.0.128.0/19 + 10.0.160.0/19)
    ├── NO internet access (explicit empty route table)
    └── RDS, ElastiCache go here
```

**Why 3 tiers (public / private / isolated)?** Private subnets can reach the internet (outbound via NAT) — needed for K3s nodes to pull container images. Isolated subnets have zero internet access — databases don't need it, and removing the route entirely is stronger than relying on security groups alone.

**Why 2 AZs?** eu-central-1 has 3 AZs, but 2 is enough for dev and keeps costs down (fewer subnets, one NAT). Can expand to 3 for production.

**Why NAT instance instead of NAT Gateway?** NAT Gateway costs ~$35/month regardless of traffic. A t4g.nano EC2 instance running Amazon Linux 2023 with nftables masquerade does the same job for ~$3/month. Single point of failure is acceptable for dev. The instance has `source_dest_check = false` (required for packet forwarding) and a security group allowing inbound from the VPC CIDR only. Note: AL2023 minimal AMI ships without `iptables` or `firewalld` — the user_data installs `nftables` via dnf (NAT instance has direct internet access through the IGW). It also uses `ens5`, not `eth0`, as the interface name.

**Why ALB subnet tags?** The AWS Load Balancer Controller uses these tags to auto-discover where to place load balancers:
- `kubernetes.io/role/elb = 1` → internet-facing ALBs go in public subnets
- `kubernetes.io/role/internal-elb = 1` → internal ALBs go in private subnets

**Why no security groups in the VPC module?** Each downstream module (K3s, RDS, etc.) creates its own security groups. Keeps modules decoupled — the VPC module just provides the network plumbing.

**CIDR allocation (/19 = 8,190 IPs each):**

| Subnet | CIDR | AZ | IPs |
|--------|------|----|-----|
| Public AZ-a | 10.0.0.0/19 | eu-central-1a | 8,190 |
| Public AZ-b | 10.0.32.0/19 | eu-central-1b | 8,190 |
| Private AZ-a | 10.0.64.0/19 | eu-central-1a | 8,190 |
| Private AZ-b | 10.0.96.0/19 | eu-central-1b | 8,190 |
| Isolated AZ-a | 10.0.128.0/19 | eu-central-1a | 8,190 |
| Isolated AZ-b | 10.0.160.0/19 | eu-central-1b | 8,190 |
| **Remaining** | 10.0.192.0/18 | — | 16,382 (future use) |

**Cost:** ~$3/month (t4g.nano NAT instance) + data processing ($0.045/GB through NAT).

## 6. DevOps Cluster UI Access (SSM tunnel + kubectl port-forward)

**Decision:** SSM port-forward to K3s API (port 6443), then `kubectl port-forward` directly to each service on distinct localhost ports. No `/etc/hosts`, no Traefik hostname routing.

**Pattern:**
```
Your laptop
  │  scripts/tunnel.sh dev
  │
  ├── SSM port-forward 6443 → K3s API (background)
  │
  ├── kubectl port-forward localhost:8080 → svc/argocd-server (argocd ns)
  ├── kubectl port-forward localhost:8081 → svc/woodpecker-server (woodpecker ns)
  └── kubectl port-forward localhost:8082 → svc/kube-prometheus-stack-grafana (monitoring ns)
```

**Usage:** `./scripts/tunnel.sh dev` — finds the server node by tag, opens everything. All UIs accessible at `http://localhost:<port>` while the script is running.

**Why not Traefik + /etc/hosts?** /etc/hosts is a manual, undocumented step that breaks silently. Direct port-forwards need no hostname routing and work the same way regardless of what ingress controller is installed.

**Future:** Tailscale operator would replace the manual tunnel with always-on access via WireGuard. Deferred until a public domain is available for Woodpecker webhook callbacks.

## 7. Observability

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

Loki requires `loki.schemaConfig` set explicitly in Helm values (a v3+ chart requirement).

---

## Open Questions

| Question | Options | Notes |
|----------|---------|-------|
| Ingress controller | Traefik (K3s default) vs nginx | Traefik requires no extra install — default unless we hit a limit |
| ALB → K3s routing | NodePort (simple) vs AWS Load Balancer Controller on K3s (SOTA) | NodePort: ALB target group points to Traefik NodePort on each node. LBC: same controller EKS uses, creates ALBs from Ingress annotations but needs extra IAM. Decide at ALB step. |
| Queue implementation | SQS vs donkeyq on ElastiCache | Decide when building apps; donkeyq avoids an extra AWS service |
