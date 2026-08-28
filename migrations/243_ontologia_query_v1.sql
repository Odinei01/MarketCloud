-- 243: ONTOLOGIA DE QUERY — agrupa grafias da mesma intencao num conceito unico.
--
-- POR QUE: o detector avaliava cada grafia isolada e jogava fora a cauda como ruido
-- estatistico. Medido no Cozedor de ovos (B0HBZJG89G): das 167 variantes, 108 tem menos
-- de 20 buscas — e essas 108 responderam por 8 das 13 compras. 62% das vendas do produto
-- vinham de grafias que o detector descartava UMA A UMA por terem 1 compra cada.
--
-- Somadas, viram evidencia. Separadas, viram ruido. O erro nao era o limiar: era a
-- unidade de analise.
--
-- COMO AGRUPA: por SOM, nao por distancia de texto. Quem digita errado erra foneticamente.
--   cozedor / cosidor / cozidor / cozideira  -> dmetaphone KSTR
--   capsula / capisula                        -> KPSL
--   parafusadeira / parafuzadeira             -> PRFS
--   nespresso / nexpresso                     -> dmetaphone difere, soundex N216 nao
-- Por isso a assinatura usa dmetaphone E soundex: se qualquer um dos dois casar, e a
-- mesma palavra mal escrita.
--
-- O ASIN ancora o conceito. Nao agrupamos "cozedor" com "cozinhar" por acaso fonetico:
-- so entram no mesmo conceito queries que levaram ao MESMO produto.
--
-- NAO corrige a grafia do cliente (spec §15): a variante errada continua existindo e
-- pode virar keyword propria. A ontologia serve para MEDIR junto, nao para normalizar
-- o que se compra. Quem digita errado compra igual — e paga menos pelo clique, porque
-- ninguem anuncia ali.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_ontologia_v1 AS
WITH tokens AS (
    SELECT
        q.query, q.asin, q.volume_busca, q.impressoes_zanom, q.cliques_zanom, q.compras_zanom,
        -- token significativo: >=4 letras, sem stopword. Numero e unidade caem fora para
        -- que "220v", "110v" e "3 coracoes" nao fragmentem o mesmo conceito.
        t.tok
    FROM marketcloud_gold.v_query_barata_v3 q
    CROSS JOIN LATERAL unnest(
        string_to_array(regexp_replace(unaccent(lower(q.query)), '[^a-z ]', ' ', 'g'), ' ')
    ) AS t(tok)
    WHERE length(t.tok) >= 4
      AND t.tok NOT IN ('para','com','sem','dos','das','pelo','pela','mais','tipo','esse','essa','este','esta')
),
assinatura AS (
    -- assinatura do conceito: as 2 palavras mais longas da query, por som.
    SELECT query, asin, volume_busca, impressoes_zanom, cliques_zanom, compras_zanom,
           string_agg(sig, '|' ORDER BY sig) AS conceito_sig
    FROM (
        SELECT query, asin, volume_busca, impressoes_zanom, cliques_zanom, compras_zanom, tok,
               dmetaphone(tok) || ':' || soundex(tok) AS sig,
               ROW_NUMBER() OVER (PARTITION BY query, asin ORDER BY length(tok) DESC, tok) rn
        FROM tokens
    ) x
    WHERE rn <= 2
    GROUP BY query, asin, volume_busca, impressoes_zanom, cliques_zanom, compras_zanom
)
SELECT
    a.asin,
    a.conceito_sig,
    -- a grafia mais buscada representa o conceito na tela
    (array_agg(a.query ORDER BY a.volume_busca DESC))[1]          AS grafia_principal,
    COUNT(*)                                                       AS variantes,
    COUNT(*) FILTER (WHERE a.volume_busca < 20)                    AS variantes_cauda,
    SUM(a.volume_busca)                                            AS volume_total,
    SUM(a.volume_busca) FILTER (WHERE a.volume_busca < 20)         AS volume_cauda,
    SUM(a.impressoes_zanom)                                        AS impressoes,
    SUM(a.cliques_zanom)                                           AS cliques,
    SUM(a.compras_zanom)                                           AS compras,
    SUM(a.compras_zanom) FILTER (WHERE a.volume_busca < 20)        AS compras_cauda,
    -- o que o detector por-grafia NAO enxergava: conversao do conceito inteiro
    ROUND((SUM(a.compras_zanom)::numeric / NULLIF(SUM(a.cliques_zanom)::numeric,0)) * 100, 1) AS cvr_conceito_pct,
    -- variantes que ja venderam sozinhas, para virar keyword propria
    array_agg(a.query ORDER BY a.compras_zanom DESC, a.volume_busca DESC)
        FILTER (WHERE a.compras_zanom > 0)                         AS grafias_que_venderam
FROM assinatura a
GROUP BY a.asin, a.conceito_sig;

COMMENT ON VIEW marketcloud_gold.v_query_ontologia_v1 IS
'Agrupa grafias da mesma intencao (inclusive erradas) num conceito unico, por som e ancorado no ASIN. Existe porque 62% das compras do Cozedor de ovos vinham da cauda de variantes que o detector por-grafia descartava uma a uma.';
