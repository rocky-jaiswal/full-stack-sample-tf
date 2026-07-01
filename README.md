# Full Stack Infra Project

A production-realistic AWS reference architecture for running a full-stack app end to end — infrastructure, CI/CD, observability, and secrets — built with Terraform (OpenTofu) + Terragrunt.

Multi-module, multi-environment, and deliberately cost-conscious: a complete hub-spoke Kubernetes platform for well under the price of a managed EKS control plane alone.

## What's Inside

- AWS IAM (bootstrap via Python/Boto3) — STS-only, no long-lived infra keys
- VPC — 3-tier (public / private / isolated) across 2 AZs
- Two K3s clusters (hub-spoke): DevOps cluster + App cluster
- KMS CMK per environment — encrypts S3, RDS, Secrets Manager
- RDS Aurora (PostgreSQL) — isolated subnet
- ElastiCache Redis — cache + sessions, isolated subnet
- SQS (or a resilient queue on Redis) — async job queues
- ECR — private container registry
- Woodpecker CI — builds images, pushes to ECR (do not rely on flaky GitHub CI)
- ArgoCD — GitOps CD, deploys Helm charts from Git to the App cluster
- Helm — standard packaging for all apps
- AWS Secrets Manager + External Secrets Operator — secrets delivered as K8s Secrets
- SSM Session Manager — cluster access, no bastion, no open ports
- Loki + Prometheus + Grafana - observability from day 1 on the DevOps cluster
- ALB — routes internet traffic into the App cluster ingress

## Structure

Terraform/Terragrunt, multi-module (`modules/`), multi-environment (`environments/<env>/`). Every environment wires the same modules together via Terragrunt `dependency` blocks — no copy-pasted HCL.

## Simple and modular Terragrunt usage

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

## Docs

- [GETTING_STARTED.md](GETTING_STARTED.md) — zero to a working Terragrunt setup
- [DESIGN.md](DESIGN.md) — decisions made, why, and open questions
- [PLAN.md](PLAN.md) — build order and what's left
