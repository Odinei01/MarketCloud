package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
)

type adsReprocessContext struct {
	RequestID   string
	RequestID64 int64
	TenantID    string
	StoreID     string
	ProfileID   string
	DataDate    time.Time
	WindowLabel string
	Metadata    map[string]any
	AccessToken string
}

type adsReportConfig struct {
	Key         string
	Grain       string
	NamePart    string
	ReportType  string
	GroupBy     []string
	Columns     []string
	Filters     []map[string]any
	ReportIDKey string
	RowsKey     string
}

func adsReprocessReportConfigs() []adsReportConfig {
	return []adsReportConfig{
		{
			Key:        "campaign",
			Grain:      "CAMPAIGN",
			NamePart:   "campaign",
			ReportType: "spCampaigns",
			GroupBy:    []string{"campaign"},
			Columns: []string{
				"date", "campaignId", "campaignName", "campaignStatus",
				"impressions", "clicks", "cost", "purchases7d", "sales7d", "unitsSoldClicks7d",
			},
			ReportIDKey: "sp_campaign_report_id",
			RowsKey:     "sp_campaign_rows_ingested",
		},
		{
			Key:        "adgroup",
			Grain:      "AD_GROUP",
			NamePart:   "adgroup",
			ReportType: "spCampaigns",
			GroupBy:    []string{"adGroup"},
			Columns: []string{
				"date", "adGroupId", "adGroupName",
				"impressions", "clicks", "cost", "purchases7d", "sales7d", "unitsSoldClicks7d",
			},
			ReportIDKey: "sp_adgroup_report_id",
			RowsKey:     "sp_adgroup_rows_ingested",
		},
		{
			Key:        "keyword",
			Grain:      "KEYWORD",
			NamePart:   "keyword",
			ReportType: "spTargeting",
			GroupBy:    []string{"targeting"},
			Columns: []string{
				"date", "campaignId", "campaignName", "adGroupId", "adGroupName",
				"keywordId", "keyword", "keywordType", "matchType",
				"impressions", "clicks", "cost", "purchases7d", "sales7d", "unitsSoldClicks7d",
			},
			Filters: []map[string]any{{
				"field":  "keywordType",
				"values": []string{"BROAD", "PHRASE", "EXACT"},
			}},
			ReportIDKey: "sp_keyword_report_id",
			RowsKey:     "sp_keyword_rows_ingested",
		},
		{
			Key:        "target",
			Grain:      "TARGET",
			NamePart:   "target",
			ReportType: "spTargeting",
			GroupBy:    []string{"targeting"},
			Columns: []string{
				"date", "campaignId", "campaignName", "adGroupId", "adGroupName",
				"targeting", "keywordType", "matchType",
				"impressions", "clicks", "cost", "purchases7d", "sales7d", "unitsSoldClicks7d",
			},
			Filters: []map[string]any{{
				"field":  "keywordType",
				"values": []string{"TARGETING_EXPRESSION", "TARGETING_EXPRESSION_PREDEFINED"},
			}},
			ReportIDKey: "sp_target_report_id",
			RowsKey:     "sp_target_rows_ingested",
		},
	}
}

