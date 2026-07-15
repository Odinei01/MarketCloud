# Terraform — Amazon Marketing Stream (SQS) para o cockpit horário

Provisiona, na **sua** conta AWS, as filas SQS que recebem o Amazon Marketing
Stream (hora-a-hora, sem supressão) e alimentam `bronze_amazon_ads_hourly`.

Escolhemos **SQS** (não Firehose) porque o destino final é um **banco relacional**
(Postgres do `pricing_db`) — a própria doc da Amazon recomenda SQS nesse caso.

## O que sobe

| Recurso | Por dataset | Papel |
|---|---|---|
| `aws_sqs_queue.ingress` | sp-traffic, sp-conversion | destino que o AMS entrega (é o `destinationArn` da subscription) |
| `aws_sqs_queue.dlq` | sp-traffic, sp-conversion | mensagens que falharam N vezes |
| `aws_sqs_queue_policy.ingress` | sp-traffic, sp-conversion | autoriza o SNS do AMS a `SendMessage` |

Criptografia SSE gerenciada, retenção de 14 dias (cobre o *restatement* da
conversão), redrive para DLQ após `max_receive_count`.

## Pré-requisitos

- Terraform >= 1.5, AWS CLI autenticada (`AWS_PROFILE`/SSO). **Este repo não
  guarda credencial AWS** — o `apply` roda na sua máquina/conta.
- Conta com **AMS liberado** — já validamos: `GET /api/amazon/ads/stream/eligibility`
  retornou `eligible:true` para o profile BR.

## Uso

```bash
cd infra/ams-stream
cp terraform.tfvars.example terraform.tfvars   # ajuste se quiser
terraform init
terraform plan
terraform apply
terraform output ingress_queue_arns            # -> usar na Fase 2
```

## ⚠️ Ponto que EU não cravei (e por quê)

A policy da fila autoriza o **SNS do AMS** a publicar. O ARN **exato** desse SNS
(e o account-id do AMS) é revelado no fluxo de *subscription* (Fase 2) e no guia
de onboarding do seu realm. **Não hardcodei um account-id** porque não consegui
verificá-lo com certeza — preferi deixar `ams_sns_source_arn_pattern` como
variável a te entregar um número possivelmente errado.

- **1º apply:** default `arn:aws:sns:us-east-1:*:*` (só serviço SNS, realm-scoped).
  Funciona para começar, mas é amplo.
- **Depois da Fase 2:** troque por `ArnEquals` do topic exato do AMS e reaplique.
  Fica no princípio de menor privilégio.

## Encaixe nas próximas fases

- **Fase 2 (SWARM):** `POST /streams/subscriptions` com `destinationArn =`
  output `ingress_queue_arns[<dataset>]`, um por dataset.
- **Fase 3 (SWARM):** consumidor Go faz long-poll em `ingress_queue_urls[<dataset>]`,
  upsert **idempotente** por `(dataset, campaignId, hora, janela_atribuição)`
  — tratando *restatement* (não somar), merge traffic+conversion na mesma linha e
  fuso — gravando em `amazon_ads_campaigns_hourly`.

Referência oficial (CDK): https://github.com/amzn/amazon-marketing-stream-examples
