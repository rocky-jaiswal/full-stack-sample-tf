# Full Stack Infra Project

Project for DevOps for any Full Stack Project

- Terraform / Terragrunt Project
- Multi module
- Multi environment project

## What I want

- AWS IAM Roles (creation, can be through Python script)
- Role can only do STS
- First - Create role which can do - create custom role
- Then - Create roles for TF / CI-CD
- Allow assumption of TF roles via STS only
- Allow assumption of CI-CD role via STS only
- VPC (public + private subnet)
- EKS
- Private Subnet
  - Servers
  - Auto Scaled
  - K3s containers cluster
- AWS Secret Manager - CMK -> Create Key for data encryption
- RDS (Aurora Cluster)
- S3
- SQS
- Redis (or AWS Redis flavor)
- Bastion server in public subnet (protect by TailScale?)
- Logging from container (Loki, OpenSearch dashboard [should be protected])
- Metrics (Opentelemetry) -> How to setup & view metrics
- Protect public subnet?
- Lambdas in private subnet (background jobs)
- How to setup apps (web in public subnet, applications / APIs in private subnet)
- CI / CD with Jenkins / Argo?
- ECR Registry setup?
- Helm?

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
| `cicd-{env}`      | IAM Role | ECR push, Secrets read, S3 artifacts (inline). Used by CI/CD pipelines.      |

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

[profile cicd-dev]
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/cicd-dev
source_profile = deployer
region = eu-central-1
```

**Then use with Terragrunt:** `AWS_PROFILE=tf-dev terragrunt plan`

**CI/CD auth:** Not decided yet. Trust policy currently allows the deployer user. Will add GitHub OIDC or Jenkins instance profile trust later.

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

### 3. Compute & CI/CD (EKS + CodeBuild + ArgoCD)

**Decision:** EKS (managed Kubernetes) instead of K3s. AWS CodeBuild for CI (build & push images). Managed ArgoCD (EKS Capability) for CD (GitOps deployment).

**Why EKS over K3s?** K3s is free but you self-manage everything — upgrades, patching, HA, networking plugins. EKS costs ~$73/month for the control plane but gives you managed Kubernetes with AWS-native integrations (IAM, ALB, EBS, Secrets Manager). For a production-realistic boilerplate, EKS is what you'd actually use at a company.

**CI/CD pipeline architecture:**

```
Code push to Git
       |
       v
AWS CodeBuild (CI)                      Managed ArgoCD (CD)
──────────────────────                  ──────────────────────
1. Build Docker image                   1. Watches Git repo continuously
2. Run tests                            2. Detects manifest changes
3. Push image to ECR                    3. Syncs cluster to match Git
4. Update K8s manifests in Git          4. Self-heals if cluster drifts
──────────────────────                  ──────────────────────
  Pay per build-minute                    ~$20/mo + $1/app/mo
```

**Why CodeBuild?** AWS-native, no infrastructure to manage, IAM role-based auth to ECR (no stored secrets), pay only when builds run. Natural fit since we're already all-in on AWS.

**Why managed ArgoCD (EKS Capability)?** Runs in the AWS control plane — not on our worker nodes. AWS handles scaling, upgrades, and HA. Native integration with ECR, Secrets Manager, and AWS Identity Center for SSO. Supports multi-cluster hub-and-spoke without VPC peering. See [AWS deep dive blog post](https://aws.amazon.com/blogs/containers/deep-dive-streamlining-gitops-with-amazon-eks-capability-for-argo-cd/).

**Why ArgoCD at all (vs just CodeBuild deploying directly)?** ArgoCD provides continuous GitOps reconciliation — it doesn't just deploy once, it _continuously_ compares the cluster to Git and self-heals drift. If someone runs a manual `kubectl edit` or a pod config changes, ArgoCD detects the difference and reverts it. Git stays the single source of truth at all times, not just at deploy time.

**Estimated monthly cost:**

| Component                | Cost                                                  |
| ------------------------ | ----------------------------------------------------- |
| EKS control plane        | ~$73                                                  |
| ArgoCD capability (base) | ~$20                                                  |
| ArgoCD per application   | ~$1/app                                               |
| CodeBuild                | Pay per build-minute (~$0.005/min for small instance) |
| **Platform overhead**    | **~$95 + build costs**                                |

Worker node costs (EC2/Fargate) are separate and depend on workload.

### 4. VPC (Networking)

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
│   ├── EKS worker nodes + app pods go here
│   └── Tagged: kubernetes.io/role/internal-elb = 1
│
└── Isolated subnets (10.0.128.0/19 + 10.0.160.0/19)
    ├── NO internet access (no route table)
    └── RDS, ElastiCache go here
```

**Why 3 tiers (public / private / isolated)?** The tutorial uses this pattern and it's best practice. Private subnets can reach the internet (outbound via NAT) — needed for EKS nodes to pull container images. Isolated subnets have zero internet access — databases don't need it, and removing the path entirely is stronger than just relying on security groups.

**Why 2 AZs?** EKS requires subnets in at least 2 AZs. eu-central-1 has 3 AZs, but 2 is enough for dev and keeps costs down (fewer subnets, one NAT). Can expand to 3 for production.

**Why single NAT Gateway?** A NAT Gateway costs ~$32/month + data processing. Production would have one per AZ for high availability, but for dev a single shared NAT is fine. If AZ-a goes down, private subnets in AZ-b lose outbound internet — acceptable for dev.

**Why EKS subnet tags?** The AWS Load Balancer Controller (installed later on EKS) uses these tags to auto-discover where to place load balancers:
- `kubernetes.io/role/elb = 1` → internet-facing ALBs go in public subnets
- `kubernetes.io/role/internal-elb = 1` → internal ALBs go in private subnets
- `kubernetes.io/cluster/app-eks-dev = owned` → this cluster owns these subnets

**Why no security groups in the VPC module?** Each downstream module (EKS, RDS, etc.) will create its own security groups. Keeps modules decoupled — the VPC module just provides the network plumbing.

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

### Networking & Compute

- **Bastion** — Tailscale mesh vs AWS SSM Session Manager vs traditional SSH bastion? Tailscale = no open ports. SSM = no keys, AWS-native. SSH bastion = simple but needs hardening.

### Application Layer

- **App topology** — Everything behind an ALB in private subnets? Or web/frontend in public, APIs in private? ALB-in-public + EKS-in-private is the typical pattern.
- **ECR** — Container registry. Simple module, no big decisions. Needed before EKS can pull images.
- **Helm** — For deploying apps onto EKS. Needed once EKS cluster is running.

### Data

- **RDS Aurora** — In isolated subnets, encrypted with our CMK. Straightforward.
- **SQS** — Message queue, private. Straightforward.
- **Redis (ElastiCache)** — In isolated subnets. Straightforward.

### Observability

- **Logging** — Loki (lightweight, free, runs on EKS) vs OpenSearch (powerful, AWS-managed, expensive). Loki + Grafana is the budget-friendly choice.
- **Metrics** — OpenTelemetry collector on EKS nodes. Send to where? Prometheus + Grafana on EKS (free) vs CloudWatch (AWS-managed, pay per metric).

### Priority Order

ECR is the next step — simple module, then EKS can follow.
