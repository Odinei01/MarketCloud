# HANDOFF - Transformacao ZanoM em SaaS vendavel

Ultima atualizacao: 2026-07-17 01:25 -03:00

## 1. Objetivo

Transformar o ZanoM/MarketCloud de uma automacao custom da conta ZanoM em um SaaS vendavel para multiplos sellers Amazon.

O produto deve permitir que um seller conecte suas contas, escolha produtos/campanhas, defina limites economicos e deixe o robo otimizar bids, orcamento e posicionamento com aprendizado horario.

Frase do produto:

> O seller escolhe um produto, define limites economicos, e o robo gerencia campanha, BID e orcamento com aprendizado horario.

## 2. Estado atual

Ja existe no piloto ZanoM:

- Integracao Amazon Ads.
- Integracao SP-API.
- Amazon Marketing Stream via SQS.
- Lake MarketCloud com bronze/silver/gold.
- Modelos horarios de campanha e target/keyword.
- Robos de BID e agenda horaria.
- Full Control piloto por produto/campanha.
- Guardrails de estoque, budget, margem e stop-loss em evolucao.
- Coleta inicial de sugestao de BID da Amazon.
- Auditoria pos-acao: proposta, aplicado, medido e outcome.

O problema: ainda ha dependencias operacionais e nomes/fluxos ligados ao piloto ZanoM. Para vender, precisa virar multi-tenant, repetivel e configuravel por seller.

## 3. Principios do SaaS

1. Multi-tenant desde a base.
2. Nenhuma regra hardcoded para ZanoM.
3. Toda acao do robo precisa ser auditavel.
4. Full Control sempre opt-in.
5. Guardrails economicos fecham antes do ML.
6. ML recomenda; governanca decide se pode aplicar.
7. Seller precisa entender o que aconteceu sem ler log.
8. Rate limit da Amazon deve ser parte do produto, nao erro invisivel.

## 4. Entidades centrais

### Tenant

Representa a empresa/seller cliente.

Campos esperados:

- `tenant_id`
- `name`
- `plan`
- `status`
- `created_at`

### Store

Representa uma loja/conta Amazon dentro do tenant.

Campos esperados:

- `store_id`
- `tenant_id`
- `marketplace`
- `seller_id`
- `ads_profile_id`
- `timezone`
- `currency`
- `status`

### Product Control Plane

Centro economico do produto que o robo vai operar.

Campos esperados:

- `product_id`
- `tenant_id`
- `store_id`
- `sku`
- `asin`
- `product_name`
- `current_price`
- `current_cost`
- `stock_available`
- `target_margin_percent`
- `break_even_acos_percent`
- `max_daily_budget`
- `max_spend_without_order`
- `stop_loss_enabled`
- `status`

### Campaign Binding

Liga produto a campanhas Amazon.

Campos esperados:

- `binding_id`
- `product_id`
- `campaign_id`
- `campaign_name`
- `ad_product_type`
- `targeting_type`
- `control_mode`
- `full_control_enabled`
- `status`

## 5. Modos do robo

### Observador

O sistema coleta dados, mede e mostra insights. Nao recomenda acao automatica.

### Sugere

O sistema recomenda mudancas, mas nao aplica.

### Aplica com aprovacao

O sistema gera a acao e aguarda aprovacao humana.

### Full Control

O sistema recomenda, aplica, monitora e reverte/bloqueia quando guardrails disparam.

Full Control deve ser configurado por produto/campanha, nunca global por padrao.

## 6. Variaveis estrategicas

Variaveis que precisam entrar no modelo e nos guardrails:

- BID base.
- BID sugerido pela Amazon.
- BID proposto pelo robo.
- Top of Search.
- Product Pages.
- Rest of Search.
- Orcamento diario.
- Gasto do dia.
- Gasto sem pedido.
- Estoque disponivel.
- Custo atual do produto.
- Preco atual.
- Margem alvo.
- Break-even ACOS.
- Stop-loss.
- Conversoes AMS.
- Cliques AMS.
- Impressoes AMS.
- ROAS horario.
- Resultado 1h, 3h e 24h apos mudanca.

## 7. Tela principal a construir

Nome sugerido: `SaaS Control Plane` ou `Product Autopilot`.

Fluxo:

1. Selecionar tenant/store.
2. Selecionar produto.
3. Mostrar custo, estoque, preco, margem e break-even.
4. Mostrar campanhas associadas ao produto.
5. Escolher modo do robo.
6. Configurar limites:
   - budget;
   - stop-loss;
   - teto de gasto sem pedido;
   - top of search max/min;
   - product pages max/min;
   - rest of search max/min;
   - bid max/min.
7. Salvar piloto.
8. Monitorar:
   - proposta do modelo;
   - sugestao Amazon;
   - acao aplicada;
   - horario aplicado;
   - resultado 1h/3h/24h;
   - ganhou/perdeu ROAS;
   - modelo concordou ou errou;
   - bloqueios de guardrail.

## 8. Backlog tecnico inicial

### P0 - Multi-tenant minimo

