##############################################
# monitoring.tf — Log groups, SNS, alarms
##############################################

# ── CloudWatch Log Groups ─────────────────────
resource "aws_cloudwatch_log_group" "instance" {
  name              = "/ec2/hardened/${var.environment}"
  retention_in_days = var.log_retention_days
  tags              = { Name = "/ec2/hardened/${var.environment}" }
}

resource "aws_cloudwatch_log_group" "userdata" {
  name              = "/ec2/hardened/${var.environment}/userdata"
  retention_in_days = var.log_retention_days
  tags              = { Name = "/ec2/hardened/${var.environment}/userdata" }
}

# ── SNS Topic ─────────────────────────────────
resource "aws_sns_topic" "alarms" {
  name = "EC2Alarms-${var.environment}"
  tags = { Name = "EC2Alarms-${var.environment}" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ── CloudWatch Alarms ─────────────────────────

# CPU utilisation alarm
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "HighCPU-${var.environment}"
  alarm_description   = "CPU over ${var.cpu_alarm_threshold}% on HardenedEC2-${var.environment}"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.hardened.id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = { Name = "HighCPU-${var.environment}" }
}

# Disk usage alarm (CloudWatch Agent custom metric)
resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "HighDisk-${var.environment}"
  alarm_description   = "Disk usage over ${var.disk_alarm_threshold}% on HardenedEC2-${var.environment}"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.disk_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.hardened.id
    path       = "/"
    fstype     = "xfs"
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = { Name = "HighDisk-${var.environment}" }
}

# Instance status check alarm
resource "aws_cloudwatch_metric_alarm" "status" {
  alarm_name          = "StatusCheckFailed-${var.environment}"
  alarm_description   = "Instance status check failed for HardenedEC2-${var.environment}"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.hardened.id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = { Name = "StatusCheckFailed-${var.environment}" }
}
