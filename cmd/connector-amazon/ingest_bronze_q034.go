package main

import (
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/q034/{execution_id} -> bronze_amc_campaign_overlap
//
// Canibalizacao entre campanhas: usuarios alcancados pelas DUAS. E a pergunta que so o
// AMC responde, porque o relatorio de Ads conta por campanha e nunca cruza pessoa.
func (s *connectorServer) ingestQ034(w http.ResponseWriter, r *http.Request) {
	cr, closeBody, ok := s.fetchQResultCSV(w, r)
	if !ok {
		return
	}
	defer closeBody()

	if _, err := s.db.Exec(r.Context(), `TRUNCATE marketcloud_bronze.bronze_amc_campaign_overlap`); err != nil {
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
			INSERT INTO marketcloud_bronze.bronze_amc_campaign_overlap
			(campaign_a, campaign_b, overlap_users, users_a, users_b,
			 overlap_rate_a, overlap_rate_b, spend_a, spend_b,
			 duplicated_spend_estimate, decision, updated_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW())`,
			row[0], row[1], num(row[2]), num(row[3]), num(row[4]),
			num(row[5]), num(row[6]), num(row[7]), num(row[8]),
			num(row[9]), row[10]); err != nil {
			log.Printf("ingestQ034 insert: %v", err)
			return
		}
		inserted++
	})

	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": chi.URLParam(r, "execution_id"),
		"inserted":     inserted,
	})
}
