"""
Bootstrap IAM and S3 state bucket for Terraform.

Step 1: Creates a 'deployer' IAM user with ONLY sts:AssumeRole permission.
Step 2: Creates per-environment roles that the deployer user can assume:
  - terraform-{env}  -- Used by Terragrunt/Terraform to manage infrastructure
Step 3: Creates the S3 bucket used by Terragrunt to store remote state.

Note: CI/CD auth (Woodpecker) and app auth use EC2 instance profiles created
by Terraform, not this script.

Usage:
  cd scripts/

  # First time (run once per AWS account, as root):
  uv run bootstrap_iam.py create-user
  uv run bootstrap_iam.py create-state-bucket --env dev

  # Then: create roles for an environment
  uv run bootstrap_iam.py create-roles --env dev

  # Tear down
  uv run bootstrap_iam.py destroy-roles --env dev
  uv run bootstrap_iam.py destroy-state-bucket --env dev
  uv run bootstrap_iam.py destroy-user
"""

import argparse
import hashlib
import json
import sys

import boto3
from botocore.exceptions import ClientError

DEPLOYER_USER_NAME = "deployer"

# ---------------------------------------------------------------------------
# Policies
# ---------------------------------------------------------------------------

TERRAFORM_MANAGED_POLICIES = [
    "arn:aws:iam::aws:policy/PowerUserAccess",
]

TERRAFORM_IAM_INLINE_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowIAMManagement",
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:DeleteRole",
                "iam:GetRole",
                "iam:ListRoles",
                "iam:TagRole",
                "iam:UntagRole",
                "iam:UpdateRole",
                "iam:PassRole",
                "iam:CreatePolicy",
                "iam:DeletePolicy",
                "iam:GetPolicy",
                "iam:GetPolicyVersion",
                "iam:ListPolicies",
                "iam:ListPolicyVersions",
                "iam:CreatePolicyVersion",
                "iam:DeletePolicyVersion",
                "iam:AttachRolePolicy",
                "iam:DetachRolePolicy",
                "iam:PutRolePolicy",
                "iam:DeleteRolePolicy",
                "iam:GetRolePolicy",
                "iam:ListRolePolicies",
                "iam:ListAttachedRolePolicies",
                "iam:CreateInstanceProfile",
                "iam:DeleteInstanceProfile",
                "iam:GetInstanceProfile",
                "iam:AddRoleToInstanceProfile",
                "iam:RemoveRoleFromInstanceProfile",
                "iam:ListInstanceProfilesForRole",
                "iam:CreateOpenIDConnectProvider",
                "iam:DeleteOpenIDConnectProvider",
                "iam:GetOpenIDConnectProvider",
                "iam:TagOpenIDConnectProvider",
            ],
            "Resource": "*",
        },
    ],
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def get_caller_identity(sts_client):
    identity = sts_client.get_caller_identity()
    return {
        "account_id": identity["Account"],
        "arn": identity["Arn"],
    }


def build_trust_policy(account_id: str, deployer_user_arn: str) -> dict:
    """Trust policy: only the deployer user can assume this role via STS."""
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AllowDeployerAssume",
                "Effect": "Allow",
                "Principal": {"AWS": deployer_user_arn},
                "Action": "sts:AssumeRole",
            },
        ],
    }


