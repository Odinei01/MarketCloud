package main

import (
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/q037/{execution_id} -> bronze_amc_reach_saturation
//
// Saturacao de alcance por campanha. E a leitura que o relatorio de Ads nao da: ele
// conta impressao, mas nao sabe em quantas PESSOAS ela bateu. 5.000 impressoes em 5.000
// pessoas e 5.000 impressoes em 300 pessoas sao decisoes de verba opostas.
func (s *connectorServer) ingestQ037(w http.ResponseWriter, r *http.Request) {
	cr, closeBody, ok := s.fetchQResultCSV(w, r)
	if !ok {
		return
	}
	defer closeBody()

	if _, err := s.db.Exec(r.Context(), `TRUNCATE marketcloud_bronze.bronze_amc_reach_saturation`); err != nil {
		writeError(w, http.StatusInternalServerError, "TRUNCATE: "+err.Error())
		return
	}

	num := func(v string) float64 {
		f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if err != nil {
			return 0
		}
		return f
	}

	inserted := 0
	readCSVRows(cr, 11, func(row []string) {
		if _, err := s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_reach_saturation
			(campaign_id, campaign_name, users_reached, impressions, clicks, spend,
			 frequency_avg, fresh_reach_rate, saturation_rate, cost_per_user, decision, updated_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW())`,
			row[0], row[1], num(row[2]), num(row[3]), num(row[4]), num(row[5]),
			num(row[6]), num(row[7]), num(row[8]), num(row[9]), row[10]); err != nil {
			log.Printf("ingestQ037 insert: %v", err)
			return
		}
		inserted++
	})

	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": chi.URLParam(r, "execution_id"),
		"inserted":     inserted,
	})
}
