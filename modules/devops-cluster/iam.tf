data "aws_caller_identity" "current" {}

resource "aws_iam_role" "devops_cluster" {
  name = "devops-cluster-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# SSM Session Manager - kubectl access, no SSH needed
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.devops_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR push + pull - Woodpecker CI builds and pushes images
resource "aws_iam_role_policy" "ecr" {
  name = "ecr-push-pull"
  role = aws_iam_role.devops_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
      },
    ]
  })
}

# S3 - Woodpecker CI build artifacts
resource "aws_iam_role_policy" "s3" {
  name = "s3-artifacts"
  role = aws_iam_role.devops_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        var.artifacts_bucket_arn,
        "${var.artifacts_bucket_arn}/*",
      ]
    }]
  })
}

# KMS - needed to write to the KMS-encrypted S3 bucket
resource "aws_iam_role_policy" "kms" {
  name = "kms-s3"
  role = aws_iam_role.devops_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:GenerateDataKey",
        "kms:Decrypt",
      ]
      Resource = var.kms_key_arn
    }]
  })
}

# Secrets Manager - Woodpecker pipeline secrets
resource "aws_iam_role_policy" "secrets" {
  name = "secrets-manager-read"
  role = aws_iam_role.devops_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/${var.environment}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "devops_cluster" {
  name = "devops-cluster-${var.environment}"
  role = aws_iam_role.devops_cluster.name
}
