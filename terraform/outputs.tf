output "lb_dns_name" {
  description = "NLB DNS name (used as externalAddress in mke4.yaml)"
  value       = aws_lb.cluster.dns_name
}

output "controller_ips" {
  description = "Public IP addresses of controller nodes"
  value       = aws_instance.cluster-controller[*].public_ip
}

output "worker_ips" {
  description = "Public IP addresses of worker nodes"
  value       = aws_instance.cluster-workers[*].public_ip
}

output "ssh_key_path" {
  description = "Path to the SSH private key"
  value       = abspath("${path.module}/aws_private.pem")
}

output "mkectl_command" {
  description = "Ready-to-run mkectl apply command"
  value       = "mkectl apply -f ${abspath("${path.module}/mke4.yaml")}"
}

output "mke3_lb_dns_name" {
  description = "MKE3 NLB DNS name (used as --san in launchpad.yaml)"
  value       = var.mke3_enabled ? aws_lb.mke3[0].dns_name : ""
}

output "bastion_public_ip" {
  description = "Bastion/registry host public IP"
  value       = var.airgap_enabled ? aws_instance.bastion[0].public_ip : ""
}

output "bastion_private_ip" {
  description = "Bastion/registry host private IP (used as registry address)"
  value       = var.airgap_enabled ? aws_instance.bastion[0].private_ip : ""
}

output "controller_private_ips" {
  description = "Private IP addresses of controller nodes"
  value       = aws_instance.cluster-controller[*].private_ip
}

output "worker_private_ips" {
  description = "Private IP addresses of worker nodes"
  value       = aws_instance.cluster-workers[*].private_ip
}

output "controller_public_dns" {
  description = "Public DNS names of controller nodes (empty strings in airgap)"
  value       = aws_instance.cluster-controller[*].public_dns
}

output "worker_public_dns" {
  description = "Public DNS names of worker nodes (empty strings in airgap)"
  value       = aws_instance.cluster-workers[*].public_dns
}

output "controller_private_dns" {
  description = "Private DNS names (ip-X-Y-Z.<region>.compute.internal) of controller nodes"
  value       = aws_instance.cluster-controller[*].private_dns
}

output "worker_private_dns" {
  description = "Private DNS names of worker nodes"
  value       = aws_instance.cluster-workers[*].private_dns
}

output "nfs_server_private_ip" {
  description = "Private IP of the NFS server"
  value       = var.nfs_enabled ? aws_instance.nfs_server[0].private_ip : ""
}

output "nfs_server_public_ip" {
  description = "Public IP of the NFS server (empty in airgap mode)"
  value       = var.nfs_enabled ? (var.airgap_enabled ? "" : aws_instance.nfs_server[0].public_ip) : ""
}
