variable "aws_region" {
  description = "Regiao da stack. BR esta no realm NA, que usa us-east-1 no AMS."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefixo dos recursos."
  type        = string
  default     = "zanom-ams"
}

variable "datasets" {
  description = "Datasets do Amazon Marketing Stream a receber, uma fila por dataset."
  type        = list(string)
  default     = ["sp-traffic", "sp-conversion"]
}

variable "ams_sns_source_arn_pattern" {
  description = "Override legado: se preenchido, usa o mesmo SourceArn do SNS do AMS para todos os datasets."
  type        = string
  default     = ""
}

variable "ams_sns_source_arn_patterns" {
  description = "SourceArn do SNS do AMS autorizado a publicar, por dataset/realm."
  type        = map(string)
  default = {
    sp-traffic    = "arn:aws:sns:us-east-1:906013806264:*"
    sp-conversion = "arn:aws:sns:us-east-1:802324068763:*"
  }
}

variable "ams_reviewer_role_arn" {
  description = "Role oficial usada pelo Amazon Marketing Stream para validar atributos da fila SQS."
  type        = string
  default     = "arn:aws:iam::926844853897:role/ReviewerRole"
}

variable "consumer_principal_arns" {
  description = "Principais AWS autorizados a consumir as filas ingress quando nao for possivel atualizar IAM identity policy."
  type        = list(string)
  default     = []
}

variable "message_retention_seconds" {
  description = "Retencao na fila principal. 14 dias cobre a janela de restatement da conversao."
  type        = number
  default     = 1209600
}

variable "dlq_retention_seconds" {
  description = "Retencao na dead-letter queue."
  type        = number
  default     = 1209600
}

variable "visibility_timeout_seconds" {
  description = "Tempo de invisibilidade apos o consumidor pegar a mensagem."
  type        = number
  default     = 300
}

variable "max_receive_count" {
  description = "Tentativas antes de mandar a mensagem para a DLQ."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags aplicadas a todos os recursos."
  type        = map(string)
  default = {
    project = "zanom-marketcloud"
    purpose = "amazon-marketing-stream-hourly"
    managed = "terraform"
  }
}

variable "cloudwatch_monitoring_enabled" {
  description = "Cria dashboard e alarmes CloudWatch para as filas SQS do AMS."
  type        = bool
  default     = true
}

variable "cloudwatch_dashboard_name" {
  description = "Nome opcional do dashboard CloudWatch. Vazio usa <name_prefix>-sqs-monitoring."
  type        = string
  default     = ""
}

variable "cloudwatch_alarm_email" {
  description = "E-mail opcional para receber alarmes via SNS. Vazio cria alarmes sem notificacao."
  type        = string
  default     = ""
}

variable "cloudwatch_alarm_evaluation_periods" {
  description = "Periodos consecutivos para disparar alarmes CloudWatch."
  type        = number
  default     = 1
}

variable "cloudwatch_visible_messages_threshold" {
  description = "Backlog maximo esperado nas filas ingress antes do alarme."
  type        = number
  default     = 1000
}

variable "cloudwatch_oldest_message_age_threshold_seconds" {
  description = "Idade maxima esperada da mensagem mais antiga na fila ingress."
  type        = number
  default     = 3600
}

variable "cloudwatch_delivery_divergence_threshold" {
  description = "Diferenca maxima esperada por hora entre NumberOfMessagesSent e NumberOfMessagesDeleted."
  type        = number
  default     = 100
}
