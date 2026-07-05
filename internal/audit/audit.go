package audit

import (
	"context"
	"encoding/json"
	"net"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/middleware"
)

type Logger struct {
	db *pgxpool.Pool
}

func New(db *pgxpool.Pool) *Logger { return &Logger{db: db} }

type Entry struct {
	TenantID     uuid.UUID
	StoreID      *uuid.UUID
	UserID       *uuid.UUID
	Action       string
	EntityType   string
	EntityID     string
	PayloadBefore any
	PayloadAfter  any
	IPAddress    string
	UserAgent    string
}

func (l *Logger) Log(ctx context.Context, e Entry) {
	var before, after []byte
	if e.PayloadBefore != nil {
		before, _ = json.Marshal(e.PayloadBefore)
	}
	if e.PayloadAfter != nil {
		after, _ = json.Marshal(e.PayloadAfter)
	}

	var storeID, userID *uuid.UUID
	if e.StoreID != nil {
		storeID = e.StoreID
	}
	if e.UserID != nil {
		userID = e.UserID
	}

	l.db.Exec(ctx, `
		INSERT INTO audit_logs
			(tenant_id, store_id, user_id, action, entity_type, entity_id,
			 payload_before, payload_after, ip_address, user_agent)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
	`, e.TenantID, storeID, userID, e.Action, e.EntityType, e.EntityID,
		before, after, ipAddr(e.IPAddress), e.UserAgent)
}

func (l *Logger) LogRequest(ctx context.Context, r *http.Request, action, entityType, entityID string, before, after any) {
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		return
	}
	uid := claims.UserID
	l.Log(ctx, Entry{
		TenantID:     claims.TenantID,
		UserID:       &uid,
		Action:       action,
		EntityType:   entityType,
		EntityID:     entityID,
		PayloadBefore: before,
		PayloadAfter:  after,
		IPAddress:    clientIP(r),
		UserAgent:    r.UserAgent(),
	})
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return xff
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

func ipAddr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
