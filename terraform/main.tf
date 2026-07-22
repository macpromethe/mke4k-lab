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
    # Stable creation timestamp for the expiry reaper (expiry.tf)
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    # Zips the reaper Lambda source (expiry.tf)
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Owner tag on every resource so cloud admins can attribute them
  default_tags {
    tags = var.owner == "" ? {} : { Owner = var.owner }
  }
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
  # Version-templated AMI name patterns per OS family.
  # ubuntu: hvm-ssd* covers both hvm-ssd (22.04) and hvm-ssd-gp3 (24.04) schemes.
  # redhat: official PAYG images (Hourly2 = hourly billing, excludes BYOS Access2).
  ami_templates = {
    ubuntu = {
      name  = "ubuntu/images/hvm-ssd*/ubuntu-*-${var.os_version}-amd64-server-*"
      owner = "099720109477" # Canonical
    }
    redhat = {
      name  = "RHEL-${var.os_version}*_HVM-*-x86_64-*-Hourly2-GP3"
      owner = "309956199498" # Red Hat
    }
  }
  # Bastion + NFS server are always Ubuntu: follow os_version when the cluster
  # nodes are Ubuntu, pin to 22.04 otherwise.
  # NOTE: keep in sync with bastion_os_version() in bin/t-commandline.bash.
  bastion_os_version = var.os_name == "ubuntu" ? var.os_version : "22.04"
}

# Cluster nodes (controllers/workers)
data "aws_ami" "node" {
  most_recent = true
  owners      = [local.ami_templates[var.os_name].owner]

  filter {
    name   = "name"
    values = [local.ami_templates[var.os_name].name]
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

# Bastion + NFS server (always Ubuntu)
data "aws_ami" "bastion" {
  most_recent = true
  owners      = [local.ami_templates["ubuntu"].owner]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-${local.bastion_os_version}-amd64-server-*"]
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

  # MSR4 NodePort
  ingress {
    description = "MSR4 NodePort"
    from_port   = 33443
    to_port     = 33443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # KOF Grafana gateway NodePort
  ingress {
    description = "KOF Grafana gateway NodePort"
    from_port   = var.kof_grafana_nodeport
    to_port     = var.kof_grafana_nodeport
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # k0rdent UI gateway NodePort
  ingress {
    description = "k0rdent UI gateway NodePort"
    from_port   = var.k0rdent_ui_nodeport
    to_port     = var.k0rdent_ui_nodeport
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

