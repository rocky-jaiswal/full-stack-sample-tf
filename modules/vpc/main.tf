# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.project_name}-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    precondition {
      condition     = length(var.azs) == length(var.public_subnet_cidrs)
      error_message = "azs and public_subnet_cidrs must have the same number of entries."
    }
    precondition {
      condition     = length(var.azs) == length(var.private_subnet_cidrs)
      error_message = "azs and private_subnet_cidrs must have the same number of entries."
    }
    precondition {
      condition     = length(var.azs) == length(var.isolated_subnet_cidrs)
      error_message = "azs and isolated_subnet_cidrs must have the same number of entries."
    }
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-igw"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Public Subnets — ALBs, NAT instance
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project_name}-${var.environment}-public-${var.azs[count.index]}"
    Environment              = var.environment
    ManagedBy                = "terraform"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-public"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidrs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# NAT Instance — fck-nat on t4g.nano (~$3/mo vs ~$35/mo for NAT Gateway)
# Single instance in first public subnet; single point of failure is fine for dev.
# -----------------------------------------------------------------------------

data "aws_ami" "nat" {
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

resource "aws_security_group" "nat" {
  name        = "${var.project_name}-${var.environment}-nat"
  description = "NAT instance - allow forwarded traffic from private subnets"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-nat"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_instance" "nat" {
  ami                         = data.aws_ami.nat.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  source_dest_check           = false
  vpc_security_group_ids      = [aws_security_group.nat.id]

  user_data = <<-EOF
    #!/bin/bash
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    dnf install -y iptables-services
    systemctl enable --now iptables
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables-save > /etc/sysconfig/iptables
  EOF

  tags = {
    Name        = "${var.project_name}-${var.environment}-nat"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Private Subnets — K3s cluster nodes (DevOps + App clusters)
# -----------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                              = "${var.project_name}-${var.environment}-private-${var.azs[count.index]}"
    Environment                       = var.environment
    ManagedBy                         = "terraform"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-private"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnet_cidrs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Isolated Subnets — RDS, ElastiCache (NO internet access at all)
# -----------------------------------------------------------------------------

resource "aws_subnet" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name        = "${var.project_name}-${var.environment}-isolated-${var.azs[count.index]}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Explicit route table with no routes — isolated subnets have local-only access.
# Without this, subnets fall back to the VPC main route table which could be
# accidentally modified to add external access.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-isolated"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_route_table_association" "isolated" {
  count = length(var.isolated_subnet_cidrs)

  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}
