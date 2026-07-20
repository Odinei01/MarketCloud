# HANDOFF — Launch Playbook (auto-criacao de campanhas de descoberta) — Spec v1

Data: 2026-07-20
Marker: `zanom-launch-playbook-v1`
Status: SPEC + modelo de dados (executor de criacao SP-API = proximo build)

Objetivo (pedido do dono): selecionar um produto NOVO (ou que nao vende) ->
aplicar um PLAYBOOK -> o SWARM/MarketCloud CRIA automaticamente o grupo de
campanhas de descoberta, **ja com guardrails acionados**. Fecha o ciclo:
"auto descobre -> robo negativa/colhe -> cria dedicada -> governa".

## 1. O template (validado no dossie das 4 campanhas m19 autopilot)
Funil de descoberta->colheita. Papeis + defaults calibrados pelo negocio
(impulso, ~R$40, 70% compra em <1h — ver [[amc-customer-behavior-insights]]):

| Campanha | match | Papel | Budget default | Bid default |
|---|---|---|---|---|
| AUTO | auto-targeting | descoberta pura | ALTO (o produto se revela) | medio |
| PHRASE | phrase | descoberta semi-controlada (seeds) | ALTO (foi a que converteu) | medio |
| EXACT | exact | COLHEITA (comeca VAZIA, enche com vencedor) | baixo/crescente | maior |
| PRODUCT | product/ASIN | pagina de concorrente/complementar | baixo (marginal) | baixo |

Regra de largada (escala micro): comecar so com AUTO + PHRASE; adicionar
EXACT + PRODUCT conforme o produto prova conversao. Nao acender as 4 no budget
cheio no dia 1 (fragmenta budget/dado fino).

## 2. Guardrails "ja acionados" no nascimento (o diferencial)
Toda campanha criada ja nasce registrada em `full_control_pilots`/governanca com:
- `min_roas`, `max_daily_budget_brl`, `max_spend_without_order_brl`,
  `minimum_stock_cover_days` (do config do produto).
- `mode='advisor'` (NAO full_auto) por default — nasce em aprendizado/shadow,
  nao mexe em dinheiro sozinha ate o dono promover pra piloto.
- estoque do FBA ao vivo (mig 138), nao total manual.
Assim a campanha nova ja e governada desde o 1o clique — nunca uma campanha
"solta" sem teto (a licao de [[full-control-pilots-data-integrity]]).

## 3. Modelo de dados (migration — construido nesta sessao)
- `marketcloud_control.launch_playbook_templates`: template reutilizavel
  (campanhas JSON, budgets, match types, guardrails default, estrategia de seed).
- `marketcloud_control.launch_playbook_runs`: 1 linha por lancamento — produto
  (asin/sku), template, status (DRAFT/APPROVED/CREATING/CREATED/FAILED),
  campaign_ids criados, guardrails aplicados, timestamps, audit.

## 4. Fluxo
1. Selecionar produto (ASIN/SKU) + template.
2. Gerar SEED keywords (do titulo/categoria do produto, ou manual). AMC/search-
   term de produtos parecidos ajuda a semear.
3. Aprovar (Observe->Approval, como todo o resto).
4. Executor de criacao (SWARM) cria via SP-API, gated (kill-switch OFF), audit-
   ANTES-da-Amazon, post-write confirm — MESMO padrao do executor de negativo.
5. Registra os campaign_ids em governanca com guardrails (passo 2 acima).

## 5. Executor de criacao (PROXIMO BUILD — SP-API)
Endpoint SWARM `POST /api/amazon/ads/launch-playbook/execute`. Sequencia SP-API:
`createCampaigns` -> `createAdGroups` -> `createProductAds` (o ASIN) ->
`createKeywords`/`createTargets` (seeds por match type) -> `createCampaignNegative`
(cross-negatives entre as campanhas pra nao competir consigo). Gates: kill-switch
`LAUNCH_PLAYBOOK_EXECUTE_ENABLED` (default OFF) + allowlist + audit + post-write.
Espelha `amazon_ads_negative_keyword_executor.go` (ja construido) e o Full Control.

## 6. Deteccao "produto precisa de playbook"
View que lista produtos elegiveis: (a) produto no catalogo SEM campanha ativa;
(b) produto com campanha mas 0 venda ha X dias (nao vende); (c) termo vendendo na
AUTO sem campanha dedicada (a evolucao original — o gatilho automatico).

## 7. Roadmap
1. [FEITO nesta sessao] modelo de dados (templates + runs).
2. Seed keyword generator (do titulo/categoria; reusa AMC de similares).
3. Executor SP-API de criacao (o build grande — mirror do negative executor).
4. UI: selecionar produto + template + aprovar.
5. Wire no scheduler + gatilho automatico (termo vende na auto -> cria dedicada).
Tudo gated, kill-switch OFF, comeca em advisor/shadow. Ver
[[negative-keyword-robot]], [[full-control-360-executor]], [[shadow-mode-2-real-lock]].
