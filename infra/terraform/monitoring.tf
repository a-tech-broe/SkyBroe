# ── Data ──────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# Everything here stays inside the CloudWatch free tier for an MVP:
# ≤ 10 alarms, ≤ 10 custom metrics, ≤ 3 dashboards, and a few MB of logs.

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
  retention_in_days = 14
  tags              = local.protect
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/skybroe/system"
  retention_in_days = 14
  tags              = local.protect
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
      # Two custom metrics only (mem + disk) — both feed alarms, and the
      # first 10 custom metrics are free.
      metrics_collected = {
        mem = { measurement = ["mem_used_percent"] }
        # drop_device: the root device name differs by instance family
        # (xvda1 on Xen, nvme0n1p1 on Nitro), so keep it out of the dimensions
        # the disk alarm and dashboard must match.
        disk = { measurement = ["disk_used_percent"], resources = ["/"], drop_device = true }
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
# Requires the instance role's AmazonSSMManagedInstanceCore attachment.
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

# Replaces the ALB health-check alarms: with a single instance and no load
# balancer, a failed EC2 status check is the "site is down" signal. (EC2's
# default simplified auto-recovery handles underlying host failures.)
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "skybroe-status-check-failed"
  alarm_description   = "EC2 instance or system status check failing for 2 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { InstanceId = aws_instance.skybroe.id }
  tags                = local.protect
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
      # Row 2+ — App logs
      {
        type = "log", x = 0, y = 6, width = 24, height = 6
        properties = {
          title  = "API Requests (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | fields @timestamp, method, path, status, ms, userId, ip | sort @timestamp desc | limit 200"
          view   = "table"
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Errors & 5xx (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | fields @timestamp, method, path, status, ms, userId, ip | filter status >= 500 or level = 'error' | sort @timestamp desc | limit 100"
          view   = "table"
        }
      },
      {
        type = "log", x = 0, y = 18, width = 12, height = 6
        properties = {
          title  = "Top Endpoints (last 1h)"
          region = var.aws_region
          query  = "SOURCE '/skybroe/app' | stats count() as hits, avg(ms) as avg_ms by path | sort hits desc | limit 20"
          view   = "table"
        }
      },
      {
        type = "log", x = 12, y = 18, width = 12, height = 6
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
