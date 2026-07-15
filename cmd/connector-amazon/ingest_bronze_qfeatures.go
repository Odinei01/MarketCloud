package main

import (
	"encoding/csv"
	"errors"
	"io"
	"log"
	"net/http"

	"github.com/go-chi/chi/v5"
)

// Baixa o CSV de um run AMC (por execution_id) e devolve o reader + resposta.
func (s *connectorServer) fetchQResultCSV(w http.ResponseWriter, r *http.Request) (*csv.Reader, func(), bool) {
	executionID := chi.URLParam(r, "execution_id")
	var s3Path string
	err := s.db.QueryRow(r.Context(), `
		SELECT COALESCE(result_object_path,'') FROM query_runs WHERE external_query_execution_id=$1
	`, executionID).Scan(&s3Path)
	if err != nil || s3Path == "" {
		writeError(w, http.StatusNotFound, "RESULT_NOT_FOUND")
		return nil, nil, false
	}
	resp, err := s.downloadS3CSV(r, s3Path)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return nil, nil, false
	}
	cr := csv.NewReader(resp.Body)
	cr.LazyQuotes = true
	cr.TrimLeadingSpace = true
	if _, err := cr.Read(); err != nil { // header
		resp.Body.Close()
		writeError(w, http.StatusBadGateway, "CSV_HEADER: "+err.Error())
		return nil, nil, false
	}
	return cr, func() { resp.Body.Close() }, true
}

func readCSVRows(cr *csv.Reader, minCols int, fn func([]string)) {
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
			break
		}
		if len(row) >= minCols {
			fn(row)
		}
	}
}

// POST /internal/amc/ingest/q019/{execution_id} -> bronze_amc_campaign_ntb (new-to-brand)
func (s *connectorServer) ingestQ019(w http.ResponseWriter, r *http.Request) {
	cr, done, ok := s.fetchQResultCSV(w, r)
	if !ok {
		return
	}
	defer done()
	if _, err := s.db.Exec(r.Context(), `TRUNCATE marketcloud_bronze.bronze_amc_campaign_ntb`); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	n := 0
	readCSVRows(cr, 9, func(row []string) {
		_, err := s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_campaign_ntb
			(campaign_id,campaign_name,product_group,new_to_brand_orders,returning_orders,
			 new_to_brand_sales,returning_sales,new_customer_rate,decision)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
			row[0], row[1], row[2], q005num(row[3]), q005num(row[4]),
			q005num(row[5]), q005num(row[6]), q005num(row[7]), row[8])
		if err == nil {
			n++
		}
	})
	log.Printf("ingest q019: inserted=%d", n)
	writeJSON(w, http.StatusOK, map[string]any{"inserted": n})
}

// POST /internal/amc/ingest/q041/{execution_id} -> bronze_amc_campaign_midfunnel (DPV/cart)
func (s *connectorServer) ingestQ041(w http.ResponseWriter, r *http.Request) {
	cr, done, ok := s.fetchQResultCSV(w, r)
	if !ok {
		return
	}
	defer done()
	if _, err := s.db.Exec(r.Context(), `TRUNCATE marketcloud_bronze.bronze_amc_campaign_midfunnel`); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	n := 0
	readCSVRows(cr, 4, func(row []string) {
		_, err := s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_campaign_midfunnel
			(campaign_id,campaign_name,detail_page_views,cart_adds)
			VALUES ($1,$2,$3,$4)`,
			row[0], row[1], q005num(row[2]), q005num(row[3]))
		if err == nil {
			n++
		}
	})
	// deriva product_key ("[SD] - Retargeting - X" -> X)
	_, _ = s.db.Exec(r.Context(), `
		UPDATE marketcloud_bronze.bronze_amc_campaign_midfunnel
		SET product_key = CASE WHEN campaign_name ILIKE '%Retargeting - %'
		                       THEN TRIM(SPLIT_PART(campaign_name,'Retargeting - ',2))
		                       ELSE campaign_name END`)
	log.Printf("ingest q041: inserted=%d", n)
	writeJSON(w, http.StatusOK, map[string]any{"inserted": n})
}

// POST /internal/amc/ingest/q042/{execution_id} -> bronze_amc_sd_retargeting_eval (alertas)
func (s *connectorServer) ingestQ042(w http.ResponseWriter, r *http.Request) {
	cr, done, ok := s.fetchQResultCSV(w, r)
	if !ok {
		return
	}
	defer done()
	if _, err := s.db.Exec(r.Context(), `TRUNCATE marketcloud_bronze.bronze_amc_sd_retargeting_eval`); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	n := 0
	readCSVRows(cr, 9, func(row []string) {
		_, err := s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_sd_retargeting_eval
			(sd_campaign,product_key,engaged_users,buyers,conversion_rate,base_cvr,lift_vs_baseline,product_orders,product_revenue)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
			row[0], row[1], q005num(row[2]), q005num(row[3]), q005num(row[4]),
			q005num(row[5]), q005num(row[6]), q005num(row[7]), q005num(row[8]))
		if err == nil {
			n++
		}
	})
	log.Printf("ingest q042: inserted=%d", n)
	writeJSON(w, http.StatusOK, map[string]any{"inserted": n})
}