- Criar/validar tabelas `tenants`, `stores`, `seller_connections`.
- Garantir `tenant_id/store_id/profile_id` nos fluxos novos.
- Mapear a conta ZanoM como tenant inicial.

### P0 - Product Control Plane

- Criar tela para selecionar produto/SKU.
- Puxar custo, estoque, preco e margem.
- Associar campanhas Amazon por ASIN/SKU.
- Salvar plano de controle por produto.

### P0 - Guardrails Full Control

- Estoque zero bloqueia.
- Budget diario bloqueia.
- Gasto sem pedido bloqueia.
- Margem/break-even bloqueia.
- Stop-loss bloqueia e/ou reduz agressividade.

### P1 - Aprendizado 360

- Persistir `proposed -> applied -> measured -> outcome_label`.
- Mostrar resultado por 1h/3h/24h.
- Treinar modelo com variaveis de placement, budget, Amazon suggested bid e outcome real.

### P1 - Operacao SaaS

- Tela de saude por seller.
- Status dos conectores.
- Status AMS/AMC.
- Status dos workers.
- Rate limit e backoff visiveis.

### P2 - Comercializacao

- Planos por volume de campanhas/gasto.
- Limites por plano.
- Logs exportaveis.
- Relatorio executivo semanal.
- Alertas Telegram/Email/WhatsApp.

## 9. Pendencias antes de vender

- Remover dependencias hardcoded ZanoM.
- Criar isolamento multi-tenant real.
- Separar credenciais por seller.
- Criar onboarding simples.
- Criar tela de auditoria entendivel.
- Garantir que Full Control nunca liga sem opt-in explicito.
- Criar mecanismo de rollback/kill-switch por tenant/store/produto.
- Documentar limites de rate limit Amazon.

## 10. Proximo passo recomendado

Comecar pelo `Product Control Plane`.

Primeira entrega:

- Uma tela em configuracoes para escolher produto/SKU.
- Mostrar custo/estoque/preco/margem.
- Mostrar campanhas derivadas.
- Permitir escolher uma campanha piloto.
- Escolher modo `Observador`, `Sugere`, `Aplica com aprovacao` ou `Full Control`.
- Salvar plano.
- Mostrar onde monitorar as acoes desse piloto.

Essa entrega transforma o robo de campanha em um robo de produto, que e a unidade comercial mais facil de vender para outro seller.

## 11. Implementacao inicial - Product Control Plane (2026-07-16)

### O que foi implementado

- Backend no app `mercado-data-app`:
  - `internal/services/amazon_ads_saas_control_plane.go`
  - rotas adicionadas em `internal/services/amazon_routes.go`
- Frontend:
  - `frontend/src/features/amazon/AmazonSaaSProductControlPage.jsx`
  - rota `#/amazon/saas/product-control`
  - item de menu Amazon `Product Control`
  - estilos adicionados em `frontend/src/App.css`
- API frontend:
  - `fetchAmazonAdsSaaSProductControlProducts`
  - `saveAmazonAdsSaaSProductControlPlan`

### Endpoints criados

- `GET /api/amazon/ads/saas/product-control/products`
  - lista produtos/SKUs;
  - junta `amazon_listings`, `amazon_listing_links`, `stock_position`;
  - deriva campanhas por SKU/ASIN em `amazon_ads_advertised_product_daily`;
  - retorna ultimo plano salvo por produto.
- `POST /api/amazon/ads/saas/product-control/plans`
  - salva plano de piloto por produto/campanha;
  - cria tabela `amazon_ads_product_control_plans` se ainda nao existir;
  - campos iniciais: modo, status, Full Control, budget diario, stop loss, gasto sem pedido, min/max bid, min/max Top of Search, Product Pages e Rest of Search.

### Validacao executada

- `go test ./internal/services -run 'TestBidRecommendationParser|TestDoesNotExist' -count=1` OK.
- `npm run build` OK.
- `docker compose build go-backend react-frontend` OK.
- `docker compose up -d go-backend react-frontend` OK.
- `GET /api/amazon/ads/saas/product-control/products` retornou 58 produtos.
- Teste de persistencia sem ligar automacao real:
  - SKU: `ZNM-NOT-0019`
  - ASIN: `B0H4ZS8F5R`
  - campanha: `241711600123126` / `Automatica beleza`
  - salvo como `DRAFT`, `full_control_enabled=false`
  - ID: `pcp-ZNM-NOT-0019-241711600123126`
  - a listagem filtrada por `ZNM-NOT-0019` retornou o plano salvo.

### Estado atual

- A tela ja permite parametrizar o piloto por produto e campanha.
- O save da tela grava espelho local em `amazon_ads_product_control_plans` e sincroniza o contrato canonico do MarketCloud em `marketcloud_control.full_control_pilots`.
- A monitoria da tela mostra o plano salvo, mas ainda nao mostra execucoes aplicadas/outcomes.

### Proximo passo

Ligar `amazon_ads_product_control_plans` ao worker de auto-apply:

