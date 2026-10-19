# ── Route53 A records (apex + www) → Elastic IP ───────────────────
# No load balancer: DNS points straight at the instance, where Caddy
# terminates TLS with a free Let's Encrypt certificate. Only created when
# hosted_zone_id is set — otherwise add the same records at your registrar
# (see the dns_records output) before the first deploy.
resource "aws_route53_record" "app" {
  count           = var.hosted_zone_id != "" ? 1 : 0
  zone_id         = var.hosted_zone_id
  name            = var.domain_name
  type            = "A"
  ttl             = 300
  records         = [data.aws_eip.skybroe.public_ip]
  allow_overwrite = true
}

# ── Retired ACM validation records — forget, never delete ──────────
# ACM reuses the same validation CNAME for a domain name across every
# certificate in the account, and another project's certificate covers this
# domain too. Destroying these with the old ACM cert would break that
# certificate's auto-renewal, so drop them from state and leave the records.
removed {
  from = aws_route53_record.cert_validation

  lifecycle {
    destroy = false
  }
}

resource "aws_route53_record" "app_www" {
  count           = var.hosted_zone_id != "" ? 1 : 0
  zone_id         = var.hosted_zone_id
  name            = "www.${var.domain_name}"
  type            = "A"
  ttl             = 300
  records         = [data.aws_eip.skybroe.public_ip]
  allow_overwrite = true
}
