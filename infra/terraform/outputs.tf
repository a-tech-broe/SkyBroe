output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.skybroe.id
}

output "public_ip" {
  description = "Elastic IP address (DNS target, SSH / direct access)"
  value       = data.aws_eip.skybroe.public_ip
}

output "app_url" {
  description = "Application URL"
  value       = "https://${var.domain_name}"
}

output "ssh_command" {
  description = "SSH one-liner to access the instance"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${data.aws_eip.skybroe.public_ip}"
}

output "dns_records" {
  description = "A records the domain needs (created automatically when hosted_zone_id is set; otherwise add them at your registrar before the first deploy)"
  value = {
    (var.domain_name)          = "A ${data.aws_eip.skybroe.public_ip}"
    ("www.${var.domain_name}") = "A ${data.aws_eip.skybroe.public_ip}"
  }
}

output "rum_app_monitor_id" {
  description = "CloudWatch RUM app monitor ID — set as VITE_RUM_APP_ID in the web build"
  value       = aws_rum_app_monitor.skybroe.id
}

output "rum_identity_pool_id" {
  description = "Cognito Identity Pool ID for CloudWatch RUM — set as VITE_RUM_IDENTITY_POOL_ID in the web build"
  value       = aws_cognito_identity_pool.rum.id
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=SkyBroe-Overview"
}
