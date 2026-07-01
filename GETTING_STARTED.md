# Getting Started

This guide walks through everything needed to go from a fresh Linux machine + AWS root account to a working Terragrunt setup.

---

## Part 1 — AWS Console (do this first)

Log in to the AWS Console as root.

### 1. Create root access keys (temporary)

The bootstrap script must run as an AWS identity with permission to create IAM users and roles. The simplest path with root access:

> IAM → Security credentials → Access keys → **Create access key**

Save the **Access Key ID** and **Secret Access Key** somewhere safe. You will use them once to run the bootstrap script, then **delete them immediately after** — root access keys are high-risk to leave around.

### 2. Note your Account ID

Top-right corner of the console → your account name → copy the **Account ID** (12-digit number). The bootstrap script uses it to auto-name the state bucket (`tf-state-<account-id>-<env>`).

---

## Part 2 — Local machine setup

### 4. Install tools (can use brew also)

```bash
# OpenTofu (open-source Terraform fork)
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh

# Terragrunt
TGVER=$(curl -s https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest | grep tag_name | cut -d'"' -f4)
wget -O /tmp/terragrunt "https://github.com/gruntwork-io/terragrunt/releases/download/${TGVER}/terragrunt_linux_amd64"
chmod +x /tmp/terragrunt && sudo mv /tmp/terragrunt /usr/local/bin/

# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install

# uv (Python package manager, needed for the bootstrap script)
curl -LsSf https://astral.sh/uv/install.sh | sh

# kubectl (needed later when K3s clusters exist)
curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm (needed later for installing tools onto K3s)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# AWS Session Manager plugin (required for 'aws ssm start-session')
# For Fedora/Nobara/RHEL-based systems:
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o /tmp/session-manager-plugin.rpm
sudo dnf install -y /tmp/session-manager-plugin.rpm
# For Ubuntu/Debian:
# curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
# sudo dpkg -i /tmp/session-manager-plugin.deb
```

Verify:

```bash
tofu --version
terragrunt --version
aws --version
uv --version
```

### 5. Configure root credentials temporarily

```ini
# ~/.aws/credentials
[root-bootstrap]
aws_access_key_id     = <root access key from step 2>
aws_secret_access_key = <root secret key from step 2>
```

---

## Part 3 — Bootstrap IAM

### 6. Run all bootstrap commands (while root keys are active)

All three commands require root access. Run them before deleting the root keys.

```bash
cd scripts/
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py create-user
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py create-state-bucket --env dev
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py create-roles --env dev
```

`create-user` creates an IAM user called `deployer` with only `sts:AssumeRole` permission and prints access keys. **Save these immediately** — they are only shown once.

`create-state-bucket` creates the remote state bucket with versioning, encryption, and public access blocked. It prints the exact bucket name and the `root.hcl` snippet to paste — **copy that snippet and update `root.hcl` before running any Terragrunt commands**.

`create-roles` creates the `terraform-dev` IAM role (PowerUser + IAM permissions) that Terragrunt will assume via `sts:AssumeRole`.

### 7. Delete the root access keys

Back in the AWS Console:

> IAM → Security credentials → Access keys → **Delete**

Root access keys should not persist. All three bootstrap commands are done — you no longer need them.

### 8. Configure deployer credentials

Replace the root credentials with the deployer keys printed in step 6:

```ini
# ~/.aws/credentials
[deployer]
aws_access_key_id     = <deployer key from step 6>
aws_secret_access_key = <deployer secret from step 6>
```

```ini
# ~/.aws/config
[profile tf-dev]
role_arn       = arn:aws:iam::<ACCOUNT_ID>:role/terraform-dev
source_profile = deployer
region         = eu-central-1
```

---

## Part 4 — Verify

### 9. Run a Terragrunt plan

```bash
cd environments/dev/kms
AWS_PROFILE=tf-dev terragrunt plan
```

> **Note:** Always use `terragrunt plan`, not `tofu plan`. Terragrunt reads `terragrunt.hcl`, configures the remote backend, and then calls `tofu` internally. Running `tofu plan` directly skips all of that and will error.

