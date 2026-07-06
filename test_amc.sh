#!/usr/bin/env bash
# Testa se o AMC API está aceitando as credenciais LWA.
# Necessita de LWA_ACCESS_TOKEN exportado, ou token obtido via /auth/token.
# Uso: LWA_ACCESS_TOKEN=<token> AMC_INSTANCE=amcoo5vzswt bash test_amc.sh

TOKEN="${LWA_ACCESS_TOKEN:?LWA_ACCESS_TOKEN não configurado}"
INSTANCE="${AMC_INSTANCE:-amcoo5vzswt}"
ENTITY_ID="${AMC_ENTITY_ID:-ENTITY1A6DL03BNNULZ}"
MARKETPLACE_ID="${AMC_MARKETPLACE_ID:-A2Q3Y263D00KWC}"
LWA_CLIENT_ID="${AMAZON_LWA_CLIENT_ID:?AMAZON_LWA_CLIENT_ID não configurado}"

echo "Testando AMC API (GET /workflows)..."
result=$(curl -s -w "\nHTTP:%{http_code}" -X GET \
  "https://advertising-api.amazon.com/amc/reporting/${INSTANCE}/workflows" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Amazon-Advertising-API-ClientId: ${LWA_CLIENT_ID}" \
  -H "Amazon-Advertising-API-AdvertiserId: ${ENTITY_ID}" \
  -H "Amazon-Advertising-API-MarketplaceId: ${MARKETPLACE_ID}" \
  -H "Content-Type: application/json" 2>&1)

http_code=$(echo "$result" | grep "HTTP:" | cut -d: -f2)
body=$(echo "$result" | grep -v "HTTP:")

echo "Status: $http_code"
echo "Body:   $body"

RUN_ID="fcb9a824-1606-4246-8a2f-a5f7e871577a"
if [ "$http_code" = "200" ]; then
  echo ""
  echo "AMC OK — disparar run:"
  echo "  docker exec -i marketcloud_db psql -U mcadmin -d marketcloud -c \\"
  echo "    \"UPDATE query_runs SET status='CREATED', error_code=NULL, error_message=NULL, updated_at=NOW() WHERE id='\$RUN_ID';\""
  echo "  curl -s -X POST http://localhost:8092/internal/trigger/\$RUN_ID"
else
  echo ""
  echo "Erro: $http_code"
fi
