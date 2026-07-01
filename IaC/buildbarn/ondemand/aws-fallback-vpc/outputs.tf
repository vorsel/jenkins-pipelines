output "vpc_id" {
  description = "Dedicated fallback VPC id."
  value       = aws_vpc.this.id
}

output "subnet_id" {
  description = "Public subnet id → set as AWS_SUBNET_ID in compose/.env."
  value       = aws_subnet.public.id
}

output "worker_security_group_id" {
  description = "Worker SG id → set as AWS_SECURITY_GROUP_IDS in compose/.env."
  value       = aws_security_group.worker.id
}

output "ubuntu_arm64_ami_id" {
  description = "Latest Canonical Ubuntu arm64 AMI → pin as AWS_AMI_ID in compose/.env."
  # SSM parameter values are sensitive by default; an AMI id is public, so
  # unwrap it (same pattern as percona-cd-platform master-psmdb.tf).
  value = nonsensitive(data.aws_ssm_parameter.ubuntu_arm64.value)
}

# Copy/paste block for compose/.env on the central.
output "env_lines" {
  description = "Paste these into compose/.env (alongside the WG_* lines from setup-wireguard-hub.sh)."
  value       = <<-EOT
    AWS_SUBNET_ID=${aws_subnet.public.id}
    AWS_SECURITY_GROUP_IDS=${aws_security_group.worker.id}
    AWS_AMI_ID=${nonsensitive(data.aws_ssm_parameter.ubuntu_arm64.value)}
  EOT
}
