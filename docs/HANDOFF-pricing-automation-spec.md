# HANDOFF — Pricing Automation Engine (ZANOM) — Especificacao Tecnica v1.1

Data: 2026-07-19 (v1.1: escala ~30 SKUs e expandindo -> tiering + near-term recalibrado)
Status: SPEC (nada construido ainda)
Marker: `zanom-pricing-automation-spec-v1`

**Escala real:** ~30 SKUs hoje, com intencao de EXPANDIR (100+). Isso justifica
construir a FUNDACAO escalavel agora (ledger, policy por SKU, executor Approval,
painel) — mas NAO o ML pesado, e SEM tratar os 30 SKUs como iguais (ver §5B
Tiering). A 30-e-crescendo a decisao vira "comecar a construir a fundacao", nao
"esperar" — mudanca vs a leitura inicial de 10 SKUs.

Robo de precificacao/promocao baseado em ML + aprendizado continuo, IRMAO do
MktAutomation (Ads) e coordenado por um orquestrador comercial. Este documento e
a spec aterrada na base REAL da ZANOM (nao um design generico) — reusa o padrao
do Full Control 360, os dados de estoque/FBA/margem e a infra de holdout/outcome
que ja existem.

---

## 0. Principio-guia (a regra que nao pode ser esquecida)

O robo NAO otimiza "qual preco vende mais". Otimiza **qual combinacao de preco,
promocao, Ads e momento maximiza o LUCRO DE CONTRIBUICAO esperado**, respeitando
estoque, margem, concorrencia e risco de ruptura — e mede o **efeito
INCREMENTAL**, nao a correlacao.

**Restricao dominante (aprendida nesta operacao):** o gargalo NAO e modelo, e
VOLUME DE DADO POR SKU. Hoje: ~30 SKUs, ~170 pedidos atribuidos no total =
**~5-6 pedidos por SKU na historia inteira**, e cada mudanca de preco "descansa"
48-72h pra medir efeito. CONTRAINTUITIVO: mais SKUs SEM mais trafego deixa o dado
por-SKU MAIS fino, nao menos. Isso GATEIA as fases: elasticidade causal e bandit
por-SKU estao a 6-18 MESES de dado, nao de codigo. Ver §10. Nao repetir o erro do
V3 (construir ML sofisticado sobre dado que nao existe).

**O que a escala de 30-e-expandindo muda vs 10 estatico:** justifica construir a
FUNDACAO escalavel agora (a 100+ SKUs a mao e inviavel) e da poder ao pooling
hierarquico. NAO muda a regra de que ML por-SKU e gateado por dado. Sintese: pode
COMECAR a construir; comece pela fundacao e pelo roteador de tier (§5B), nao pelo
ML.

---

## 1. Arquitetura e onde cada coisa vive (espelha o Full Control 360)

O Full Control ja provou o padrao: **cerebro de ML no marketcloud, maos de
execucao no SWARM (mercado-data-app), ponte por FDW**. A precificacao segue igual.

```
                 CommercialOrchestrator  (novo — reconcilia Ads x Preco x Estoque)
                          |
     +--------------------+--------------------+
     |                                         |
  MktAutomation (existe)               PricingAutomation (novo)
  marketcloud: ML de bid                marketcloud: ML de preco/elasticidade
  SWARM: executor de bid                SWARM: executor de preco/cupom (SP-API)
```

- **marketcloud (`marketcloud_db`, mcadmin, :5433)** — cerebro:
  - Pricing feature store + snapshot; modelos (forecast/conversao/elasticidade)
    no fleet do `modeling-worker` (Python), reusando `model_registry`, features
    de calendario (`feature_*_calendar_context_v1`), holdout
    (`marketcloud_control.holdout_cells`, `v_holdout_analysis_v1`) e loop de
    outcome (`v_learning_loop_hourly_v1`).
  - Decision engine + ledger `pricing_decisions` + policy por SKU + telas React.
  - Le dado de estoque/FBA/orders do SWARM via FDW `swarm_src`.
