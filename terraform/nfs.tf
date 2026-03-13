# ---------------------------------------------------------------------------
# NFS server — gated on var.nfs_enabled
# ---------------------------------------------------------------------------

resource "aws_instance" "nfs_server" {
  count                  = var.nfs_enabled ? 1 : 0
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.nfs_flavor
  key_name               = aws_key_pair.cluster.key_name
  vpc_security_group_ids = [aws_security_group.cluster_allow_ssh.id]
  subnet_id              = var.airgap_enabled ? aws_subnet.airgap_private[0].id : aws_subnet.public.id

  user_data = <<-EOF
    #!/bin/bash
    HOSTNAME=$(curl -s http://169.254.169.254/latest/meta-data/hostname)
    echo $HOSTNAME > /etc/hostname
    sed -i "s|\(127\.0\..\..*\)localhost|\1$HOSTNAME|" /etc/hosts
    hostname $HOSTNAME
  EOF

  root_block_device {
    volume_size = var.nfs_disk_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.cluster_name}-nfs"
    Cluster = var.cluster_name
    Role    = "nfs"
  }
}
