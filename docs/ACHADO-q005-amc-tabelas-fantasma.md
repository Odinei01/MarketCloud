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

---

## Os outros 19 templates (28/08)

Todos os 19 que usam `sponsored_ads_traffic_report` tem **zero execucoes concluidas**.
Nao quebraram: nunca funcionaram. Foram escritos contra um schema imaginado —
`amc_attributed_purchases` (18 deles), `amc_campaign_overlap`, `amc_campaign_users`,
`amc_frequency`, `business_report`, `product_metrics`, `promotion_report`,
`search_term_report`. Nenhuma existe no AMC. Todos ja estavam marcados `BROKEN`.

### Criterio: o que e genuinamente do AMC

O AMC so tem uma coisa que nenhuma outra fonte tem: **`user_id`**, que permite cruzar a
mesma PESSOA entre campanhas, produtos e no tempo. Tudo o mais que esses templates
pediam — venda organica, sessao de pagina, cupom, estoque, margem, ticket, search term —
esta no Postgres, com custo real por SKU e estoque real, sem a supressao do AMC, e ja
alimenta o ML. Traze-lo do AMC seria trocar fonte boa por pior.

| feito no AMC | por que so o AMC |
|---|---|
| **Q005** — assist por campanha | posicao do toque na jornada da mesma pessoa |
| **Q034** — canibalizacao | mesmo usuario alcancado por 2 campanhas |
| **Q037** — saturacao de alcance | impressoes por PESSOA distinta |

Os 17 restantes ficam `BROKEN` de proposito: a resposta deles nao mora aqui.
Q010 (placement) e Q011 (horarios) tambem saem — o Postgres tem fonte horaria mais rica
(ver [[dayparting-data-sources]]).

### O que o Q037 revelou (13-26/08)

| | campanhas | gasto | frequencia | alcance fresco |
|---|---|---|---|---|
| CABE_VERBA | 20 | R$ 1.417,28 | 1,36 | 77,7% |
| MONITOR | 2 | R$ 281,09 | 2,12 | 48,8% |

**Nenhuma campanha esta saturada.** A frequencia media e 1,36 — quase todo mundo viu o
anuncio UMA vez. Nao ha martelo em cima das mesmas pessoas, entao o limite da operacao
nao e alcance. Confirma pelo lado do AMC o que o diagnostico de campanha ja dizia: a
trava e conversao, nao exposicao.

Custo por pessoa alcancada varia 58x: M19-CLONE AUTO a R$0,003 contra Seladora a R$0,18.

---

## Auditoria dos extractors que JA rodavam (28/08)

Rodar nao prova que o numero esta certo — o Q005 rodava havia meses e dava R$536 mil.
Auditei E001, E002, E005-E008, Q016, Q019, Q022 procurando o mesmo tipo de defeito.

### E001: nao infla, FALTA 35%

Confrontado com `amazon_ads_campaigns_daily` (13-26/08):

| | E001 | Ads | |
|---|---|---|---|
| gasto | R$ 1.202,49 | R$ 1.832,20 | **65,6%** |
| venda | R$ 4.920,93 | R$ 7.767,85 | **63,3%** |

Para comparar: o Q005 reconstruido, sobre a MESMA tabela de trafego, captura 92%.

E o oposto do fan-out — sub-cobertura. E gasto e venda caem quase na mesma proporcao
(65,6% e 63,3%), entao o ROAS derivado fica plausivel e o buraco nao aparece. So aparece
conferindo o TOTAL contra quem cobra.

**Causa NAO confirmada.** Minha hipotese era que `traffic_clean` descartava linhas com
`ad_product_type`/`campaign_name` nulos (o lado das conversoes preserva com COALESCE, o
do trafego descarta — assimetria real). Removi o descarte, rodei, e o total ficou
IDENTICO: R$1.202,49. Nao havia linhas nesse estado. Hipotese errada, alteracao revertida
— nao fica mudanca em producao sem ganho medido.

Os 35% seguem sem explicacao. Fica como divida, nao como conserto.

### bronze_amc_campaign_daily acumulava duplicatas