- se `status=ACTIVE` e `full_control_enabled=true`, campanha entra no modo piloto;
- aplicar guardrails de estoque, budget, stop loss e gasto sem pedido antes de qualquer bid/budget/placement;
- gravar cada decisao em ledger `proposed -> applied -> measured -> outcome_label`;
- enviar Telegram com campanha, horario, variavel alterada, valor anterior e valor novo;
- mostrar na propria tela a linha do tempo do piloto.

## 12. Ponte Product Control Plane -> MarketCloud Full Control (2026-07-16)

### O que foi implementado

- `POST /api/amazon/ads/saas/product-control/plans` agora faz dual-write:
  - banco operacional ZanoM: `amazon_ads_product_control_plans`;
  - banco MarketCloud: `marketcloud_control.full_control_pilots`.
- A conexao com MarketCloud usa:
  - env `MARKETCLOUD_DATABASE_URL`, se definida;
  - fallback local: `postgres://mcadmin:mcsecret@host.docker.internal:5433/marketcloud?sslmode=disable`.
- A tela passou a enviar `price`, `current_cost` e `stock_available` para evitar piloto sem economia/estoque.
- O worker `workers/modeling-worker/marketcloud_ml_auto_apply_campaign_recommendations.py` agora considera pilotos `mode='full_control'` e `status='active'` como parte da allowlist canônica, além da allowlist full-auto existente.

### Como o fluxo ficou

1. Usuario seleciona produto e campanha em `#/amazon/saas/product-control`.
2. Ao salvar, o plano fica no ZanoM e tambem em `marketcloud_control.full_control_pilots`.
3. A view `marketcloud_gold.full_control_effective_governance_v1` calcula:
   - estoque efetivo;
   - custo/preco;
   - budget diario;
   - gasto sem pedido;
   - `can_control`;
   - `gate_reason`.
4. O auto-apply so pode considerar uma campanha full-control ativa se ela estiver no contrato canonico do MarketCloud.
5. Mesmo considerada, a campanha so aplica se `can_control=true`; caso contrario o gate bloqueia.

### Validacao executada

- `go test ./internal/services -run 'TestBidRecommendationParser|TestDoesNotExist' -count=1` OK.
- `npm run build` OK.
- `docker compose build go-backend react-frontend` OK.
- `docker compose up -d go-backend react-frontend` OK.
- Save de teste sem ligar automacao real:
  - SKU `ZNM-NOT-0019`;
  - ASIN `B0H4ZS8F5R`;
  - campanha `241711600123126` / `Automatica beleza`;
  - `status=draft`;
  - `full_control_enabled=false`;
  - MarketCloud retornou `pilot_id=11`, `mode=monitor_only`, `status=draft`.
- Governance confirmou o piloto:
  - `pilot_id=11`;
  - `gate_reason=NOT_FULL_CONTROL`;
  - `can_control=false`, como esperado para draft/monitor_only.
- Sintaxe do worker validada dentro do container `marketcloud_modeling_worker`.
- Dry-run do worker:
  - `ML_AUTO_APPLY_CAMPAIGN_ENABLED=true`;
  - `ML_AUTO_APPLY_DRY_RUN=true`;
  - carregou `full control gates active=1`;
  - nao aplicou alteracao real.

### Proximo passo

Criar/mostrar na tela a monitoria do piloto usando `marketcloud_gold.full_control_effective_governance_v1` e `marketcloud_recommendations.v_auto_apply_audit_360_v1`:

- status do gate (`READY`, `NO_STOCK`, `DAILY_BUDGET_CAP_REACHED`, etc.);
- timeline de acoes propostas/aplicadas;
- resultado 1h/3h/24h;
- Telegram/auditoria de alteracoes;
- botao explicito para promover `draft/monitor_only` para `active/full_control`.

## 13. Monitoria do piloto na tela Product Control (2026-07-16)

### O que foi implementado

- Backend ZanoM:
  - `GET /api/amazon/ads/saas/product-control/monitoring`
  - consulta MarketCloud direto no Postgres local;
  - retorna `governance` de `marketcloud_gold.full_control_effective_governance_v1`;
  - retorna `actions` de `marketcloud_recommendations.v_auto_apply_audit_360_v1`.
- Frontend:
  - tela `#/amazon/saas/product-control` agora carrega monitoria ao trocar produto/campanha;
  - bloco `Monitoria piloto` mostra:
    - `gate_reason`;
    - `mode`;
    - `status`;
    - gasto e pedidos de hoje;
    - budget diario;
    - cap de gasto sem pedido;
    - ROAS hoje;
    - atualizado em;
  - bloco `Timeline 360` mostra ultimas acoes aplicadas/medidas:
    - quando;
    - hora;
    - acao;
    - decisao;
    - outcome 1h/3h/24h.

### Validacao executada

