package store

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/audit"
	"github.com/zanom/marketcloud/internal/middleware"
)

type Handler struct {
	db    *pgxpool.Pool
	audit *audit.Logger
}

func NewHandler(db *pgxpool.Pool, auditLogger *audit.Logger) *Handler {
	return &Handler{db: db, audit: auditLogger}
}

// POST /api/v1/stores
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())

	var req struct {
		OrganizationID string `json:"organization_id"`
		Name           string `json:"name"`
		BrandName      string `json:"brand_name"`
		Country        string `json:"country"`
		Currency       string `json:"default_currency"`
		Timezone       string `json:"timezone"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	country := "BR"
	if req.Country != "" {
		country = strings.ToUpper(req.Country)
	}
	currency := "BRL"
	if req.Currency != "" {
		currency = strings.ToUpper(req.Currency)
	}
	timezone := "America/Sao_Paulo"
	if req.Timezone != "" {
		timezone = req.Timezone
	}

	var orgID *uuid.UUID
	if req.OrganizationID != "" {
		id, err := uuid.Parse(req.OrganizationID)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid organization_id")
			return
		}
		orgID = &id
	}

	var s Store
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO stores (tenant_id, organization_id, name, brand_name, country, default_currency, timezone)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, tenant_id, organization_id, name, brand_name, country, default_currency, timezone, status, created_at, updated_at
	`, tenantID, orgID, req.Name, req.BrandName, country, currency, timezone).Scan(
		&s.ID, &s.TenantID, &s.OrganizationID, &s.Name, &s.BrandName,
		&s.Country, &s.Currency, &s.Timezone, &s.Status, &s.CreatedAt, &s.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "create_failed: "+err.Error())
		return
	}

	h.audit.LogRequest(r.Context(), r, "STORE_CREATED", "store", s.ID.String(), nil, s)
	writeJSON(w, http.StatusCreated, s)
}

// GET /api/v1/stores
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())

	rows, err := h.db.Query(r.Context(), `
		SELECT id, tenant_id, organization_id, name, brand_name, country, default_currency, timezone, status, created_at, updated_at
		FROM stores WHERE tenant_id = $1 AND status = 'ACTIVE'
		ORDER BY name ASC
	`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	stores := []Store{}
	for rows.Next() {
		var s Store
		if err := rows.Scan(&s.ID, &s.TenantID, &s.OrganizationID, &s.Name, &s.BrandName,
			&s.Country, &s.Currency, &s.Timezone, &s.Status, &s.CreatedAt, &s.UpdatedAt); err == nil {
			stores = append(stores, s)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": stores, "total": len(stores)})
}

// GET /api/v1/stores/{store_id}
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	storeID := chi.URLParam(r, "store_id")

	var s Store
	err := h.db.QueryRow(r.Context(), `
		SELECT id, tenant_id, organization_id, name, brand_name, country, default_currency, timezone, status, created_at, updated_at
		FROM stores WHERE id = $1 AND tenant_id = $2
	`, storeID, tenantID).Scan(
		&s.ID, &s.TenantID, &s.OrganizationID, &s.Name, &s.BrandName,
		&s.Country, &s.Currency, &s.Timezone, &s.Status, &s.CreatedAt, &s.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusNotFound, "STORE_ACCESS_DENIED")
		return
	}
	writeJSON(w, http.StatusOK, s)
}