- **mercado-data-app / SWARM (`pricing_db`=pricing_intelligence, admin, :5432)** —
  maos + fonte de dado:
  - Fonte: `stock_position`, `stock_movements`, `amazon_fba_inventory`,
    `amazon_ads_campaigns_daily`, orders, ASIN_DATA_API (concorrente/BSR).
  - **Executor de preco/cupom** espelhando
    `internal/services/amazon_ads_full_control_executor.go`: audit-ANTES-da-
    Amazon, kill-switch, allowlist por SKU, cooldown, post-write confirmation.
  - Endpoint `POST /api/pricing/execute-action` (igual ao full-control/execute).

**Por que esse split:** o SP-API de listing/preco e a integracao Amazon vivem no
SWARM; o ML e a governanca de decisao vivem no marketcloud. Nao inventar um 3o
lugar.

---

## 2. FASE 0 — Feasibility SP-API (FAZER ANTES DE QUALQUER LINHA)

Risco tecnico #1: **da pra executar todas as acoes via API?** Sem isso, constroi-
se um motor que nao consegue agir. Validar, em ambiente de teste:

- **Preco:** `PATCH` de preco via SP-API **Listings Items API**
  (`putListingsItem` / `patchListingsItem`, atributo `purchasable_offer`).
  Confirmar latencia de propagacao e rollback.
- **Cupom / promocao:** ATENCAO — no BR a criacao programatica de cupom/deal e
  LIMITADA. Verificar se ha API (`Amazon Coupons`/`Deals`) disponivel pra conta;
  se nao, `ACTIVATE_COUPON_*` vira **acao semi-manual** (o robo recomenda, humano
  aplica no Seller Central) na v1. Isso muda o executor.
- **Buy Box / Featured Offer:** confirmar leitura via Product Pricing API
  (`getFeaturedOfferExpectedPrice` / `getCompetitiveSummary`).

**Criterio de aceite Fase 0:** documento dizendo, por acao, se e
`API_FULL` (auto), `API_PARTIAL` (auto com ressalva) ou `MANUAL` (so recomenda).
Esse mapa define o `allowed_actions` executavel do executor.

---

## 3. Acoes discretas (nunca preco livre)

Enum canonico (mesma filosofia do Full Control: primitivo discreto + guardrail):

```
KEEP_PRICE
INCREASE_PRICE_2 | INCREASE_PRICE_5
DECREASE_PRICE_2 | DECREASE_PRICE_5 | DECREASE_PRICE_8
ACTIVATE_COUPON_5 | ACTIVATE_COUPON_10 | REMOVE_COUPON
CREATE_PROMO | STOP_PROMOTION | LIMIT_PROMO_STOCK
FULL_PRICE_MODE
INTENSIFY_ADS_DURING_PROMO | REDUCE_ADS_LOW_MARGIN   (delega ao MktAutomation)
NO_ACTION_LOW_CONFIDENCE
```

Preco e promocao sao ENTIDADES SEPARADAS (psicologia/exibicao diferem):
`base_price`, `displayed_price`, `coupon_percentage`, `promotion_type`,
`reference_price`, `discount_badge`, `promo_duration`, `promo_units_limit`.

---

## 4. Modelo de dados (DDL esqueleto — schema `pricing` no pricing_db)

### 4.1 `pricing.policy_sku` — guardrails por SKU (config, igual full_control_pilots)
```
sku TEXT, asin TEXT, marketplace TEXT,
min_price NUMERIC, max_price NUMERIC, min_contribution_margin NUMERIC,
max_daily_change_pct NUMERIC, cooldown_hours INT,
min_promo_duration_hours INT, max_promo_duration_days INT,
minimum_stock_cover_days INT,
allowed_actions TEXT[],          -- filtrado pelo mapa da Fase 0 E pelo tier
tier CHAR(1),                     -- A|B|C|D recomputado diario (§5B) -> decide estrategia
tier_reason TEXT, tier_updated_at TIMESTAMPTZ,
mode TEXT,                        -- observe|approval|controlled_auto|full_auto
status TEXT,                      -- active|paused|draft
created_by/updated_by/created_at/updated_at
```
LICAO DA MIGRATION 136/137/138: economia (preco/custo) NUNCA digitada solta sem
validacao, e ESTOQUE sempre do `amazon_fba_inventory` ao vivo (nunca o total
manual). O `minimum_stock_cover_days` e a unica coisa "de negocio" digitada.