def create_role(
    iam_client,
    role_name: str,
    trust_policy: dict,
    managed_policy_arns: list[str] | None = None,
    inline_policy_name: str | None = None,
    inline_policy_doc: dict | None = None,
    env: str = "dev",
):
    try:
        iam_client.get_role(RoleName=role_name)
        print(f"  Role '{role_name}' already exists, updating trust policy...")
        iam_client.update_assume_role_policy(
            RoleName=role_name,
            PolicyDocument=json.dumps(trust_policy),
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            print(f"  Creating role '{role_name}'...")
            iam_client.create_role(
                RoleName=role_name,
                AssumeRolePolicyDocument=json.dumps(trust_policy),
                Description=f"Managed by bootstrap script - env: {env}",
                Tags=[
                    {"Key": "Environment", "Value": env},
                    {"Key": "ManagedBy", "Value": "bootstrap-script"},
                ],
            )
        else:
            raise

    for policy_arn in managed_policy_arns or []:
        print(f"  Attaching managed policy: {policy_arn}")
        iam_client.attach_role_policy(RoleName=role_name, PolicyArn=policy_arn)

    if inline_policy_name and inline_policy_doc:
        print(f"  Putting inline policy: {inline_policy_name}")
        iam_client.put_role_policy(
            RoleName=role_name,
            PolicyName=inline_policy_name,
            PolicyDocument=json.dumps(inline_policy_doc),
        )


def destroy_role(iam_client, role_name: str):
    try:
        iam_client.get_role(RoleName=role_name)
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            print(f"  Role '{role_name}' does not exist, skipping.")
            return
        raise

    attached = iam_client.list_attached_role_policies(RoleName=role_name)
    for policy in attached["AttachedPolicies"]:
        print(f"  Detaching: {policy['PolicyArn']}")
        iam_client.detach_role_policy(RoleName=role_name, PolicyArn=policy["PolicyArn"])

    inline = iam_client.list_role_policies(RoleName=role_name)
    for policy_name in inline["PolicyNames"]:
        print(f"  Deleting inline policy: {policy_name}")
        iam_client.delete_role_policy(RoleName=role_name, PolicyName=policy_name)

    print(f"  Deleting role '{role_name}'...")
    iam_client.delete_role(RoleName=role_name)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_create_user(iam_client, sts_client):
    """Create the deployer IAM user with only sts:AssumeRole permission."""
    identity = get_caller_identity(sts_client)
    account_id = identity["account_id"]
    print(f"\n--- Creating deployer user (account: {account_id}) ---\n")

    # Create user
    try:
        iam_client.get_user(UserName=DEPLOYER_USER_NAME)
        print(f"  User '{DEPLOYER_USER_NAME}' already exists.")
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            print(f"  Creating user '{DEPLOYER_USER_NAME}'...")
            iam_client.create_user(
                UserName=DEPLOYER_USER_NAME,
                Tags=[{"Key": "ManagedBy", "Value": "bootstrap-script"}],
            )
        else:
            raise

    # Attach inline policy: only sts:AssumeRole
    sts_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AllowAssumeRole",
                "Effect": "Allow",
                "Action": "sts:AssumeRole",
                "Resource": f"arn:aws:iam::{account_id}:role/*",
            },
        ],
    }
    print("  Attaching STS-only inline policy...")
    iam_client.put_user_policy(
        UserName=DEPLOYER_USER_NAME,
        PolicyName="sts-assume-role-only",
        PolicyDocument=json.dumps(sts_policy),
    )

    # Create access keys (only if none exist)
    existing_keys = iam_client.list_access_keys(UserName=DEPLOYER_USER_NAME)
    if existing_keys["AccessKeyMetadata"]:
        print("  Access keys already exist. Not creating new ones.")
        print("  (To rotate: delete existing keys in AWS Console, then re-run)")
        print(f"""
--- Done! ---

User '{DEPLOYER_USER_NAME}' exists with access keys.
If you need to see the keys again, delete them in AWS Console and re-run this command.
""")
        return

    print("  Creating access keys...")
    keys = iam_client.create_access_key(UserName=DEPLOYER_USER_NAME)
    access_key = keys["AccessKey"]["AccessKeyId"]
    secret_key = keys["AccessKey"]["SecretAccessKey"]

    print(f"""
--- Done! ---

User created: {DEPLOYER_USER_NAME}
  ARN: arn:aws:iam::{account_id}:user/{DEPLOYER_USER_NAME}

Access keys (SAVE THESE - they won't be shown again):
  Access Key ID:     {access_key}
  Secret Access Key: {secret_key}

Add to ~/.aws/credentials:

  [deployer]
  aws_access_key_id = {access_key}
  aws_secret_access_key = {secret_key}

Then update ~/.aws/config profiles to use source_profile = deployer:

  [profile tf-dev]
  role_arn = arn:aws:iam::{account_id}:role/terraform-dev
  source_profile = deployer
  region = eu-central-1
""")


