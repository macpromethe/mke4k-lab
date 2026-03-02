terraform {
  required_version = ">= 0.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# SSH Key pair
# ---------------------------------------------------------------------------
resource "tls_private_key" "cluster" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "cluster" {
  key_name   = "${var.cluster_name}-key"
  public_key = tls_private_key.cluster.public_key_openssh

  tags = {
    Name    = "${var.cluster_name}-key"
    Cluster = var.cluster_name
  }
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.cluster.private_key_pem
  filename        = "${path.module}/aws_private.pem"
  file_permission = "0600"
}

# ---------------------------------------------------------------------------
# AMI lookup
# ---------------------------------------------------------------------------
locals {
  ami_filters = {
    "ubuntu-22.04" = {
      name  = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      owner = "099720109477" # Canonical
    }
    "ubuntu-24.04" = {
      name  = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      owner = "099720109477" # Canonical
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = [local.ami_filters[var.os_distro].owner]

  filter {
    name   = "name"
    values = [local.ami_filters[var.os_distro].name]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster_allow_ssh" {
  name        = "${var.cluster_name}-sg"
  description = "MKE4k cluster security group"
  vpc_id      = aws_vpc.lab.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MKE API / controller join
  ingress {
    description = "MKE API / controller join"
    from_port   = 9443
    to_port     = 9443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Ingress / NodePort
  ingress {
    description = "Ingress controller"
    from_port   = 33001
    to_port     = 33001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP ingress
  ingress {
    description = "HTTP"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MKE3 UI / HTTPS (from MKE3 NLB)
  ingress {
    description = "MKE3 UI / HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Intra-cluster: all traffic within the security group
  ingress {
    description = "Intra-cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.cluster_name}-sg"
    Cluster                                     = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