// POST /internal/ads/reprocess/{request_id}/submit
func (s *connectorServer) submitAdsReprocessReport(w http.ResponseWriter, r *http.Request) {
	ctx, err := s.loadAdsReprocessContext(r.Context(), chi.URLParam(r, "request_id"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	results := map[string]any{}
	submittedAny := false
	for _, cfg := range adsReprocessReportConfigs() {
		if stringFromAny(ctx.Metadata[cfg.ReportIDKey]) != "" {
			results[cfg.Key] = map[string]any{"status": "ALREADY_SUBMITTED", "report_id": stringFromAny(ctx.Metadata[cfg.ReportIDKey])}
			continue
		}
		reportID, raw, recovered, err := s.submitOneAdsReport(r.Context(), ctx, cfg)
		if err != nil {
			s.updateAdsReprocessStatus(r.Context(), ctx.RequestID, "WAITING_REAL_ADS_REPORT_EXECUTOR", "submit_failed_"+cfg.Key, err.Error())
			writeError(w, http.StatusBadGateway, err.Error())
			return
		}
		if err := s.markAdsReportSubmitted(r.Context(), ctx, cfg, reportID, raw); err != nil {
			writeError(w, http.StatusInternalServerError, "ADS_REPORT_SUBMIT_DB_FAILED: "+err.Error())
			return
		}
		ctx.Metadata[cfg.ReportIDKey] = reportID
		results[cfg.Key] = map[string]any{"status": "SUBMITTED", "report_id": reportID, "duplicate_recovered": recovered}
		submittedAny = true
	}

	if err := s.markAdsReprocessReadyToPoll(r.Context(), ctx); err != nil {
		writeError(w, http.StatusInternalServerError, "ADS_REPORT_SUBMIT_STATUS_DB_FAILED: "+err.Error())
		return
	}
	status := "SUBMITTED"
	if !submittedAny {
		status = "ALREADY_SUBMITTED"
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status, "reports": results})
}

func (s *connectorServer) submitOneAdsReport(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig) (string, []byte, bool, error) {
	configuration := map[string]any{
		"adProduct":    "SPONSORED_PRODUCTS",
		"groupBy":      cfg.GroupBy,
		"reportTypeId": cfg.ReportType,
		"timeUnit":     "DAILY",
		"format":       "GZIP_JSON",
		"columns":      cfg.Columns,
	}
	if len(cfg.Filters) > 0 {
		configuration["filters"] = cfg.Filters
	}
	payload := map[string]any{
		"name":          fmt.Sprintf("marketcloud-sp-%s-%s-%s", cfg.NamePart, c.DataDate.Format("2006-01-02"), c.RequestID),
		"startDate":     c.DataDate.Format("2006-01-02"),
		"endDate":       c.DataDate.Format("2006-01-02"),
		"configuration": configuration,
	}
	body, _ := json.Marshal(payload)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(s.cfg.AmazonAdsAPIURL, "/")+"/reporting/reports", bytes.NewReader(body))
	s.setAdsHeaders(req, c)
	req.Header.Set("Content-Type", "application/vnd.createasyncreportrequest.v3+json")
	req.Header.Set("Accept", "application/vnd.createasyncreportresponse.v3+json")

	resp, err := (&http.Client{Timeout: 45 * time.Second}).Do(req)
	if err != nil {
		return "", nil, false, fmt.Errorf("ADS_REPORT_SUBMIT_HTTP %s: %w", cfg.Key, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusTooManyRequests {
		return "", raw, false, fmt.Errorf("ADS_REPORT_RATE_LIMITED %s: %s", cfg.Key, string(raw))
	}
	if duplicateReportID := duplicateAdsReportID(raw); duplicateReportID != "" {
		return duplicateReportID, raw, true, nil
	}
	if resp.StatusCode >= 400 {
		return "", raw, false, fmt.Errorf("ADS_REPORT_SUBMIT_FAILED %s http=%d body=%s", cfg.Key, resp.StatusCode, string(raw))
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", raw, false, fmt.Errorf("ADS_REPORT_SUBMIT_BAD_JSON %s: %w", cfg.Key, err)
	}
	reportID := firstString(out, "reportId", "report_id")
	if reportID == "" {
		return "", raw, false, fmt.Errorf("ADS_REPORT_SUBMIT_NO_REPORT_ID %s: %s", cfg.Key, string(raw))
	}
	return reportID, raw, false, nil
}

func (s *connectorServer) markAdsReportSubmitted(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig, reportID string, raw []byte) error {
	_, err := s.db.Exec(ctx, `
		UPDATE marketcloud_ops.ads_reporting_reprocess_requests
		SET updated_at=NOW(),
		    error_message=NULL,
		    metadata_json = metadata_json || jsonb_build_object(
		        $1::text, $2::text,
		        'profile_id', $3::text,
		        $4::text, NOW(),
		        $5::text, $6::jsonb
		    )
		WHERE id=$7
	`, cfg.ReportIDKey, reportID, c.ProfileID, cfg.Key+"_submitted_at", cfg.Key+"_submit_response", string(raw), c.RequestID64)
	return err
}

func (s *connectorServer) markAdsReprocessReadyToPoll(ctx context.Context, c *adsReprocessContext) error {
	_, err := s.db.Exec(ctx, `
		UPDATE marketcloud_ops.ads_reporting_reprocess_requests
		SET status='SUBMITTED',
		    updated_at=NOW(),
		    error_message=NULL
		WHERE id=$1
	`, c.RequestID64)
	return err
}

// POST /internal/ads/reprocess/{request_id}/poll
func (s *connectorServer) pollAdsReprocessReport(w http.ResponseWriter, r *http.Request) {
	ctx, err := s.loadAdsReprocessContext(r.Context(), chi.URLParam(r, "request_id"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	results := map[string]any{}
	pending := 0
	failed := 0
	for _, cfg := range adsReprocessReportConfigs() {
		reportID := stringFromAny(ctx.Metadata[cfg.ReportIDKey])
		if reportID == "" {
			pending++
			results[cfg.Key] = map[string]any{"status": "NOT_SUBMITTED"}
			continue
		}
		if stringFromAny(ctx.Metadata[cfg.RowsKey]) != "" {
			results[cfg.Key] = map[string]any{"status": "COMPLETED", "report_id": reportID, "rows_ingested": intFromAny(ctx.Metadata[cfg.RowsKey])}
			continue
		}
		// Report que a Amazon ja marcou como falho e TERMINAL — nao re-pollar
		// pra sempre (evita loop do orquestrador a cada 5min).
		if stringFromAny(ctx.Metadata[cfg.Key+"_last_poll_status"]) == "FAILED_PERMANENT" {
			failed++
			results[cfg.Key] = map[string]any{"status": "FAILED", "report_id": reportID}
			continue
		}
		status, rows, err := s.pollOneAdsReport(r.Context(), ctx, cfg, reportID)
		if err != nil {
			s.updateAdsReprocessStatus(r.Context(), ctx.RequestID, "RUNNING", "poll_failed_"+cfg.Key, err.Error())
			writeError(w, http.StatusBadGateway, err.Error())
			return
		}
		results[cfg.Key] = map[string]any{"status": status, "report_id": reportID, "rows_ingested": rows}
		switch status {
		case "COMPLETED":
			ctx.Metadata[cfg.RowsKey] = rows
		case "FAILED":
			failed++
		default:
			pending++
		}
	}

	// Terminal quando nao ha mais nada pendente: COMPLETED, ou
	// COMPLETED_WITH_FAILURES se algum report falhou de vez.
	status := "RUNNING"
	if pending == 0 {
		if failed > 0 {
			status = "COMPLETED_WITH_FAILURES"
		} else {
			status = "COMPLETED"
		}
	}
	if err := s.markAdsReprocessPollStatus(r.Context(), ctx, status, results); err != nil {
		writeError(w, http.StatusInternalServerError, "ADS_REPORT_POLL_STATUS_DB_FAILED: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status, "reports": results})
}

func (s *connectorServer) pollOneAdsReport(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig, reportID string) (string, int, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(s.cfg.AmazonAdsAPIURL, "/")+"/reporting/reports/"+reportID, nil)
	s.setAdsHeaders(req, c)
	req.Header.Set("Accept", "application/vnd.getasyncreportresponse.v3+json")
	resp, err := (&http.Client{Timeout: 45 * time.Second}).Do(req)
	if err != nil {
		return "", 0, fmt.Errorf("ADS_REPORT_POLL_HTTP %s: %w", cfg.Key, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return "", 0, fmt.Errorf("ADS_REPORT_POLL_FAILED %s http=%d body=%s", cfg.Key, resp.StatusCode, string(raw))
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", 0, fmt.Errorf("ADS_REPORT_POLL_BAD_JSON %s: %w", cfg.Key, err)
	}
	status := strings.ToUpper(firstString(out, "status", "processingStatus"))
	switch status {
	case "SUCCESS", "COMPLETED", "DONE":
		downloadURL := firstString(out, "url", "downloadLocation", "location")
		if downloadURL == "" {
			return "", 0, fmt.Errorf("ADS_REPORT_COMPLETED_WITHOUT_DOWNLOAD_URL %s: %s", cfg.Key, string(raw))
		}
		rows, err := s.downloadAndIngestSPReport(ctx, c, cfg, reportID, downloadURL)
		if err != nil {
			return "", rows, fmt.Errorf("ADS_REPORT_INGEST_FAILED %s: %w", cfg.Key, err)
		}
		if err := s.markAdsReportCompleted(ctx, c, cfg, rows, raw); err != nil {
			return "", rows, err
		}
		return "COMPLETED", rows, nil
	case "FAILURE", "FAILED", "CANCELLED":
		// TERMINAL: report que a Amazon marcou como falho nunca vai completar.
		// Antes isso retornava erro -> request ficava RUNNING -> orquestrador
		// re-pollava a cada 5min PARA SEMPRE (mesma classe do incidente de
		// loop sem backoff). Agora propaga "FAILED" e o handler encerra o request.
		if err := s.markAdsReportPending(ctx, c, cfg, "FAILED_PERMANENT", raw); err != nil {
			return "", 0, err
		}
		return "FAILED", 0, nil
	default:
		if status == "" {
			status = "RUNNING"
		}
		if err := s.markAdsReportPending(ctx, c, cfg, status, raw); err != nil {
			return "", 0, err
		}
		return status, 0, nil
	}
}

func (s *connectorServer) markAdsReportCompleted(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig, rows int, raw []byte) error {
	_, err := s.db.Exec(ctx, `
		UPDATE marketcloud_ops.ads_reporting_reprocess_requests
		SET updated_at=NOW(),
		    error_message=NULL,
		    metadata_json = metadata_json || jsonb_build_object(
		        $1::text, $2::int,
		        $3::text, 'COMPLETED',
		        $4::text, NOW(),
		        $5::text, $6::jsonb
		    )
		WHERE id=$7
	`, cfg.RowsKey, rows, cfg.Key+"_last_poll_status", cfg.Key+"_last_poll_at", cfg.Key+"_poll_response", string(raw), c.RequestID64)
	return err
}

func (s *connectorServer) markAdsReportPending(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig, status string, raw []byte) error {
	_, err := s.db.Exec(ctx, `
		UPDATE marketcloud_ops.ads_reporting_reprocess_requests
		SET status='RUNNING',
		    updated_at=NOW(),
		    metadata_json = metadata_json || jsonb_build_object(
		        $1::text, $2::text,
		        $3::text, NOW(),
		        $4::text, $5::jsonb
		    )
		WHERE id=$6
	`, cfg.Key+"_last_poll_status", status, cfg.Key+"_last_poll_at", cfg.Key+"_poll_response", string(raw), c.RequestID64)
	return err
}

func (s *connectorServer) markAdsReprocessPollStatus(ctx context.Context, c *adsReprocessContext, status string, results map[string]any) error {
	raw, _ := json.Marshal(results)
	completedAt := "NULL"
	if status == "COMPLETED" {
		completedAt = "NOW()"
	}
	_, err := s.db.Exec(ctx, fmt.Sprintf(`
		UPDATE marketcloud_ops.ads_reporting_reprocess_requests
		SET status=$1,
		    completed_at=%s,
		    updated_at=NOW(),
		    error_message=NULL,
		    metadata_json = metadata_json || jsonb_build_object(
		        'last_poll_status', $1::text,
		        'last_poll_at', NOW(),
		        'report_statuses', $2::jsonb
		    )
		WHERE id=$3
	`, completedAt), status, string(raw), c.RequestID64)
	return err
}

func (s *connectorServer) loadAdsReprocessContext(ctx context.Context, requestID string) (*adsReprocessContext, error) {
	var c adsReprocessContext
	var metadataBytes []byte
	err := s.db.QueryRow(ctx, `
		SELECT r.id::text, r.id, r.data_date, r.window_label, r.metadata_json,
		       p.tenant_id::text, p.store_id::text, p.amazon_profile_id
		FROM marketcloud_ops.ads_reporting_reprocess_requests r
		CROSS JOIN LATERAL (
		    SELECT tenant_id, store_id, amazon_profile_id
		    FROM amazon_ads_profiles
		    WHERE status='ACTIVE'
		    ORDER BY updated_at DESC
		    LIMIT 1
		) p
		WHERE r.id=$1
	`, requestID).Scan(&c.RequestID, &c.RequestID64, &c.DataDate, &c.WindowLabel, &metadataBytes, &c.TenantID, &c.StoreID, &c.ProfileID)
	if err != nil {
		return nil, fmt.Errorf("ADS_REPROCESS_REQUEST_NOT_FOUND: %w", err)
	}
	_ = json.Unmarshal(metadataBytes, &c.Metadata)
	if c.Metadata == nil {
		c.Metadata = map[string]any{}
	}
	token, err := s.getValidAccessToken(ctx, c.TenantID, c.StoreID)
	if err != nil {
		return nil, err
	}
	c.AccessToken = token
	return &c, nil
}

func (s *connectorServer) setAdsHeaders(req *http.Request, ctx *adsReprocessContext) {
	req.Header.Set("Authorization", "Bearer "+ctx.AccessToken)
	req.Header.Set("Amazon-Advertising-API-ClientId", s.cfg.AmazonLWAClientID)
	req.Header.Set("Amazon-Advertising-API-Scope", ctx.ProfileID)
}

func (s *connectorServer) downloadAndIngestSPReport(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig, reportID, downloadURL string) (int, error) {
	rows, err := downloadAdsJSONRows(ctx, downloadURL)
	if err != nil {
		return 0, err
	}
	switch cfg.Grain {
	case "CAMPAIGN":
		return s.ingestCampaignRows(ctx, c, reportID, rows)
	case "AD_GROUP":
		return s.ingestAdGroupRows(ctx, c, reportID, rows)
	case "KEYWORD", "TARGET":
		return s.ingestTargetingRows(ctx, c, cfg, reportID, rows)
	default:
		return 0, fmt.Errorf("unsupported grain %s", cfg.Grain)
	}
}

func downloadAdsJSONRows(ctx context.Context, downloadURL string) ([]map[string]any, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, downloadURL, nil)
	resp, err := (&http.Client{Timeout: 120 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("download http=%d body=%s", resp.StatusCode, string(raw))
	}
	rawPayload, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var reader io.Reader = bytes.NewReader(rawPayload)
	if strings.Contains(strings.ToLower(resp.Header.Get("Content-Encoding")), "gzip") ||
		strings.HasSuffix(strings.ToLower(downloadURL), ".gz") ||
		bytes.HasPrefix(rawPayload, []byte{0x1f, 0x8b}) {
		gz, err := gzip.NewReader(bytes.NewReader(rawPayload))
		if err != nil {
			return nil, err
		}
		defer gz.Close()
		reader = gz
	}
	dec := json.NewDecoder(reader)
	dec.UseNumber()
	var rows []map[string]any
	return rows, dec.Decode(&rows)
}

func (s *connectorServer) ingestCampaignRows(ctx context.Context, c *adsReprocessContext, reportID string, rows []map[string]any) (int, error) {
	inserted := 0
	for _, row := range rows {
		dataDate := firstString(row, "date")
		campaignID := firstString(row, "campaignId", "campaign_id")
		if dataDate == "" || campaignID == "" {
			continue
		}
		raw, _ := json.Marshal(row)
		_, err := s.db.Exec(ctx, `
			INSERT INTO marketcloud_ops.ads_reporting_sp_campaign_daily_v3 (
				profile_id, data_date, campaign_id, campaign_name, campaign_status,
				impressions, clicks, cost, attributed_sales, purchases, units_sold,
				currency, report_id, raw_json, synced_at
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14::jsonb,NOW())
			ON CONFLICT (profile_id, data_date, campaign_id) DO UPDATE SET
				campaign_name = EXCLUDED.campaign_name,
				campaign_status = EXCLUDED.campaign_status,
				impressions = EXCLUDED.impressions,
				clicks = EXCLUDED.clicks,
				cost = EXCLUDED.cost,
				attributed_sales = EXCLUDED.attributed_sales,
				purchases = EXCLUDED.purchases,
				units_sold = EXCLUDED.units_sold,
				currency = EXCLUDED.currency,
				report_id = EXCLUDED.report_id,
				raw_json = EXCLUDED.raw_json,
				synced_at = NOW()
		`, c.ProfileID, dataDate, campaignID,
			firstString(row, "campaignName", "campaign_name"),
			firstString(row, "campaignStatus", "campaign_status"),
			intFromAny(row["impressions"]),
			intFromAny(row["clicks"]),
			floatFromAny(row["cost"]),
			firstNumber(row, "sales7d", "sales14d", "attributedSales7d", "attributedSales14d"),
			firstInt(row, "purchases7d", "purchases14d", "attributedConversions7d", "attributedConversions14d"),
			firstInt(row, "unitsSoldClicks7d", "unitsSoldSameSku7d", "unitsSold14d"),
			firstString(row, "currency", "campaignBudgetCurrencyCode"),
			reportID,
			string(raw),
		)
		if err != nil {
			return inserted, err
		}
		inserted++
	}
	log.Printf("ads reporting v3 ingest request=%s grain=campaign report=%s rows=%d", c.RequestID, reportID, inserted)
	return inserted, nil
}

func (s *connectorServer) ingestAdGroupRows(ctx context.Context, c *adsReprocessContext, reportID string, rows []map[string]any) (int, error) {
	inserted := 0
	for _, row := range rows {
		dataDate := firstString(row, "date")
		campaignID := firstString(row, "campaignId", "campaign_id")
		adGroupID := firstString(row, "adGroupId", "ad_group_id")
		if dataDate == "" || campaignID == "" || adGroupID == "" {
			if dataDate == "" || adGroupID == "" {
				continue
			}
			campaignID, _ = s.resolveCampaignForAdGroup(ctx, c.ProfileID, adGroupID)
			if campaignID == "" {
				campaignID = "UNKNOWN"
			}
		}
		campaignName := firstString(row, "campaignName", "campaign_name")
		if campaignName == "" {
			_, campaignName = s.resolveCampaignForAdGroup(ctx, c.ProfileID, adGroupID)
		}
		raw, _ := json.Marshal(row)
		_, err := s.db.Exec(ctx, `
			INSERT INTO marketcloud_ops.ads_reporting_sp_adgroup_daily_v3 (
				profile_id, data_date, campaign_id, campaign_name, ad_group_id, ad_group_name,
				impressions, clicks, cost, attributed_sales, purchases, units_sold,
				currency, report_id, raw_json, synced_at
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15::jsonb,NOW())
			ON CONFLICT (profile_id, data_date, campaign_id, ad_group_id) DO UPDATE SET
				campaign_name = EXCLUDED.campaign_name,
				ad_group_name = EXCLUDED.ad_group_name,
				impressions = EXCLUDED.impressions,
				clicks = EXCLUDED.clicks,
				cost = EXCLUDED.cost,
				attributed_sales = EXCLUDED.attributed_sales,
				purchases = EXCLUDED.purchases,
				units_sold = EXCLUDED.units_sold,
				currency = EXCLUDED.currency,
				report_id = EXCLUDED.report_id,
				raw_json = EXCLUDED.raw_json,
				synced_at = NOW()
		`, c.ProfileID, dataDate, campaignID,
			campaignName,
			adGroupID,
			firstString(row, "adGroupName", "ad_group_name"),
			intFromAny(row["impressions"]),
			intFromAny(row["clicks"]),
			floatFromAny(row["cost"]),
			firstNumber(row, "sales7d", "sales14d", "attributedSales7d", "attributedSales14d"),
			firstInt(row, "purchases7d", "purchases14d", "attributedConversions7d", "attributedConversions14d"),
			firstInt(row, "unitsSoldClicks7d", "unitsSoldSameSku7d", "unitsSold14d"),
			firstString(row, "currency", "campaignBudgetCurrencyCode"),
			reportID,
			string(raw),
		)
		if err != nil {
			return inserted, err
		}
		inserted++
	}
	log.Printf("ads reporting v3 ingest request=%s grain=adgroup report=%s rows=%d", c.RequestID, reportID, inserted)
	return inserted, nil
}

func (s *connectorServer) resolveCampaignForAdGroup(ctx context.Context, profileID, adGroupID string) (string, string) {
	var campaignID, campaignName string
	_ = s.db.QueryRow(ctx, `
		SELECT campaign_id, campaign_name
		FROM swarm_src.amazon_ads_targeting_inventory
		WHERE profile_id=$1 AND ad_group_id=$2 AND campaign_id IS NOT NULL
		ORDER BY updated_at DESC NULLS LAST
		LIMIT 1
	`, profileID, adGroupID).Scan(&campaignID, &campaignName)
	return campaignID, campaignName
}

func (s *connectorServer) ingestTargetingRows(ctx context.Context, c *adsReprocessContext, cfg adsReportConfig, reportID string, rows []map[string]any) (int, error) {
	inserted := 0
	for _, row := range rows {
		dataDate := firstString(row, "date")
		campaignID := firstString(row, "campaignId", "campaign_id")
		adGroupID := firstString(row, "adGroupId", "ad_group_id")
		keywordID := firstString(row, "keywordId", "keyword_id")
		targetID := firstString(row, "targetId", "target_id")
		targetText := firstString(row, "keyword", "keywordText", "targeting", "targetingText", "targetingExpression")
		targetKey := firstNonEmpty(keywordID, targetID, lowerStable(targetText))
		if dataDate == "" || campaignID == "" || targetKey == "" {
			continue
		}
		raw, _ := json.Marshal(row)
		_, err := s.db.Exec(ctx, `
			INSERT INTO marketcloud_ops.ads_reporting_sp_targeting_daily_v3 (
				profile_id, data_date, report_grain, campaign_id, campaign_name,
				ad_group_id, ad_group_name, keyword_id, target_id, target_entity_key,
				target_text, match_type, impressions, clicks, cost, attributed_sales,
				purchases, units_sold, currency, report_id, raw_json, synced_at
			) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21::jsonb,NOW())
			ON CONFLICT (profile_id, data_date, report_grain, campaign_id, ad_group_id, target_entity_key) DO UPDATE SET
				campaign_name = EXCLUDED.campaign_name,
				ad_group_name = EXCLUDED.ad_group_name,
				keyword_id = EXCLUDED.keyword_id,
				target_id = EXCLUDED.target_id,
				target_text = EXCLUDED.target_text,
				match_type = EXCLUDED.match_type,
				impressions = EXCLUDED.impressions,
				clicks = EXCLUDED.clicks,
				cost = EXCLUDED.cost,
				attributed_sales = EXCLUDED.attributed_sales,
				purchases = EXCLUDED.purchases,
				units_sold = EXCLUDED.units_sold,
				currency = EXCLUDED.currency,
				report_id = EXCLUDED.report_id,
				raw_json = EXCLUDED.raw_json,
				synced_at = NOW()
		`, c.ProfileID, dataDate, cfg.Grain, campaignID,
			firstString(row, "campaignName", "campaign_name"),
			adGroupID,
			firstString(row, "adGroupName", "ad_group_name"),
			keywordID,
			targetID,
			targetKey,
			targetText,
			firstString(row, "matchType", "match_type", "keywordType"),
			intFromAny(row["impressions"]),
			intFromAny(row["clicks"]),
			floatFromAny(row["cost"]),
			firstNumber(row, "sales7d", "sales14d", "attributedSales7d", "attributedSales14d"),
			firstInt(row, "purchases7d", "purchases14d", "attributedConversions7d", "attributedConversions14d"),
			firstInt(row, "unitsSoldClicks7d", "unitsSoldSameSku7d", "unitsSold14d"),
			firstString(row, "currency", "campaignBudgetCurrencyCode"),
			reportID,
			string(raw),
		)
		if err != nil {
			return inserted, err
		}
		inserted++
	}
	log.Printf("ads reporting v3 ingest request=%s grain=%s report=%s rows=%d", c.RequestID, strings.ToLower(cfg.Grain), reportID, inserted)
	return inserted, nil
}

func (s *connectorServer) updateAdsReprocessStatus(ctx context.Context, requestID, status, code, msg string) {
	_, _ = s.db.Exec(ctx, `
		UPDATE marketcloud_ops.ads_reporting_reprocess_requests
		SET status=$1,
		    updated_at=NOW(),
		    error_message=NULLIF($3,''),
		    metadata_json = metadata_json || jsonb_build_object('last_status_code', $2::text, 'last_status_at', NOW())
		WHERE id=$4
	`, status, code, msg, requestID)
}

func failStatusFromReports(results map[string]any) string {
	for _, v := range results {
		m, ok := v.(map[string]any)
		if !ok {
			continue
		}
		st, _ := m["status"].(string)
		if st != "COMPLETED" {
			return "RUNNING"
		}
	}
	return "COMPLETED"
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v := stringFromAny(m[k]); v != "" {
			return v
		}
	}
	return ""
}

func firstNumber(m map[string]any, keys ...string) float64 {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			return floatFromAny(v)
		}
	}
	return 0
}

func firstInt(m map[string]any, keys ...string) int64 {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			return intFromAny(v)
		}
	}
	return 0
}

func stringFromAny(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case json.Number:
		return x.String()
	case float64:
		return strconv.FormatInt(int64(x), 10)
	case int64:
		return strconv.FormatInt(x, 10)
	case int:
		return strconv.Itoa(x)
	default:
		return ""
	}
}

