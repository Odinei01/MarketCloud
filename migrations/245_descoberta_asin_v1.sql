-- 245: descoberta por ASIN sobre a ontologia — onde ha mercado que a ZANOM nao cobre.
--
-- Junta as duas medidas que so fazem sentido juntas:
--   volume_total  = quanto o mercado busca aquele conceito (inclusive escrito errado)
--   cobertura_pct = quanto disso a ZANOM sequer aparece (impressoes / volume)
--
-- Cobertura baixa com volume alto e onde cabe campanha nova. Cobertura alta e mercado
-- ja trabalhado — ali o ganho vem de lance e conversao, nao de expansao.
--
-- So faz sentido lido em cima da ontologia: por grafia isolada, a cauda vira ruido e a
-- soma do mercado fica invisivel. No cozedor, 106 das 165 variantes tem menos de 20
-- buscas e responderam por 8 das 13 compras.

CREATE OR REPLACE VIEW marketcloud_gold.v_descoberta_asin_v1 AS
SELECT
    o.asin,
    COUNT(*)                     AS conceitos,
    SUM(o.variantes)             AS variantes,
    SUM(o.variantes_cauda)       AS variantes_cauda,
    SUM(o.volume_total)          AS volume_mercado,
    SUM(o.impressoes)            AS impressoes,
    SUM(o.cliques)               AS cliques,
    SUM(o.compras)               AS compras,
    SUM(o.compras_cauda)         AS compras_da_cauda,
    ROUND(100.0 * SUM(o.impressoes)::numeric / NULLIF(SUM(o.volume_total)::numeric, 0), 1) AS cobertura_pct,
    ROUND(100.0 * SUM(o.compras)::numeric  / NULLIF(SUM(o.cliques)::numeric, 0), 1)        AS cvr_pct,
    -- espaco nao coberto, em buscas. E o tamanho da oportunidade, nao uma projecao de venda.
    (SUM(o.volume_total) - SUM(o.impressoes))                                              AS buscas_nao_alcancadas,
    CASE
        WHEN SUM(o.compras) > 0
         AND ROUND(100.0*SUM(o.impressoes)::numeric/NULLIF(SUM(o.volume_total)::numeric,0),1) < 20
        THEN 'EXPANDIR'          -- ja converte e o mercado mal conhece o produto
        WHEN SUM(o.compras) > 0
        THEN 'OTIMIZAR'          -- converte e ja cobre bem: ganho vem de lance/conversao
        WHEN SUM(o.cliques) >= 5
        THEN 'INVESTIGAR'        -- traz clique e nao vende: oferta, preco ou pagina
        ELSE 'SEM_SINAL'
    END AS decisao
FROM marketcloud_gold.v_query_ontologia_v2 o
GROUP BY o.asin;

COMMENT ON VIEW marketcloud_gold.v_descoberta_asin_v1 IS
'Descoberta por ASIN sobre a ontologia de query: volume de mercado x cobertura da ZANOM. EXPANDIR = ja converte e cobre menos de 20% das buscas do conceito.';
