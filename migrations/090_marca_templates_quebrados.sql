-- P1 da auditoria (16/07): templates AMC invalidos (DAYOFWEEK, ||, objetos
-- inexistentes) que so devolvem AMC_QUERY_REJECTED. Nao estao na automacao
-- diaria (so E001-E009 + os Q corrigidos), entao nao queimam recurso — mas
-- ficam na tela como cards clicaveis que sempre dao erro.
--
-- Reescrever os 31 e trabalho iterativo de dias (o dono valida cada um no
-- console AMC). Enquanto isso: marca como BROKEN o template que SO falhou e
-- NUNCA completou. Criterio por DADO (historico de runs), nao por lista chutada.
-- A tela pode esconder BROKEN; o dono para de clicar e tomar erro.
UPDATE query_templates qt
SET status = 'BROKEN', updated_at = NOW()
WHERE qt.status = 'ACTIVE'
  AND EXISTS (SELECT 1 FROM query_runs r WHERE r.query_template_id = qt.id AND r.status = 'FAILED')
  AND NOT EXISTS (SELECT 1 FROM query_runs r WHERE r.query_template_id = qt.id
                  AND r.status IN ('SUCCEEDED','MODELING_COMPLETED'));
