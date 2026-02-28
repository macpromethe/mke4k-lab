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
