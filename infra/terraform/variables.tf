variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  # The full stack idles at ~85 MB of container memory (~550 MB with OS,
  # Docker and the CloudWatch agent), so 1 GB + the 2 GB swap file is ample
  # for test users. Step up to t4g.small (2 GB) if the memory alarm fires.
  description = "EC2 instance type. Default t4g.micro (Graviton, 2 vCPU / 1 GB) is sized for an MVP; the AMI architecture follows the type"
  type        = string
  default     = "t4g.micro"
}

variable "root_volume_gb" {
  description = "Root EBS volume size (GB) — holds the OS, Docker images, Postgres data and a 2 GB swap file"
  type        = number
  default     = 16
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
  default     = "keyit"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH — tighten to your IP in production"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path prefix for app secrets"
  type        = string
  default     = "/skybroe"
}

variable "domain_name" {
  description = "App domain (e.g. skybroe.com) — Caddy obtains its TLS certificate for this name and www.<name>"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID — if set, the apex + www A records pointing at the Elastic IP are created automatically"
  type        = string
  default     = ""
}

variable "app_eip" {
  description = "Existing Elastic IP for the app EC2 (value of EC2_HOST GitHub Secret)"
  type        = string
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (leave empty to skip)"
  type        = string
  default     = ""
}