// POST /api/v1/stores/{store_id}/amazon-profiles
func (h *Handler) RegisterAmazonProfile(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	storeID := chi.URLParam(r, "store_id")

	// Verify store belongs to tenant
	var exists bool
	h.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM stores WHERE id=$1 AND tenant_id=$2)`, storeID, tenantID).Scan(&exists)
	if !exists {
		writeError(w, http.StatusForbidden, "STORE_ACCESS_DENIED")
		return
	}

	var req struct {
		AmazonProfileID        string `json:"amazon_profile_id"`
		MarketplaceAccountID   string `json:"marketplace_account_id"`
		AccountType            string `json:"account_type"`
		CountryCode            string `json:"country_code"`
		CurrencyCode           string `json:"currency_code"`
		Timezone               string `json:"timezone"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AmazonProfileID == "" {
		writeError(w, http.StatusBadRequest, "amazon_profile_id required")
		return
	}

	accountType := "SELLER"
	if req.AccountType != "" {
		accountType = req.AccountType
	}
	country := "BR"
	if req.CountryCode != "" {
		country = req.CountryCode
	}
	currency := "BRL"
	if req.CurrencyCode != "" {
		currency = req.CurrencyCode
	}
	timezone := "America/Sao_Paulo"
	if req.Timezone != "" {
		timezone = req.Timezone
	}

	var p AmazonProfile
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO amazon_ads_profiles
			(tenant_id, store_id, marketplace_account_id, amazon_profile_id, account_type, country_code, currency_code, timezone)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (tenant_id, amazon_profile_id) DO UPDATE SET
			store_id = EXCLUDED.store_id, updated_at = NOW()
		RETURNING id, tenant_id, store_id, amazon_profile_id, account_type, country_code, currency_code, timezone, status, created_at, updated_at
	`, tenantID, storeID, nullIfEmpty(req.MarketplaceAccountID), req.AmazonProfileID, accountType, country, currency, timezone).Scan(
		&p.ID, &p.TenantID, &p.StoreID, &p.AmazonProfileID, &p.AccountType,
		&p.CountryCode, &p.CurrencyCode, &p.Timezone, &p.Status, &p.CreatedAt, &p.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "register_profile_failed: "+err.Error())
		return
	}

	h.audit.LogRequest(r.Context(), r, "AMAZON_PROFILE_REGISTERED", "amazon_ads_profile", p.ID.String(), nil, p)
	writeJSON(w, http.StatusCreated, p)
}

// GET /api/v1/stores/{store_id}/amazon-profiles
func (h *Handler) ListAmazonProfiles(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	storeID := chi.URLParam(r, "store_id")

	rows, err := h.db.Query(r.Context(), `
		SELECT id, tenant_id, store_id, amazon_profile_id, account_type, country_code, currency_code, timezone, status, last_synced_at, created_at, updated_at
		FROM amazon_ads_profiles WHERE tenant_id = $1 AND store_id = $2 AND status = 'ACTIVE'
		ORDER BY created_at DESC
	`, tenantID, storeID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	profiles := []AmazonProfile{}
	for rows.Next() {
		var p AmazonProfile
		if err := rows.Scan(&p.ID, &p.TenantID, &p.StoreID, &p.AmazonProfileID, &p.AccountType,
			&p.CountryCode, &p.CurrencyCode, &p.Timezone, &p.Status, &p.LastSyncedAt, &p.CreatedAt, &p.UpdatedAt); err == nil {
			profiles = append(profiles, p)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": profiles, "total": len(profiles)})
}

// POST /api/v1/stores/{store_id}/amc/instances
func (h *Handler) RegisterAMCInstance(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	storeID := chi.URLParam(r, "store_id")

	var exists bool
	h.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM stores WHERE id=$1 AND tenant_id=$2)`, storeID, tenantID).Scan(&exists)
	if !exists {
		writeError(w, http.StatusForbidden, "STORE_ACCESS_DENIED")
		return
	}

	var req struct {
		AmazonProfileID string `json:"amazon_profile_id"`
		AMCInstanceID   string `json:"amc_instance_id"`
		Name            string `json:"name"`
		Region          string `json:"region"`
		Country         string `json:"country"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AMCInstanceID == "" || req.Name == "" {
		writeError(w, http.StatusBadRequest, "amc_instance_id and name required")
		return
	}

	region := "NA"
	if req.Region != "" {
		region = req.Region
	}
	country := "BR"
	if req.Country != "" {
		country = req.Country
	}

	var inst AMCInstance
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO amc_instances (tenant_id, store_id, amazon_profile_id, amc_instance_id, name, region, country)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (tenant_id, amc_instance_id) DO UPDATE SET name = EXCLUDED.name, updated_at = NOW()
		RETURNING id, tenant_id, store_id, amc_instance_id, name, region, country, status, created_at, updated_at
	`, tenantID, storeID, nullIfEmpty(req.AmazonProfileID), req.AMCInstanceID, req.Name, region, country).Scan(
		&inst.ID, &inst.TenantID, &inst.StoreID, &inst.AMCInstanceID, &inst.Name,
		&inst.Region, &inst.Country, &inst.Status, &inst.CreatedAt, &inst.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "register_amc_failed: "+err.Error())
		return
	}

	h.audit.LogRequest(r.Context(), r, "AMC_INSTANCE_REGISTERED", "amc_instance", inst.ID.String(), nil, inst)
	writeJSON(w, http.StatusCreated, inst)
}

// GET /api/v1/stores/{store_id}/amc/instances
func (h *Handler) ListAMCInstances(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	storeID := chi.URLParam(r, "store_id")

	rows, err := h.db.Query(r.Context(), `
		SELECT id, tenant_id, store_id, amc_instance_id, name, region, country, status, created_at, updated_at
		FROM amc_instances WHERE tenant_id = $1 AND store_id = $2 AND status = 'ACTIVE'
		ORDER BY name ASC
	`, tenantID, storeID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	instances := []AMCInstance{}
	for rows.Next() {
		var inst AMCInstance
		if err := rows.Scan(&inst.ID, &inst.TenantID, &inst.StoreID, &inst.AMCInstanceID, &inst.Name,
			&inst.Region, &inst.Country, &inst.Status, &inst.CreatedAt, &inst.UpdatedAt); err == nil {
			instances = append(instances, inst)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": instances, "total": len(instances)})
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

type Store struct {
	ID             uuid.UUID  `json:"id"`
	TenantID       uuid.UUID  `json:"tenant_id"`
	OrganizationID *uuid.UUID `json:"organization_id,omitempty"`
	Name           string     `json:"name"`
	BrandName      string     `json:"brand_name,omitempty"`
	Country        string     `json:"country"`
	Currency       string     `json:"default_currency"`
	Timezone       string     `json:"timezone"`
	Status         string     `json:"status"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

type AmazonProfile struct {
	ID              uuid.UUID  `json:"id"`
	TenantID        uuid.UUID  `json:"tenant_id"`
	StoreID         uuid.UUID  `json:"store_id"`
	AmazonProfileID string     `json:"amazon_profile_id"`
	AccountType     string     `json:"account_type"`
	CountryCode     string     `json:"country_code"`
	CurrencyCode    string     `json:"currency_code"`
	Timezone        string     `json:"timezone"`
	Status          string     `json:"status"`
	LastSyncedAt    *time.Time `json:"last_synced_at,omitempty"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

type AMCInstance struct {
	ID            uuid.UUID `json:"id"`
	TenantID      uuid.UUID `json:"tenant_id"`
	StoreID       uuid.UUID `json:"store_id"`
	AMCInstanceID string    `json:"amc_instance_id"`
	Name          string    `json:"name"`
	Region        string    `json:"region"`
	Country       string    `json:"country"`
	Status        string    `json:"status"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}
