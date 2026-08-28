-- 251: cobertura passa a ser IMPRESSION SHARE de verdade, medido pela Amazon.
--
-- O QUE ESTAVA ERRADO: cobertura = impressoes_zanom / volume_busca. Isso e "impressoes
-- por busca", nao "fracao das impressoes daquela busca que foram minhas". A prova de que
-- nao era fracao: 155 buscas tinham MAIS impressoes nossas do que buscas registradas —
-- razao acima de 100%. Uma busca gera varias impressoes (posicoes, paginas, rolagem),
-- entao o numero nunca foi percentual de nada.
--
-- Com isso o cozedor aparecia com 90,7% de "cobertura". A metrica honesta e outra.
--
-- A METRICA CERTA JA EXISTIA: brand_impression_share, no relatorio Search Query
-- Performance do Brand Analytics — a propria Amazon informa qual fracao das impressoes
-- daquela busca foi da marca. 5.515 linhas proprietarias, 100% preenchidas, periodo
-- 02/08 a 22/08. Nao precisou consertar nada: o E001 do BA voltou a rodar (ultimos jobs
-- PROCESSED com 1.327, 1.219 e 1.200 linhas) e o campo estava la, sem uso.
--
-- A diferenca de ordem de grandeza e brutal. Em 'caixa organizadora': 546.798 impressoes
-- de mercado, 283 nossas — share de 0,05%. A media da conta e 2,36%.
--
-- CONSEQUENCIA PRATICA: os limiares mudam de faixa. 'EXPANDIR' com cobertura < 20% fazia
-- sentido na escala inflada; no share real, share de 20% seria dominancia de mercado.
-- Passa a usar < 5%, que na media de 2,36% ainda e generoso.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_share_v1 AS
SELECT
    UPPER(s.asin)                          AS asin,
    lower(btrim(s.search_query))           AS query,
    MAX(s.search_query_volume)             AS volume_busca,
    SUM(s.impressions)                     AS impressoes_marca,
    MAX(s.total_impressions)               AS impressoes_mercado,
    -- a Amazon devolve em pontos percentuais (0-100)
    ROUND(AVG(s.brand_impression_share)::numeric, 4) AS impression_share_pct,
    SUM(s.clicks)                          AS cliques,
    SUM(s.purchases)                       AS compras,
    MAX(s.period_end)                       AS visto_ate
FROM swarm_src.amazon_brand_analytics_search_query_performance s
WHERE COALESCE(s.data_domain,'PROPRIETARY_SEARCH_QUERY') = 'PROPRIETARY_SEARCH_QUERY'
  AND COALESCE(s.asin,'') <> ''
  AND COALESCE(s.search_query,'') <> ''
GROUP BY UPPER(s.asin), lower(btrim(s.search_query));

COMMENT ON VIEW marketcloud_gold.v_query_share_v1 IS
'Impression share por query x ASIN, medido pela Amazon (brand_impression_share do Search Query Performance). Substitui a razao impressoes/buscas, que passava de 100% e nao era fracao de nada.';

-- Descoberta sobre share real, ainda filtrada por relevancia de intencao.
DROP VIEW IF EXISTS marketcloud_gold.v_descoberta_zm19_v1;
DROP VIEW IF EXISTS marketcloud_gold.v_descoberta_asin_v1;

CREATE VIEW marketcloud_gold.v_descoberta_asin_v1 AS
WITH rel AS (
    SELECT r.asin, r.query, r.volume_busca, r.impressoes_zanom, r.cliques_zanom, r.compras_zanom
    FROM marketcloud_gold.v_query_relevancia_v1 r
    WHERE r.relevante
),
comshare AS (
    SELECT rel.*, sh.impression_share_pct, sh.impressoes_mercado
    FROM rel LEFT JOIN marketcloud_gold.v_query_share_v1 sh
      ON sh.asin = UPPER(rel.asin) AND sh.query = lower(btrim(rel.query))
)
SELECT
    asin,
    COUNT(DISTINCT query)                                   AS conceitos,
    COUNT(*)                                                AS variantes,
    COUNT(*) FILTER (WHERE volume_busca < 20)               AS variantes_cauda,
    SUM(volume_busca)                                       AS volume_mercado,
    SUM(impressoes_zanom)                                   AS impressoes,
    SUM(cliques_zanom)                                      AS cliques,
    SUM(compras_zanom)                                      AS compras,
    SUM(compras_zanom) FILTER (WHERE volume_busca < 20)     AS compras_da_cauda,
    -- share ponderado pelo tamanho da busca: dominar uma busca de 10 nao vale o mesmo
    -- que aparecer pouco numa de 500.000
    ROUND((SUM(impression_share_pct * volume_busca) / NULLIF(SUM(volume_busca) FILTER (WHERE impression_share_pct IS NOT NULL),0))::numeric, 2) AS share_pct,
    COUNT(*) FILTER (WHERE impression_share_pct IS NOT NULL) AS queries_com_share,
    ROUND(100.0 * SUM(compras_zanom)::numeric / NULLIF(SUM(cliques_zanom)::numeric, 0), 1) AS cvr_pct,
    SUM(impressoes_mercado)                                 AS impressoes_mercado,
    CASE
        WHEN COUNT(*) FILTER (WHERE impression_share_pct IS NOT NULL) = 0 THEN 'SEM_SHARE'
        WHEN SUM(compras_zanom) > 0
         AND (SUM(impression_share_pct * volume_busca) / NULLIF(SUM(volume_busca) FILTER (WHERE impression_share_pct IS NOT NULL),0)) < 5.0
        THEN 'EXPANDIR'
        WHEN SUM(compras_zanom) > 0 THEN 'OTIMIZAR'
        WHEN SUM(cliques_zanom) >= 5 THEN 'INVESTIGAR'
        ELSE 'SEM_SINAL'
    END AS decisao
FROM comshare
GROUP BY asin;

COMMENT ON VIEW marketcloud_gold.v_descoberta_asin_v1 IS
'Descoberta por ASIN: impression share REAL da Amazon (ponderado por volume), sobre o mercado relevante. EXPANDIR = ja converte e share abaixo de 5% (media da conta: 2,36%).';

CREATE VIEW marketcloud_gold.v_descoberta_zm19_v1 AS
WITH zm19_asins AS (
    SELECT product_asin AS asin, SUM(spend) gasto_zm19, SUM(clicks) cliques_zm19, SUM(sales) venda_zm19,
           string_agg(DISTINCT regexp_replace(campaign_name,'^ZANOM M19-CLONE - ([A-Z]+).*$','\1'),'+') tipos
    FROM marketcloud_bronze.bronze_amc_product_asin_daily
    WHERE campaign_name LIKE 'ZANOM M19-CLONE%' AND product_asin IS NOT NULL
    GROUP BY product_asin
)
SELECT z.asin, z.tipos AS tipos_campanha,
       ROUND(z.gasto_zm19::numeric,2) gasto_zm19, z.cliques_zm19, ROUND(z.venda_zm19::numeric,2) venda_zm19,
       d.volume_mercado, d.share_pct, d.impressoes_mercado, d.queries_com_share,
       d.cliques AS cliques_organicos_e_pagos, d.compras, d.cvr_pct,
       d.variantes, d.variantes_cauda, d.compras_da_cauda, d.decisao
FROM zm19_asins z
LEFT JOIN marketcloud_gold.v_descoberta_asin_v1 d ON d.asin = z.asin;
