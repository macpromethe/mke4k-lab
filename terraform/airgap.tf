# ---------------------------------------------------------------------------
# Airgap infrastructure — gated on var.airgap_enabled
# ---------------------------------------------------------------------------

# --- Private subnet for cluster nodes (no internet) ---
resource "aws_subnet" "airgap_private" {
  count                   = var.airgap_enabled ? 1 : 0
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "172.31.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.cluster_name}-airgap-private"
    Cluster                                     = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Route table with NO internet gateway — only local VPC routing
resource "aws_route_table" "airgap_private" {
  count  = var.airgap_enabled ? 1 : 0
  vpc_id = aws_vpc.lab.id

  tags = {
    Name    = "${var.cluster_name}-airgap-private-rt"
    Cluster = var.cluster_name
  }
}

resource "aws_route_table_association" "airgap_private" {
  count          = var.airgap_enabled ? 1 : 0
  subnet_id      = aws_subnet.airgap_private[0].id
  route_table_id = aws_route_table.airgap_private[0].id
}

# --- Bastion/registry host (public subnet, internet access) ---
resource "aws_instance" "bastion" {
  count                  = var.airgap_enabled ? 1 : 0
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.airgap_registry_flavor
  key_name               = aws_key_pair.cluster.key_name
  vpc_security_group_ids = [aws_security_group.cluster_allow_ssh.id]
  subnet_id = aws_subnet.public.id

  user_data = <<-EOF
    #!/bin/bash
    HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/hostname)
    echo $HOSTNAME > /etc/hostname
    sed -i "s|\(127\.0\..\..*\)localhost|\1$HOSTNAME|" /etc/hosts
    hostname $HOSTNAME
  EOF

  root_block_device {
    volume_size = var.airgap_registry_disk_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.cluster_name}-bastion"
    Cluster = var.cluster_name
    Role    = "bastion"
  }
}
