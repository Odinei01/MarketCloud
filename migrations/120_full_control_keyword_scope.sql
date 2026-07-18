-- =====================================================================
-- 120: Granularidade de KEYWORD no Full Control.
--
-- Ate aqui o Full Control era por (produto, campanha). O dono pediu escolher
-- tambem QUAIS keywords da campanha o robo gerencia. Esta tabela escopa isso:
--   - se uma campanha full_control TEM keywords aqui (enabled) -> so essas sao
--     geridas pelo robo (BID);
--   - se NAO tem nenhuma -> todas as keywords ativas (comportamento atual).
-- Budget/placement do 360 seguem no grao CAMPANHA (nao ha placement por keyword
-- na Amazon), entao a keyword escopa o lado de BID/keyword.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_control.full_control_keywords (
    id BIGSERIAL PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    campaign_id TEXT NOT NULL,
    ad_group_id TEXT,
    keyword_id TEXT,
    keyword_text TEXT NOT NULL,
    match_type TEXT,
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fc_keyword
    ON marketcloud_control.full_control_keywords
       (tenant_id, campaign_id, lower(trim(keyword_text)), lower(trim(COALESCE(match_type,''))));
CREATE INDEX IF NOT EXISTS idx_fc_keyword_campaign
    ON marketcloud_control.full_control_keywords (tenant_id, campaign_id, enabled);

-- Resolve o escopo efetivo por campanha full_control: quando escopo != vazio,
-- so as keywords listadas contam; senao, todas. Base para a UI e para o BID.
CREATE OR REPLACE VIEW marketcloud_gold.v_full_control_keyword_scope_v1 AS
WITH fc AS (
    SELECT DISTINCT tenant_id, campaign_id, campaign_name
    FROM marketcloud_control.full_control_pilots
    WHERE mode = 'full_control' AND status = 'active' AND COALESCE(campaign_id,'') <> ''
), scoped AS (
    SELECT tenant_id, campaign_id,
           count(*) FILTER (WHERE enabled) AS keywords_selecionadas
    FROM marketcloud_control.full_control_keywords
    GROUP BY tenant_id, campaign_id
)
SELECT
    fc.tenant_id, fc.campaign_id, fc.campaign_name,
    COALESCE(s.keywords_selecionadas, 0) AS keywords_selecionadas,
    CASE WHEN COALESCE(s.keywords_selecionadas,0) > 0
         THEN 'ESCOPO_KEYWORD'      -- so as listadas
         ELSE 'CAMPANHA_INTEIRA'    -- todas as keywords ativas
    END AS escopo
FROM fc
LEFT JOIN scoped s ON s.tenant_id = fc.tenant_id AND s.campaign_id = fc.campaign_id;

COMMENT ON VIEW marketcloud_gold.v_full_control_keyword_scope_v1 IS
    'Escopo de keyword por campanha full_control: CAMPANHA_INTEIRA (todas) ou ESCOPO_KEYWORD (so as selecionadas em full_control_keywords).';
