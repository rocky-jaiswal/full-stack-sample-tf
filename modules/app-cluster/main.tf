data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-kernel-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "app_cluster" {
  name        = "app-cluster-${var.environment}"
  description = "App cluster K3s nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "All inter-node traffic within cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "K3s API - ArgoCD on the DevOps cluster deploys here"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [var.devops_cluster_sg_id]
  }

  ingress {
    description     = "NodePort range - Prometheus on the DevOps cluster scrapes app + node-exporter metrics here"
    from_port       = 30000
    to_port         = 32767
    protocol        = "tcp"
    security_groups = [var.devops_cluster_sg_id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "app-cluster-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# K3s server node (AZ-a) — control plane + app workloads
# -----------------------------------------------------------------------------

resource "aws_instance" "server" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.app_cluster.name
  vpc_security_group_ids = [aws_security_group.app_cluster.id]

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  user_data = templatefile("${path.module}/templates/server.sh.tpl", {
    k3s_token = random_password.k3s_token.result
  })

  tags = {
    Name        = "app-cluster-server-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Role        = "k3s-server"
    Cluster     = "app"
  }

  # AMI floats to "most_recent" on every plan — pin the node to whatever
  # AMI it actually launched with so a new AL2023 release doesn't force
  # a silent replace. Bump the AMI deliberately (taint + apply) when needed.
  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# K3s agent node (AZ-b) — additional capacity, different AZ for resilience
# -----------------------------------------------------------------------------

resource "aws_instance" "agent" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[1]
  iam_instance_profile   = aws_iam_instance_profile.app_cluster.name
  vpc_security_group_ids = [aws_security_group.app_cluster.id]

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  user_data = templatefile("${path.module}/templates/agent.sh.tpl", {
    k3s_token = random_password.k3s_token.result
    server_ip = aws_instance.server.private_ip
  })

  depends_on = [aws_instance.server]

  tags = {
    Name        = "app-cluster-agent-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Role        = "k3s-agent"
    Cluster     = "app"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
