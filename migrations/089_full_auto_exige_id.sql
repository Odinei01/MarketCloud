-- P0 da auditoria (16/07): full-auto com 16 campanhas, 7 sem campaign_id,
-- casando por NOME. campaign_allowed() libera por id OU nome — entao qualquer
-- campanha nova que alguem batize com um desses nomes entra em full-auto
-- sozinha, sem liberacao. Governanca frouxa num caminho que mexe em lance real.
--
-- As 7 orfas resolvem cada uma pra UM id unico no bronze (sem ambiguidade hoje),
-- e a "Seladora" orfa aponta pro MESMO id da Seladora com id: e duplicata.
--
-- 1) preenche o campaign_id das orfas a partir do bronze;
-- 2) remove as que ficaram duplicadas (mesmo id);
-- 3) trava: campaign_id passa a ser obrigatorio pra enabled=true.
UPDATE marketcloud_control.ml_full_auto_campaign_flags f
SET campaign_id = b.campaign_id, updated_at = NOW()
FROM (
    SELECT lower(trim(campaign_name)) AS nome, max(campaign_id) AS campaign_id
    FROM marketcloud_bronze.bronze_swarm_current_bids
    WHERE coalesce(campaign_id,'') <> ''
    GROUP BY 1
    HAVING count(DISTINCT campaign_id) = 1   -- so preenche quando nao ha ambiguidade
) b
WHERE coalesce(f.campaign_id,'') = ''
  AND lower(trim(f.campaign_name)) = b.nome;

-- duplicatas (mesmo campaign_id): mantem a mais recente, apaga o resto
DELETE FROM marketcloud_control.ml_full_auto_campaign_flags a
USING marketcloud_control.ml_full_auto_campaign_flags b
WHERE a.campaign_id = b.campaign_id
  AND coalesce(a.campaign_id,'') <> ''
  AND a.ctid < b.ctid;

-- qualquer orfa que sobrou (nome nao resolveu pra id unico) e DESLIGADA:
-- melhor perder a liberacao do que liberar a campanha errada.
UPDATE marketcloud_control.ml_full_auto_campaign_flags
SET enabled = FALSE, updated_at = NOW(),
    notes = coalesce(notes,'') || ' [desligada 16/07: sem campaign_id resolvivel]'
WHERE enabled AND coalesce(campaign_id,'') = '';

-- trava dura: nao da mais pra ligar full-auto sem id.
ALTER TABLE marketcloud_control.ml_full_auto_campaign_flags
    DROP CONSTRAINT IF EXISTS chk_full_auto_requires_id;
ALTER TABLE marketcloud_control.ml_full_auto_campaign_flags
    ADD CONSTRAINT chk_full_auto_requires_id
    CHECK (enabled = FALSE OR coalesce(campaign_id,'') <> '');
