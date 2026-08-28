-- 239: E001, E002 e E003 estavam presos no tenant de seed.
--
-- Eles tinham tenant_id = 00000000-0000-0000-0000-000000000001 (o tenant demo do seed),
-- enquanto os irmaos E004..E013 estao no tenant real e outros 49 templates sao globais.
-- Resquicio de seed, nao configuracao.
--
-- EFEITO PRATICO: o agendamento funcionava (o orchestrator le direto do banco e nao
-- valida tenant), mas qualquer execucao MANUAL era recusada — a API cruza o tenant do
-- token com o do template e com o dono da store, e devolvia STORE_ACCESS_DENIED. Ou seja:
-- os tres extractors mais importantes nao podiam ser testados sob demanda.
--
-- Alinha com E004..E013, que ja usam o tenant real e rodam manualmente sem problema.

UPDATE query_templates
SET tenant_id = 'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9', updated_at = NOW()
WHERE code IN ('MC_ZANOM_E001','MC_ZANOM_E002','MC_ZANOM_E003')
  AND tenant_id = '00000000-0000-0000-0000-000000000001';
