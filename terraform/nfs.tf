# ---------------------------------------------------------------------------
# NFS server — gated on var.nfs_enabled
# ---------------------------------------------------------------------------

resource "aws_instance" "nfs_server" {
  count                  = var.nfs_enabled ? 1 : 0
  ami                    = data.aws_ami.bastion.id
  instance_type          = var.nfs_flavor
  key_name               = aws_key_pair.cluster.key_name
  vpc_security_group_ids = [aws_security_group.cluster_allow_ssh.id]
  subnet_id              = var.airgap_enabled ? aws_subnet.airgap_private[0].id : aws_subnet.public.id

  # FQDN hostname, consistent with the cluster nodes — see controller.tf
  user_data = <<-EOF
    #cloud-config
    preserve_hostname: false
    prefer_fqdn_over_hostname: true
    manage_etc_hosts: localhost
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