func floatFromAny(v any) float64 {
	switch x := v.(type) {
	case json.Number:
		f, _ := x.Float64()
		return f
	case float64:
		return x
	case int64:
		return float64(x)
	case int:
		return float64(x)
	case string:
		f, _ := strconv.ParseFloat(strings.ReplaceAll(x, ",", ""), 64)
		return f
	default:
		return 0
	}
}

func intFromAny(v any) int64 {
	switch x := v.(type) {
	case json.Number:
		i, _ := x.Int64()
		return i
	case float64:
		return int64(x)
	case int64:
		return x
	case int:
		return int64(x)
	case string:
		i, _ := strconv.ParseInt(strings.ReplaceAll(x, ",", ""), 10, 64)
		return i
	default:
		return 0
	}
}

func duplicateAdsReportID(raw []byte) string {
	var body struct {
		Code   string `json:"code"`
		Detail string `json:"detail"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return ""
	}
	if body.Code != "425" || !strings.Contains(strings.ToLower(body.Detail), "duplicate of") {
		return ""
	}
	parts := strings.Split(body.Detail, ":")
	if len(parts) == 0 {
		return ""
	}
	return strings.TrimSpace(parts[len(parts)-1])
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func lowerStable(v string) string {
	return strings.ToLower(strings.TrimSpace(v))
}