- `go test ./internal/services -run 'TestBidRecommendationParser|TestDoesNotExist' -count=1` OK.
- `npm run build` OK.
- `docker compose build go-backend react-frontend` OK.
- `docker compose up -d go-backend react-frontend` OK.
- Endpoint validado:
  - `GET /api/amazon/ads/saas/product-control/monitoring?campaign_id=241711600123126&seller_sku=ZNM-NOT-0019&asin=B0H4ZS8F5R`
  - retornou `status=OK`;
  - `gate_reason=NOT_FULL_CONTROL`;
  - `mode=monitor_only`;
  - `status=draft`;
  - `economics_ready=true`;
  - `stock_available=115`;
  - `spend_today=0.30`;
  - `orders_today=0`;
  - `action_count=0`.

### Proximo passo

Adicionar uma acao explicita de promocao do piloto:

- botao `Ativar Full Control`;
- confirmacao forte antes de ligar;
- salvar como `status=ACTIVE` e `full_control_enabled=true`;
- registrar no handoff e, idealmente, enviar Telegram avisando que o piloto entrou em modo ativo.

## 14. Correcao de derivacao de campanha sem SKU/ASIN (2026-07-16)

### Problema

Ao configurar a campanha `Abridor de Vinho`, a tela nao encontrava campanha para os produtos de Abridor.

Causa:

- `amazon_ads_advertised_product_daily` nao tinha linhas para `Abridor de Vinho`;
- `amazon_ads_campaigns_daily` tinha a campanha e performance, mas com `advertised_sku` e `advertised_asin` vazios;
- a primeira versao do Product Control Plane derivava campanhas apenas por SKU/ASIN explicito.

### Correcao

- `GET /api/amazon/ads/saas/product-control/products` passou a usar fallback:
  - quando a campanha diaria nao tem SKU/ASIN;
  - cruza `amazon_ads_campaigns_daily.campaign_name` com `amazon_listings.title`;
  - exemplo: `Abridor de Vinho` agora aparece nos produtos Abridor.

### Validacao

- Busca `q=Abridor` passou a retornar:
  - `ZNM-NOT-0036` / `B0H887XGCJ` com `campaign_count=1`;
  - campanha `243188188856118` / `Abridor de Vinho`;
  - 45d: `217` cliques, `R$ 334,56` custo, `34` pedidos, `R$ 1.468,50` vendas.
- Save de teste sem ligar automacao real:
  - SKU `ZNM-NOT-0036`;
  - ASIN `B0H887XGCJ`;
  - campanha `243188188856118` / `Abridor de Vinho`;
  - `status=draft`;
  - `full_control_enabled=false`;
  - MarketCloud retornou `pilot_id=16`, `mode=monitor_only`, `status=draft`.
- Monitoria retornou:
  - `gate_reason=NOT_FULL_CONTROL`;
  - `economics_ready=true`;
  - `stock_available=50`;
  - `sale_price_brl=69.90`;
  - `unit_cost_brl=29.00`.

### Nota

O fallback por nome e uma ponte operacional para campanhas cujo relatorio nao traz produto anunciado. O ideal SaaS e evoluir para um mapeamento manual confirmado usuario: produto -> campanha, com origem/auditoria do match.

## 15. Avaliacoes, solicitacao de review e features de qualidade no ML (2026-07-16)

### Confirmacao oficial Amazon

- Existe SP-API para solicitar avaliacao ao cliente: `Solicitations API v1`.
- Fluxo correto:
  - chamar `getSolicitationActionsForOrder` para o pedido;
  - se a acao `productReviewAndSellerFeedback` vier disponivel, chamar `createProductReviewAndSellerFeedbackSolicitation`;
  - a Amazon envia um e-mail template unico pedindo product review + seller feedback.
- Pre-requisitos oficiais:
  - pedido elegivel para solicitacao;
  - autorizacao do seller;
  - role `Buyer Solicitation` ou `Product Listing` no developer profile/app registration.
- Tambem existe `Customer Feedback API v2024-06-01` para insights de reviews/returns, mas a documentacao oficial atual lista lojas US/UK/FR/IT/DE/ES/JP e nao lista BR. Para ZANOM/BR, manter fallback com snapshot/externo/returns ate a Amazon liberar a regiao/role aplicavel.

### Implementado no app operacional

- Criado `internal/services/amazon_review_solicitations.go`.
- Rotas adicionadas:
  - `GET /api/amazon/reviews/solicitations/status`
  - `GET /api/amazon/reviews/solicitations/orders`
  - `POST /api/amazon/reviews/solicitations/bulk`
  - `POST /api/amazon/reviews/solicitations/request`
- A rota `request` recebe:
  - `amazon_order_id` ou `order_id`;
  - `marketplace_id` opcional, default do conector.
- Comportamento:
  - cria tabela `amazon_review_solicitation_requests`;
  - lista pedidos enviados (`Shipped` / `PartiallyShipped`) agrupaveis por ASIN/SKU;
  - consulta elegibilidade via `/solicitations/v1/orders/{amazonOrderId}`;
  - so envia `/solicitations/v1/orders/{amazonOrderId}/solicitations/productReviewAndSellerFeedback` se a acao estiver disponivel;
  - grava status `SENT`, `NOT_ELIGIBLE` ou `FAILED`;
  - audit log passa a classificar `/solicitations/` como `Solicitations API`.
