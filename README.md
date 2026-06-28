# Full Stack Infra Project

Project for DevOps for any Full Stack Project

- Terraform / Terragrunt Project
- Multi module
- Multi environment project

## What we want

- AWS IAM Roles (bootstrap via Python/Boto3 script) — STS-only, no long-lived infra keys
- VPC — 3-tier (public / private / isolated) across 2 AZs
- Two K3s clusters (hub-spoke): DevOps cluster + App cluster
- KMS CMK per environment — encrypts S3, RDS, Secrets Manager
- RDS Aurora (PostgreSQL) — isolated subnet
- ElastiCache Redis — cache + sessions, isolated subnet
- SQS (or donkeyq on Redis) — async job queues
- ECR — private container registry
- Woodpecker CI — builds images, pushes to ECR
- ArgoCD — GitOps CD, deploys Helm charts from Git to App cluster
- Helm — standard packaging for all apps/services
- AWS Secrets Manager + External Secrets Operator — secrets delivered as K8s Secrets
- SSM Session Manager — cluster access, no bastion, no open ports
- Loki + Prometheus + Grafana — observability on DevOps cluster
- ALB — routes internet traffic into App cluster ingress

## Terragrunt Usage

```bash
# Plan a single module
cd environments/dev/kms
AWS_PROFILE=tf-dev terragrunt plan

# Apply a single module
AWS_PROFILE=tf-dev terragrunt apply

# Plan all modules in dev
cd environments/dev
AWS_PROFILE=tf-dev terragrunt plan --all

# Apply specific modules only
AWS_PROFILE=tf-dev terragrunt plan --all --queue-include-dir=kms --queue-include-dir=s3
```

---

## Decisions & Design Notes

### 1. IAM Roles & STS

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

### 2. KMS + S3 (Encryption & Storage)

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

### 3. Access & Secret Management

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

---

### 4. Compute & CI/CD (K3s + Woodpecker CI + ArgoCD)

**Decision:** K3s on t3.medium EC2 instances (private subnets), hub-spoke: separate DevOps cluster and App cluster. Woodpecker CI for CI pipelines. Self-hosted ArgoCD on K3s for CD/GitOps. Apps packaged as Helm charts.

**Why K3s over EKS?** EKS charges ~$73/month just for the control plane, before a single node runs. K3s is a lightweight, fully conformant Kubernetes distribution that runs on regular EC2 instances at no additional cost. Two clusters of 2 x `t3.medium` (~$30/mo each) = ~$120/month total for both clusters — still cheaper than EKS control plane + nodes. Trade-off: you manage K3s upgrades yourself.

**Why Woodpecker CI?** Open-source, self-hosted on K3s, runs pipelines defined in `.woodpecker.yml` alongside your code. Native GitHub/Gitea webhooks, Docker-in-Docker builds, no per-minute billing. Runs as a pod on your cluster — no external service to pay for.

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

**Estimated monthly cost (cluster compute only):**

| Component | Cost |
|-----------|------|
| DevOps cluster: 2 x t3.medium | ~$60 |
| App cluster: 2 x t3.medium | ~$60 |
| Woodpecker CI + ArgoCD + PLG | $0 (runs on your nodes) |
| **Cluster total** | **~$120/mo** |

Compare to EKS: ~$73 control plane + node costs — K3s hub-spoke is cheaper and demonstrates a more realistic pattern.

### 5. VPC (Networking)

**Decision:** 3-tier VPC across 2 AZs in eu-central-1. Single NAT Gateway for dev (cost-saving). Based on [Anton Putra's EKS VPC tutorial](https://github.com/antonputra/tutorials/tree/main/lessons/256/1-terraform).

**VPC layout (`modules/vpc`):**

```
VPC 10.0.0.0/16 (eu-central-1)
│
├── Public subnets (10.0.0.0/19 + 10.0.32.0/19)
│   ├── Internet Gateway → full internet access
│   ├── NAT Gateway (single, in AZ-a)
│   ├── ALBs go here
│   └── Tagged: kubernetes.io/role/elb = 1
│
├── Private subnets (10.0.64.0/19 + 10.0.96.0/19)
│   ├── Outbound only via NAT Gateway
│   ├── K3s nodes (DevOps + App clusters) go here
│   └── Tagged: kubernetes.io/role/internal-elb = 1
│
└── Isolated subnets (10.0.128.0/19 + 10.0.160.0/19)
    ├── NO internet access (no route table)
    └── RDS, ElastiCache go here
```

**Why 3 tiers (public / private / isolated)?** Private subnets can reach the internet (outbound via NAT) — needed for K3s nodes to pull container images. Isolated subnets have zero internet access — databases don't need it, and removing the route entirely is stronger than relying on security groups alone.

**Why 2 AZs?** eu-central-1 has 3 AZs, but 2 is enough for dev and keeps costs down (fewer subnets, one NAT). Can expand to 3 for production.

**Why single NAT Gateway?** A NAT Gateway costs ~$32/month + data processing. Production would have one per AZ for high availability, but for dev a single shared NAT is fine. If AZ-a goes down, private subnets in AZ-b lose outbound internet — acceptable for dev.

**Why ALB subnet tags?** The AWS Load Balancer Controller uses these tags to auto-discover where to place load balancers:
- `kubernetes.io/role/elb = 1` → internet-facing ALBs go in public subnets
- `kubernetes.io/role/internal-elb = 1` → internal ALBs go in private subnets

**Why no security groups in the VPC module?** Each downstream module (K3s, RDS, etc.) will create its own security groups. Keeps modules decoupled — the VPC module just provides the network plumbing.

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

**Cost:** ~$32/month (NAT Gateway) + ~$3.60/month (Elastic IP) + data processing ($0.045/GB through NAT).

---

## Remaining Decisions (TODO)

### Application Layer

- **Ingress controller** — Traefik (ships with K3s, zero config) vs nginx-ingress. Traefik is the default choice unless we hit a limitation.
- **SQS vs donkeyq** — SQS for async jobs, or donkeyq (Redis Streams-based queue) since we already have ElastiCache. Decide when apps are being built.

### Build Order

1. **ECR** ← next
2. **DevOps cluster** (K3s, 2 x t3.medium, SSM agent via user_data, `devops-cluster-{env}` instance profile)
3. **Woodpecker CI + ArgoCD** (Helm on DevOps cluster)
4. **App cluster** (K3s, 2 x t3.medium, `app-cluster-{env}` instance profile, registered with ArgoCD)
5. **External Secrets Operator** (Helm on App cluster)
6. **RDS Aurora + ElastiCache Redis + SQS**
7. **Loki + Prometheus + Grafana** (Helm on DevOps cluster)
8. **ALB + DNS**