### 4.2 `pricing.decisions` — ledger (espelha ml_full_control_action_recommendations)
```
decision_id, sku, asin, marketplace, decision_timestamp,
current_price, recommended_price, executed_price,
coupon_before, coupon_after, action_type,
model_version, policy_version, experiment_id,
expected_units, expected_revenue, expected_margin, expected_conversion,
expected_stock_cover, confidence_score, exploration_probability,
decision_reason, blocked_reason, guardrail_triggered,
executed_at, valid_until, evaluation_window_start, evaluation_window_end,
actual_units, actual_revenue, actual_margin, actual_conversion,
incremental_units, incremental_margin, reward,
decision_status   -- RECOMMENDED|APPROVED|EXECUTED|BLOCKED|ROLLED_BACK|EVALUATED
```

### 4.3 `pricing.feature_snapshot` — estado NO MOMENTO da decisao
Chave `decision_id`. Guarda TODAS as variaveis (tempo, preco, funil, Ads,
estoque, produto) do §5. Sem isso o retreino aprende correlacao errada. E o
equivalente do que faltou no P1-6 do ML (linhagem).

### 4.4 `pricing.experiments` — testes controlados (reusa holdout)
Celulas tratamento/controle por periodo, ligadas a `marketcloud_control.
holdout_cells` (mesma mecanica ja usada no Ads).

---

## 5. Feature store (a maioria JA EXISTE — so mapear)

| Grupo | Fonte que JA existe | Novo a construir |
|---|---|---|
| Tempo/calendario | `feature_*_calendar_context_v1` (mig 129) | — |
| Estoque | `amazon_fba_inventory`, `stock_position` | velocidade/tendencia/lead-time |
| Margem/custo | feature comercial (mig 137) | margem-apos-desconto |
| Funil/AMC | AMC (`amazon_attributed_events_*`, DPV/ATC) | serie de DPV/ATC por SKU/dia |
| Ads | `gold_hourly_signal_unified`, model_registry V2 | TACOS, participacao org/paga |
| Preco | — | historico de preco/promo (7/15/30/90d), elasticidade por faixa |
| Produto/oferta | ASIN_DATA_API (nota/review/BSR), FBA | estagio do ASIN, buy-box share |

O que REALMENTE falta construir e o **historico de preco/promocao** e a
**velocidade de venda** — sem eles nao ha elasticidade. Fase 1 comeca por isso.

**Distincao critica que o AMC habilita:** separar "sem venda por PRECO ruim" de
"sem venda por FALTA DE TRAFEGO" de "sem venda por OFERTA/anuncio ruim". Sem essa
separacao, o robo baixa preco quando o problema era trafego.

---

## 5B. Tiering / roteador por SKU (a espinha dorsal que faz escalar de 30 -> 300)

**Regra central:** NAO tratar os 30 SKUs (nem os 300 futuros) como iguais. O
motor primeiro CLASSIFICA cada SKU e ROTEIA para uma estrategia diferente por
riqueza de dado e estagio de vida. Sem isso, escalar vira caos e o ML faminto
contamina o SKU cauda-longa.

### Dimensoes de classificacao (calculadas, nao digitadas)
- **Riqueza de dado:** pedidos/dia, nº de faixas de preco ja observadas,
  meses de historico. Define se ha sinal pra ML ou so pra regra.
