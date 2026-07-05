package organization

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/middleware"
)

type Handler struct{ db *pgxpool.Pool }

func NewHandler(db *pgxpool.Pool) *Handler { return &Handler{db: db} }

type Org struct {
	ID        uuid.UUID `json:"id"`
	TenantID  uuid.UUID `json:"tenant_id"`
	Name      string    `json:"name"`
	Document  string    `json:"document,omitempty"`
	Country   string    `json:"country"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	var req struct {
		Name     string `json:"name"`
		Document string `json:"document"`
		Country  string `json:"country"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Name == "" {
		writeError(w, 400, "name required")
		return
	}
	country := "BR"
	if req.Country != "" {
		country = req.Country
	}
	var o Org
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO organizations (tenant_id, name, document, country) VALUES ($1,$2,$3,$4)
		RETURNING id, tenant_id, name, COALESCE(document,''), country, status, created_at, updated_at
	`, tid, req.Name, req.Document, country).Scan(&o.ID, &o.TenantID, &o.Name, &o.Document, &o.Country, &o.Status, &o.CreatedAt, &o.UpdatedAt)
	if err != nil {
		writeError(w, 500, "create_failed: "+err.Error())
		return
	}
	writeJSON(w, 201, o)
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(), `
		SELECT id, tenant_id, name, COALESCE(document,''), country, status, created_at, updated_at
		FROM organizations WHERE tenant_id=$1 AND status='ACTIVE' ORDER BY name
	`, tid)
	if err != nil {
		writeError(w, 500, "list_failed")
		return
	}
	defer rows.Close()
	orgs := []Org{}
	for rows.Next() {
		var o Org
		if rows.Scan(&o.ID, &o.TenantID, &o.Name, &o.Document, &o.Country, &o.Status, &o.CreatedAt, &o.UpdatedAt) == nil {
			orgs = append(orgs, o)
		}
	}
	writeJSON(w, 200, map[string]any{"items": orgs, "total": len(orgs)})
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	tid := middleware.TenantIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	var o Org
	err := h.db.QueryRow(r.Context(), `
		SELECT id, tenant_id, name, COALESCE(document,''), country, status, created_at, updated_at
		FROM organizations WHERE id=$1 AND tenant_id=$2
	`, id, tid).Scan(&o.ID, &o.TenantID, &o.Name, &o.Document, &o.Country, &o.Status, &o.CreatedAt, &o.UpdatedAt)
	if err != nil {
		writeError(w, 404, "not_found")
		return
	}
	writeJSON(w, 200, o)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
