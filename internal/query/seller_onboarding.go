package query

import (
	"math"
	"net/http"
	"strconv"

	"github.com/zanom/marketcloud/internal/middleware"
)

type onboardingStep struct {
	Key       string `json:"key"`
	Title     string `json:"title"`
	Status    string `json:"status"`
	Detail    string `json:"detail"`
	Next      string `json:"next"`
	UpdatedAt any    `json:"updated_at,omitempty"`
}

// GET /api/v1/settings/onboarding
func (h *Handler) SellerOnboarding(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tenantID := middleware.TenantIDFromCtx(ctx).String()

	steps := []onboardingStep{}
	add := func(key, title, status, detail, next string, updatedAt any) {
		steps = append(steps, onboardingStep{
			Key:       key,
			Title:     title,
			Status:    status,
			Detail:    detail,
			Next:      next,
			UpdatedAt: updatedAt,
		})
	}

	var operationalMode string
	var settingsUpdated any
	if err := h.db.QueryRow(ctx, `
		SELECT operational_mode, updated_at
		FROM marketcloud_control.tenant_settings
		WHERE tenant_id = $1`, tenantID).Scan(&operationalMode, &settingsUpdated); err != nil {
		add("seller_settings", "Travas do seller", "error", "Config Center ainda nao inicializado", "Salvar o modo operacional e guardrails do seller.", nil)
	} else if operationalMode == "full_auto" {
		add("seller_settings", "Travas do seller", "ok", "Seller permite Full-auto quando a campanha tambem estiver liberada", "Revisar ROAS minimo, horas protegidas e budget de risco.", settingsUpdated)
	} else {
		add("seller_settings", "Travas do seller", "warn", "Seller esta em modo "+operationalMode, "Mudar para Full-auto somente quando quiser liberar execucao automatica.", settingsUpdated)
	}

	var adsProfiles int
	var adsUpdated any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*), MAX(updated_at)
		FROM amazon_ads_profiles
		WHERE tenant_id = $1`, tenantID).Scan(&adsProfiles, &adsUpdated)
	if adsProfiles > 0 {
		add("ads_connection", "Amazon Ads conectado", "ok", strconv.Itoa(adsProfiles)+" profile(s) Amazon Ads cadastrados", "Manter tokens e profile atualizados.", adsUpdated)
	} else {
		add("ads_connection", "Amazon Ads conectado", "error", "Nenhum profile Amazon Ads cadastrado", "Conectar o seller ao Amazon Ads antes do piloto.", nil)
	}

	var bidRows, bidIDs int
	var bidUpdated any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE COALESCE(campaign_id,'') <> ''),
		       MAX(ingested_at)
		FROM marketcloud_bronze.bronze_swarm_current_bids`).Scan(&bidRows, &bidIDs, &bidUpdated)
	if bidRows > 0 && bidIDs == bidRows {
		add("campaign_inventory", "Inventario de campanhas", "ok", strconv.Itoa(bidRows)+" entidades com IDs sincronizados", "Manter o sync de estrutura em dia.", bidUpdated)
	} else if bidRows > 0 {
		add("campaign_inventory", "Inventario de campanhas", "warn", strconv.Itoa(bidIDs)+"/"+strconv.Itoa(bidRows)+" entidades com campaign_id", "Corrigir identidade das campanhas sem ID antes de vender escala.", bidUpdated)
	} else {
		add("campaign_inventory", "Inventario de campanhas", "error", "Sem snapshot de bids/campanhas", "Rodar a sincronizacao de Ads/SWARM.", nil)
	}

	var productCount, economicsReady int
	var productUpdated any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE economics_ready),
		       MAX(GREATEST(COALESCE(stock_updated_at, 'epoch'::timestamp), COALESCE(last_seen_date::timestamp, 'epoch'::timestamp)))
		FROM marketcloud_gold.full_control_product_candidates_v1
		WHERE tenant_id = $1`, tenantID).Scan(&productCount, &economicsReady, &productUpdated)
	if productCount > 0 && economicsReady > 0 {
		add("product_plane", "Produto com economia", "ok", strconv.Itoa(economicsReady)+"/"+strconv.Itoa(productCount)+" produtos com custo, preco e estoque", "Escolher um produto para o piloto Full Control.", productUpdated)
	} else if productCount > 0 {
		add("product_plane", "Produto com economia", "warn", strconv.Itoa(productCount)+" produtos encontrados, mas sem economia completa", "Popular custo, preco e estoque antes de liberar automacao.", productUpdated)
	} else {
		add("product_plane", "Produto com economia", "error", "Nenhum produto candidato encontrado", "Sincronizar campanhas/produtos e conferir ASIN anunciado.", nil)
	}

	var amsRows, amsTraffic, amsOrders int
	var amsUpdated any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE COALESCE(impressions,0) > 0 OR COALESCE(clicks,0) > 0 OR COALESCE(spend,0) > 0),
		       COUNT(*) FILTER (WHERE COALESCE(orders_7d,0) > 0 OR COALESCE(sales_7d,0) > 0),
		       MAX(updated_at)
		FROM marketcloud_bronze.bronze_ams_hourly`).Scan(&amsRows, &amsTraffic, &amsOrders, &amsUpdated)
	if amsTraffic > 0 && amsOrders > 0 {
		add("hourly_signal", "AMS hora a hora", "ok", strconv.Itoa(amsTraffic)+" linhas com trafego e "+strconv.Itoa(amsOrders)+" com conversao", "Monitorar atraso de conversao e qualidade do parser.", amsUpdated)
	} else if amsTraffic > 0 {
		add("hourly_signal", "AMS hora a hora", "warn", strconv.Itoa(amsTraffic)+" linhas com trafego, mas conversao ainda limitada", "Usar como sinal de clique/trafego e aguardar atribuicao de pedidos.", amsUpdated)
	} else if amsRows > 0 {
		add("hourly_signal", "AMS hora a hora", "warn", "AMS recebeu linhas, mas sem trafego positivo", "Validar parser, subscriptions e CloudWatch.", amsUpdated)
	} else {
		add("hourly_signal", "AMS hora a hora", "error", "Nenhuma linha AMS recebida", "Validar stream antes de vender autonomia hora a hora.", nil)
	}

	var lastModelStatus, lastModelKind string
	var modelUpdated any
	_ = h.db.QueryRow(ctx, `
		SELECT COALESCE(run_kind,''),
		       COALESCE(status,''),
		       finished_at
		FROM marketcloud_gold.ml_hourly_run_status
		ORDER BY finished_at DESC
		LIMIT 1`).Scan(&lastModelKind, &lastModelStatus, &modelUpdated)
	if lastModelStatus == "COMPLETED" {
		add("ml_loop", "ML horario", "ok", lastModelKind+" COMPLETED", "Acompanhar outcomes 1h/3h/24h para medir aprendizado.", modelUpdated)
	} else if lastModelStatus != "" {
		add("ml_loop", "ML horario", "warn", lastModelKind+" "+lastModelStatus, "Investigar status parcial antes de liberar Full Control amplo.", modelUpdated)
	} else {
		add("ml_loop", "ML horario", "error", "Nenhuma execucao ML encontrada", "Rodar o worker horario antes do piloto.", nil)
	}

	var fullAuto, canApply int
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*) FILTER (WHERE campaign_mode = 'full_auto'),
		       COUNT(*) FILTER (WHERE can_auto_apply)
		FROM marketcloud_gold.gold_campaign_automation_governance
		WHERE tenant_id = $1`, tenantID).Scan(&fullAuto, &canApply)
	if fullAuto > 0 && canApply > 0 {
		add("campaign_allowlist", "Allowlist de campanhas", "ok", strconv.Itoa(canApply)+"/"+strconv.Itoa(fullAuto)+" campanhas full-auto aptas", "Manter a liberacao por campanha explicita.", nil)
	} else if fullAuto > 0 {
		add("campaign_allowlist", "Allowlist de campanhas", "warn", strconv.Itoa(fullAuto)+" campanhas full-auto, mas nenhuma apta agora", "Verificar holdout, guardrails e governanca.", nil)
	} else {
		add("campaign_allowlist", "Allowlist de campanhas", "warn", "Nenhuma campanha liberada em full-auto", "Liberar somente campanhas escolhidas para piloto.", nil)
	}

	var pilots, activePilots, fullControlPilots, blockedPilots int
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE status = 'active'),
		       COUNT(*) FILTER (WHERE status = 'active' AND mode = 'full_control'),
		       COUNT(*) FILTER (WHERE status = 'active' AND mode = 'full_control' AND NOT can_control)
		FROM marketcloud_gold.full_control_effective_governance_v1
		WHERE tenant_id = $1`, tenantID).Scan(&pilots, &activePilots, &fullControlPilots, &blockedPilots)
	if fullControlPilots > 0 && blockedPilots == 0 {
		add("pilot_360", "Piloto Full Control", "ok", strconv.Itoa(fullControlPilots)+" piloto(s) Full Control ativo(s) e liberados", "Monitorar acoes, budget, estoque e outcomes diariamente.", nil)
	} else if activePilots > 0 {
		add("pilot_360", "Piloto Full Control", "warn", strconv.Itoa(activePilots)+" piloto(s) ativo(s), "+strconv.Itoa(blockedPilots)+" bloqueado(s)", "Resolver gate_reason dos pilotos antes de escalar.", nil)
	} else if pilots > 0 {
		add("pilot_360", "Piloto Full Control", "warn", strconv.Itoa(pilots)+" piloto(s) salvos, nenhum ativo", "Ativar monitoria ou Full Control para o caso de uso comercial.", nil)
	} else {
		add("pilot_360", "Piloto Full Control", "warn", "Nenhum piloto configurado", "Escolher produto, campanha, budget, stop-loss e modo do robo.", nil)
	}

	score := readinessScore(steps)
	status := "error"
	if score >= 85 {
		status = "ok"
	} else if score >= 60 {
		status = "warn"
	}
	headline := "Falta preparar a conta para operar como SaaS"
	if status == "ok" {
		headline = "Conta pronta para piloto comercial controlado"
	} else if status == "warn" {
		headline = "Conta quase pronta; existem pendencias antes de escalar"
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"tenant_id":              tenantID,
		"readiness_score":        score,
		"status":                 status,
		"headline":               headline,
		"steps":                  steps,
		"products_total":         productCount,
		"products_ready":         economicsReady,
		"full_auto_campaigns":    fullAuto,
		"auto_apply_ready":       canApply,
		"active_pilots":          activePilots,
		"full_control_pilots":    fullControlPilots,
		"blocked_full_control":   blockedPilots,
		"commercial_next_module": "Seller Onboarding + Product Control Plane",
	})
}

func readinessScore(steps []onboardingStep) int {
	if len(steps) == 0 {
		return 0
	}
	var points float64
	for _, item := range steps {
		switch item.Status {
		case "ok":
			points += 1
		case "warn":
			points += 0.5
		}
	}
	return int(math.Round(points / float64(len(steps)) * 100))
}
