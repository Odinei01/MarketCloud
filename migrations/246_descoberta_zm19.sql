-- 246: descoberta da ontologia recortada nos ASINs que a ZM19 anuncia.
--
-- O vinculo campanha->ASIN estava em bronze_amc_product_asin_daily (campaign_name +
-- product_asin). As tabelas de produto do FDW do robo nao carregam campanha, por isso
-- o recorte so era possivel pelo AMC.
--
-- ESCOPO: apenas 'ZANOM M19-CLONE%'. As campanhas 'SP - All products - m19 auto' sao do
-- M19 CONCORRENTE rodando na propria conta — o cerebro nunca deve trata-las como suas,
-- e o mesmo cuidado vale aqui: misturar as duas faria a descoberta recomendar expansao
-- em cima do inventario de outro autopilot.

CREATE OR REPLACE VIEW marketcloud_gold.v_descoberta_zm19_v1 AS
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

COMMENT ON VIEW marketcloud_gold.v_descoberta_zm19_v1 IS
'Descoberta (ontologia de query) recortada nos ASINs anunciados pelas campanhas ZANOM M19-CLONE. Exclui de proposito as campanhas do M19 concorrente que rodam na mesma conta.';
