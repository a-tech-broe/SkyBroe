variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
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

variable "dockerhub_username" {
  description = "Docker Hub username (images pulled as <username>/skybroe-backend, skybroe-web)"
  type        = string
}

variable "app_image_tag" {
  description = "Docker image tag to deploy (e.g. latest, sha-abc1234)"
  type        = string
  default     = "latest"
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path prefix for app secrets"
  type        = string
  default     = "/skybroe"
}

variable "domain_name" {
  description = "Domain name for the ACM certificate and app URL (e.g. skybroe.example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID — if set, DNS validation records and A records are created automatically"
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

variable "ses_from_email" {
  description = "Verified SES sender for password-reset emails (defaults to noreply@<domain_name>)"
  type        = string
  default     = ""
}