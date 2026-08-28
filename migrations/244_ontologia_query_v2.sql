-- 244: ontologia v2 — aglutina por RADICAL DOMINANTE do ASIN.
--
-- A v1 assinava o conceito com as 2 palavras mais longas da busca, e ainda fragmentava:
-- 'cozedor eletrico', 'cozidor de ovos', 'cozinhar ovos eletrico' e 'ovo eletrico' sao a
-- MESMA intencao e caiam em conceitos diferentes, porque as palavras longas mudam de uma
-- grafia para outra. Dava 69 conceitos para um produto so.
--
-- COMO A v2 RESOLVE: para cada ASIN, ranqueia os radicais foneticos por volume de busca.
-- O radical mais forte e o nucleo do produto (no cozedor, o som de 'ovo'). Cada busca
-- entra no conceito do radical de maior rank que ela contem — entao 'cozinhar ovos' e
-- 'cozideira de ovo eletrica 220w' caem no mesmo lugar sem compartilhar palavra escrita.
--
-- DUAS CORRECOES QUE FIZERAM A DIFERENCA:
--   1. token de 3 letras passa a contar. 'ovo' tem 3 e estava sendo descartado — o
--      nucleo do produto ficava de fora em metade das buscas.
--   2. plural normalizado antes do som: dmetaphone('ovo')=AF e dmetaphone('ovos')=AFS
--      sao radicais DIFERENTES. Sem tirar o 's', singular e plural viravam conceitos
--      separados.
-- Com as duas, o cozedor foi de 69 conceitos (v1) para 5, sendo que o principal agrupa
-- 158 das 165 variantes: 7.318 buscas, 77 cliques, 11 compras, CVR 14,3%.
--
-- Por que nao agrupar simplesmente por ASIN: o mesmo produto atende intencoes distintas
-- ('porta capsula nespresso' x 'porta capsula dolce gusto'). O radical preserva essa
-- separacao quando ela existe no vocabulario, e aglutina quando nao existe. Os 4
-- conceitos residuais do cozedor sao legitimos: 'dash 220v' (marca), 'eggs boiler 220w'
-- (ingles) e afins — nao compartilham o nucleo fonetico com o resto.
--
-- Numeros e unidades ficam fora do radical: '220v' e '3 coracoes' nao podem quebrar o
-- conceito, mas seguem visiveis na grafia principal.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_ontologia_v2 AS
 WITH toks AS (
         SELECT q.query,
            q.asin,
            q.volume_busca,
            q.impressoes_zanom,
            q.cliques_zanom,
            q.compras_zanom,
            t.tok,
            dmetaphone(regexp_replace(t.tok, 's$'::text, ''::text)) AS rad
           FROM marketcloud_gold.v_query_barata_v3 q
             CROSS JOIN LATERAL unnest(string_to_array(regexp_replace(unaccent(lower(q.query)), '[^a-z ]'::text, ' '::text, 'g'::text), ' '::text)) t(tok)
          WHERE length(t.tok) >= 3 AND (t.tok <> ALL (ARRAY['para'::text, 'com'::text, 'sem'::text, 'dos'::text, 'das'::text, 'pelo'::text, 'pela'::text, 'mais'::text, 'tipo'::text, 'esse'::text, 'essa'::text, 'este'::text, 'esta'::text, 'eletrico'::text, 'eletrica'::text, 'automatico'::text])) AND dmetaphone(regexp_replace(t.tok, 's$'::text, ''::text)) <> ''::text
        ), rad_rank AS (
         SELECT toks.asin,
            toks.rad,
            sum(toks.volume_busca) AS peso,
            row_number() OVER (PARTITION BY toks.asin ORDER BY (sum(toks.volume_busca)) DESC, toks.rad) AS rn
           FROM toks
          GROUP BY toks.asin, toks.rad
        ), query_conceito AS (
         SELECT t.query,
            t.asin,
            min(r.rn) AS rn
           FROM toks t
             JOIN rad_rank r ON r.asin = t.asin AND r.rad = t.rad
          GROUP BY t.query, t.asin
        ), atrib AS (
         SELECT DISTINCT q.query,
            q.asin,
            r.rad AS conceito_rad
           FROM query_conceito q
             JOIN rad_rank r ON r.asin = q.asin AND r.rn = q.rn
        ), base AS (
         SELECT a.asin,
            a.conceito_rad,
            v.query,
            v.volume_busca,
            v.impressoes_zanom,
            v.cliques_zanom,
            v.compras_zanom
           FROM atrib a
             JOIN marketcloud_gold.v_query_barata_v3 v ON v.query = a.query AND v.asin = a.asin
        )
 SELECT asin,
    conceito_rad,
    (array_agg(query ORDER BY volume_busca DESC))[1] AS grafia_principal,
    count(*) AS variantes,
    count(*) FILTER (WHERE volume_busca < 20::double precision) AS variantes_cauda,
    sum(volume_busca) AS volume_total,
    sum(volume_busca) FILTER (WHERE volume_busca < 20::double precision) AS volume_cauda,
    sum(impressoes_zanom) AS impressoes,
    sum(cliques_zanom) AS cliques,
    sum(compras_zanom) AS compras,
    sum(compras_zanom) FILTER (WHERE volume_busca < 20::double precision) AS compras_cauda,
    round(sum(compras_zanom)::numeric / NULLIF(sum(cliques_zanom)::numeric, 0::numeric) * 100::numeric, 1) AS cvr_conceito_pct,
    round(sum(impressoes_zanom)::numeric / NULLIF(sum(volume_busca)::numeric, 0::numeric) * 100::numeric, 1) AS cobertura_pct,
    array_agg(query ORDER BY compras_zanom DESC, volume_busca DESC) FILTER (WHERE compras_zanom > 0::double precision) AS grafias_que_venderam
   FROM base
  GROUP BY asin, conceito_rad;
;

COMMENT ON VIEW marketcloud_gold.v_query_ontologia_v2 IS
'Ontologia por radical fonetico dominante do ASIN. Aglutina grafias erradas da mesma intencao que a v1 separava por nao compartilharem palavra escrita igual.';
