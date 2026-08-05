resource "aws_instance" "cluster-controller" {
  count                  = var.controller_count
  ami                    = data.aws_ami.node.id
  instance_type          = var.controller_flavor
  key_name               = aws_key_pair.cluster.key_name
  iam_instance_profile   = var.ccm_enabled ? aws_iam_instance_profile.mke4k_ccm[0].name : null
  vpc_security_group_ids = [aws_security_group.cluster_allow_ssh.id]
  subnet_id              = var.airgap_enabled ? aws_subnet.airgap_private[0].id : aws_subnet.public.id

  # AWS CCM matches Nodes to instances by PrivateDnsName (the FQDN), but Ubuntu's
  # cloud-init defaults to the SHORT hostname — force the FQDN form. Declarative so
  # cloud-init fetches local-hostname itself (over IMDSv2) and re-applies it every
  # boot. RHEL's cloud-init already prefers the FQDN; this is a no-op there.
  # manage_etc_hosts must stay "localhost": "true" re-renders the whole file each
  # boot and would wipe the airgap registry entry added by setup_node_dns.
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
    Name                                        = "${var.cluster_name}-controller-${count.index}"
    Cluster                                     = var.cluster_name
    Role                                        = "controller+worker"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