- **Estagio de vida:** lancamento | crescimento | maturidade | liquidacao
  (deriva de idade do ASIN + tendencia de velocidade + cobertura de estoque).
- **Estoque:** cobertura em dias vs lead-time (empurra defesa vs pressao promo).

### Tiers e estrategia roteada
| Tier | Criterio | Estrategia de preco | ML? |
|---|---|---|---|
| **A — Volumoso/maduro** | pedidos/dia altos, historico com variacao de preco | experimentos de preco + modelo proprio | sim, dado proprio |
| **B — Crescimento** | subindo, dado moderado | pooling (prior de categoria) + regras + cupom-teste | pooled |
| **C — Cauda-longa/novo** | poucos pedidos, sem variacao de preco | SO regras deterministicas + herda elasticidade da CATEGORIA | nao (so prior) |
| **D — Liquidacao** | cobertura > 90d ou fim de ciclo | peso alto no custo de estoque, desconto agressivo dentro do guardrail | regra + heuristica |

- O `tier` e um campo recomputado (diario) em `pricing.policy_sku`, e ele decide
  `allowed_actions` efetivo, frequencia e SE o SKU entra em experimento.
- **Pooling hierarquico opera SOBRE os tiers:** a elasticidade aprendida nos
  Tier A/B da categoria vira PRIOR Bayesiano pros Tier C da mesma categoria. E
  como 30 SKUs magros geram sinal util — o que bandit por-SKU nunca faria.
- Ao expandir (novos SKUs entram como Tier C), eles ja nascem cobertos por regra
  + prior de categoria, sem precisar de ML proprio. Isso e o que faz 30 -> 300
  sem reescrever o motor.

---

## 6. Objetivo / recompensa

```
reward = contribution_margin
       - stockout_risk_penalty
       - excess_inventory_penalty
       - price_change_penalty        (anti-oscilacao — ESSENCIAL)
       - buybox_loss_penalty
       - advertising_waste_penalty
```
`contribution_margin` usa preco/custo/comissao/frete/imposto REAIS. O
`price_change_penalty` impede o robo de reagir a ruido (ex.: 1 pedido). Regra dura
gemea do Risk: **nunca alterar preco por causa de uma unica venda.**

---

## 7. Executor de preco (espelha amazon_ads_full_control_executor.go)

Endpoint SWARM `POST /api/pricing/execute-action`. Sequencia OBRIGATORIA (mesma
do Full Control, ja auditada — migration/commit 0d9e6e3):

1. `!realWrite` (dry-run ou mode!=auto) -> retorna `DRY_RUN` antes de tudo.
2. **AUDIT ANTES DA AMAZON:** grava `pricing.decisions` (status RUNNING) +
   snapshot. Falha de persistencia -> `AUDIT_PERSIST_FAILED`, NAO chama Amazon.
3. Gates (todos precisam passar pra `realWrite`):
   - kill-switch `PRICING_EXECUTE_ENABLED=true` (default OFF);
   - SKU em `PRICING_ALLOWLIST_SKUS`;
   - `policy_sku.status='active'` AND `mode` permite a acao;
   - guardrails §8 OK; cooldown OK; endpoint cooldown (rate limit) OK.
4. Chama SP-API (preco/cupom).
5. **Post-write confirmation** (le de volta o preco aplicado); senao
   `FAILED_POST_WRITE_CONFIRMATION`. Fecha `EXECUTED` ou `FAILED_*`.

**Kill-switches (default OFF, igual Full Control):** `PRICING_EXECUTE_ENABLED`,
`PRICING_ALLOWLIST_SKUS`, `PRICING_APPLY_DRY_RUN=true`. Nunca armar sem o dono.

---

## 8. Guardrails (motor deterministico — barram ANTES do ML)

