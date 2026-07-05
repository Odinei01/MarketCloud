package amazon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/audit"
	"github.com/zanom/marketcloud/internal/config"
	"github.com/zanom/marketcloud/internal/middleware"
)

type OAuthHandler struct {
	db     *pgxpool.Pool
	cfg    config.Config
	audit  *audit.Logger
	states map[string]oauthState // in-memory for MVP; use Redis in production
}

type oauthState struct {
	TenantID  uuid.UUID
	StoreID   uuid.UUID
	UserID    uuid.UUID
	ExpiresAt time.Time
}

func NewOAuthHandler(db *pgxpool.Pool, cfg config.Config, auditLogger *audit.Logger) *OAuthHandler {
	return &OAuthHandler{
		db:     db,
		cfg:    cfg,
		audit:  auditLogger,
		states: make(map[string]oauthState),
	}
}

// POST /api/v1/connections/amazon/oauth/start
func (h *OAuthHandler) Start(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		StoreID string `json:"store_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.StoreID == "" {
		writeError(w, http.StatusBadRequest, "store_id required")
		return
	}

	storeID, err := uuid.Parse(req.StoreID)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid store_id")
		return
	}

	// Verify store ownership
	var exists bool
	h.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM stores WHERE id=$1 AND tenant_id=$2)`, storeID, claims.TenantID).Scan(&exists)
	if !exists {
		writeError(w, http.StatusForbidden, "STORE_ACCESS_DENIED")
		return
	}

	state := fmt.Sprintf("%s_%s", claims.TenantID, storeID)
	h.states[state] = oauthState{
		TenantID:  claims.TenantID,
		StoreID:   storeID,
		UserID:    claims.UserID,
		ExpiresAt: time.Now().Add(10 * time.Minute),
	}

	params := url.Values{
		"client_id":     {h.cfg.AmazonLWAClientID},
		"scope":         {"advertising::campaign_management"},
		"response_type": {"code"},
		"redirect_uri":  {h.cfg.AmazonAdsRedirectURI},
		"state":         {state},
	}

	authURL := h.cfg.AmazonAdsAuthURL + "?" + params.Encode()
	writeJSON(w, http.StatusOK, map[string]string{"auth_url": authURL, "state": state})
}

// GET /api/v1/connections/amazon/oauth/callback
func (h *OAuthHandler) Callback(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	state := r.URL.Query().Get("state")
	errParam := r.URL.Query().Get("error")

	if errParam != "" {
		writeError(w, http.StatusBadRequest, "amazon_oauth_denied: "+errParam)
		return
	}

	ostate, ok := h.states[state]
	if !ok || time.Now().After(ostate.ExpiresAt) {
		writeError(w, http.StatusBadRequest, "invalid or expired oauth state")
		return
	}
	delete(h.states, state)

	tokens, err := h.exchangeCode(r.Context(), code)
	if err != nil {
		writeError(w, http.StatusBadGateway, "AMAZON_AUTH_EXPIRED: "+err.Error())
		return
	}

	_, err = h.db.Exec(r.Context(), `
		INSERT INTO amazon_oauth_connections
			(tenant_id, store_id, access_token, refresh_token, token_expires_at, scopes, status)
		VALUES ($1, $2, $3, $4, $5, $6, 'ACTIVE')
		ON CONFLICT (tenant_id, store_id) DO UPDATE SET
			access_token = EXCLUDED.access_token,
			refresh_token = EXCLUDED.refresh_token,
			token_expires_at = EXCLUDED.token_expires_at,
			status = 'ACTIVE',
			updated_at = NOW()
	`, ostate.TenantID, ostate.StoreID, tokens.AccessToken, tokens.RefreshToken,
		time.Now().Add(time.Duration(tokens.ExpiresIn)*time.Second),
		[]string{"advertising::campaign_management"},
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "persist_token_failed")
		return
	}

	h.audit.Log(r.Context(), audit.Entry{
		TenantID:   ostate.TenantID,
		StoreID:    &ostate.StoreID,
		UserID:     &ostate.UserID,
		Action:     "AMAZON_CONNECTION_CREATED",
		EntityType: "amazon_oauth_connection",
		EntityID:   ostate.StoreID.String(),
	})

	writeJSON(w, http.StatusOK, map[string]string{
		"status":   "connected",
		"store_id": ostate.StoreID.String(),
	})
}

