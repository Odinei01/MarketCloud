package query

import (
	"fmt"
	"net/http"
)

// GET /api/v1/gold/robot-today
// "Meu Robô Hoje" — tudo em português de dono: dinheiro, o que o robô fez,
// o que precisa de você, e se dá pra confiar. Sem jargão técnico.
func (h *Handler) RobotToday(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	out := map[string]any{}

	// 1) DINHEIRO — últimos 30 dias vs 30 anteriores
	var spend, sales, orders, spendPrev, salesPrev float64
	_ = h.db.QueryRow(ctx, `
		SELECT COALESCE(SUM(spend),0), COALESCE(SUM(sales_7d),0), COALESCE(SUM(orders_7d),0)
		FROM marketcloud_bronze.bronze_amazon_ads_hourly WHERE data_date >= CURRENT_DATE-30`).
		Scan(&spend, &sales, &orders)
	_ = h.db.QueryRow(ctx, `
		SELECT COALESCE(SUM(spend),0), COALESCE(SUM(sales_7d),0)
		FROM marketcloud_bronze.bronze_amazon_ads_hourly
		WHERE data_date >= CURRENT_DATE-60 AND data_date < CURRENT_DATE-30`).
		Scan(&spendPrev, &salesPrev)
	roas := 0.0
	if spend > 0 {
		roas = sales / spend
	}
	varSales := 0.0
	if salesPrev > 0 {
		varSales = (sales - salesPrev) / salesPrev * 100
	}
	out["resumo"] = map[string]any{
		"gastei": spend, "vendi": sales, "pedidos": orders, "retorno": roas,
		"variacao_venda_pct": varSales,
	}

	// 2) CONFIANÇA — traduz o AUC do modelo de conversão num farol
	var auc *float64
	_ = h.db.QueryRow(ctx, `
		SELECT (metrics_json->>'roc_auc')::float8
		FROM marketcloud_features.model_registry
		WHERE model_name = 'HourlyConversionRealV2' AND metrics_json ? 'roc_auc'
		ORDER BY last_trained_at DESC LIMIT 1`).Scan(&auc)
	nivel, texto := "aprendendo", "🟡 Aprendendo — ainda juntando dados pra ficar preciso."
	if auc != nil {
		pct := int(*auc * 100)
		switch {
		case *auc >= 0.9:
			nivel, texto = "alta", fmt.Sprintf("🟢 Confiável — o robô acerta cerca de %d%% das horas boas.", pct)
		case *auc >= 0.75:
			nivel, texto = "media", fmt.Sprintf("🟡 Razoável — o robô acerta ~%d%% das horas boas; melhora com mais dado.", pct)
		default:
			nivel, texto = "baixa", "🔴 Ainda fraco — pouca conversão pra aprender bem."
		}
	}
	out["confianca"] = map[string]any{"nivel": nivel, "texto": texto}

	// 3) O ROBÔ FEZ — recomendações acionáveis, em português
	acoes := []map[string]any{}
	rows, err := h.db.Query(ctx, `
		SELECT action_type, campaign_name, event_hour
		FROM marketcloud_gold.gold_hourly_recommendations_v1
		WHERE action_type <> 'KEEP_STRONG'
		ORDER BY priority_score DESC NULLS LAST LIMIT 8`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var act, camp string
			var hour int
			if rows.Scan(&act, &camp, &hour) != nil {
				continue
			}
			var icon, txt string
			switch act {
			case "BID_UP":
				icon, txt = "⬆️", fmt.Sprintf("Reforçar %s às %dh — costuma vender bem nesse horário", camp, hour)
			case "CUT_HOUR":
				icon, txt = "✂️", fmt.Sprintf("Cortar %s às %dh — não converte, economiza gasto", camp, hour)
			case "BID_DOWN":
				icon, txt = "⬇️", fmt.Sprintf("Baixar o lance de %s às %dh — está caro pro retorno", camp, hour)
			default:
				icon, txt = "•", fmt.Sprintf("%s às %dh: %s", camp, hour, act)
			}
			acoes = append(acoes, map[string]any{"icon": icon, "texto": txt})
		}
	}
	out["robo_fez"] = acoes

	// 4) PRECISA DE VOCÊ — alertas de retargeting (reativar/matar)
	alertas := []map[string]any{}
	arows, err := h.db.Query(ctx, `
		SELECT alerta, verdict FROM marketcloud_gold.gold_amc_retargeting_alerts
		WHERE verdict IN ('MATAR','ESCALAR') ORDER BY priority, product_revenue DESC`)
	if err == nil {
		defer arows.Close()
		for arows.Next() {
			var alerta, verdict string
			if arows.Scan(&alerta, &verdict) != nil {
				continue
			}
			alertas = append(alertas, map[string]any{"texto": alerta, "verdict": verdict})
		}
	}
	out["precisa_voce"] = alertas

	writeJSON(w, http.StatusOK, out)
}