- Nunca vender < `min_contribution_margin`.
- Nunca > 1 mudanca de preco no `cooldown_hours`.
- Nunca reduzir preco com `stock_cover_days < lead_time + seguranca`.
- Nunca aumentar > `max_price` nem reduzir < `min_price`.
- Nunca criar promo sem estoque suficiente pro `promo_units_limit`.
- Nunca acao com `confidence_score < min`.
- Nunca acao por 1 venda.
Estoque SEMPRE do `amazon_fba_inventory` ao vivo (licao mig 138: a trava usa dado
real, nao total manual).

### Circuit breaker (gemeo do Risk STOP LOSS)
- Preco caiu e margem total caiu > 15% -> rollback + bloqueia reducao 7 dias.
- Preco subiu e conversao caiu > 30% sem compensar margem -> rollback.
- Promo consumiu > 30% do estoque antes de 25% da janela -> suspende.
- Concorrente sem estoque -> congela desconto, avalia aumento.

---

## 9. Estados operacionais (identico ao arme faseado do Full Control)

`Observe` (so registra) -> `Approval` (recomenda, humano aprova) ->
`Controlled Auto` (so acoes leves: +-2%, cupom <=5%, dentro do guardrail) ->
`Full Auto` (tudo autorizado, com circuit breaker + rollback).
Comecar em Observe. So subir de modo com dado de outcome provando ganho.

---

## 10. Fases de ML — GATEADAS POR DADO (a parte honesta)

| Fase | Entrega | Metodo | Gate |
|---|---|---|---|
| 1 | coleta + margem real + regras + simulador de faixas | motor deterministico | AGORA |
| 2 | conversao/unidades esperadas por preco; ranking por margem | XGBoost/LightGBM tabular (NAO rede neural) | ~semanas de dado |
| 3 | elasticidade + efeito CAUSAL/incremental | diff-in-diff, matched periods, synthetic control (reusa holdout) | MESES de dado |
| 4 | escolha adaptativa de acao | contextual bandit (Thompson/LinUCB) COM restricao de margem/estoque | 6-18 MESES de dado |

**Correcao do plano original p/ a escala da ZANOM:** com 10 SKUs magros, bandit
POR-SKU nunca converge. Usar **pooling hierarquico**: aprender elasticidade no
nivel de CATEGORIA e usar como PRIOR Bayesiano por SKU (borrow strength). Extrai
sinal de pouca cauda que o bandit por-SKU nao extrai. Comecar Fase 2 ja pooled.

`IncrementalLift = VendaObservada - VendaEsperadaSemPromocao` — NUNCA contar toda
venda promocional como gerada pela promo. Reusa a mecanica de contrafactual do
holdout que ja roda no Ads.

---

## 11. Frequencia

Coleta/indicadores: 1h. Previsao: 6h. Recomendacao comercial: 1x/dia. Mudanca
normal de preco: no maximo a cada 48-72h. Promo: minimo 48-72h. Emergencia
(ruptura/erro de preco/margem negativa): imediata via circuit breaker.
Mudanca frequente demais DESTROI o aprendizado (o modelo precisa observar o
efeito) — mesma logica do `price_change_penalty`.

---

## 12. Telas (React, padrao do modal Keywords x hora ja consertado)

Cada decisao AUDITAVEL, nunca "a IA decidiu":
```
RECOMENDACAO: Ativar cupom 5% por 72h.
MOTIVOS: conversao 24% abaixo do esperado; DPV 18% acima; estoque 74 dias;
         margem apos desconto R$14,20; cupons 5% subiram conversao 16% neste ASIN.
PREVISAO: unidades 11->14; margem R$176->R$191; confianca 78%.
LIMITACOES: promo limitada a 20 un; reavaliar em 72h.
```
Reusa o padrao `explanation_json` + matview (mig 139) pra nao travar a tela.

---

## 13. Orquestrador comercial (o valor real — nao otimizar isolado)

