package main

import (
	"encoding/csv"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/q005/{execution_id}
// Carrega o resultado da Q005 (assist por campanha, AMC) em
// marketcloud_bronze.bronze_amc_campaign_assist — feature de contexto do ML.
func (s *connectorServer) ingestQ005(w http.ResponseWriter, r *http.Request) {
	executionID := chi.URLParam(r, "execution_id")

	var s3Path string
	err := s.db.QueryRow(r.Context(), `
		SELECT COALESCE(result_object_path,'')
		FROM query_runs WHERE external_query_execution_id = $1
	`, executionID).Scan(&s3Path)
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

	cr := csv.NewReader(resp.Body)
	cr.LazyQuotes = true
	cr.TrimLeadingSpace = true
	if _, err := cr.Read(); err != nil { // pula header
		writeError(w, http.StatusBadGateway, "CSV_HEADER: "+err.Error())
		return
	}

	// snapshot: substitui o conteudo (feature = estado atual, janela movel)
	if _, err := s.db.Exec(r.Context(), `TRUNCATE marketcloud_bronze.bronze_amc_campaign_assist`); err != nil {
		writeError(w, http.StatusInternalServerError, "TRUNCATE: "+err.Error())
		return
	}

	inserted := 0
	for {
		row, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			var pe *csv.ParseError
			if errors.As(err, &pe) {
				continue
			}
			log.Printf("ingest q005: csv read abortado (I/O): %v", err)
			break
		}
		if len(row) < 15 {
			continue
		}
		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_campaign_assist
			(campaign_id,campaign_name,product_group,spend,direct_orders,direct_sales,direct_roas,
			 assisted_orders,assisted_sales,assisted_roas,assist_rate,first_touch_rate,middle_touch_rate,last_touch_rate,decision)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,
			row[0], row[1], row[2], q005num(row[3]), q005num(row[4]), q005num(row[5]), q005num(row[6]),
			q005num(row[7]), q005num(row[8]), q005num(row[9]), q005num(row[10]), q005num(row[11]),
			q005num(row[12]), q005num(row[13]), row[14])
		if err == nil {
			inserted++
		}
	}
	log.Printf("ingest q005: execution=%s inserted=%d", executionID, inserted)
	writeJSON(w, http.StatusOK, map[string]any{"execution_id": executionID, "inserted": inserted})
}

func q005num(s string) interface{} {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return f
	}
	return nil
}
