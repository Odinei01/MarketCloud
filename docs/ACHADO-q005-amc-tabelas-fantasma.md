# Q005 (AMC): as duas tabelas não existem mais. O dado é fóssil.

Data: 27/08/2026

## O que eu fui consertar

`bronze_amc_campaign_assist` mostrava **R$536.795,68 de venda direta sobre R$1.689,29
de gasto** (ROAS 604 na "Localizador"), numa operação que fatura ~R$28 mil/mês.
Diagnostiquei produto cartesiano: o `JOIN` só por `campaign_id` cruzava cada linha de
tráfego com cada caminho de compra, contando gasto M vezes e venda N vezes.

O diagnóstico do fan-out está certo. Mas o problema real é maior.

## O que eu achei

Tentei cinco reescritas. Todas recusadas pelo AMC. Perseguindo as mensagens do parser
em vez de adivinhar, o quadro é este:

1. **`sponsored_ads_traffic_report` não existe no AMC.** Retorna `Object not found`
   mesmo no `FROM` de topo. A tabela real de tráfego é `sponsored_ads_traffic`, com
   `event_date` (não `date`), `campaign` (não `campaign_name`) e spend em microcents —
   é o que o E001 usa, e o E001 roda todo dia.
2. **`amc_path_to_purchase` também não existe.** Mesmo erro, também no topo. Todos os
   templates que dependem dela (`ASSISTED_CONVERSIONS`, Q037, Q040) estão com 0
   execuções concluídas.
3. **`c.date` não passa mais no parser.** `DATE` é palavra reservada no dialeto atual
   (Apache Calcite estilo BigQuery: aspas duplas são string, identificador citado é
   crase). É o mesmo erro que derruba Q037 e Q040.

## Por que então ele "roda" todo dia

Roda porque **o AMC reaproveita o workflow já validado**. O SQL do Q005 foi aceito
quando essas tabelas ainda existiam e nunca mais passou pelo parser. Qualquer SQL novo
— inclusive o texto **idêntico** ao do seed — é revalidado e recusado. Foi por isso que
minhas cinco tentativas falharam enquanto o agendamento das 09:00 continuava concluindo.

Ou seja: o Q005 não é uma query com bug. É um workflow fóssil, rodando sobre um schema
que o AMC já aposentou, produzindo número que não descreve a operação.

## O que isso contamina

`bronze_amc_campaign_assist` alimenta feature de ML (migrations 063, 064, 065, 067).
De lá o ML consome quatro colunas:

| coluna | estado | por quê |
|---|---|---|
| `assist_rate` | **confiável** | `COUNT(DISTINCT user_id)` — o fan-out duplica linha, não usuário |
| `first_touch_rate` | **confiável** | idem |
| `assisted_roas` | **envenenado** | razão entre dois `SUM()` inflados por fatores diferentes |
| `decision` | **envenenado** | deriva de `direct_roas`, inflado |

## Próximo passo (não executado)

Reconstruir o Q005 sobre `sponsored_ads_traffic` e reconstruir o caminho/touchpoint a
partir das tabelas de atribuição que existem (`amazon_attributed_events_by_traffic_time`
/ `by_conversion_time`) — não há substituta pronta para `amc_path_to_purchase`.

Enquanto isso não existir, `assisted_roas` e `decision` não deveriam pesar no ML.
Cortar feature mexe em dinheiro, então fica como decisão do dono, não como efeito
colateral deste conserto.

## Estado deixado

Template restaurado ao texto do seed (migration 010). Nada foi degradado: o
agendamento das 09:00 continua exatamente como estava antes de eu mexer.