If it prints a plan without credential errors — everything is wired up correctly.

---

## Teardown (when done)

```bash
cd scripts/

AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py destroy-roles --env dev
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py destroy-state-bucket --env dev
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py destroy-user
```

`destroy-state-bucket` deletes all object versions before removing the bucket — S3 will refuse to delete a versioned bucket that still has objects.

---

## What's next

See [PLAN.md](PLAN.md) for the full build order.

---

## Part 5 — Bootstrap DevOps cluster apps

Installs ArgoCD, Woodpecker CI, Loki, and kube-prometheus-stack (Prometheus + Grafana) on the DevOps cluster via Terragrunt (`modules/devops-cluster-apps/`).

### 1. Fetch the kubeconfig (one-time)

```bash
./scripts/get-kubeconfig.sh dev
# saves to ~/.kube/devops-cluster-dev
```

### 2. Start the K3s API tunnel (keep running during apply)

Open a separate terminal and leave it running:

```bash
./scripts/api-tunnel.sh dev
# SSM port-forward: localhost:6443 → K3s API
```

### 3. Create a GitHub OAuth App for Woodpecker

GitHub → Settings → Developer settings → OAuth Apps → **New OAuth App**

- Application name: `Woodpecker CI`
- Homepage URL: anything for now
- Authorization callback URL: `http://localhost:8081/authorize`

Save the **Client ID** and generate a **Client Secret**.

### 4. Run Terragrunt apply

> **Fish shell:** use `set -x` — the `KEY=VALUE command` prefix syntax is bash-only.

```fish
set -x TF_VAR_woodpecker_agent_secret (openssl rand -hex 32)
set -x TF_VAR_woodpecker_github_client_id <client-id>
set -x TF_VAR_woodpecker_github_client_secret <client-secret>
set -x AWS_PROFILE tf-dev
set -x KUBECONFIG /home/<you>/.kube/devops-cluster-dev

cd environments/dev/devops-cluster-apps
terragrunt apply
```

Takes ~10 minutes (ArgoCD and kube-prometheus-stack wait for all pods to be ready).

**Helm chart notes:**
- Woodpecker chart is OCI-based: `oci://ghcr.io/woodpecker-ci/helm/woodpecker` — the old `https://woodpecker-ci.org/helm` URL is dead.
- Loki v3+ requires `loki.schemaConfig` in values — already set in `helm-values/loki.yaml`.

### 5. Access the UIs

```bash
./scripts/tunnel.sh dev
```

Opens the K3s API tunnel and `kubectl port-forward` for all three services in one command.

| URL | Credentials |
|-----|-------------|
| `http://localhost:8080` ArgoCD | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| `http://localhost:8081` Woodpecker | Log in with GitHub |
| `http://localhost:8082` Grafana | admin / admin |

> **Future:** Tailscale operator on the DevOps cluster would give always-on access without running `tunnel.sh` each session. Deferred until a custom domain is available for the Woodpecker webhook URL.

---

## Part 6 — Bootstrap the App cluster

Provisions the App cluster (`modules/app-cluster/`) — 2 x t4g.medium K3s nodes where application workloads run, separate from the DevOps cluster.

### 1. Apply

```bash
cd environments/dev/app-cluster
AWS_PROFILE=tf-dev terragrunt apply
```

Takes ~1-2 minutes for both nodes to boot and join K3s.

### 2. Verify

```bash
./scripts/get-kubeconfig-app.sh dev
# saves to ~/.kube/app-cluster-dev

./scripts/api-tunnel-app.sh dev   # separate terminal, keep running
# then: KUBECONFIG=~/.kube/app-cluster-dev kubectl get nodes
```

Both nodes should show `Ready`.

> **Note:** the App cluster isn't registered with ArgoCD yet — that happens as part of Step 7 (hello-fastify) in [PLAN.md](PLAN.md), since it requires a `Secret` resource in `modules/devops-cluster-apps/`.
