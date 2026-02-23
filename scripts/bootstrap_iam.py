"""
Bootstrap IAM for Terraform and CI/CD.

Step 1: Creates a 'deployer' IAM user with ONLY sts:AssumeRole permission.
Step 2: Creates per-environment roles that the deployer user can assume:
  - terraform-{env}  -- Used by Terragrunt/Terraform to manage infrastructure
  - cicd-{env}       -- Used by CI/CD pipelines for deployments

Usage:
  cd scripts/

  # First time: create the deployer user (run once per AWS account)
  uv run bootstrap_iam.py create-user

  # Then: create roles for an environment
  uv run bootstrap_iam.py create-roles --env dev

  # Tear down
  uv run bootstrap_iam.py destroy-roles --env dev
  uv run bootstrap_iam.py destroy-user
"""

import argparse
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

CICD_INLINE_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ECRAccess",
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
            ],
            "Resource": "*",
        },
        {
            "Sid": "SecretsReadOnly",
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret",
            ],
            "Resource": "*",
        },
        {
            "Sid": "S3DeployArtifacts",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:ListBucket",
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
    """Create terraform and cicd roles for the given environment."""
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
    cicd_role_name = f"cicd-{env}"

    print(f"\n--- Creating roles for env: {env} ---")
    print(f"  Account:  {account_id}")
    print(f"  Trusted:  {deployer_arn}")
    print()

    trust_policy = build_trust_policy(account_id, deployer_arn)

    print(f"[1/2] Terraform role: {tf_role_name}")
    create_role(
        iam_client,
        role_name=tf_role_name,
        trust_policy=trust_policy,
        managed_policy_arns=TERRAFORM_MANAGED_POLICIES,
        inline_policy_name="terraform-iam-management",
        inline_policy_doc=TERRAFORM_IAM_INLINE_POLICY,
        env=env,
    )

    print(f"\n[2/2] CI/CD role: {cicd_role_name}")
    create_role(
        iam_client,
        role_name=cicd_role_name,
        trust_policy=trust_policy,
        inline_policy_name="cicd-deployment",
        inline_policy_doc=CICD_INLINE_POLICY,
        env=env,
    )

    print(f"""
--- Done! ---

Roles created:
  {tf_role_name}   -> arn:aws:iam::{account_id}:role/{tf_role_name}
  {cicd_role_name}  -> arn:aws:iam::{account_id}:role/{cicd_role_name}

Both roles trust: {deployer_arn}

Use with Terragrunt:
  AWS_PROFILE=tf-{env} terragrunt plan
""")


def cmd_destroy_roles(iam_client, env: str):
    """Destroy terraform and cicd roles for the given environment."""
    print(f"\n--- Destroying roles for env: {env} ---\n")
    destroy_role(iam_client, f"terraform-{env}")
    destroy_role(iam_client, f"cicd-{env}")
    print("\nDone. Roles destroyed.")


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
        choices=["create-user", "destroy-user", "create-roles", "destroy-roles"],
        help="Action to perform",
    )
    parser.add_argument("--env", help="Environment name (required for *-roles commands)")
    parser.add_argument("--profile", default=None, help="AWS CLI profile to use")
    parser.add_argument("--region", default="eu-central-1", help="AWS region")
    args = parser.parse_args()

    if args.command in ("create-roles", "destroy-roles") and not args.env:
        parser.error(f"--env is required for {args.command}")

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    iam_client = session.client("iam")
    sts_client = session.client("sts")

    match args.command:
        case "create-user":
            cmd_create_user(iam_client, sts_client)
        case "destroy-user":
            cmd_destroy_user(iam_client)
        case "create-roles":
            cmd_create_roles(iam_client, sts_client, args.env)
        case "destroy-roles":
            cmd_destroy_roles(iam_client, args.env)


if __name__ == "__main__":
    main()
