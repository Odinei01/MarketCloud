// Package stream — Amazon Marketing Stream (push hora-a-hora).
//
// Fase 2: gerência de subscriptions via Amazon Ads API (/streams/subscriptions).
// Reusa o OAuth já existente do marketcloud (amazon_oauth_connections, escopo
// advertising::campaign_management). ADVISOR/INGESTÃO — não muta campanha.
//
// OBS honesta: o shape exato do corpo do POST /streams/subscriptions pode variar
// por versão; centralizei em buildSubscriptionBody e o handler devolve a resposta
// crua da Amazon (inclusive erros de validação) para iterarmos no "connect".
package stream

import (
	"bytes"
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
	"github.com/zanom/marketcloud/internal/config"
)

// media type confirmado no exemplo oficial da Amazon (v1.0, não v1)
const streamSubscriptionMediaType = "application/vnd.MarketingStreamSubscriptions.StreamSubscriptionResource.v1.0+json"

type Handler struct {
	db  *pgxpool.Pool
	cfg config.Config
}

func NewHandler(db *pgxpool.Pool, cfg config.Config) *Handler {
	return &Handler{db: db, cfg: cfg}
}

// resolve o store cuja conexão OAuth autoriza a chamada (query > cfg default).
func (h *Handler) storeID(r *http.Request) string {
	if s := strings.TrimSpace(r.URL.Query().Get("store_id")); s != "" {
		return s
	}
	return h.cfg.StreamDefaultStoreID
}

// getAdsToken busca o access_token ativo da conexão Amazon do store e faz
// refresh via LWA se estiver perto de expirar. Mesmo mecanismo do OAuthHandler.
func (h *Handler) getAdsToken(ctx context.Context, storeID string) (string, error) {
	if strings.TrimSpace(storeID) == "" {
		return "", fmt.Errorf("store_id vazio (configure STREAM_DEFAULT_STORE_ID ou passe ?store_id=)")
	}
	var access, refresh string
	var expiresAt time.Time
	err := h.db.QueryRow(ctx, `
		SELECT access_token, refresh_token, token_expires_at
		FROM amazon_oauth_connections WHERE store_id=$1 AND status='ACTIVE'
	`, storeID).Scan(&access, &refresh, &expiresAt)
	if err != nil {
		return "", fmt.Errorf("sem conexão Amazon ativa para o store %s: %w", storeID, err)
	}
	if time.Now().Before(expiresAt.Add(-5 * time.Minute)) {
		return access, nil
	}
	newAccess, newRefresh, ttl, err := h.refreshLWA(ctx, refresh)
	if err != nil {
		return "", fmt.Errorf("refresh LWA falhou: %w", err)
	}
	h.db.Exec(ctx, `
		UPDATE amazon_oauth_connections SET access_token=$1, refresh_token=$2, token_expires_at=$3, updated_at=NOW()
		WHERE store_id=$4
	`, newAccess, newRefresh, time.Now().Add(time.Duration(ttl)*time.Second), storeID)
	return newAccess, nil
}

func (h *Handler) refreshLWA(ctx context.Context, refreshToken string) (access, refresh string, expiresIn int, err error) {
	params := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refreshToken},
		"client_id":     {h.cfg.AmazonLWAClientID},
		"client_secret": {h.cfg.AmazonLWAClientSecret},
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, h.cfg.AmazonLWATokenURL, strings.NewReader(params.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", "", 0, fmt.Errorf("LWA %d: %s", resp.StatusCode, body)
	}
	var out struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int    `json:"expires_in"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	return out.AccessToken, out.RefreshToken, out.ExpiresIn, nil
}

// adsRequest faz uma chamada autenticada à Ads API para endpoints /streams/*.
func (h *Handler) adsRequest(ctx context.Context, method, path string, body any, token string) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, h.cfg.AmazonAdsAPIURL+path, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Amazon-Advertising-API-ClientId", h.cfg.AmazonLWAClientID)
	if h.cfg.AmazonAdsProfileID != "" {
		req.Header.Set("Amazon-Advertising-API-Scope", h.cfg.AmazonAdsProfileID)
	}
	req.Header.Set("Accept", streamSubscriptionMediaType)
	if body != nil {
		req.Header.Set("Content-Type", streamSubscriptionMediaType)
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, raw, nil
}

// corpo da subscription — dataset + destino SQS. Centralizado p/ ajuste fácil.
func buildSubscriptionBody(dataset, destinationArn, clientToken string) map[string]any {
	return map[string]any{
		"dataSetId":          dataset,
		"destinationArn":     destinationArn,
		"clientRequestToken": clientToken,
		"notes":              "zanom marketcloud hourly ingest",
	}
}

// POST /api/v1/stream/subscriptions   body: { "dataset": "sp-traffic", "destination_arn": "arn:aws:sqs:..." }
func (h *Handler) CreateSubscription(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Dataset        string `json:"dataset"`
		DestinationArn string `json:"destination_arn"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Dataset == "" || body.DestinationArn == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "dataset e destination_arn obrigatórios"})
		return
	}
	token, err := h.getAdsToken(r.Context(), h.storeID(r))
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
		return
	}
	clientToken := uuid.NewString() // <= 36 chars (exigência da API)
	status, raw, err := h.adsRequest(r.Context(), http.MethodPost, "/streams/subscriptions",
		buildSubscriptionBody(body.Dataset, body.DestinationArn, clientToken), token)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeRawAmazon(w, status, raw, map[string]any{"dataset": body.Dataset, "destination_arn": body.DestinationArn})
}

// GET /api/v1/stream/subscriptions
func (h *Handler) ListSubscriptions(w http.ResponseWriter, r *http.Request) {
	token, err := h.getAdsToken(r.Context(), h.storeID(r))
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
		return
	}
	status, raw, err := h.adsRequest(r.Context(), http.MethodGet, "/streams/subscriptions", nil, token)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeRawAmazon(w, status, raw, nil)
}

func buildArchiveSubscriptionBody() map[string]any {
	return map[string]any{"status": "ARCHIVED"}
}

// DELETE /api/v1/stream/subscriptions/{id}
// A Ads API arquiva subscriptions via PUT status=ARCHIVED; manter DELETE aqui
// preserva a semantica externa do nosso endpoint de cleanup.
func (h *Handler) DeleteSubscription(w http.ResponseWriter, r *http.Request, id string) {
	token, err := h.getAdsToken(r.Context(), h.storeID(r))
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
		return
	}
	status, raw, err := h.adsRequest(r.Context(), http.MethodPut, "/streams/subscriptions/"+id, buildArchiveSubscriptionBody(), token)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeRawAmazon(w, status, raw, map[string]any{"subscription_id": id})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeRawAmazon(w http.ResponseWriter, amazonStatus int, raw []byte, extra map[string]any) {
	out := map[string]any{"amazon_status": amazonStatus}
	var parsed any
	if json.Unmarshal(raw, &parsed) == nil {
		out["amazon_response"] = parsed
	} else {
		out["amazon_response_raw"] = string(raw)
	}
	for k, v := range extra {
		out[k] = v
	}
	code := http.StatusOK
	if amazonStatus >= 400 {
		code = http.StatusBadGateway
	}
	writeJSON(w, code, out)
}