O ingest do E001 nao e idempotente: reingerir o mesmo periodo insere de novo em vez de
substituir. Encontrado ao reingerir manualmente por engano — o pipeline ja ingere sozinho
quando o run chega a MODELING_COMPLETED, e eu chamei por cima.

Limpei 265 linhas duplicadas. **241 eram minhas; 24 ja estavam la** — ou seja, o defeito
e real e vinha acumulando silenciosamente. Hoje a tabela esta com 0 duplicatas.

Corrigir de vez pede indice unico + ON CONFLICT no ingest. Nao apliquei: um indice unico
sobre um INSERT puro quebra o pipeline diario se a chave real for outra. Fica proposto.

### E001/E002/E003 estavam no tenant de seed

Tinham `tenant_id = 00000000-...-0001` enquanto E004..E013 usam o tenant real e outros 49
templates sao globais. O agendamento funcionava (o orchestrator le direto do banco), mas
execucao MANUAL era recusada com STORE_ACCESS_DENIED — os tres extractors mais importantes
nao podiam ser testados sob demanda. Corrigido na migration 239.

---

## Confronto de TODAS as fontes do AMC (28/08)

Cada tabela do AMC da um numero diferente para a MESMA operacao (13-26/08, contra
`amazon_ads_campaigns_daily`):

| fonte | gasto | % | venda | % |
|---|---|---|---|---|
| placement_creative_daily (E007) | R$ 2.092,40 | **114,2%** | — | — |
| product_asin_daily | R$ 1.533,05 | 83,7% | R$ 3.109,32 | 40,0% |
| hourly_performance | R$ 1.344,49 | 73,4% | R$ 237,11 | **3,1%** |
| campaign_daily (E001) | R$ 1.202,49 | 65,6% | R$ 4.920,93 | 63,3% |
| search_term_daily | R$ 1.158,43 | 63,2% | R$ 3.789,39 | 48,8% |
| target_daily | R$ 1.148,60 | 62,7% | R$ 3.814,29 | 49,1% |
| conversions_daily_total (E008) | — | — | R$ 7.538,18 | **97,0%** |
| conversions_unified_daily (E009) | — | — | R$ 4.410,43 | 56,8% |
| new_to_brand_halo_daily (E002) | — | — | R$ 3.109,32 | 40,0% |

**Nao existe "o numero do AMC".** O gasto da mesma operacao varia de 62,7% a 114,2%.

### O E001 nao tem defeito de valor

Comparado dia a dia, campanha a campanha, ele bate **ao centavo**:

| dia | Ads | E001 | placement |
|---|---|---|---|
| 18/08 | 16,69 | **16,69** | 39,12 |
| 19/08 | 24,84 | **24,84** | 62,52 |
| 20/08 | 24,54 | **24,54** | 44,92 |

Os 65,6% sao falta de COBERTURA (dias/campanhas que nao entraram), nao valor errado. O que
esta la esta certo. Isso e divida de ingestao, nao de query.

### O E007 infla, e nao e duplicata nem query

Quase apaguei 27 mil linhas: com chave incompleta apareciam ~14 mil "duplicatas" em
product_asin_daily e ~11 mil em search_term_daily. Inspecionar duas linhas de um grupo
mostrou impressoes 11 e 2 — dado legitimo, separado por `customer_search_term`, que eu
tinha deixado de fora da chave. Com a chave completa: **zero duplicatas** em todas.

A query tambem esta limpa (GROUP BY simples, sem JOIN).

E o proprio AMC: no grao placement x creative ele devolve a mesma impressao em mais de uma
combinacao. **O gasto nao e somavel nesse grao.**

### O que foi cortado do ML (migration 240)

A inflacao e uniforme — gasto 1,142, cliques 1,139, impressoes 1,147. A linha e replicada
inteira, entao toda razao se preserva:

| feature | estado |
|---|---|
| `top_search_spend_share_45d`, `product_page_*`, `rest_search_*` (shares) | **ficam** — razao imune |
| `top_search_cpc_45d`, `product_page_cpc_45d`, `rest_search_cpc_45d` | **ficam** — razao imune |
| `placement_spend_45d`, `placement_clicks_45d`, `placement_impressions_45d` | **cortados** |
| `top_search_spend_45d`, `product_page_spend_45d`, `rest_search_spend_45d` | **cortados** |

