variable "region" {
  description = "AWS region for the Graviton fallback fleet. eu-central-1 is closest to Hetzner hel1 (low CAS-over-WireGuard latency)."
  type        = string
  default     = "eu-central-1"
}

variable "availability_zone" {
  description = "AZ for the single public subnet."
  type        = string
  default     = "eu-central-1a"
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR for the DEDICATED fallback VPC. MUST NOT overlap the WireGuard tunnel
    pool (10.99.0.0/16) or the Hetzner private network (10.30.246.0/24) — the
    worker carries interfaces on all three at once.
  EOT
  type        = string
  default     = "10.111.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the public subnet (must be inside vpc_cidr)."
  type        = string
  default     = "10.111.0.0/20"
}

variable "billing_tag" {
  description = "iit-billing-tag value — isolates cost AND satisfies the percona-dev-admin cleanup Lambdas. Must match aws.billing_tag in ondemand-pools.yaml."
  type        = string
  default     = "psmdb-worker"
}

variable "ubuntu_version" {
  description = "Ubuntu release whose arm64 AMI to resolve for AWS_AMI_ID (worker VM host OS — just a Docker host, decoupled from the runner distro)."
  type        = string
  default     = "24.04"
}

variable "extra_tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
