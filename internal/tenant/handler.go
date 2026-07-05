package tenant

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/audit"
	"github.com/zanom/marketcloud/internal/auth"
	"github.com/zanom/marketcloud/internal/middleware"
)

type Handler struct {
	db    *pgxpool.Pool
	audit *audit.Logger
	jwtSecret string
}

func NewHandler(db *pgxpool.Pool, auditLogger *audit.Logger, jwtSecret string) *Handler {
	return &Handler{db: db, audit: auditLogger, jwtSecret: jwtSecret}
}

// POST /api/v1/tenants  (SUPER_ADMIN only — bootstraps new tenants)
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
		Slug string `json:"slug"`
		Plan string `json:"plan"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.Name == "" || req.Slug == "" {
		writeError(w, http.StatusBadRequest, "name and slug are required")
		return
	}
	plan := "STARTER"
	if req.Plan != "" {
		plan = req.Plan
	}

	var t Tenant
	err := h.db.QueryRow(r.Context(), `
		INSERT INTO tenants (name, slug, plan)
		VALUES ($1, $2, $3)
		RETURNING id, name, slug, status, plan, billing_status, created_at, updated_at
	`, req.Name, strings.ToLower(req.Slug), plan).Scan(
		&t.ID, &t.Name, &t.Slug, &t.Status, &t.Plan, &t.BillingStatus, &t.CreatedAt, &t.UpdatedAt,
	)
	if err != nil {
		if strings.Contains(err.Error(), "unique") {
			writeError(w, http.StatusConflict, "slug already taken")
			return
		}
		writeError(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.LogRequest(r.Context(), r, "TENANT_CREATED", "tenant", t.ID.String(), nil, t)
	writeJSON(w, http.StatusCreated, t)
}

// GET /api/v1/tenants/{id}
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	// Non-SUPER_ADMIN can only read their own tenant
	if claims.Role != "SUPER_ADMIN" && claims.TenantID.String() != id {
		writeError(w, http.StatusForbidden, "TENANT_ACCESS_DENIED")
		return
	}

	var t Tenant
	err := h.db.QueryRow(r.Context(), `
		SELECT id, name, slug, status, plan, billing_status, created_at, updated_at
		FROM tenants WHERE id = $1
	`, id).Scan(&t.ID, &t.Name, &t.Slug, &t.Status, &t.Plan, &t.BillingStatus, &t.CreatedAt, &t.UpdatedAt)
	if err != nil {
		writeError(w, http.StatusNotFound, "tenant_not_found")
		return
	}
	writeJSON(w, http.StatusOK, t)
}

// --- Auth endpoints ---

// POST /api/v1/auth/login
func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	var u User
	err := h.db.QueryRow(r.Context(), `
		SELECT id, tenant_id, email, password_hash, name, role, status
		FROM users WHERE email = $1 AND status = 'ACTIVE'
	`, strings.ToLower(req.Email)).Scan(
		&u.ID, &u.TenantID, &u.Email, &u.PasswordHash, &u.Name, &u.Role, &u.Status,
	)
	if err != nil || !auth.CheckPassword(u.PasswordHash, req.Password) {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	// Collect store IDs
	rows, _ := h.db.Query(r.Context(), `SELECT store_id FROM user_store_access WHERE user_id = $1`, u.ID)
	defer rows.Close()
	var storeIDs []string
	for rows.Next() {
		var sid uuid.UUID
		if rows.Scan(&sid) == nil {
			storeIDs = append(storeIDs, sid.String())
		}
	}

	pair, err := auth.IssueTokenPair(h.jwtSecret, u.TenantID, u.ID, u.Role, storeIDs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_issue_failed")
		return
	}

	// Persist refresh token hash
	hash, _ := auth.HashToken(pair.RefreshToken)
	h.db.Exec(r.Context(), `
		INSERT INTO refresh_tokens (user_id, tenant_id, token_hash, expires_at)
		VALUES ($1, $2, $3, $4)
	`, u.ID, u.TenantID, hash, time.Now().Add(7*24*time.Hour))

	h.db.Exec(r.Context(), `UPDATE users SET last_login_at = NOW() WHERE id = $1`, u.ID)
	h.audit.LogRequest(r.Context(), r, "USER_LOGIN", "user", u.ID.String(), nil, map[string]string{"email": u.Email})

	writeJSON(w, http.StatusOK, pair)
}

// POST /api/v1/auth/register  (creates first TENANT_ADMIN for a new tenant)
func (h *Handler) Register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TenantID string `json:"tenant_id"`
		Email    string `json:"email"`
		Password string `json:"password"`
		Name     string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.Email == "" || req.Password == "" || req.Name == "" || req.TenantID == "" {
		writeError(w, http.StatusBadRequest, "all fields required")
		return
	}

	tenantID, err := uuid.Parse(req.TenantID)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid tenant_id")
		return
	}

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "hash_failed")
		return
	}

	var u User
	err = h.db.QueryRow(r.Context(), `
		INSERT INTO users (tenant_id, email, password_hash, name, role)
		VALUES ($1, $2, $3, $4, 'TENANT_ADMIN')
		RETURNING id, tenant_id, email, name, role, status, created_at
	`, tenantID, strings.ToLower(req.Email), hash, req.Name).Scan(
		&u.ID, &u.TenantID, &u.Email, &u.Name, &u.Role, &u.Status, &u.CreatedAt,
	)
	if err != nil {
		if strings.Contains(err.Error(), "unique") {
			writeError(w, http.StatusConflict, "email already registered in this tenant")
			return
		}
		writeError(w, http.StatusInternalServerError, "register_failed")
		return
	}

	h.audit.LogRequest(r.Context(), r, "USER_REGISTERED", "user", u.ID.String(), nil, map[string]string{"email": u.Email, "role": u.Role})
	writeJSON(w, http.StatusCreated, u)
}

// POST /api/v1/auth/refresh
func (h *Handler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		writeError(w, http.StatusBadRequest, "refresh_token required")
		return
	}

	rows, _ := h.db.Query(r.Context(), `
		SELECT rt.id, rt.user_id, rt.tenant_id, rt.token_hash, rt.expires_at,
		       u.role, u.status
		FROM refresh_tokens rt
		JOIN users u ON u.id = rt.user_id
		WHERE rt.revoked = false AND rt.expires_at > NOW()
		ORDER BY rt.created_at DESC LIMIT 50
	`)
	defer rows.Close()

	type row struct {
		ID         uuid.UUID
		UserID     uuid.UUID
		TenantID   uuid.UUID
		TokenHash  string
		ExpiresAt  time.Time
		Role       string
		UserStatus string
	}

	for rows.Next() {
		var rt row
		if err := rows.Scan(&rt.ID, &rt.UserID, &rt.TenantID, &rt.TokenHash, &rt.ExpiresAt, &rt.Role, &rt.UserStatus); err != nil {
			continue
		}
		if !auth.CheckToken(rt.TokenHash, req.RefreshToken) {
			continue
		}
		if rt.UserStatus != "ACTIVE" {
			writeError(w, http.StatusUnauthorized, "user inactive")
			return
		}

		h.db.Exec(r.Context(), `UPDATE refresh_tokens SET revoked = true WHERE id = $1`, rt.ID)

		pair, err := auth.IssueTokenPair(h.jwtSecret, rt.TenantID, rt.UserID, rt.Role, nil)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "token_issue_failed")
			return
		}
		newHash, _ := auth.HashToken(pair.RefreshToken)
		h.db.Exec(r.Context(), `
			INSERT INTO refresh_tokens (user_id, tenant_id, token_hash, expires_at)
			VALUES ($1, $2, $3, $4)
		`, rt.UserID, rt.TenantID, newHash, time.Now().Add(7*24*time.Hour))

		writeJSON(w, http.StatusOK, pair)
		return
	}

	writeError(w, http.StatusUnauthorized, "invalid or expired refresh token")
}

// GET /api/v1/auth/me
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	uid := middleware.UserIDFromCtx(r.Context())
	var u User
	err := h.db.QueryRow(r.Context(), `
		SELECT id, tenant_id, email, name, role, status, last_login_at, created_at
		FROM users WHERE id = $1
	`, uid).Scan(&u.ID, &u.TenantID, &u.Email, &u.Name, &u.Role, &u.Status, &u.LastLoginAt, &u.CreatedAt)
	if err != nil {
		writeError(w, http.StatusNotFound, "user_not_found")
		return
	}
	writeJSON(w, http.StatusOK, u)
}

// --- helpers ---

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