- UI adicionada no app operacional:
  - rota `#/amazon/reviews/solicitations`;
  - menu Amazon: `Solicitar Reviews`;
  - mostra pedidos por ASIN;
  - permite solicitar um pedido individual;
  - permite solicitar todos os pendentes do ASIN selecionado em lote;
  - o lote continua chamando a Amazon pedido a pedido, pois a API oficial e por orderId.

### Implementado no MarketCloud / ML

- Criada migration `migrations/106_product_quality_ml_features.sql`.
- Novas foreign tables em `swarm_src`:
  - `amazon_product_quality_snapshot`;
  - `amazon_product_quality_reviews`;
  - `amazon_product_returns`.
- Nova view:
  - `marketcloud_features.feature_product_quality_v1`.
- Features expostas para ML:
  - `quality_orders_30d`;
  - `quality_units_sold_30d`;
  - `refund_total_30d`;
  - `return_quantity_30d`;
  - `return_events_30d`;
  - `return_units_30d`;
  - `return_refund_amount_30d`;
  - `return_rate_30d`;
  - `net_profit_after_quality_30d`;
  - `net_margin_after_quality_ratio_30d`;
  - `product_rating_latest`;
  - `product_reviews_total_latest`;
  - `review_source_confidence`;
  - `low_rating_flag`;
  - `high_return_flag`;
  - `refund_flag`.
- Workers atualizados:
  - `marketcloud_ml_worker_hourly_real_v2.py`;
  - `marketcloud_ml_worker_hourly_target_real_v3.py`.
- Os workers fazem join por `campaign_id -> full_control_effective_governance_v1 -> product_asin/seller_sku -> feature_product_quality_v1`.
- Nao ha vazamento de alvo: reviews/retornos entram como contexto de qualidade/produto, enquanto pedidos/vendas/ROAS continuam sendo labels maduros.

### Validacao

- `gofmt` aplicado nos arquivos Go alterados.
- `go test ./internal/services -run TestAmazonSPAPI -count=1` OK.
- `py -3 -m py_compile` OK para os dois workers.
- `docker exec marketcloud_modeling_worker python -m py_compile ...` OK.
- `modeling-worker` rebuildado/recriado e validado ao vivo:
  - `hourly_real_v2.load()` retornou `611` linhas com `product_rating_latest`, `return_rate_30d`, `refund_flag`;
  - `hourly_target_real_v3.load()` retornou `783` linhas com as mesmas features.
- `go-backend` e `react-frontend` rebuildados/recriados no app operacional.
- Endpoint ao vivo:
  - `GET http://localhost:8080/api/amazon/reviews/solicitations/status`;
  - retornou `build_marker=swarm-amazon-review-solicitations-v1`;
  - `status=OK`;
  - contadores zerados, como esperado antes do primeiro pedido solicitado.
- Endpoint de tela validado:
  - `GET http://localhost:8080/api/amazon/reviews/solicitations/orders?limit=5`;
  - retornou `status=OK`, `groups` por ASIN e `items` por pedido.
- Migration aplicada no `marketcloud_db`:
  - `CREATE FOREIGN TABLE` x3;
  - `CREATE VIEW`;
  - `COMMENT`.
- Checagem da view:
  - `marketcloud_features.feature_product_quality_v1` retornou 14 linhas;
  - no snapshot atual, `with_rating=0` e `with_returns=0`, entao o ML passa a receber zeros ate a fonte popular esses sinais.

### Proximos passos

- Liberar/confirmar role SP-API `Buyer Solicitation` ou `Product Listing` para a app antes de usar solicitacao em producao.
- A UI operacional de solicitacao de review ja existe. Proximo refinamento: adicionar pre-check/preview de elegibilidade assíncrono por lote se a role SP-API estiver liberada e a Amazon nao limitar a taxa.
- Popular melhor `amazon_product_quality_reviews`:
  - se Amazon liberar Customer Feedback para BR/conta, implementar coletor oficial;
  - enquanto nao liberar, manter snapshot externo/Serp/ASIN data como fonte parcial, sempre marcado em `review_source`.
- Quando `feature_product_quality_v1` comecar a ter rating/retornos reais, rodar os workers e comparar feature importance para saber se qualidade do produto esta mudando decisao de bid/budget/placement.

## 16. Correcao Solicitation API - janela Amazon e quota (2026-07-16)

### Problema

A tela `#/amazon/reviews/solicitations` estava listando qualquer pedido `Shipped` / `PartiallyShipped` dentro dos ultimos 30 dias. Isso era amplo demais.

Regra operacional correta da Amazon para `Request a Review` / `Solicitations API`:

- solicitar apenas uma vez por pedido;
- primeiro consultar `getSolicitationActionsForOrder`;
- so enviar `createProductReviewAndSellerFeedbackSolicitation` se a acao `productReviewAndSellerFeedback` estiver disponivel;
- respeitar a janela de solicitacao: 5 a 30 dias apos a entrega estimada/entrega.

