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

resource "aws_security_group" "devops_cluster" {
  name        = "devops-cluster-${var.environment}"
  description = "DevOps cluster K3s nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "All inter-node traffic within cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "devops-cluster-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# K3s server node (AZ-a) — runs control plane + Woodpecker + ArgoCD + PLG
# -----------------------------------------------------------------------------

resource "aws_instance" "server" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.devops_cluster.name
  vpc_security_group_ids = [aws_security_group.devops_cluster.id]

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
    Name        = "devops-cluster-server-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Role        = "k3s-server"
  }
}

# -----------------------------------------------------------------------------
# K3s agent node (AZ-b) — additional capacity, different AZ for resilience
# -----------------------------------------------------------------------------

resource "aws_instance" "agent" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[1]
  iam_instance_profile   = aws_iam_instance_profile.devops_cluster.name
  vpc_security_group_ids = [aws_security_group.devops_cluster.id]

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
    Name        = "devops-cluster-agent-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Role        = "k3s-agent"
  }
}
