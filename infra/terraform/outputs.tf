output "api_endpoint" {
  value = "https://${aws_lb.api.dns_name}:6443"
}

output "api_nlb_dns" {
  value = aws_lb.api.dns_name
}

output "control_plane_public_ips" {
  value = aws_instance.control_plane[*].public_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}

output "ssh_first_control_plane" {
  value = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${aws_instance.control_plane[0].public_ip}"
}
