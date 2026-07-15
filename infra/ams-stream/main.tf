locals {
  # uma fila (+DLQ) por dataset: sp-traffic, sp-conversion
  datasets = toset(var.datasets)

  ams_sns_source_arns = merge(
    var.ams_sns_source_arn_patterns,
    var.ams_sns_source_arn_pattern == "" ? {} : {
      for dataset in var.datasets : dataset => var.ams_sns_source_arn_pattern
    }
  )
}

# ---------- Dead-letter queues ----------
resource "aws_sqs_queue" "dlq" {
  for_each = local.datasets

  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = var.dlq_retention_seconds
  sqs_managed_sse_enabled   = true
  tags                      = merge(var.tags, { dataset = each.key, role = "dlq" })
}

# ---------- Filas de ingress (destino do AMS) ----------
resource "aws_sqs_queue" "ingress" {
  for_each = local.datasets

  name                       = "${var.name_prefix}-${each.key}-ingress"
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, { dataset = each.key, role = "ingress" })
}

# ---------- Policy: autoriza o SNS do AMS a publicar na fila ----------
data "aws_iam_policy_document" "ingress" {
  for_each = local.datasets

  # Permite ao serviço SNS (topic do AMS) chamar SendMessage nesta fila.
  statement {
    sid    = "AllowAmazonMarketingStreamSNS"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingress[each.key].arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.ams_sns_source_arns[each.key]]
    }
  }

  # O CDK oficial da Amazon tambem concede GetQueueAttributes para o
  # ReviewerRole do Marketing Stream; a API usa isso no pre-check do destino.
  statement {
    sid    = "AllowAmazonMarketingStreamReviewer"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.ams_reviewer_role_arn]
    }

    actions   = ["sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.ingress[each.key].arn]
  }

  dynamic "statement" {
    for_each = length(var.consumer_principal_arns) > 0 ? [1] : []
    content {
      sid    = "AllowAmsConsumerRead"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.consumer_principal_arns
      }

      actions = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility",
      ]
      resources = [aws_sqs_queue.ingress[each.key].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "ingress" {
  for_each = local.datasets

  queue_url = aws_sqs_queue.ingress[each.key].id
  policy    = data.aws_iam_policy_document.ingress[each.key].json
}
