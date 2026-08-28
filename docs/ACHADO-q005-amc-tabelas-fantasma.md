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

---

## RESOLVIDO (28/08) — migration 233

A substituta nao precisou ser inventada: o **Q007** ja reconstruia a jornada, com 161
execucoes concluidas, sobre duas tabelas vivas — `sponsored_ads_traffic` (user_id,
campaign_id, event_dt, spend) e `conversions_with_relevance` (conversao com valor).
Reaproveitei esse miolo e troquei a saida: em vez do caminho como texto, a posicao do
toque (FIRST/MIDDLE/LAST) agregada por campanha.

Gasto e jornada sao agregados SEPARADAMENTE, cada um ja com uma linha por campanha, e
so entao juntados — o fan-out deixa de ser possivel pela forma da query.

### O que o AMC recusou pelo caminho (dialeto real)

| tentativa | recusa |
|---|---|
| `SAFE_DIVIDE(NUMERIC, NUMERIC)` | assinatura inexistente; `CAST AS DOUBLE` nao resolve. Trocado por divisao direta — `NULLIF` ja protege do zero |
| `COUNT(*) OVER (...)` | "COUNT window expression had 0 value expressions"; precisa de `COUNT(coluna) OVER` |

### Duas armadilhas de dado que quase passaram

1. **`conversions_with_relevance` tem uma linha por produto.** O `ROW_NUMBER` percorria
   produto x campanha e a mesma campanha recebia varias ordens — todas as taxas de toque
   saturavam em 1,000. Corrigido deduplicando por `conversion_id`.
2. **`total_product_sales` ja e o total do pedido**, repetido em cada linha. `SUM` sobre
   ele devolveu R$541.589 — praticamente o numero errado antigo, por outra causa.
   Correto e `MAX`.

A primeira so apareceu porque `assist_rate = 1,000` em 19 de 19 campanhas nao passou no
cheiro. A segunda, porque o total foi conferido contra o relatorio de Ads.

### Resultado, conferido contra a fonte autoritativa (13-26/08)

| | Q005 | Ads | leitura |
|---|---|---|---|
| gasto | R$ 1.689,29 | R$ 1.838,42 | 92% — AMC so conta impressao com user resolvido |
| venda direta | R$ 9.251,10 | R$ 7.578,15 | +22% — janela de 28d pega o que o Ads nao atribui |
| maior ROAS | 29,5 | — | era 604 |

`assist_rate` voltou a discriminar (0,045 / 0,000 / 0,136) em vez de saturar.

### Pendente

Religar `amc_assisted_roas` e `amc_protect` no ML (cortadas na migration 232, quando o
dado era lixo). A causa do corte foi removida, mas ha uma execucao validada apenas —
fica como decisao do dono, nao como efeito colateral.

Os outros 19 templates que usam `sponsored_ads_traffic_report` (Q010, Q011, Q017, Q018,
Q021, Q023-Q040) continuam mortos pela mesma tabela fantasma.