`CommercialOrchestrator` reconcilia antes de executar:
```
Pricing: "cupom 5% sobe conversao prevista 18%."
Ads:     "com essa conversao, +12% no bid da keyword."
Estoque: "nao — cobertura cairia < 18 dias."
Orquestrador: "manter cupom, LIMITAR unidades promo, PRESERVAR bid."
```
Implementacao: uma camada de reconciliacao que le recomendacoes das duas engines
+ estado de estoque e emite a decisao final coordenada. Ads e Preco NUNCA
executam direto sem passar por aqui quando a acao de um afeta o outro.

---

## 14. Roadmap / orcamento (esforco focado, reusando infra)

| Fase | Escopo | Esforco | Depende |
|---|---|---|---|
| 0 Feasibility | write de preco+cupom SP-API | 2-4 dias | — |
| 1 MVP | coleta+regras+margem+ledger+snapshot+**tier classifier (§5B)**+tela+simulador | 3-5 semanas | 0 |
| Executor | preco/cupom modo Observe->Approval (espelha Full Control) | 2-3 semanas | 1 |
| 2 ML preditivo | conversao/unidades POOLED por categoria + simulador | 3-4 semanas | dado da 1 |
| 3 Causal | incremental lift, testes controlados (reusa holdout) | 2-3 sem codigo | MESES dado |
| 4 Bandit/hier. | Thompson/LinUCB com guardrail, so Tier A | semanas codigo | 6-18m dado |

**Recomendacao recalibrada (30 SKUs e expandindo):** a 30-e-crescendo, COMECAR a
construir a fundacao ja se justifica (a 100+ SKUs a mao e inviavel). Near-term
(0+1+executor Approval): **~6-9 semanas** -> robo de preco em recomendacao+
aprovacao, margem real, outcome medido, **roteado por tier**. **Cupom-first**
(mais seguro/rapido de aprender que mexer no preco). Segurar 3/4 atras do dado;
NUNCA Full-Auto de preco cedo (raio de estrago > bid: e publico e visto pelo
concorrente).

---

## 15. Criterios de aceite por fase

- **F0:** mapa por acao (API_FULL/PARTIAL/MANUAL). Sem chute.
- **F1:** toda recomendacao grava decision + snapshot completo; margem calculada
  com custo/comissao/frete/imposto reais; guardrails barram em teste; tela
  auditavel. Zero write real (Observe).
- **Executor:** dry-run nunca chama Amazon; audit-antes-da-Amazon; post-write
  confirmation; kill-switch default OFF; `go test` do executor OK (espelhar os
  testes do Full Control).
- **F2:** modelo bate baseline (regra ingenua) em outcome medido, com metrica
  HONESTA (holdout/incremental, nao correlacao) — licao do AUC clicado.
- **F3:** incremental lift reconcilia com contrafactual do holdout.
- **F4:** so liga com Fase 3 madura; exploration limitada por guardrail.

---

## 16. Riscos (nomeados, nao escondidos)

1. **DADO** — o maior. Fases 3/4 sao dado, nao codigo. Mitigacao: pooling
   hierarquico + comecar coleta JA (Fase 1) pra o relogio correr.
2. **API de cupom/promo BR limitada** — pode forcar acao manual (Fase 0 decide).
3. **Confusao preco vs cupom** — tratar como entidades separadas desde o schema.
4. **Integridade do mapa SKU/ASIN/economia** — MESMO risco do Full Control
   (tabela manual). Reusar a licao: estoque do FBA ao vivo, validar ASIN, nao
   digitar solto. Ver §4.1 e as migrations 136-138.
5. **Ads x Preco brigando** — resolvido pelo CommercialOrchestrator (§13).

---

## 17. Nome

Produto: **PricingAutomation** (casa com MktAutomation). Topo:
**CommercialOrchestrator**. Futuro: InventoryAutomation.

---

## Proximo passo

Com esta spec aprovada, o build comeca pela **Fase 0 (feasibility SP-API)** — 2-4
dias que decidem o `allowed_actions` executavel de tudo. So depois Fase 1 (MVP em
modo Observe), reusando o padrao Full Control 360 ponta a ponta.