Como nossos pedidos BR nao estavam trazendo `EarliestDeliveryDate` / `LatestDeliveryDate` no snapshot local, pedidos enviados hoje tambem apareciam como candidatos. Isso pode gerar `NOT_ELIGIBLE` e aumentar consumo de cota sem necessidade.

### Correcao aplicada

Repositorio: `C:\dev\estudo-cloud-native\mercado-data-app`.

- Backend `internal/services/amazon_review_solicitations.go`:
  - build marker atualizado para `swarm-amazon-review-solicitations-v2-window-throttle`;
  - query de pedidos agora calcula `review_reference_at`;
  - usa `LatestDeliveryDate` quando existir;
  - depois `EarliestDeliveryDate`;
  - se a Amazon nao trouxe entrega, usa fallback conservador `purchase_date + 7 days`;
  - so lista/envia pedidos com `review_reference_at` entre `CURRENT_DATE - 30 days` e `CURRENT_DATE - 5 days`;
  - bulk reduziu default para 25 e teto para 50;
  - bulk adicionou intervalo de 1200ms entre pedidos para reduzir risco de quota/throttling.
- Frontend `AmazonReviewSolicitationsPage.jsx`:
  - texto da tela explica a janela 5-30 dias;
  - bulk envia no maximo 50 por ASIN;
  - tabela mostra `Janela Amazon`, com dias desde a referencia e a data de referencia.
- CSS ajustado para suportar a quinta metrica de status e badge de janela.

### Validacao esperada

- Pedidos de hoje/ontem nao devem mais aparecer na lista por padrao.
- O endpoint deve retornar:
  - `build_marker=swarm-amazon-review-solicitations-v2-window-throttle`;
  - `filters.amazon_window=5_to_30_days_after_estimated_delivery`;
  - itens apenas dentro da janela.
- Nao disparar lote real sem confirmar a quantidade exibida na tela.

### Nota SaaS

Rate limit da Amazon deve ser tratado como produto: preview claro, janela elegivel antes da chamada externa, limite por lote e backoff/throttle visivel. Nao devemos usar a SP-API para descobrir em massa o que poderia ter sido filtrado localmente.

## 17. Worker diario de solicitacao de reviews (2026-07-17)

### Objetivo

Automatizar a solicitacao de reviews sem depender de clique manual diario, mas sem repetir o erro de gastar cota com pedido fora da janela Amazon.

### Implementado

Repositorio: `C:\dev\estudo-cloud-native\mercado-data-app`.

- Novo worker Go:
  - `internal/services/amazon_review_solicitations_worker.go`.
- Inicializacao:
  - `RegisterAmazonRoutes` chama `connector.startAmazonReviewSolicitationWorker()`.
- Cadencia:
  - diaria;
  - default `10:35 BRT`;
  - configuravel por env:
    - `AMAZON_REVIEW_SOLICITATION_WORKER_ENABLED`;
    - `AMAZON_REVIEW_SOLICITATION_WORKER_HOUR_BRT`;
    - `AMAZON_REVIEW_SOLICITATION_WORKER_MINUTE_BRT`;
    - `AMAZON_REVIEW_SOLICITATION_WORKER_LIMIT`;
    - `AMAZON_REVIEW_SOLICITATION_WORKER_TIMEOUT_SECONDS`.
- Limites:
  - default `25` pedidos por rodada;
  - teto `50`;
  - reaproveita throttle de `1200ms` entre pedidos.
- Elegibilidade local antes de chamar Amazon:
  - usa a mesma query filtrada da tela;
  - somente pedidos pendentes;
  - somente pedidos dentro da janela `5_to_30_days_after_estimated_delivery`;
  - periodo do worker busca 45 dias para nao perder pedidos cujo fallback e `purchase_date + 7 days`.
- Ordem de processamento:
  - pedidos mais antigos na janela primeiro, para reduzir risco de perder pedido perto dos 30 dias.
- Endpoints operacionais:
  - `GET /api/amazon/reviews/solicitations/worker/status`;
  - `POST /api/amazon/reviews/solicitations/worker/run-now`.
- Painel tecnico:
  - `review_solicitations` incluido em `GET /api/amazon/ops/status`.

### Cuidados

- `run-now` dispara envio real para pedidos elegiveis; usar apenas quando a contagem da tela fizer sentido.
- O worker nao reenvia pedido com ultimo status `SENT`.
- Pedido `NOT_ELIGIBLE` pode voltar a aparecer futuramente se continuar pendente; a protecao principal e a janela local + check oficial `getSolicitationActionsForOrder`.

### Execucao manual de limpeza (2026-07-17 00:05 BRT)

Solicitado pelo operador para limpar tudo que fosse possivel no momento.

Resultado da rodada manual:

- `trigger=MANUAL`;
- `limit=25`;
- `total=25`;
- `sent=2`;
- `not_eligible=23`;
- `failed=0`;
- duracao aproximada `38.6s`;
- throttle aplicado: `1200ms` entre pedidos.

Pedidos efetivamente solicitados:

- `701-3662710-8431465` / ASIN `B0H2ZBJ727` / SKU `ZNM-NOT-0016`;
- `702-4651162-1933828` / ASIN `B0H2ZBJ727` / SKU `ZNM-NOT-0016`.

