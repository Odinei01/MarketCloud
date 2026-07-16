package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"
)

const swarmSyncMarker = "marketcloud-swarm-account-state-sync-v1"

type swarmSyncConfig struct {
	Enabled        bool
	Interval       time.Duration
	RunImmediately bool
}

func loadSwarmSyncConfig() swarmSyncConfig {
	cfg := swarmSyncConfig{
		Enabled:        true,
		Interval:       time.Hour,
		RunImmediately: true,
	}
	if v := strings.TrimSpace(os.Getenv("SWARM_SYNC_ENABLED")); v != "" {
		cfg.Enabled = strings.EqualFold(v, "true") || v == "1" || strings.EqualFold(v, "yes")
	}
	if v := envInt("SWARM_SYNC_INTERVAL_MINUTES", 0); v > 0 {
		cfg.Interval = time.Duration(v) * time.Minute
	}
	if v := strings.TrimSpace(os.Getenv("SWARM_SYNC_RUN_IMMEDIATELY")); v != "" {
		cfg.RunImmediately = strings.EqualFold(v, "true") || v == "1" || strings.EqualFold(v, "yes")
	}
	return cfg
}

func (o *orchestrator) runSwarmSyncLoop(ctx context.Context) {
	cfg := loadSwarmSyncConfig()
	if !cfg.Enabled {
		log.Printf("[swarm-sync] disabled marker=%s", swarmSyncMarker)
		return
	}
	log.Printf("[swarm-sync] loop up interval=%s run_immediately=%t marker=%s",
		cfg.Interval, cfg.RunImmediately, swarmSyncMarker)

	if cfg.RunImmediately {
		o.refreshSwarmAccountState(ctx)
	}

	ticker := time.NewTicker(cfg.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.refreshSwarmAccountState(ctx)
		}
	}
}

func (o *orchestrator) refreshSwarmAccountState(ctx context.Context) {
	refreshCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	// ..._and_target: sync + refresh do alvo do ML materializado, juntos. Separar
	// os dois deixaria a tela com agenda nova e alvo velho.
	rows, err := o.db.Query(refreshCtx, `SELECT source_table, rows_inserted FROM marketcloud_bronze.refresh_swarm_state_and_target()`)
	if err != nil {
		log.Printf("[swarm-sync] refresh failed: %v marker=%s", err, swarmSyncMarker)
		return
	}
	defer rows.Close()

	total := int64(0)
	for rows.Next() {
		var source string
		var inserted int64
		if err := rows.Scan(&source, &inserted); err != nil {
			log.Printf("[swarm-sync] scan failed: %v marker=%s", err, swarmSyncMarker)
			return
		}
		total += inserted
		log.Printf("[swarm-sync] refreshed %s rows=%d marker=%s", source, inserted, swarmSyncMarker)
	}
	if err := rows.Err(); err != nil {
		log.Printf("[swarm-sync] rows failed: %v marker=%s", err, swarmSyncMarker)
		return
	}
	log.Printf("[swarm-sync] refresh complete total_rows=%d marker=%s", total, swarmSyncMarker)
}
