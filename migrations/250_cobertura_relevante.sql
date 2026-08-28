-- 250: exige 2 tokens para afirmar relevancia + aplica o filtro no denominador.
--
-- 'porta' (1.616 buscas) passava com 1/1 = 100%. Busca de um token generico nao afirma
-- intencao nenhuma — casa com qualquer produto que tenha a palavra no texto. Passa a
-- exigir 2 tokens significativos, salvo quando houve venda medida.
--
-- E entao a cobertura passa a ser calculada SO sobre o mercado relevante. Antes o
-- denominador somava buscas de outra intencao e a cobertura do porta-capsulas dava 4,5%
-- quando, onde ele compete, e 85%.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_relevancia_v1 AS
WITH q AS (
    SELECT DISTINCT query, asin, volume_busca, impressoes_zanom, cliques_zanom, compras_zanom
    FROM marketcloud_gold.v_query_barata_v3
),
tok AS (
    SELECT q.query, q.asin, t.tok
    FROM q
    CROSS JOIN LATERAL unnest(
        string_to_array(regexp_replace(unaccent(lower(q.query)), '[^a-z ]', ' ', 'g'), ' ')
    ) AS t(tok)
    WHERE length(t.tok) >= 3
      AND t.tok NOT IN ('para','com','sem','dos','das','pelo','pela','que','uma','por')
),
score AS (
    SELECT t.query, t.asin,
           COUNT(*) AS tokens,
           COUNT(*) FILTER (
               WHERE position(regexp_replace(t.tok,'s$','') IN unaccent(lower(p.profile))) > 0
           ) AS casados
    FROM tok t
    JOIN swarm_src.v_asin_product_profile p ON UPPER(p.asin) = UPPER(t.asin)
    GROUP BY t.query, t.asin
)
SELECT q.query, q.asin, q.volume_busca, q.impressoes_zanom, q.cliques_zanom, q.compras_zanom,
       COALESCE(s.tokens,0)  AS tokens,
       COALESCE(s.casados,0) AS tokens_casados,
       ROUND(COALESCE(s.casados,0)::numeric / NULLIF(s.tokens,0), 2) AS relevancia,
       CASE
           WHEN q.compras_zanom > 0 THEN true          -- venda medida vence a heuristica
           WHEN s.tokens IS NULL OR s.tokens < 2 THEN false
           ELSE (s.casados::numeric / NULLIF(s.tokens,0)) >= 0.60
       END AS relevante
FROM q
LEFT JOIN score s ON s.query = q.query AND s.asin = q.asin;

-- Descoberta recalculada sobre o mercado RELEVANTE.
DROP VIEW IF EXISTS marketcloud_gold.v_descoberta_zm19_v1;
DROP VIEW IF EXISTS marketcloud_gold.v_descoberta_asin_v1;
CREATE VIEW marketcloud_gold.v_descoberta_asin_v1 AS
WITH rel AS (
    SELECT asin, query, volume_busca, impressoes_zanom, cliques_zanom, compras_zanom
    FROM marketcloud_gold.v_query_relevancia_v1
    WHERE relevante
)
SELECT
    r.asin,
    COUNT(DISTINCT r.query)                        AS conceitos,
    COUNT(*)                                       AS variantes,
    COUNT(*) FILTER (WHERE r.volume_busca < 20)    AS variantes_cauda,
    SUM(r.volume_busca)                            AS volume_mercado,
    SUM(r.impressoes_zanom)                        AS impressoes,
    SUM(r.cliques_zanom)                           AS cliques,
    SUM(r.compras_zanom)                           AS compras,
    SUM(r.compras_zanom) FILTER (WHERE r.volume_busca < 20) AS compras_da_cauda,
    ROUND(100.0 * SUM(r.impressoes_zanom)::numeric / NULLIF(SUM(r.volume_busca)::numeric, 0), 1) AS cobertura_pct,
    ROUND(100.0 * SUM(r.compras_zanom)::numeric  / NULLIF(SUM(r.cliques_zanom)::numeric, 0), 1)  AS cvr_pct,
    GREATEST(SUM(r.volume_busca) - SUM(r.impressoes_zanom), 0)                                   AS buscas_nao_alcancadas,
    CASE
        WHEN SUM(r.compras_zanom) > 0
         AND ROUND(100.0*SUM(r.impressoes_zanom)::numeric/NULLIF(SUM(r.volume_busca)::numeric,0),1) < 20
        THEN 'EXPANDIR'
        WHEN SUM(r.compras_zanom) > 0 THEN 'OTIMIZAR'
        WHEN SUM(r.cliques_zanom) >= 5 THEN 'INVESTIGAR'
        ELSE 'SEM_SINAL'
    END AS decisao
FROM rel r
GROUP BY r.asin;

COMMENT ON VIEW marketcloud_gold.v_descoberta_asin_v1 IS
'Descoberta por ASIN sobre o mercado RELEVANTE (v_query_relevancia_v1). O denominador nao conta busca de outra intencao — era isso que fazia o porta-capsulas parecer 4,5% coberto quando, onde compete, e 85%.';

-- recria a ZM19 sobre a descoberta corrigida (foi derrubada em cascata acima)
CREATE VIEW marketcloud_gold.v_descoberta_zm19_v1 AS
WITH zm19_asins AS (
    SELECT product_asin AS asin,
           SUM(spend)  AS gasto_zm19,
           SUM(clicks) AS cliques_zm19,
           SUM(sales)  AS venda_zm19,
           string_agg(DISTINCT
               regexp_replace(campaign_name, '^ZANOM M19-CLONE - ([A-Z]+).*$', '\1'), '+') AS tipos
    FROM marketcloud_bronze.bronze_amc_product_asin_daily
    WHERE campaign_name LIKE 'ZANOM M19-CLONE%'
      AND product_asin IS NOT NULL
    GROUP BY product_asin
)
SELECT z.asin, z.tipos AS tipos_campanha,
       ROUND(z.gasto_zm19::numeric, 2)  AS gasto_zm19,
       z.cliques_zm19,
       ROUND(z.venda_zm19::numeric, 2)  AS venda_zm19,
       d.volume_mercado, d.cobertura_pct, d.buscas_nao_alcancadas,
       d.cliques AS cliques_organicos_e_pagos, d.compras, d.cvr_pct,
       d.variantes, d.variantes_cauda, d.compras_da_cauda,
       d.decisao
FROM zm19_asins z
LEFT JOIN marketcloud_gold.v_descoberta_asin_v1 d ON d.asin = z.asin;
