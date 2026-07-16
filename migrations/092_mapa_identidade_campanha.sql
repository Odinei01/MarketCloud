-- P0-2 da auditoria (16/07): a ponte campaign_name <-> campaign_id e fragil.
-- bronze_amazon_ads_hourly (relatorio, que o ML treina) tem NOME e nao ID;
-- bronze_ams_hourly (stream) tem ID e nome vazio (848/848). Cada join refaz o
-- casamento por texto normalizado. Hoje funciona (o sinal do ML tem nome em
-- 100%), mas e frouxo: um nome novo ou um rename quebra em silencio.
--
-- Nao esta quebrado, e divida. Fix minimo e honesto: uma fonte unica de verdade
-- pro mapa, e uma sentinela que ACUSA quando aparecer nome sem id ou ambiguo —
-- em vez de descobrir pelo resultado errado.
CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_identity AS
SELECT lower(trim(campaign_name)) AS campaign_norm,
       max(campaign_name)  AS campaign_name,
       max(campaign_id)    AS campaign_id,
       count(DISTINCT campaign_id) AS ids_distintos
FROM marketcloud_bronze.bronze_swarm_current_bids
WHERE coalesce(campaign_id,'') <> '' AND coalesce(campaign_name,'') <> ''
GROUP BY 1;

COMMENT ON VIEW marketcloud_gold.gold_campaign_identity IS
    'Fonte unica nome<->id de campanha (do robo, que tem os dois). Joins de ML/AMS/robo devem resolver id por aqui, nao por texto solto.';

-- Sentinela: nomes que o ML/relatorio usa mas o mapa nao resolve pra 1 id.
-- Vazio = saudavel. Nao-vazio = alguem tem que olhar (rename, campanha nova
-- sem sync, ou nome ambiguo).
CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_identity_alertas AS
WITH usados AS (
    SELECT DISTINCT lower(trim(campaign_name)) AS campaign_norm, campaign_name
    FROM marketcloud_gold.gold_hourly_signal_amc
    WHERE coalesce(campaign_name,'') <> ''
)
SELECT u.campaign_name,
       CASE WHEN i.campaign_id IS NULL THEN 'SEM_ID_NO_MAPA'
            WHEN i.ids_distintos > 1   THEN 'NOME_AMBIGUO'
            ELSE 'OK' END AS situacao
FROM usados u
LEFT JOIN marketcloud_gold.gold_campaign_identity i ON i.campaign_norm = u.campaign_norm
WHERE i.campaign_id IS NULL OR i.ids_distintos > 1;

COMMENT ON VIEW marketcloud_gold.gold_campaign_identity_alertas IS
    'Nomes que o ML usa mas nao resolvem pra 1 id unico. Vazio = saudavel; nao-vazio = rename/campanha nova/ambiguidade a resolver.';
