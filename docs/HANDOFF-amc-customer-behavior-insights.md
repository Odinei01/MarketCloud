# HANDOFF — Insights de comportamento do cliente (AMC) + jogadas acionaveis

Data: 2026-07-20
Marker: `zanom-amc-customer-behavior-v1`

Analise AMC (queries coarse corrigidas) sobre ~50 dias / 303 pedidos atribuidos.
As queries originais Q007-Q020 do runner voltavam 1 linha/vazias por SQL errado
(grao fino demais / tabela errada), NAO por falta de dado. Versoes coarse
corretas provaram que o dado existe e trouxeram sinal real.

## Os 5 achados (dado real, nao suposicao)

1. **Sanidade:** 303 compras, 318 usuarios atribuidos, 136k alcancados no
   trafego, R$ 12.159 vendas. Conversao geral ~0,21%.
2. **Novo vs recorrente:** 43 novos (14%) / 260 recorrentes (86%). Ticket
   identico (~R$ 40) nos dois. -> Ads sao motor de RECOMPRA/harvest, nao de
   aquisicao. (new_to_brand = 1a compra da marca em 12m; provavel que havia
   venda organica antes dos Ads.)
3. **Tempo ate conversao:** 70% em <1h, 82% em <24h, so 18% "voltam depois".
   -> Compra por IMPULSO/decisao rapida (produtos ~R$40 baixa consideracao).
   Consequencia tecnica: a janela de 24h do robo NAO e o gargalo do loop de
   aprendizado (82% cabe nela); o gargalo e ESPARSIDADE (0-vs-0 por hora).
4. **Frequencia:** conversao sobe com exposicao (0,15%->0,70% de 1 para 8+),
   MAS e viES DE INTENCAO (quem quer busca/ve mais), nao causa. 44% das compras
   sao de exposicao UNICA. -> Nao pompar frequencia; focar em estar na hora/busca
   certa. Sem evidencia de saturacao nem de ganho causal.
5. **Cross-sell:** VAZIO real (~1 compra/usuario). -> Clientes compram 1 item e
   vao embora. Oportunidade clara (hoje = R$0).

## Retrato do negocio
Cliente **recorrente, 1 produto, por impulso, em <1h, exposicao unica**. Motor de
recompra rapida de item avulso. Cresce por (a) aquisicao de novos (14% hoje) e
(b) cross-sell/bundle (0 hoje).

## As 5 jogadas (priorizadas por ROI real na escala atual)

### #1 (maior alavanca) — Cross-sell / bundle pros clientes que ja tem
- 318 compradores levaram 1 item; vender um 2o e mais barato que adquirir novo.
- Fazer: bundles/kits (ja existe "Kit Kadukli"); remarketing pos-compra pra lista
  de compradores com 2o produto; preco de kit como entidade no Pricing Engine.

### #2 (economia imediata) — Questionar incrementalidade do gasto recorrente
- 86% das compras via Ads sao de quem ja conhece a marca; pode-se estar pagando
  por compra que aconteceria organica.
- Fazer: holdout medir incremental SEPARADO por novo vs recorrente; se termo de
  marca/recorrente for pouco incremental, cortar bid ali e economizar.

### #3 (1o experimento do pricing) — Cupom no momento do impulso
- Decisao imediata (70% em 1h) + 0,21% de conversao + ticket fixo ~R$40.
- Fazer: badge de desconto no momento, em produto de trafego alto, medido com
  holdout. Cupom-first, alinhado ao [[pricing-automation-spec]].

### #4 (testar pequeno, sem apostar) — Aquisicao de novos
- So 14% novos. Aquisicao paga em termo amplo e cara/nao-provada nesta escala.
- Fazer: 1-2 campanhas pequenas de descoberta com NTB como KPI; medir CAC; so
  escalar se pagar. NAO despejar budget.

### O que NAO fazer
- Nao pompar frequencia (item 4): e intencao, nao causa; 44% compram na 1a vez.

## Impacto no que esta sendo construido
- **Bid robot:** priorizar momento/intencao; questionar incrementalidade do
  recorrente (economia). Janela de 24h esta OK (nao esticar).
- **Pricing engine:** cupom-first + preco de kit sao os 2 primeiros experimentos;
  os achados dao a hipotese. Ver [[pricing-automation-spec]].
- **AMC features:** as 5 queries coarse corretas viram input real (funil, novo/
  recorrente, tempo) — pendente reescrever o pacote Q007-Q020 do runner (hoje
  gravam 1 linha por SQL errado).

## Recomendacao de foco
Comecar por #1 (bundle/cross-sell = receita nova sem custo de aquisicao) e #2
(cortar gasto nao-incremental = economia imediata). Somam mais que perseguir
cliente novo agora.

## Pendente
- Reescrever Q007-Q020 corrigidas no runner AMC (coarse, tabela certa) pra popular
  as tabelas em vez de 1 linha. Q016 (cross-sell) fica vazia de verdade ate ter
  volume/cross-sell; confirmar nome de coluna `tracked_asin` com a Amazon.

## Evolucao futura (pedido do dono, 2026-07-20) — auto-criacao de campanha
Quando o robo detectar um search term que VENDE na campanha Automatica (catch-all)
e que NAO tem campanha de produto manual/dedicada, ele proprio deve **criar a
campanha manual** com configuracoes pre-estabelecidas e guardrails ja acionados
(budget, min_roas, max_spend_without_order, allowlist/kill-switch). Ou seja: a
descoberta na auto vira campanha dedicada automaticamente, ja governada. E o
passo seguinte ao executor de negativo — fecha o ciclo "auto descobre -> negativa
na auto -> cria dedicada -> governa". Gated aos pilotos como todo o resto.
