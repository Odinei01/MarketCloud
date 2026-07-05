package apiclient

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/auth"
	"github.com/zanom/marketcloud/internal/middleware"
)

type Handler struct{ db *pgxpool.Pool }

func NewHandler(db *pgxpool.Pool) *Handler { return &Handler{db: db} }

type APIClient struct {
	ID          uuid.UUID `json:"id"`
	TenantID    uuid.UUID `json:"tenant_id"`
	Name        string    `json:"name"`
	APIKey      string    `json:"api_key"`
	Scopes      []string  `json:"scopes"`
	StoreIDs    []string  `json:"store_ids"`
	Status      string    `json:"status"`
	LastUsedAt  *time.Time `json:"last_used_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

// POST /api/v1/api-clients
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	var req struct {
		Name     string   `json:"name"`
		Scopes   []string `json:"scopes"`
		StoreIDs []string `json:"store_ids"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Name == "" {
		writeError(w, 400, "name required")
		return
	}
	if len(req.Scopes) == 0 {
		req.Scopes = []string{"recommendations:read"}
	}

	apiKey := auth.GenerateAPIKey()
	secretHash, _ := auth.HashPassword(apiKey) // hash for storage; return raw key once

	var c APIClient
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO api_clients (tenant_id, name, api_key, api_secret_hash, scopes, store_ids)
		VALUES ($1,$2,$3,$4,$5,$6)
		RETURNING id, tenant_id, name, api_key, scopes, store_ids, status, created_at
	`, tid, req.Name, apiKey, secretHash, req.Scopes, req.StoreIDs).Scan(
		&c.ID, &c.TenantID, &c.Name, &c.APIKey, &c.Scopes, &c.StoreIDs, &c.Status, &c.CreatedAt,
	)
	if err != nil {
		writeError(w, 500, "create_failed: "+err.Error())
		return
	}
	writeJSON(w, 201, c) // api_key shown only at creation
}

// GET /api/v1/api-clients
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(), `
		SELECT id, tenant_id, name, api_key, scopes, store_ids, status, last_used_at, created_at
		FROM api_clients WHERE tenant_id=$1 AND status='ACTIVE' ORDER BY created_at DESC
	`, tid)
	if err != nil {
		writeError(w, 500, "list_failed")
		return
	}
	defer rows.Close()
	clients := []APIClient{}
	for rows.Next() {
		var c APIClient
		if rows.Scan(&c.ID, &c.TenantID, &c.Name, &c.APIKey, &c.Scopes, &c.StoreIDs, &c.Status, &c.LastUsedAt, &c.CreatedAt) == nil {
			// Mask key after creation
			if len(c.APIKey) > 8 {
				c.APIKey = c.APIKey[:7] + "••••••••"
			}
			clients = append(clients, c)
		}
	}
	writeJSON(w, 200, map[string]any{"items": clients, "total": len(clients)})
}

// DELETE /api/v1/api-clients/{id}
func (h *Handler) Revoke(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	h.db.Exec(r.Context(), `UPDATE api_clients SET status='REVOKED', updated_at=NOW() WHERE id=$1 AND tenant_id=$2`, id, tid)
	writeJSON(w, 200, map[string]string{"status": "revoked"})
}

// GET /api/v1/usage
func (h *Handler) Usage(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	month := r.URL.Query().Get("month")
	if month == "" {
		month = time.Now().Format("2006-01")
	}
	rows, err := h.db.Query(r.Context(), `
		SELECT metric, SUM(value) FROM usage_records
		WHERE tenant_id=$1 AND period_month=$2 GROUP BY metric ORDER BY metric
	`, tid, month)
	if err != nil {
		writeError(w, 500, "usage_failed")
		return
	}
	defer rows.Close()
	usage := map[string]float64{}
	for rows.Next() {
		var metric string
		var value float64
		if rows.Scan(&metric, &value) == nil {
			usage[metric] = value
		}
	}
	writeJSON(w, 200, map[string]any{"month": month, "usage": usage})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
