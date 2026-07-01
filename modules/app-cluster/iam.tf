data "aws_caller_identity" "current" {}

resource "aws_iam_role" "app_cluster" {
  name = "app-cluster-${var.environment}"

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
  role       = aws_iam_role.app_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR pull only — apps pull their own images, never push
resource "aws_iam_role_policy" "ecr" {
  name = "ecr-pull"
  role = aws_iam_role.app_cluster.id

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
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
      },
    ]
  })
}

# S3 - scoped app data read/write
resource "aws_iam_role_policy" "s3" {
  name = "s3-app-data"
  role = aws_iam_role.app_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
      ]
      Resource = "${var.app_bucket_arn}/*"
    }]
  })
}

# KMS - needed to write to the KMS-encrypted S3 bucket and read encrypted secrets
resource "aws_iam_role_policy" "kms" {
  name = "kms-s3-secrets"
  role = aws_iam_role.app_cluster.id

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

# Secrets Manager - External Secrets Operator reads app secrets
resource "aws_iam_role_policy" "secrets" {
  name = "secrets-manager-read"
  role = aws_iam_role.app_cluster.id

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

# SQS - async job queues (queues themselves come later, in modules/sqs)
resource "aws_iam_role_policy" "sqs" {
  name = "sqs-app-queues"
  role = aws_iam_role.app_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = "arn:aws:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-${var.environment}-*"
    }]
  })
}

resource "aws_iam_instance_profile" "app_cluster" {
  name = "app-cluster-${var.environment}"
  role = aws_iam_role.app_cluster.name
}
