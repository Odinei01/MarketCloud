package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e007/{execution_id}
// Downloads E007 CSV from S3 and upserts into marketcloud_bronze.bronze_amc_placement_creative_daily.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E007: traffic-only (placement + creative + video). No conversion metrics — cross with E001/E002/E005 in Silver.
func (s *connectorServer) ingestE007(w http.ResponseWriter, r *http.Request) {
	executionID := chi.URLParam(r, "execution_id")

	var req struct {
		TenantID      string `json:"tenant_id"`
		AMCInstanceID string `json:"amc_instance_id"`
		AdsProfileID  string `json:"ads_profile_id"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	var s3Path string
	var workflowRunID *int64
	err := s.db.QueryRow(r.Context(), `
		SELECT COALESCE(result_object_path,''), NULL::BIGINT
		FROM query_runs
		WHERE external_query_execution_id = $1
	`, executionID).Scan(&s3Path, &workflowRunID)
	if err != nil || s3Path == "" {
		writeError(w, http.StatusNotFound, "RESULT_NOT_FOUND")
		return
	}

	resp, err := s.downloadS3CSV(r, s3Path)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer resp.Body.Close()

	csvReader := csv.NewReader(resp.Body)
	csvReader.LazyQuotes = true
	csvReader.TrimLeadingSpace = true
	// FieldsPerRecord = -1: aceita linha com contagem de campos diferente do
	// cabecalho em vez de abortar com "wrong number of fields". A Amazon manda
	// linhas assim quando um campo de texto tem virgula/quebra — antes elas
	// viravam ParseError e eram jogadas fora em silencio (skipped=1004 num lote,
	// achado da auditoria 16/07). col() ja e defensivo com indice fora do range.
	csvReader.FieldsPerRecord = -1

	headers, err := csvReader.Read()
	if err != nil {
		writeError(w, http.StatusBadGateway, "CSV_PARSE_ERROR: "+err.Error())
		return
	}
	colIdx := make(map[string]int, len(headers))
	for i, h := range headers {
		colIdx[strings.TrimSpace(h)] = i
	}

	col := func(row []string, name string) string {
		i, ok := colIdx[name]
		if !ok || i >= len(row) {
			return ""
		}
		return strings.TrimSpace(row[i])
	}

	inserted, skipped := 0, 0
	// motivos separados: dado faltando em silencio e o pior modo de falha.
	parseErrs, missingKeys, missingDate, upsertErrs := 0, 0, 0, 0

	for {
		row, err := csvReader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			if _, ok := err.(*csv.ParseError); ok {
				parseErrs++
				log.Printf("ingest e007: csv parse error (linha ignorada): %v", err)
				continue
			}
			log.Printf("ingest e007: csv read abortado (I/O), parando: %v", err)
			break
		}

		campaignID := col(row, "campaign_id")
		campaignName := col(row, "campaign_name")
		adProductType := col(row, "ad_product_type")

		if campaignID == "" || campaignName == "" || adProductType == "" {
			skipped++
			missingKeys++
			continue
		}

		rawDate := col(row, "data_date")
		if rawDate == "" {
			skipped++
			missingDate++
			continue
		}
		dataDate := rawDate
		if len(dataDate) > 10 {
			dataDate = dataDate[:10]
		}

		adGroupName := col(row, "ad_group_name")
		if adGroupName == "" {
			adGroupName = "NO_AD_GROUP"
		}
		targeting := col(row, "targeting")
		if targeting == "" {
			targeting = "NO_TARGETING"
		}
		matchType := col(row, "match_type")
		if matchType == "" {
			matchType = "NO_MATCH_TYPE"
		}
		placementType := col(row, "placement_type")
		if placementType == "" {
			placementType = "NO_PLACEMENT"
		}
		creative := col(row, "creative")
		if creative == "" {
			creative = "NO_CREATIVE"
		}
		creativeType := col(row, "creative_type")
		if creativeType == "" {
			creativeType = "NO_CREATIVE_TYPE"
		}
		creativeAsin := col(row, "creative_asin")
		if creativeAsin == "" {
			creativeAsin = "NO_CREATIVE_ASIN"
		}
		portfolioID := col(row, "portfolio_id")
		if portfolioID == "" {
			portfolioID = "NO_PORTFOLIO"
		}
		portfolioName := col(row, "portfolio_name")
		if portfolioName == "" {
			portfolioName = "NO_PORTFOLIO"
		}

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_placement_creative_daily (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				data_date, campaign_id, campaign_name, ad_product_type, ad_group_name,
				targeting, match_type, placement_type, creative, creative_type, creative_asin,
				currency_iso_code, portfolio_id, portfolio_name,
				activity_rows,
				impressions, clicks, spend,
				viewable_impressions, five_sec_views,
				video_first_quartile_views, video_midpoint_views,
				video_third_quartile_views, video_complete_views, video_unmutes,
				ctr, cpc, viewability_rate, video_completion_rate,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,$6,$7,$8,$9,
				$10,$11,$12,$13,$14,$15,
				$16,$17,$18,
				$19,
				$20,$21,$22,
				$23,$24,
				$25,$26,
				$27,$28,$29,
				$30,$31,$32,$33,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, data_date, campaign_id, ad_product_type, ad_group_name, targeting, match_type, placement_type, creative, creative_type, creative_asin)
			DO UPDATE SET
				campaign_name              = EXCLUDED.campaign_name,
				currency_iso_code          = EXCLUDED.currency_iso_code,
				portfolio_id               = EXCLUDED.portfolio_id,
				portfolio_name             = EXCLUDED.portfolio_name,
				activity_rows              = EXCLUDED.activity_rows,
				impressions                = EXCLUDED.impressions,
				clicks                     = EXCLUDED.clicks,
				spend                      = EXCLUDED.spend,
				viewable_impressions       = EXCLUDED.viewable_impressions,
				five_sec_views             = EXCLUDED.five_sec_views,
				video_first_quartile_views = EXCLUDED.video_first_quartile_views,
				video_midpoint_views       = EXCLUDED.video_midpoint_views,
				video_third_quartile_views = EXCLUDED.video_third_quartile_views,
				video_complete_views       = EXCLUDED.video_complete_views,
				video_unmutes              = EXCLUDED.video_unmutes,
				ctr                        = EXCLUDED.ctr,
				cpc                        = EXCLUDED.cpc,
				viewability_rate           = EXCLUDED.viewability_rate,
				video_completion_rate      = EXCLUDED.video_completion_rate,
				workflow_run_id            = EXCLUDED.workflow_run_id,
				loaded_at                  = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			dataDate, campaignID, campaignName, adProductType, adGroupName,
			targeting, matchType, placementType, creative, creativeType, creativeAsin,
			col(row, "currency_iso_code"), portfolioID, portfolioName,
			toInt64(col(row, "activity_rows")),
			toInt64(col(row, "impressions")), toInt64(col(row, "clicks")), toFloat(col(row, "spend")),
			toInt64(col(row, "viewable_impressions")), toInt64(col(row, "five_sec_views")),
			toInt64(col(row, "video_first_quartile_views")), toInt64(col(row, "video_midpoint_views")),
			toInt64(col(row, "video_third_quartile_views")), toInt64(col(row, "video_complete_views")),
			toInt64(col(row, "video_unmutes")),
			toFloat(col(row, "ctr")), toFloat(col(row, "cpc")),
			toFloat(col(row, "viewability_rate")), toFloat(col(row, "video_completion_rate")),
		)
		if err != nil {
			log.Printf("ingest e007: upsert error campaign=%s placement=%s date=%s: %v", campaignID, placementType, dataDate, err)
			skipped++
			upsertErrs++
			continue
		}
		inserted++
	}

	log.Printf("ingest e007: execution=%s inserted=%d skipped=%d (parse=%d chaves=%d data=%d upsert=%d)",
		executionID, inserted, skipped, parseErrs, missingKeys, missingDate, upsertErrs)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id":  executionID,
		"inserted":      inserted,
		"skipped":       skipped,
		"parse_errors":  parseErrs,
		"missing_keys":  missingKeys,
		"missing_date":  missingDate,
		"upsert_errors": upsertErrs,
		"status":        "OK",
	})
}