def cmd_destroy_user(iam_client):
    """Delete the deployer user and all associated resources."""
    print("\n--- Destroying deployer user ---\n")

    try:
        iam_client.get_user(UserName=DEPLOYER_USER_NAME)
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            print(f"  User '{DEPLOYER_USER_NAME}' does not exist.")
            return
        raise

    # Delete access keys
    keys = iam_client.list_access_keys(UserName=DEPLOYER_USER_NAME)
    for key in keys["AccessKeyMetadata"]:
        print(f"  Deleting access key: {key['AccessKeyId']}")
        iam_client.delete_access_key(
            UserName=DEPLOYER_USER_NAME, AccessKeyId=key["AccessKeyId"]
        )

    # Delete inline policies
    policies = iam_client.list_user_policies(UserName=DEPLOYER_USER_NAME)
    for name in policies["PolicyNames"]:
        print(f"  Deleting inline policy: {name}")
        iam_client.delete_user_policy(UserName=DEPLOYER_USER_NAME, PolicyName=name)

    print(f"  Deleting user '{DEPLOYER_USER_NAME}'...")
    iam_client.delete_user(UserName=DEPLOYER_USER_NAME)
    print("\nDone. User destroyed.")


def cmd_create_roles(iam_client, sts_client, env: str):
    """Create the terraform role for the given environment."""
    identity = get_caller_identity(sts_client)
    account_id = identity["account_id"]
    deployer_arn = f"arn:aws:iam::{account_id}:user/{DEPLOYER_USER_NAME}"

    # Verify deployer user exists
    try:
        iam_client.get_user(UserName=DEPLOYER_USER_NAME)
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            print(f"\nError: User '{DEPLOYER_USER_NAME}' not found.")
            print("Run 'create-user' first.")
            sys.exit(1)
        raise

    tf_role_name = f"terraform-{env}"

    print(f"\n--- Creating roles for env: {env} ---")
    print(f"  Account:  {account_id}")
    print(f"  Trusted:  {deployer_arn}")
    print()

    trust_policy = build_trust_policy(account_id, deployer_arn)

    print(f"[1/1] Terraform role: {tf_role_name}")
    create_role(
        iam_client,
        role_name=tf_role_name,
        trust_policy=trust_policy,
        managed_policy_arns=TERRAFORM_MANAGED_POLICIES,
        inline_policy_name="terraform-iam-management",
        inline_policy_doc=TERRAFORM_IAM_INLINE_POLICY,
        env=env,
    )

    print(f"""
--- Done! ---

Role created:
  {tf_role_name} -> arn:aws:iam::{account_id}:role/{tf_role_name}

Trusts: {deployer_arn}

Use with Terragrunt:
  AWS_PROFILE=tf-{env} terragrunt plan
""")


def cmd_destroy_roles(iam_client, env: str):
    """Destroy the terraform role for the given environment."""
    print(f"\n--- Destroying roles for env: {env} ---\n")
    destroy_role(iam_client, f"terraform-{env}")
    print("\nDone. Roles destroyed.")


# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------


def state_bucket_name(account_id: str, env: str) -> str:
    suffix = hashlib.sha256(account_id.encode()).hexdigest()[:6]
    return f"tf-state-{account_id}-{env}-{suffix}"


