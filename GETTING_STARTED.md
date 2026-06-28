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

### 4. Install tools

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

### 6. Create the deployer user and state bucket

```bash
cd scripts/
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py create-user
AWS_PROFILE=root-bootstrap uv run bootstrap_iam.py create-state-bucket --env dev
```

`create-user` creates an IAM user called `deployer` with only `sts:AssumeRole` permission and prints access keys. **Save these immediately** — they are only shown once.

`create-state-bucket` creates `tf-state-<account-id>-dev` with versioning, encryption, and public access blocked. It prints the exact bucket name and the `root.hcl` snippet to paste — **copy that snippet and update `root.hcl` before running any Terragrunt commands**.

### 7. Delete the root access keys

Back in the AWS Console:

> IAM → Security credentials → Access keys → **Delete**

Root access keys should not persist. From this point on, everything runs through the `deployer` user.

### 8. Configure deployer credentials

Replace the root credentials with the deployer keys:

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

### 9. Create the Terraform role

```bash
cd scripts/
uv run bootstrap_iam.py create-roles --env dev
```

This creates the `terraform-dev` IAM role (PowerUser + IAM permissions) that Terragrunt will assume via `sts:AssumeRole`.

---

## Part 4 — Verify

### 10. Run a Terragrunt plan

```bash
cd environments/dev/kms
AWS_PROFILE=tf-dev terragrunt plan
```

If it prints a plan without credential errors — everything is wired up correctly.

---

## Teardown (when done)

```bash
cd scripts/

uv run bootstrap_iam.py destroy-roles --env dev
uv run bootstrap_iam.py destroy-state-bucket --env dev
uv run bootstrap_iam.py destroy-user
```

`destroy-state-bucket` deletes all object versions before removing the bucket — S3 will refuse to delete a versioned bucket that still has objects.

---

## What's next

See [PLAN.md](PLAN.md) for the full build order.