// GET /api/v1/amazon/profiles  (calls Amazon Ads API to list profiles)
func (h *OAuthHandler) ListProfiles(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	storeID := r.URL.Query().Get("store_id")
	if storeID == "" {
		writeError(w, http.StatusBadRequest, "store_id required")
		return
	}

	token, err := h.getValidToken(r.Context(), claims.TenantID, storeID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "AMAZON_AUTH_EXPIRED")
		return
	}

	req, _ := http.NewRequestWithContext(r.Context(), "GET", h.cfg.AmazonAdsAPIURL+"/v2/profiles", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Amazon-Advertising-API-ClientId", h.cfg.AmazonLWAClientID)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "amazon_api_error")
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

// GET /api/v1/connections/amazon/status
func (h *OAuthHandler) ConnectionStatus(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	storeID := r.URL.Query().Get("store_id")

	var status, expiresAt string
	err := h.db.QueryRow(r.Context(), `
		SELECT status, token_expires_at::text FROM amazon_oauth_connections
		WHERE tenant_id=$1 AND store_id=$2
	`, tenantID, storeID).Scan(&status, &expiresAt)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]string{"connected": "false"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"connected":         true,
		"status":            status,
		"token_expires_at":  expiresAt,
	})
}

func (h *OAuthHandler) getValidToken(ctx context.Context, tenantID uuid.UUID, storeID string) (string, error) {
	var accessToken, refreshToken string
	var expiresAt time.Time
	err := h.db.QueryRow(ctx, `
		SELECT access_token, refresh_token, token_expires_at
		FROM amazon_oauth_connections WHERE tenant_id=$1 AND store_id=$2 AND status='ACTIVE'
	`, tenantID, storeID).Scan(&accessToken, &refreshToken, &expiresAt)
	if err != nil {
		return "", fmt.Errorf("no active connection: %w", err)
	}

	if time.Now().Before(expiresAt.Add(-5 * time.Minute)) {
		return accessToken, nil
	}

	// Refresh
	tokens, err := h.refreshToken(ctx, refreshToken)
	if err != nil {
		return "", fmt.Errorf("refresh failed: %w", err)
	}

	h.db.Exec(ctx, `
		UPDATE amazon_oauth_connections
		SET access_token=$1, refresh_token=$2, token_expires_at=$3, updated_at=NOW()
		WHERE tenant_id=$4 AND store_id=$5
	`, tokens.AccessToken, tokens.RefreshToken,
		time.Now().Add(time.Duration(tokens.ExpiresIn)*time.Second),
		tenantID, storeID)

	return tokens.AccessToken, nil
}

type lwaTokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
}

func (h *OAuthHandler) exchangeCode(ctx context.Context, code string) (lwaTokenResponse, error) {
	return h.callTokenEndpoint(ctx, url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {h.cfg.AmazonAdsRedirectURI},
		"client_id":     {h.cfg.AmazonLWAClientID},
		"client_secret": {h.cfg.AmazonLWAClientSecret},
	})
}

func (h *OAuthHandler) refreshToken(ctx context.Context, refreshToken string) (lwaTokenResponse, error) {
	return h.callTokenEndpoint(ctx, url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refreshToken},
		"client_id":     {h.cfg.AmazonLWAClientID},
		"client_secret": {h.cfg.AmazonLWAClientSecret},
	})
}

func (h *OAuthHandler) callTokenEndpoint(ctx context.Context, params url.Values) (lwaTokenResponse, error) {
	req, _ := http.NewRequestWithContext(ctx, "POST", h.cfg.AmazonLWATokenURL,
		strings.NewReader(params.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return lwaTokenResponse{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return lwaTokenResponse{}, fmt.Errorf("LWA error %d: %s", resp.StatusCode, body)
	}

	var tokens lwaTokenResponse
	json.NewDecoder(resp.Body).Decode(&tokens)
	return tokens, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
