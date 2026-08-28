-- 252: o limiar do EXPANDIR passa a ser RELATIVO, nao um numero inventado.
--
-- ERRO DA 251: usei 'share < 5%' como corte. A media da conta e 2,36% — praticamente
-- tudo fica abaixo de 5%, entao os SEIS ASINs que vendem viraram EXPANDIR, o cozedor
-- (o mais trabalhado da conta) junto. A regua deixou de separar qualquer coisa.
--
-- Trocar uma metrica errada por uma metrica certa com corte arbitrario nao resolve: o
-- share real e da ordem de 0,05% a 2,4% nesta conta, e nenhum limiar absoluto tirado de
-- fora respeita essa escala.
--
-- CORRECAO: comparar cada ASIN com a MEDIANA dos que ja provaram converter. A pergunta
-- deixa de ser 'o share e baixo?' (sempre e) e passa a ser 'entre os produtos que
-- funcionam, este e dos menos presentes?'. O corte se recalibra sozinho conforme a conta
-- cresce, em vez de envelhecer.

DROP VIEW IF EXISTS marketcloud_gold.v_descoberta_zm19_v1;
DROP VIEW IF EXISTS marketcloud_gold.v_descoberta_asin_v1;

CREATE VIEW marketcloud_gold.v_descoberta_asin_v1 AS
WITH rel AS (
    SELECT r.asin, r.query, r.volume_busca, r.impressoes_zanom, r.cliques_zanom, r.compras_zanom
    FROM marketcloud_gold.v_query_relevancia_v1 r WHERE r.relevante
),
comshare AS (
    SELECT rel.*, sh.impression_share_pct, sh.impressoes_mercado
    FROM rel LEFT JOIN marketcloud_gold.v_query_share_v1 sh
      ON sh.asin = UPPER(rel.asin) AND sh.query = lower(btrim(rel.query))
),
agg AS (
    SELECT asin,
        COUNT(DISTINCT query) conceitos, COUNT(*) variantes,
        COUNT(*) FILTER (WHERE volume_busca < 20) variantes_cauda,
        SUM(volume_busca) volume_mercado, SUM(impressoes_zanom) impressoes,
        SUM(cliques_zanom) cliques, SUM(compras_zanom) compras,
        SUM(compras_zanom) FILTER (WHERE volume_busca < 20) compras_da_cauda,
        ROUND((SUM(impression_share_pct*volume_busca)/NULLIF(SUM(volume_busca) FILTER (WHERE impression_share_pct IS NOT NULL),0))::numeric,2) share_pct,
        COUNT(*) FILTER (WHERE impression_share_pct IS NOT NULL) queries_com_share,
        ROUND(100.0*SUM(compras_zanom)::numeric/NULLIF(SUM(cliques_zanom)::numeric,0),1) cvr_pct,
        SUM(impressoes_mercado) impressoes_mercado
    FROM comshare GROUP BY asin
),
-- referencia: mediana do share ENTRE OS QUE JA CONVERTEM. Produto que nunca vendeu nao
-- serve de regua — o share dele pode ser baixo por nao ter mercado, nao por falta de
-- presenca.
ref AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY share_pct) AS share_mediano
    FROM agg WHERE compras > 0 AND share_pct IS NOT NULL
)
SELECT a.*, ROUND(r.share_mediano::numeric,2) AS share_mediano_referencia,
    CASE
        WHEN a.queries_com_share = 0 THEN 'SEM_SHARE'
        WHEN a.compras > 0 AND a.share_pct < r.share_mediano THEN 'EXPANDIR'
        WHEN a.compras > 0                                   THEN 'OTIMIZAR'
        WHEN a.cliques >= 5                                  THEN 'INVESTIGAR'
        ELSE 'SEM_SINAL'
    END AS decisao
FROM agg a CROSS JOIN ref r;

COMMENT ON VIEW marketcloud_gold.v_descoberta_asin_v1 IS
'Descoberta por ASIN: impression share real da Amazon, ponderado por volume, sobre o mercado relevante. EXPANDIR = converte E share abaixo da MEDIANA dos que convertem — limiar relativo, porque o share desta conta vive entre 0,05% e 2,4% e nenhum corte absoluto separa.';

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
       d.volume_mercado, d.share_pct, d.share_mediano_referencia, d.impressoes_mercado,
       d.cliques AS cliques_organicos_e_pagos, d.compras, d.cvr_pct,
       d.variantes, d.variantes_cauda, d.compras_da_cauda, d.decisao
FROM zm19_asins z
LEFT JOIN marketcloud_gold.v_descoberta_asin_v1 d ON d.asin = z.asin;
