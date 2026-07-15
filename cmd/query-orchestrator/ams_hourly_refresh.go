package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"
)

const amsHourlyRefreshMarker = "marketcloud-ams-hourly-refresh-d14-v1"

type amsHourlyRefreshConfig struct {
	Enabled        bool
	Interval       time.Duration
	RunImmediately bool
	LookbackDays   int
}

func loadAmsHourlyRefreshConfig() amsHourlyRefreshConfig {
	cfg := amsHourlyRefreshConfig{
		Enabled:        true,
		Interval:       time.Hour,
		RunImmediately: true,
		LookbackDays:   14,
	}
	if v := strings.TrimSpace(os.Getenv("AMS_HOURLY_REFRESH_ENABLED")); v != "" {
		cfg.Enabled = strings.EqualFold(v, "true") || v == "1" || strings.EqualFold(v, "yes")
	}
	if v := envInt("AMS_HOURLY_REFRESH_INTERVAL_MINUTES", 0); v > 0 {
		cfg.Interval = time.Duration(v) * time.Minute
	}
	if v := strings.TrimSpace(os.Getenv("AMS_HOURLY_REFRESH_RUN_IMMEDIATELY")); v != "" {
		cfg.RunImmediately = strings.EqualFold(v, "true") || v == "1" || strings.EqualFold(v, "yes")
	}
	if v := envInt("AMS_HOURLY_REFRESH_LOOKBACK_DAYS", 0); v > 0 {
		cfg.LookbackDays = v
	}
	return cfg
}

func (o *orchestrator) runAmsHourlyRefreshLoop(ctx context.Context) {
	cfg := loadAmsHourlyRefreshConfig()
	if !cfg.Enabled {
		log.Printf("[ams-hourly-refresh] disabled marker=%s", amsHourlyRefreshMarker)
		return
	}
	log.Printf("[ams-hourly-refresh] loop up interval=%s lookback_days=%d run_immediately=%t marker=%s", cfg.Interval, cfg.LookbackDays, cfg.RunImmediately, amsHourlyRefreshMarker)

	if cfg.RunImmediately {
		o.refreshAmsHourly(ctx, cfg.LookbackDays)
	}

	ticker := time.NewTicker(cfg.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.refreshAmsHourly(ctx, cfg.LookbackDays)
		}
	}
}

func (o *orchestrator) refreshAmsHourly(ctx context.Context, lookbackDays int) {
	refreshCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	var rowsUpserted int64
	var rowsUnresolved int64
	if err := o.db.QueryRow(refreshCtx, `
		WITH src AS (
			SELECT data_date, event_hour, campaign_name, impressions, clicks, spend, cpc, orders_7d, acos, roas, sales_7d
			FROM marketcloud_bronze.v_ams_hourly_resolved
			WHERE campaign_name IS NOT NULL
			  AND data_date >= CURRENT_DATE - ($1::int * INTERVAL '1 day')
		), upserted AS (
			INSERT INTO marketcloud_bronze.bronze_amazon_ads_hourly
				(data_date, event_hour, campaign_name, impressions, clicks, spend, cpc, orders_7d, acos, roas, sales_7d)
			SELECT data_date, event_hour, campaign_name, impressions, clicks, spend, cpc, orders_7d, acos, roas, sales_7d
			FROM src
			ON CONFLICT (data_date, event_hour, campaign_name) DO UPDATE SET
				-- tráfego: AMS acumula, mas NÃO pode degradar reporting/CSV completo.
				-- GREATEST mantém o maior (CSV completo > AMS parcial; e acompanha o
				-- AMS acumulando nas datas frescas sem CSV). Camada canônica §44.
				impressions = GREATEST(bronze_amazon_ads_hourly.impressions, EXCLUDED.impressions),
				clicks      = GREATEST(bronze_amazon_ads_hourly.clicks, EXCLUDED.clicks),
				spend       = GREATEST(bronze_amazon_ads_hourly.spend, EXCLUDED.spend),
				cpc         = CASE WHEN GREATEST(bronze_amazon_ads_hourly.clicks, EXCLUDED.clicks) > 0
				                   THEN ROUND(GREATEST(bronze_amazon_ads_hourly.spend, EXCLUDED.spend)
				                        / GREATEST(bronze_amazon_ads_hourly.clicks, EXCLUDED.clicks), 4)
				                   ELSE bronze_amazon_ads_hourly.cpc END,
				-- conversão: o AMS ainda vem 0 (delay de atribuição). NÃO sobrescrever
				-- conversão madura (CSV/reporting) com vazio — só atualiza quando o AMS
				-- realmente traz conversão. Camada canônica §44.
				orders_7d   = CASE WHEN COALESCE(EXCLUDED.orders_7d,0) > 0 OR COALESCE(EXCLUDED.sales_7d,0) > 0
				                   THEN EXCLUDED.orders_7d ELSE bronze_amazon_ads_hourly.orders_7d END,
				sales_7d    = CASE WHEN COALESCE(EXCLUDED.orders_7d,0) > 0 OR COALESCE(EXCLUDED.sales_7d,0) > 0
				                   THEN EXCLUDED.sales_7d ELSE bronze_amazon_ads_hourly.sales_7d END,
				roas        = CASE WHEN COALESCE(EXCLUDED.orders_7d,0) > 0 OR COALESCE(EXCLUDED.sales_7d,0) > 0
				                   THEN EXCLUDED.roas ELSE bronze_amazon_ads_hourly.roas END,
				acos        = CASE WHEN COALESCE(EXCLUDED.orders_7d,0) > 0 OR COALESCE(EXCLUDED.sales_7d,0) > 0
				                   THEN EXCLUDED.acos ELSE bronze_amazon_ads_hourly.acos END
			RETURNING 1
		), unresolved AS (
			SELECT COUNT(*) AS rows_unresolved
			FROM marketcloud_bronze.v_ams_hourly_resolved
			WHERE campaign_name IS NULL
			  AND data_date >= CURRENT_DATE - ($1::int * INTERVAL '1 day')
		)
		SELECT (SELECT COUNT(*) FROM upserted), (SELECT rows_unresolved FROM unresolved)
	`, lookbackDays).Scan(&rowsUpserted, &rowsUnresolved); err != nil {
		log.Printf("[ams-hourly-refresh] refresh failed: %v marker=%s", err, amsHourlyRefreshMarker)
		return
	}
	log.Printf("[ams-hourly-refresh] refresh complete lookback_days=%d rows_upserted=%d rows_unresolved=%d marker=%s", lookbackDays, rowsUpserted, rowsUnresolved, amsHourlyRefreshMarker)
}