Correcao adicional aplicada apos a rodada:

- a query de pendentes agora considera pendente apenas `solicitation_status = PENDING`;
- antes ela excluia somente `SENT`, entao `NOT_ELIGIBLE` e `FAILED` ainda apareciam como pendentes e poderiam gastar cota de novo;
- apos rebuild do backend, `GET /api/amazon/reviews/solicitations/orders?limit=30` retornou `count=0` para candidatos ainda nao tentados dentro da janela.

Estado final: nao havia mais pedidos nunca tentados dentro da janela Amazon no momento da validacao.

## 18. Monitor de avaliacoes recebidas (2026-07-17)

### Objetivo

Monitorar se os produtos receberam novas avaliacoes apos as solicitacoes de review.

### Observacao importante

A implementacao atual monitora dados agregados por ASIN:

- rating atual;
- total de avaliacoes/reviews;
- delta de reviews;
- queda de rating.

Ela nao captura ainda o texto individual da review. A API oficial `Customer Feedback API v2024-06-01` existe para insights de reviews e returns, mas foi testada em 2026-07-17 e o endpoint rejeitou explicitamente o marketplace BR `A2Q3Y263D00KWC`. A fonte ativa segue `ZANOM_PRODUCT_MONITOR`, derivada dos dados de produto ja capturados pelo ZanoM/Serp/ASIN.

### Implementado

Repositorio: `C:\dev\estudo-cloud-native\mercado-data-app`.

- Tabela nova:
  - `amazon_product_review_monitor_events`.
- Reuso/seed em:
  - `amazon_product_quality_reviews`.
- Novas rotas:
  - `GET /api/amazon/quality/reviews/monitor`;
  - `POST /api/amazon/quality/reviews/monitor/sync`.
- Novo worker:
  - `internal/services/amazon_review_monitor_worker.go`;
  - roda diariamente por default as `09:20 BRT`;
  - configuravel por env:
    - `AMAZON_REVIEW_MONITOR_WORKER_ENABLED`;
    - `AMAZON_REVIEW_MONITOR_WORKER_HOUR_BRT`;
    - `AMAZON_REVIEW_MONITOR_WORKER_MINUTE_BRT`;
    - `AMAZON_REVIEW_MONITOR_WORKER_TIMEOUT_SECONDS`.
- Painel tecnico:
  - worker `review_monitor` incluido em `GET /api/amazon/ops/status`.
- Tela operacional criada:
  - rota `#/amazon/reviews/monitor`;
  - menu Amazon > Operacao > `Monitor Reviews`;
  - arquivo `frontend/src/features/amazon/AmazonReviewMonitorPage.jsx`;
  - APIs frontend em `frontend/src/api/amazonConnectorApi.js`:
    - `fetchAmazonReviewMonitor`;
    - `syncAmazonReviewMonitor`.
  - a tela mostra KPIs, eventos detectados, produtos monitorados, rating atual, total de reviews e alerta de rating baixo.

### Regra de deteccao

Por ASIN/SKU:

- se `current_reviews > previous_reviews`, cria evento `NEW_REVIEW_DETECTED`;
- se `current_reviews = previous_reviews` e `current_rating < previous_rating`, cria evento `RATING_DROPPED`.

### Validacao executada

- Primeira tentativa capturou ASINs demais do monitor antigo. Corrigido para usar apenas ASINs presentes em `amazon_listings`.
- Baseline poluido removido:
  - `DELETE FROM amazon_product_quality_reviews WHERE source='ZANOM_PRODUCT_MONITOR'`.
- Novo baseline criado via:
  - `POST /api/amazon/quality/reviews/monitor/sync`.
- Resultado:
  - `inserted=3`;
  - `events=0`, esperado na primeira linha de base;
  - `products_monitored=3`;
  - `snapshots=3`.
- Produtos monitorados no baseline:
  - `B0H2SRPWF9` / `ZNM-NOT-0011` / rating `2.50` / reviews `3`;
  - `B0H2QWNRSB` / `ZNM-NOT-0006` / rating `3.00` / reviews `3`;
  - `B0H2NJGX4Y` / `ZNM-NOT-0009` / rating `3.00` / reviews `2`.
- Validacao da tela:
  - `npm run build` em `frontend` passou;
  - `docker compose up -d --build react-frontend` recriou `pricing_dashboard`;
  - `GET http://localhost:3000/#/amazon/reviews/monitor` retornou HTTP `200`;
  - `GET http://localhost:8080/api/amazon/quality/reviews/monitor?limit=5` retornou `status=OK`, `source=ZANOM_PRODUCT_MONITOR`.
- Correcao posterior:
  - a tela repetia produtos porque o endpoint devolvia todos os snapshots no campo `latest`;
  - criado `amazonProductReviewMonitorLatest`, que usa `ROW_NUMBER()` para retornar apenas o ultimo snapshot por ASIN/SKU;
  - validado com `GET /api/amazon/quality/reviews/monitor?limit=50`: `latest_count=3`, `products_monitored=3`, `snapshots=36`.
  - detectado evento real: `B0H2NJGX4Y` / `ZNM-NOT-0009` subiu de `2` para `4` reviews, status `NEW_REVIEW_DETECTED`.