Verificado: 1.087 linhas, 0 nao-nulas nos absolutos, shares e CPC vivos em 408.

### Hierarquia de confianca do AMC

1. **Dinheiro (gasto e venda absolutos): use o relatorio de Ads, nunca o AMC.**
2. **E008** (venda, 97%) e o melhor agregado de venda do AMC.
3. **E001** e exato no que cobre, mas cobre 66%.
4. **hourly_performance**: 3,1% de venda — inutilizavel para venda por hora, o que confirma
   a decisao ja tomada em [[cockpit-fonte-cega-amc]] e [[dayparting-data-sources]].
5. **Razoes e shares** do AMC sobrevivem mesmo onde os absolutos nao.

---

## Por que faltam 35% no E001 (28/08) — RESPONDIDO

Nao e bug do E001. **E supressao do AMC, e ela cresce conforme o grao fica mais fino.**

O mesmo gasto, lido da MESMA tabela `sponsored_ads_traffic`, no mesmo periodo:

| query | grao | cobertura do gasto |
|---|---|---|
| Q005 | campanha | **92%** |
| E001 | dia x campanha | **66%** |
| hourly_performance | hora x campanha | 73% de gasto, **3,1% de venda** |

Quanto mais fina a quebra, mais o AMC suprime. E o mesmo fenomeno ja registrado em
[[cockpit-fonte-cega-amc]] (25 de 361 horas com venda) — agora medido como gradiente.

### O que foi descartado no caminho

- **Nao e filtro da query.** Removi `campaign IS NOT NULL` e `ad_product_type IS NOT NULL`
  do `traffic_raw` (o filtro efetivo) e do `traffic_clean`: resultado IDENTICO ao centavo,
  R$1.202,49. Testei tambem trocar `event_date` por `CAST(event_dt AS DATE)`: identico.
- **Nao e campanha excluida.** So 1 campanha nunca aparece, e ela gastou R$0,00.
- **Nao sao campanhas SD.** As mesmas campanhas aparecem em uns dias e somem em outros
  (Porta Capsula: presente em 7 dias, ausente em 6). Se fosse tipo, faltaria sempre.
- **Nao e volume baixo do jeito obvio.** Os pares ausentes gastam MAIS que os presentes
  (R$8,99 contra R$5,22 de media). O limiar do AMC e de USUARIOS unicos, nao de gasto —
  campanha com CPC alto atinge poucas pessoas e cai na supressao mesmo gastando bem.
- **Nao e lag nem janela.** A janela e de 14 dias e rola diariamente: o dia 13 foi
  reprocessado uma duzia de vezes e as campanhas continuaram ausentes.
- **Nao sao as linhas sem data.** O CSV traz linhas com `data_date` vazio (o ingest as
  reporta como `skipped`), mas elas somam **R$0,00** de gasto — sao conversoes sem trafego
  (brand halo / view-through), justamente o que a migration 036 quis capturar.

### O numero que fecha o diagnostico

Uma execucao do E001 com janela de 14 dias devolve **90 linhas e R$222,07** de gasto,
num periodo em que a Amazon cobrou R$1.832,20. Uma execucao isolada cobre ~12%. O bronze
so chega a 66% porque **acumula** ~14 execucoes diarias via upsert — e nunca completa,
porque os pares suprimidos sao suprimidos em toda execucao.

### Consequencia pratica

Os 35% nao tem conserto: e como o AMC funciona. O que muda e a regra de uso, ja aplicada:

- **gasto e venda absolutos: relatorio de Ads, sempre.** O E001 e exato no que traz
  (bate ao centavo), mas nunca traz tudo.
- **do AMC: jornada, sobreposicao, alcance e razoes** — o que depende de `user_id` e
  nenhuma outra fonte tem.
- **quanto mais fino o grao pedido ao AMC, menos confiavel o total.**

Template restaurado ao original (migration 036). Nenhuma das quatro variacoes testadas
ficou no banco.
