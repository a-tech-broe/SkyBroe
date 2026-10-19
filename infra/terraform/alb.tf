# ── Default VPC Subnets (ALB requires ≥ 2 AZs) ───────────────────
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── ACM Certificate ───────────────────────────────────────────────
resource "aws_acm_certificate" "skybroe" {
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge({ Name = "skybroe-cert" }, local.protect)
}

# ── Route53 DNS validation — only created when hosted_zone_id set ─
resource "aws_route53_record" "cert_validation" {
  for_each = var.hosted_zone_id != "" ? {
    for dvo in aws_acm_certificate.skybroe.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.hosted_zone_id
}

resource "aws_acm_certificate_validation" "skybroe" {
  count                   = var.hosted_zone_id != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.skybroe.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── ALB Security Group ────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "skybroe-alb-sg"
  description = "SkyBroe ALB: HTTP + HTTPS from internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "skybroe-alb-sg" }, local.protect)
}

# ── Target Groups ─────────────────────────────────────────────────
resource "aws_lb_target_group" "web" {
  name     = "skybroe-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge({ Name = "skybroe-web-tg" }, local.protect)
}

resource "aws_lb_target_group" "backend" {
  name     = "skybroe-api-tg"
  port     = 3001
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge({ Name = "skybroe-api-tg" }, local.protect)
}

resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.skybroe.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "backend" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.skybroe.id
  port             = 3001
}

# ── Application Load Balancer ─────────────────────────────────────
resource "aws_lb" "skybroe" {
  name               = "skybroe-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.alb_subnets

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }

  tags       = { Name = "skybroe-alb" }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# ── HTTP → HTTPS redirect ─────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.skybroe.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge({ Name = "skybroe-http-listener" }, local.protect)
}

# ── HTTPS listener — default to web, /api/* and /health → backend ─
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.skybroe.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.hosted_zone_id != "" ? aws_acm_certificate_validation.skybroe[0].certificate_arn : aws_acm_certificate.skybroe.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = merge({ Name = "skybroe-https-listener" }, local.protect)
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*", "/health"]
    }
  }

  tags = merge({ Name = "skybroe-api-rule" }, local.protect)
}

# ── Route53 A records (apex + www) → ALB ─────────────────────────
resource "aws_route53_record" "app" {
  count           = var.hosted_zone_id != "" ? 1 : 0
  zone_id         = var.hosted_zone_id
  name            = var.domain_name
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.skybroe.dns_name
    zone_id                = aws_lb.skybroe.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "app_www" {
  count           = var.hosted_zone_id != "" ? 1 : 0
  zone_id         = var.hosted_zone_id
  name            = "www.${var.domain_name}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.skybroe.dns_name
    zone_id                = aws_lb.skybroe.zone_id
    evaluate_target_health = true
  }
}