- Teste real da Customer Feedback API oficial:
  - endpoint oficial testado: `GET /customerFeedback/2024-06-01/items/{asin}/reviews/topics`;
  - ASIN usado: `B0H2NJGX4Y`;
  - token LWA retornou OK;
  - BR `marketplaceId=A2Q3Y263D00KWC` com `sortBy=MENTIONS` retornou HTTP `400`, request id `3bf91ad9-058a-4028-8166-33277d07d95e`;
  - BR `marketplaceId=A2Q3Y263D00KWC` com `sortBy=STAR_RATING_IMPACT` retornou HTTP `400`, request id `84ed9029-1773-4d57-b5ff-7c7ed3345731`;
  - corpo Amazon: `marketplaceId` BR falhou na enum permitida `[ATVPDKIKX0DER, A1F83G8C2ARO7P, A1PA6795UKMFR9, A1RKKUPIHCS9HS, A1VC38T7YXB528, A13V1IB3VIYZZH, APJ6JRA9NG5V4]`;
  - controle com marketplace suportado `ATVPDKIKX0DER` retornou HTTP `204 Success`, request id `6586a850-cade-4ccf-a446-3786a4b620fe`, provando que a rota/app/token respondem, mas BR nao e suportado.
  - status tecnico atualizado para `CUSTOMER_FEEDBACK_API_VALIDATED_BR_MARKETPLACE_UNSUPPORTED`.
- Correcao de cobertura do monitor:
  - problema reportado: `ZNM-NOT-0016` tinha review na Amazon, mas nao aparecia na tela;
  - causa: o monitor dependia de `zanom_produtos_monitorados`, mas essa tabela cobria apenas `4` dos `58` ASINs de `amazon_listings`;
  - `ZNM-NOT-0016` esta em `amazon_listings` como ASIN `B0H2ZBJ727`, mas nao existia em `zanom_produtos_monitorados`;
  - correção no backend: `amazonProductReviewMonitorCandidates` agora inclui todos os listings proprios, reutiliza o ultimo snapshot quando houver, e usa fallback `SERPAPI_AMAZON_PRODUCT` quando nao houver dado local ou o snapshot estiver velho;
  - limite controlado por env `AMAZON_REVIEW_MONITOR_EXTERNAL_FETCH_LIMIT`, default `25`;
  - sync manual executado apos rebuild:
    - `external.attempts=25`;
    - `external.success=10`;
    - `inserted=13`;
    - `products_monitored=13`;
  - validacao especifica:
    - `GET /api/amazon/quality/reviews/monitor?sku=ZNM-NOT-0016&limit=10`;
    - retornou `B0H2ZBJ727`, `rating=4.40`, `review_count=2`, `source=SERPAPI_AMAZON_PRODUCT`.
  - nota: como foi o primeiro snapshot desse SKU, nao houve evento de delta; proximos aumentos de reviews passam a gerar `NEW_REVIEW_DETECTED`.
- Correcao de integridade do rating/reviews:
  - problema reportado: havia produto com `rating=4.40` e `review_count=0`, o que deixava a tela incoerente;
  - causa: o fallback `SERPAPI_AMAZON_PRODUCT` podia retornar nota agregada sem contador de reviews confiavel;
  - regra nova no backend: qualquer fonte com `reviews <= 0` nao pode carregar `rating > 0`; o rating passa a ser tratado como sem dado confiavel;
  - `amazonProductReviewMonitorCandidates` agora so propaga rating quando existe contagem de reviews;
  - `amazonProductReviewMonitorFetchExternal` agora so aceita resposta externa quando `RatingsTotal > 0`;
  - limpeza executada no historico:
    - `ZNM-NOT-0001` / `B0H2SLZ9XC`;
    - `ZNM-NOT-0002` / `B0H2SQRJKR`;
    - `ZNM-NOT-0003` / `B0H2XNTDVL`;
    - `ZNM-NOT-0008` / `B0H2T3T246`;
    - todos ficaram com `rating=0` e `source=SERPAPI_AMAZON_PRODUCT_NO_REVIEW_COUNT`.
  - validacao:
    - `go test ./internal/services -run TestAmazonSPAPI -count=1` passou;
    - `docker compose up -d --build go-backend` recriou `pricing_api`;
    - query de auditoria retornou `0` linhas para `rating > 0 AND reviews = 0`;
    - `GET /api/amazon/quality/reviews/monitor?sku=ZNM-NOT-0016&limit=10` retornou `rating=4.40`, `review_count=2`, `source=SERPAPI_AMAZON_PRODUCT`.

### Proximo refinamento

- correlacionar solicitacoes enviadas vs reviews recebidas por ASIN;
- adicionar serie historica por produto;
- plugar eventos de rating/review no painel ML/Full Control como variavel de qualidade do produto.