def cmd_create_state_bucket(s3_client, sts_client, env: str):
    """Create the S3 bucket used by Terragrunt for remote state."""
    account_id = get_caller_identity(sts_client)["account_id"]
    bucket = state_bucket_name(account_id, env)
    region = s3_client.meta.region_name

    print(f"\n--- Creating Terraform state bucket ---\n")
    print(f"  Bucket: {bucket}")
    print(f"  Region: {region}\n")

    try:
        if region == "us-east-1":
            s3_client.create_bucket(Bucket=bucket)
        else:
            s3_client.create_bucket(
                Bucket=bucket,
                CreateBucketConfiguration={"LocationConstraint": region},
            )
        print(f"  Bucket '{bucket}' created.")
    except ClientError as e:
        if e.response["Error"]["Code"] in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
            print(f"  Bucket '{bucket}' already exists.")
        else:
            raise

    print("  Enabling versioning...")
    s3_client.put_bucket_versioning(
        Bucket=bucket,
        VersioningConfiguration={"Status": "Enabled"},
    )

    print("  Blocking all public access...")
    s3_client.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )

    print("  Enabling server-side encryption (SSE-S3)...")
    s3_client.put_bucket_encryption(
        Bucket=bucket,
        ServerSideEncryptionConfiguration={
            "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
        },
    )

    print(f"""
--- Done! ---

State bucket ready: {bucket}

Update root.hcl with this bucket name:

  remote_state {{
    backend = "s3"
    config = {{
      bucket = "{bucket}"
      key    = "${{path_relative_to_include()}}/terraform.tfstate"
      region = "{region}"
      ...
    }}
  }}
""")


def cmd_destroy_state_bucket(s3_client, sts_client, env: str):
    """Delete the Terraform state bucket (empties all versions first)."""
    account_id = get_caller_identity(sts_client)["account_id"]
    bucket = state_bucket_name(account_id, env)

    print(f"\n--- Destroying Terraform state bucket: {bucket} ---\n")

    try:
        s3_client.head_bucket(Bucket=bucket)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchBucket"):
            print(f"  Bucket '{bucket}' does not exist, skipping.")
            return
        raise

    # Delete all object versions (required before bucket deletion)
    print("  Deleting all object versions...")
    paginator = s3_client.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=bucket):
        objects = [
            {"Key": v["Key"], "VersionId": v["VersionId"]}
            for v in page.get("Versions", []) + page.get("DeleteMarkers", [])
        ]
        if objects:
            s3_client.delete_objects(Bucket=bucket, Delete={"Objects": objects})

    print(f"  Deleting bucket '{bucket}'...")
    s3_client.delete_bucket(Bucket=bucket)
    print("\nDone. State bucket destroyed.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Bootstrap IAM for Terraform & CI/CD",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
commands:
  create-user     Create the 'deployer' IAM user (run once per account)
  destroy-user    Delete the 'deployer' IAM user
  create-roles    Create terraform-{env} and cicd-{env} roles
  destroy-roles   Destroy terraform-{env} and cicd-{env} roles
        """,
    )
    parser.add_argument(
        "command",
        choices=[
            "create-user", "destroy-user",
            "create-roles", "destroy-roles",
            "create-state-bucket", "destroy-state-bucket",
        ],
        help="Action to perform",
    )
    parser.add_argument("--env", help="Environment name (required for *-roles and *-state-bucket commands)")
    parser.add_argument("--profile", default=None, help="AWS CLI profile to use")
    parser.add_argument("--region", default="eu-central-1", help="AWS region")
    args = parser.parse_args()

    env_required = ("create-roles", "destroy-roles", "create-state-bucket", "destroy-state-bucket")
    if args.command in env_required and not args.env:
        parser.error(f"--env is required for {args.command}")

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    iam_client = session.client("iam")
    sts_client = session.client("sts")
    s3_client = session.client("s3")

    match args.command:
        case "create-user":
            cmd_create_user(iam_client, sts_client)
        case "destroy-user":
            cmd_destroy_user(iam_client)
        case "create-roles":
            cmd_create_roles(iam_client, sts_client, args.env)
        case "destroy-roles":
            cmd_destroy_roles(iam_client, args.env)
        case "create-state-bucket":
            cmd_create_state_bucket(s3_client, sts_client, args.env)
        case "destroy-state-bucket":
            cmd_destroy_state_bucket(s3_client, sts_client, args.env)


if __name__ == "__main__":
    main()
