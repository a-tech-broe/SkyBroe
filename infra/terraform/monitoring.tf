# ── Data ──────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "main" {}

# ── SNS — alert notifications ──────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "skybroe-alerts"
  tags = local.protect
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ── CloudWatch Log Groups ─────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/skybroe/app"
  retention_in_days = 30
  tags              = local.protect
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/skybroe/system"
  retention_in_days = 14
  tags              = local.protect
}

# ── ALB Access Logs → S3 ─────────────────────────────────────────
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "skybroe-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.protect
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-90d"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 90 }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    }]
  })
}

# ── CloudWatch Agent config in SSM ───────────────────────────────
resource "aws_ssm_parameter" "cw_agent_config" {
  name = "/skybroe/cloudwatch-agent-config"
  type = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      append_dimensions = { InstanceId = "$${aws:InstanceId}" }
      metrics_collected = {
        mem = { measurement = ["mem_used_percent"] }
        # drop_device: the root device name differs by instance family
        # (xvda1 on Xen, nvme0n1p1 on Nitro), so keep it out of the dimensions
        # the disk alarm and dashboard must match.
        disk    = { measurement = ["disk_used_percent"], resources = ["/"], drop_device = true }
        diskio  = { measurement = ["io_time", "write_bytes", "read_bytes"], resources = ["*"] }
        netstat = { measurement = ["tcp_established", "tcp_time_wait"] }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [{
            file_path       = "/var/log/skybroe-init.log"
            log_group_name  = "/skybroe/system"
            log_stream_name = "{instance_id}"
            timezone        = "UTC"
          }]
        }
      }
    }
  })
  tags = local.protect
}

# ── SSM Associations — install + configure CloudWatch Agent ───────
resource "aws_ssm_association" "cw_agent_install" {
  name = "AWS-ConfigureAWSPackage"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.skybroe.id]
  }
  parameters = {
    action = "Install"
    name   = "AmazonCloudWatch"
  }
}

resource "aws_ssm_association" "cw_agent_configure" {
  name = "AmazonCloudWatch-ManageAgent"
  targets {
    key    = "InstanceIds"
    values = [aws_instance.skybroe.id]
  }
  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cw_agent_config.name
    optionalRestart               = "yes"
  }
  depends_on = [aws_ssm_association.cw_agent_install]
}

# ── CloudWatch RUM — Cognito Identity Pool ────────────────────────
resource "aws_cognito_identity_pool" "rum" {
  identity_pool_name               = "skybroe_rum"
  allow_unauthenticated_identities = true
  tags                             = local.protect
}

resource "aws_iam_role" "rum_unauth" {
  name = "skybroe-rum-unauth"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "cognito-identity.amazonaws.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals             = { "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.rum.id }
        "ForAnyValue:StringLike" = { "cognito-identity.amazonaws.com:amr" = "unauthenticated" }
      }
    }]
  })
  tags = local.protect
}

resource "aws_iam_role_policy" "rum_unauth" {
  name = "skybroe-rum-unauth-policy"
  role = aws_iam_role.rum_unauth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["rum:PutRumEvents"]
      Resource = "arn:aws:rum:${var.aws_region}:${data.aws_caller_identity.current.account_id}:appmonitor/skybroe-web"
    }]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "rum" {
  identity_pool_id = aws_cognito_identity_pool.rum.id
  roles            = { unauthenticated = aws_iam_role.rum_unauth.arn }
}

resource "aws_rum_app_monitor" "skybroe" {
  name   = "skybroe-web"
  domain = var.domain_name

  app_monitor_configuration {
    allow_cookies       = true
    enable_xray         = false
    identity_pool_id    = aws_cognito_identity_pool.rum.id
    guest_role_arn      = aws_iam_role.rum_unauth.arn
    session_sample_rate = 1.0
    telemetries         = ["errors", "performance", "http"]
  }

  custom_events { status = "ENABLED" }
  tags = local.protect
}

