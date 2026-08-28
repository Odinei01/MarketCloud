-- 249: filtra o denominador da cobertura por RELEVANCIA de intencao.
--
-- O DEFEITO que isso corrige (achado em 28/08): a cobertura tratava como "mercado do
-- produto" toda busca em que a Amazon exibiu o ASIN — inclusive quando exibiu errado.
-- No porta-capsulas (B0HBLS7BPG), das 68.529 buscas ditas "nao cobertas":
--     capsula dolce gusto    30.935
--     capsula 3 coracoes     18.491
--     dolce gusto capsulas   10.237
--     cantinho do cafe        2.490
-- Quem busca 'capsula dolce gusto' quer COMPRAR CAPSULA, nao o suporte. ~64 mil das
-- 68 mil buscas eram de outra intencao, e a cobertura de 4,5% era falsa: onde ele de
-- fato compete ('porta capsulas nespresso') a cobertura e 85%.
--
-- Com o denominador errado, o EXPANDIR virava falso positivo — e o cerebro da ZM19 ja
-- estava ordenando alvo por esse numero.
--
-- CRITERIO: fracao dos tokens significativos da busca que aparecem no perfil do produto
-- (titulo + bullets + descricao, de v_asin_product_profile).
--     'capsula dolce gusto'      -> capsula sim, dolce nao, gusto nao   = 0,33
--     'porta capsulas nespresso' -> porta sim, capsulas sim, nespresso nao = 0,67
-- Limiar 0,6. Determinístico e explicavel: nao usa modelo, nao adivinha sinonimo.
--
-- LIMITACAO ASSUMIDA: marca de terceiro no perfil derruba o score (nespresso conta como
-- ausente). Isso torna o filtro CONSERVADOR — prefere descartar busca boa a inflar o
-- mercado, que era o erro anterior.

IMPORT FOREIGN SCHEMA public LIMIT TO (v_asin_product_profile)
FROM SERVER swarm_pg INTO swarm_src;

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
           -- venda medida vence qualquer heuristica: se converteu, e do produto
           WHEN q.compras_zanom > 0 THEN true
           WHEN s.tokens IS NULL THEN false      -- sem perfil: nao afirma relevancia
           ELSE (s.casados::numeric / NULLIF(s.tokens,0)) >= 0.60
       END AS relevante
FROM q
LEFT JOIN score s ON s.query = q.query AND s.asin = q.asin;

COMMENT ON VIEW marketcloud_gold.v_query_relevancia_v1 IS
'A busca pertence ao mercado do ASIN? Fracao dos tokens da busca presentes no perfil do produto, limiar 0,60. Venda medida sobrepoe a heuristica. Existe porque a cobertura contava buscas de outra intencao (capsula dolce gusto no porta-capsulas).';
