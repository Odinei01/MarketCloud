locals {
  cloudwatch_dashboard_name = var.cloudwatch_dashboard_name != "" ? var.cloudwatch_dashboard_name : "${var.name_prefix}-sqs-monitoring"
  cloudwatch_alarm_actions  = var.cloudwatch_alarm_email != "" && var.cloudwatch_monitoring_enabled ? [aws_sns_topic.cloudwatch_alarms[0].arn] : []
}

resource "aws_sns_topic" "cloudwatch_alarms" {
  count = var.cloudwatch_monitoring_enabled && var.cloudwatch_alarm_email != "" ? 1 : 0

  name = "${var.name_prefix}-cloudwatch-alarms"
  tags = merge(var.tags, { role = "cloudwatch-alarms" })
}

resource "aws_sns_topic_subscription" "cloudwatch_alarm_email" {
  count = var.cloudwatch_monitoring_enabled && var.cloudwatch_alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.cloudwatch_alarms[0].arn
  protocol  = "email"
  endpoint  = var.cloudwatch_alarm_email
}

resource "aws_cloudwatch_dashboard" "ams_sqs" {
  count = var.cloudwatch_monitoring_enabled ? 1 : 0

  dashboard_name = local.cloudwatch_dashboard_name
  dashboard_body = jsonencode({
    widgets = flatten([
      for idx, dataset in var.datasets : [
        {
          type   = "metric"
          x      = 0
          y      = idx * 12
          width  = 12
          height = 6
          properties = {
            title   = "${dataset} ingress: visible messages"
            view    = "timeSeries"
            region  = var.aws_region
            stat    = "Maximum"
            period  = 300
            metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.ingress[dataset].name]]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = idx * 12
          width  = 12
          height = 6
          properties = {
            title   = "${dataset} ingress: oldest message age"
            view    = "timeSeries"
            region  = var.aws_region
            stat    = "Maximum"
            period  = 300
            metrics = [["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.ingress[dataset].name]]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = idx * 12 + 6
          width  = 12
          height = 6
          properties = {
            title  = "${dataset} ingress: sent vs deleted"
            view   = "timeSeries"
            region = var.aws_region
            stat   = "Sum"
            period = 3600
            metrics = [
              ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.ingress[dataset].name, { label = "Sent" }],
              [".", "NumberOfMessagesDeleted", ".", ".", { label = "Deleted" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = idx * 12 + 6
          width  = 12
          height = 6
          properties = {
            title   = "${dataset} DLQ: visible messages"
            view    = "timeSeries"
            region  = var.aws_region
            stat    = "Maximum"
            period  = 300
            metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq[dataset].name]]
          }
        }
      ]
    ])
  })
}

resource "aws_cloudwatch_metric_alarm" "ingress_visible_messages" {
  for_each = var.cloudwatch_monitoring_enabled ? local.datasets : toset([])

  alarm_name          = "${var.name_prefix}-${each.key}-ingress-visible-messages"
  alarm_description   = "AMS ${each.key} ingress queue has visible messages above the expected polling backlog."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = var.cloudwatch_alarm_evaluation_periods
  threshold           = var.cloudwatch_visible_messages_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.cloudwatch_alarm_actions
  ok_actions          = local.cloudwatch_alarm_actions

  dimensions = {
    QueueName = aws_sqs_queue.ingress[each.key].name
  }

  tags = merge(var.tags, { dataset = each.key, role = "cloudwatch-alarm" })
}

resource "aws_cloudwatch_metric_alarm" "ingress_oldest_message_age" {
  for_each = var.cloudwatch_monitoring_enabled ? local.datasets : toset([])

  alarm_name          = "${var.name_prefix}-${each.key}-ingress-oldest-message-age"
  alarm_description   = "AMS ${each.key} ingress queue has messages older than the expected consumer SLA."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = var.cloudwatch_alarm_evaluation_periods
  threshold           = var.cloudwatch_oldest_message_age_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.cloudwatch_alarm_actions
  ok_actions          = local.cloudwatch_alarm_actions

  dimensions = {
    QueueName = aws_sqs_queue.ingress[each.key].name
  }

  tags = merge(var.tags, { dataset = each.key, role = "cloudwatch-alarm" })
}

resource "aws_cloudwatch_metric_alarm" "dlq_visible_messages" {
  for_each = var.cloudwatch_monitoring_enabled ? local.datasets : toset([])

  alarm_name          = "${var.name_prefix}-${each.key}-dlq-visible-messages"
  alarm_description   = "AMS ${each.key} DLQ received messages; inspect parsing/consumer failures."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.cloudwatch_alarm_actions
  ok_actions          = local.cloudwatch_alarm_actions

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  tags = merge(var.tags, { dataset = each.key, role = "cloudwatch-alarm" })
}

resource "aws_cloudwatch_metric_alarm" "ingress_sent_deleted_divergence" {
  for_each = var.cloudwatch_monitoring_enabled ? local.datasets : toset([])

  alarm_name          = "${var.name_prefix}-${each.key}-sent-deleted-divergence"
  alarm_description   = "AMS ${each.key} sent/deleted divergence suggests delivery without successful consumer deletion."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.cloudwatch_alarm_evaluation_periods
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.cloudwatch_alarm_actions
  ok_actions          = local.cloudwatch_alarm_actions

  metric_query {
    id          = "sent"
    return_data = false

    metric {
      namespace   = "AWS/SQS"
      metric_name = "NumberOfMessagesSent"
      period      = 3600
      stat        = "Sum"
      dimensions = {
        QueueName = aws_sqs_queue.ingress[each.key].name
      }
    }
  }

  metric_query {
    id          = "deleted"
    return_data = false

    metric {
      namespace   = "AWS/SQS"
      metric_name = "NumberOfMessagesDeleted"
      period      = 3600
      stat        = "Sum"
      dimensions = {
        QueueName = aws_sqs_queue.ingress[each.key].name
      }
    }
  }

  metric_query {
    id          = "divergence"
    expression  = "IF((sent-deleted) > ${var.cloudwatch_delivery_divergence_threshold}, 1, 0)"
    label       = "Sent minus deleted over threshold"
    return_data = true
  }

  tags = merge(var.tags, { dataset = each.key, role = "cloudwatch-alarm" })
}