# ── CloudWatch Alarms ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "skybroe-cpu-high"
  alarm_description   = "EC2 CPU > 80% for 4 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { InstanceId = aws_instance.skybroe.id }
  tags                = local.protect
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "skybroe-memory-high"
  alarm_description   = "EC2 memory > 85% for 4 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 120
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { InstanceId = aws_instance.skybroe.id }
  tags                = local.protect
}

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "skybroe-disk-high"
  alarm_description   = "Root disk > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Maximum"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    InstanceId = aws_instance.skybroe.id
    path       = "/"
    fstype     = "xfs"
  }
  tags = local.protect
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "skybroe-alb-5xx"
  alarm_description   = "More than 10 backend 5xx in 1 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { LoadBalancer = aws_lb.skybroe.arn_suffix }
  tags                = local.protect
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "skybroe-alb-latency"
  alarm_description   = "ALB p95 response time > 3s for 2 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { LoadBalancer = aws_lb.skybroe.arn_suffix }
  tags                = local.protect
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy" {
  alarm_name          = "skybroe-alb-unhealthy-hosts"
  alarm_description   = "One or more backend targets unhealthy"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions = {
    LoadBalancer = aws_lb.skybroe.arn_suffix
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
  }
  tags = local.protect
}

# ── CloudWatch Dashboard ──────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "skybroe" {
  dashboard_name = "SkyBroe-Overview"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1 — EC2 Infrastructure
      {
        type = "metric", x = 0, y = 0, width = 6, height = 6
        properties = {
          title   = "CPU Utilization"
          region  = var.aws_region
          view    = "timeSeries"
          period  = 60
          stat    = "Average"
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.skybroe.id]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 6, y = 0, width = 6, height = 6
        properties = {
          title   = "Memory Used %"
          region  = var.aws_region
          view    = "timeSeries"
          period  = 60
          stat    = "Average"
          metrics = [["CWAgent", "mem_used_percent", "InstanceId", aws_instance.skybroe.id]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 6, height = 6
        properties = {
          title   = "Disk Used %"
          region  = var.aws_region
          view    = "timeSeries"
          period  = 300
          stat    = "Maximum"
          metrics = [["CWAgent", "disk_used_percent", "InstanceId", aws_instance.skybroe.id, "path", "/", "fstype", "xfs"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 18, y = 0, width = 6, height = 6
        properties = {
          title  = "Network I/O (bytes)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.skybroe.id, { stat = "Sum", label = "In" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.skybroe.id, { stat = "Sum", label = "Out" }]
          ]
        }
      },
      # Row 2 — ALB
      {
        type = "metric", x = 0, y = 6, width = 6, height = 6
        properties = {
          title   = "Request Count"
          region  = var.aws_region
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.skybroe.arn_suffix]]
        }
      },
      {
        type = "metric", x = 6, y = 6, width = 6, height = 6
        properties = {
          title  = "Response Time (s)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "p99", label = "p99" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 6, height = 6
        properties = {
          title  = "HTTP Status Codes"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "Sum", label = "2xx" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "Sum", label = "4xx" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "Sum", label = "5xx" }]
          ]
        }
      },
      {
        type = "metric", x = 18, y = 6, width = 6, height = 6
        properties = {
          title  = "Active / New Connections"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "Sum", label = "Active" }],
            ["AWS/ApplicationELB", "NewConnectionCount", "LoadBalancer", aws_lb.skybroe.arn_suffix, { stat = "Sum", label = "New" }]
          ]
        }
      },
      # Row 3 — App logs
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "API Requests (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | fields @timestamp, method, path, status, ms, userId, ip | sort @timestamp desc | limit 200"
          view   = "table"
        }
      },
      {
        type = "log", x = 0, y = 18, width = 24, height = 6
        properties = {
          title  = "Errors & 5xx (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | fields @timestamp, method, path, status, ms, userId, ip | filter status >= 500 or level = 'error' | sort @timestamp desc | limit 100"
          view   = "table"
        }
      },
      {
        type = "log", x = 0, y = 24, width = 12, height = 6
        properties = {
          title  = "Top Endpoints (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | stats count() as hits, avg(ms) as avg_ms by path | sort hits desc | limit 20"
          view   = "table"
        }
      },
      {
        type = "log", x = 12, y = 24, width = 12, height = 6
        properties = {
          title  = "Active Users (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | stats count() as requests by userId | filter ispresent(userId) and userId != 'null' | sort requests desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}
