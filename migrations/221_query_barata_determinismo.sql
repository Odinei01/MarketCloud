-- 221: torna o detector DETERMINISTICO.
--
-- BUG ENCONTRADO AO EXPORTAR O ARQUIVO: a mesma consulta devolvia 611 linhas sem
-- ORDER BY e 634 COM ORDER BY. Contagem que muda conforme a ordenacao significa que a
-- view nao e reproduzivel — e um numero que nao se repete nao pode virar decisao de
-- onde gastar.
--
-- CAUSA: tokens_do_catalogo era uma SUBCONSULTA CORRELACIONADA sobre
-- swarm_src.amazon_listings, que e uma foreign table. Dependendo do plano escolhido,
-- o Postgres avalia a subconsulta mais de uma vez, e cada varredura do FDW abre sua
-- propria leitura — sem garantia de ver o mesmo snapshot. Com ORDER BY o plano muda,
-- a subconsulta e reavaliada, e o filtro > 0 passa a aceitar linhas diferentes.
--
-- CORRECAO: materializar o vocabulario do catalogo numa TABELA local e trocar a
-- subconsulta correlacionada por LEFT JOIN + agregacao. Uma varredura, um resultado.
--
-- A tabela e recarregada por refresh_vocabulario_catalogo(); o catalogo muda quando
-- entra produto novo, nao a cada consulta.

CREATE TABLE IF NOT EXISTS marketcloud_gold.vocabulario_catalogo (
  token       text PRIMARY KEY,
  atualizado  timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_vocabulario_catalogo()
  RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE v_rows int;
BEGIN
  DELETE FROM marketcloud_gold.vocabulario_catalogo;
  INSERT INTO marketcloud_gold.vocabulario_catalogo (token)
  SELECT DISTINCT lower(tok)
  FROM swarm_src.amazon_listings l,
       LATERAL unnest(string_to_array(
         regexp_replace(lower(COALESCE(l.title,'')), '[^a-z0-9áàâãéêíóôõúç ]', ' ', 'g'), ' ')) tok
  WHERE COALESCE(l.title,'') <> '' AND length(tok) >= 4
  ON CONFLICT (token) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END $fn$;

SELECT marketcloud_gold.refresh_vocabulario_catalogo();

CREATE OR REPLACE VIEW marketcloud_gold.v_query_barata_candidata_v2 AS
SELECT c.*,
       COALESCE(cat.n, 0) AS tokens_do_catalogo
FROM marketcloud_gold.v_query_barata_candidata c
LEFT JOIN LATERAL (
  -- JOIN em tabela LOCAL: uma varredura, resultado estavel independente do plano
  SELECT COUNT(*) n
  FROM unnest(string_to_array(c.query, ' ')) t
  JOIN marketcloud_gold.vocabulario_catalogo v ON v.token = lower(t)
) cat ON true;
