# Handoff DevOps — Amazon Marketing Stream (filas SQS)

**Objetivo:** provisionar, na conta AWS da ZANOM, as filas SQS que recebem o
Amazon Marketing Stream (dados de anúncios hora-a-hora, push pela Amazon). A
aplicação (marketcloud) consome dessas filas e grava no banco. Já validamos que
a conta de Ads tem AMS liberado; falta só a infra AWS.

Todo o provisionamento está em **Terraform** neste diretório
(`marketcloud/infra/ams-stream/`). Não precisa escrever nada — só rodar e
devolver 3 coisas (ver seção "O que devolver").

---

## 1. O que será criado

| Recurso | Qtd | Nome | Função |
|---|---|---|---|
| SQS Queue (ingress) | 2 | `zanom-ams-sp-traffic-ingress`, `zanom-ams-sp-conversion-ingress` | destino que a Amazon entrega |
| SQS Queue (DLQ) | 2 | `zanom-ams-*-dlq` | mensagens que falharam N vezes |
| Queue Policy | 2 | (inline) | autoriza o SNS do AMS a publicar |

Config já definida no Terraform: SSE (criptografia gerenciada), retenção **14
dias** (cobre a rejanela de atribuição), redrive pra DLQ após 5 tentativas.

**Região: `us-east-1` (obrigatório).** O Brasil está no realm **NA** do AMS, que
só entrega em us-east-1. Não mudar.

---

## 2. Pré-requisitos

- **Conta AWS da ZANOM** (a mesma onde a app vai rodar/ler as filas).
- **Terraform >= 1.5** e **AWS CLI** autenticada nessa conta.
- Credencial de quem roda o `terraform apply` precisa poder criar SQS:
  `sqs:CreateQueue`, `sqs:SetQueueAttributes`, `sqs:GetQueueAttributes`,
  `sqs:TagQueue`, `sqs:GetQueueUrl`. (Não cria IAM role — o caminho SQS não exige.)

---

## 3. Passo a passo

```bash
cd marketcloud/infra/ams-stream
cp terraform.tfvars.example terraform.tfvars      # ajustar se quiser o prefixo
terraform init
terraform plan                                    # confere: 6 a criar, 0 a destruir
terraform apply                                   # digitar 'yes'
terraform output ingress_queue_arns
terraform output ingress_queue_urls
```

> Erro `InvalidClientTokenId` no apply = credencial AWS inválida/expirada, não é
> o Terraform. Rode `aws sts get-caller-identity` até retornar Account/Arn.

---

## 4. ⚠️ IAM da aplicação consumidora (o ponto que mais importa)

Além de criar as filas, a **app marketcloud** precisa de uma identidade AWS com
permissão de **ler** essas duas filas. Crie um **IAM user** (ou role, se a app
rodar em EC2/ECS/EKS) com esta policy e nos entregue a credencial:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AmsConsumerReadIngressQueues",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": [
        "arn:aws:sqs:us-east-1:<ACCOUNT_ID>:zanom-ams-sp-traffic-ingress",
        "arn:aws:sqs:us-east-1:<ACCOUNT_ID>:zanom-ams-sp-conversion-ingress"
      ]
    }
  ]
}
```

`<ACCOUNT_ID>` = o número de 12 dígitos da conta (sai no `terraform apply`).

> Se preferir **role** (recomendado, sem chave estática): crie a role com a
> policy acima e o trust pro serviço onde a app roda; nos diga o Role ARN.
> Se for **IAM user**: gere Access Key + Secret e nos passe por canal seguro
> (não por e-mail/chat aberto).

---

## 5. O que devolver pra gente

1. `terraform output ingress_queue_arns`  → 2 ARNs (sp-traffic, sp-conversion)
2. `terraform output ingress_queue_urls`  → 2 URLs (o consumidor faz long-poll)
3. Credencial do consumidor: **Role ARN** (preferido) **ou** Access Key + Secret
   do IAM user da seção 4.

Com isso, a app cria as subscriptions na Amazon (aponta pras filas) e liga o
consumidor. Nada mais do lado AWS.

---

## 6. Segurança e custo

- **Policy da fila (cross-account):** hoje o Terraform autoriza qualquer SNS em
  us-east-1 (`arn:aws:sns:us-east-1:*:*`) a publicar — amplo pra destravar o
  início. Assim que a app criar a subscription e a Amazon revelar o **SNS topic
  ARN exato**, a gente te passa o valor e você aperta a variável
  `ams_sns_source_arn_pattern` pra `ArnEquals` do topic (menor privilégio) e
  reaplica. Fica anotado no README.
- **Custo:** SQS é barato (US$0,40 / milhão de requisições após o free tier).
  No volume dessa conta, esperado **centavos a poucos dólares/mês**. DLQ e SSE
  gerenciada não têm custo extra relevante.
- **Sem segredo no repo:** o Terraform não guarda credencial; o `apply` usa a
  credencial da sua sessão AWS.

---

## 7. O que NÃO precisa fazer

- ❌ Não criar Firehose, S3, nem Lambda — escolhemos o caminho **SQS** (destino é
  banco relacional; é o recomendado pela própria Amazon nesse caso).
- ❌ Não criar a subscription no AMS — isso a **aplicação** faz via API de Ads.
- ❌ Não mexer na região — us-east-1 é mandatório pro realm NA (BR).

**Resumo do pedido:** rodar o Terraform (seção 3), criar a identidade IAM de
leitura (seção 4), e devolver os 3 itens da seção 5.
