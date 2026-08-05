resource "aws_instance" "cluster-workers" {
  count                  = var.worker_count
  ami                    = data.aws_ami.node.id
  instance_type          = var.worker_flavor
  key_name               = aws_key_pair.cluster.key_name
  iam_instance_profile   = var.ccm_enabled ? aws_iam_instance_profile.mke4k_ccm[0].name : null
  vpc_security_group_ids = [aws_security_group.cluster_allow_ssh.id]
  subnet_id              = var.airgap_enabled ? aws_subnet.airgap_private[0].id : aws_subnet.public.id

  # FQDN hostname for AWS CCM — see the comment in controller.tf
  user_data = <<-EOF
    #cloud-config
    preserve_hostname: false
    prefer_fqdn_over_hostname: true
    manage_etc_hosts: localhost
  EOF

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name                                        = "${var.cluster_name}-worker-${count.index}"
    Cluster                                     = var.cluster_name
    Role                                        = "worker"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
