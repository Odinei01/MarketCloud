# ARNs das filas de ingress -> usar como destinationArn na subscription (Fase 2).
output "ingress_queue_arns" {
  description = "ARN por dataset. É o destinationArn do POST /streams/subscriptions."
  value       = { for k, q in aws_sqs_queue.ingress : k => q.arn }
}

output "ingress_queue_urls" {
  description = "URL por dataset. É o que o consumidor Go usa no long-poll da SQS."
  value       = { for k, q in aws_sqs_queue.ingress : k => q.id }
}

output "dlq_arns" {
  description = "ARNs das dead-letter queues (monitorar profundidade > 0 = mensagens falhando)."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.arn }
}

output "next_steps" {
  description = "O que fazer com esses outputs."
  value       = <<-EOT
    1) Confirme o SNS topic ARN do AMS no seu realm (Fase 2 / onboarding) e
       aperte 'ams_sns_source_arn_pattern' para ArnEquals do topic exato.
    2) Fase 2 (SWARM): POST /streams/subscriptions com destinationArn =
       ingress_queue_arns[<dataset>], um por dataset (sp-traffic, sp-conversion).
    3) Fase 3 (SWARM): consumidor Go faz long-poll em ingress_queue_urls[<dataset>].
  EOT
}

output "cloudwatch_dashboard_url" {
  description = "URL do dashboard CloudWatch para acompanhar entrega e consumo das filas AMS."
  value       = var.cloudwatch_monitoring_enabled ? "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.cloudwatch_dashboard_name}" : null
}

output "cloudwatch_alarm_topic_arn" {
  description = "SNS topic dos alarmes CloudWatch, quando cloudwatch_alarm_email for configurado."
  value       = try(aws_sns_topic.cloudwatch_alarms[0].arn, null)
}

output "cloudwatch_read_policy_json" {
  description = "Policy minima para um operador consultar metricas/alarmes/dashboard CloudWatch do AMS."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AmsCloudWatchReadOnly"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetDashboard"
        ]
        Resource = "*"
      }
    ]
  })
}

output "cloudwatch_manage_policy_json" {
  description = "Policy para o usuario/role do Terraform criar e manter o monitoramento CloudWatch do AMS."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AmsCloudWatchMonitoringManage"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetDashboard",
          "cloudwatch:PutDashboard",
          "cloudwatch:DeleteDashboards",
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:TagResource",
          "cloudwatch:UntagResource",
          "cloudwatch:ListTagsForResource"
        ]
        Resource = "*"
      }
    ]
  })
}
