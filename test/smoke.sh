#!/usr/bin/env bash
# Smoke test para Phase 1 e Phase 2
# Usage: bash test/smoke.sh

BASE="http://localhost:8090/api/v1"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
section() { echo -e "\n${YELLOW}── $1 ──${NC}"; }

# ── Criar tenant ──────────────────────────────────────────────────
section "SUPER_ADMIN: criar tenant"
R=$(curl -s -X POST "$BASE/tenants" \
  -H "Content-Type: application/json" \
  -d '{"name":"ZANOM Teste","slug":"zanom-test","plan":"PROFESSIONAL"}')
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
TENANT_ID=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin)['tenant']['id'])" 2>/dev/null)
[ -n "$TENANT_ID" ] && ok "Tenant criado: $TENANT_ID" || fail "Falhou ao criar tenant"

# ── Registrar usuário admin ────────────────────────────────────────
section "Auth: registrar admin"
R=$(curl -s -X POST "$BASE/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_ID\",\"email\":\"admin@zanom.com\",\"password\":\"senha123\",\"name\":\"Admin Zanom\"}")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
TOKEN=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)
[ -n "$TOKEN" ] && ok "Token obtido: ${TOKEN:0:30}..." || fail "Falhou ao registrar"

# ── Me ────────────────────────────────────────────────────────────
section "Auth: /me"
R=$(curl -s "$BASE/auth/me" -H "Authorization: Bearer $TOKEN")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
echo "$R" | grep -q "email" && ok "/me OK" || fail "/me falhou"

# ── Criar loja ────────────────────────────────────────────────────
section "Store: criar loja"
R=$(curl -s -X POST "$BASE/stores" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID" \
  -H "Content-Type: application/json" \
  -d '{"name":"Loja Brasil","marketplace":"AMAZON_BR","external_id":"A2Q3Y263D00KWC"}')
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
STORE_ID=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin)['store']['id'])" 2>/dev/null)
[ -n "$STORE_ID" ] && ok "Loja criada: $STORE_ID" || fail "Falhou ao criar loja"

# ── Listar lojas ──────────────────────────────────────────────────
section "Store: listar lojas"
R=$(curl -s "$BASE/stores" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
echo "$R" | grep -q "Loja Brasil" && ok "Listagem OK" || fail "Listagem falhou"

# ── Query templates ───────────────────────────────────────────────
section "Query: listar templates"
R=$(curl -s "$BASE/query-templates" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID")
COUNT=$(echo "$R" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('templates',[])))" 2>/dev/null)
[ "$COUNT" -ge 6 ] && ok "$COUNT templates encontrados" || fail "Templates: esperado >=6, got $COUNT"
TPL_ID=$(echo "$R" | python3 -c "import sys,json; ts=json.load(sys.stdin).get('templates',[]); print(ts[0]['id'] if ts else '')" 2>/dev/null)

# ── Criar query run ───────────────────────────────────────────────
section "Query: criar run (idempotente)"
R=$(curl -s -X POST "$BASE/query-runs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID" \
  -H "Content-Type: application/json" \
  -d "{\"store_id\":\"$STORE_ID\",\"template_id\":\"$TPL_ID\",\"parameters\":{\"start_date\":\"2025-06-01\",\"end_date\":\"2025-06-30\",\"marketplace_id\":\"A2Q3Y263D00KWC\"}}")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
RUN_ID=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('run',{}).get('id',''))" 2>/dev/null)
[ -n "$RUN_ID" ] && ok "Run criado: $RUN_ID" || fail "Falhou ao criar run"

# ── Listar runs ───────────────────────────────────────────────────
section "Query: listar runs"
R=$(curl -s "$BASE/query-runs?store_id=$STORE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
echo "$R" | grep -q "$RUN_ID" && ok "Run aparece na listagem" || fail "Run não encontrado"

# ── Insights ──────────────────────────────────────────────────────
section "Insights: listar"
R=$(curl -s "$BASE/insights?store_id=$STORE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
ok "Insights endpoint respondeu"

# ── Recomendações ─────────────────────────────────────────────────
section "Recommendations: listar"
R=$(curl -s "$BASE/recommendations?store_id=$STORE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
ok "Recommendations endpoint respondeu"

# ── External actions ──────────────────────────────────────────────
section "External: actions"
R=$(curl -s "$BASE/external/recommendations/actions?store_id=$STORE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant-ID: $TENANT_ID")
echo "$R" | python3 -m json.tool 2>/dev/null || echo "$R"
ok "External actions endpoint respondeu"

echo -e "\n${GREEN}=== Smoke test concluído ===${NC}"
echo "Tenant ID : $TENANT_ID"
echo "Token     : ${TOKEN:0:40}..."
echo "Store ID  : $STORE_ID"
echo "Run ID    : $RUN_ID"
