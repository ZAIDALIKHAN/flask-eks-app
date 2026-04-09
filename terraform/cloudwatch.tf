# ── Log Groups ────────────────────────────────────────────────

# Log group for EKS control plane logs
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.project_name}-cluster/cluster"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-eks-logs"
  }
}

# Log group for Flask app logs
# Fluent Bit DaemonSet ships all pod logs to this group
resource "aws_cloudwatch_log_group" "flask_app" {
  name              = "/eks/${var.project_name}/flask-app"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-flask-app-logs"
  }
}

# ── SNS Topic & Email Subscription ───────────────────────────
# SNS (Simple Notification Service) is the notification channel
# CloudWatch alarms publish to this topic when they fire or recover
# SNS then delivers the notification to all subscriptions (email, slack, etc)

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"

  tags = {
    Name = "${var.project_name}-alerts"
  }
}

# Email subscription — who gets notified
# IMPORTANT: After terraform apply, AWS sends a confirmation email
# to this address. You MUST click "Confirm subscription" in that email.
# Without clicking confirm, SNS will never deliver notifications.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "zaidalikhan5i1@gmail.com"
}

# ── Alarms ────────────────────────────────────────────────────

# Alarm — EKS node CPU
# Metric comes from CloudWatch Agent DaemonSet (Container Insights)
resource "aws_cloudwatch_metric_alarm" "node_cpu_high" {
  alarm_name          = "${var.project_name}-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "EKS node CPU > 70%"
  treat_missing_data  = "notBreaching"

  # alarm_actions — triggers when state goes OK → ALARM
  # ok_actions    — triggers when state goes ALARM → OK (recovery)
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = "${var.project_name}-cluster"
  }
}

# Alarm — RDS CPU
# Metric comes from AWS automatically (no agent needed for RDS)
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project_name}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "RDS CPU > 70%"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = "${var.project_name}-postgres"
  }
}

# Alarm — RDS DB connections
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${var.project_name}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS connections > 80"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = "${var.project_name}-postgres"
  }
}

# ── Dashboard ─────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node CPU Utilization"
          region = var.aws_region
          period = 300
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["ContainerInsights", "node_cpu_utilization",
            "ClusterName", "${var.project_name}-cluster"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "RDS CPU Utilization"
          region = var.aws_region
          period = 300
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization",
            "DBInstanceIdentifier", "${var.project_name}-postgres"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "RDS Database Connections"
          region = var.aws_region
          period = 60
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "DatabaseConnections",
            "DBInstanceIdentifier", "${var.project_name}-postgres"]
          ]
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Flask App Logs"
          region = var.aws_region
          query  = "SOURCE '/eks/${var.project_name}/flask-app' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}

