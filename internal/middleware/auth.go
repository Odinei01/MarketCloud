package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/zanom/marketcloud/internal/auth"
)

type contextKey string

const (
	claimsKey    contextKey = "claims"
	tenantIDKey  contextKey = "tenant_id"
	userIDKey    contextKey = "user_id"
	roleKey      contextKey = "role"
)

func Auth(jwtSecret string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if header == "" || !strings.HasPrefix(header, "Bearer ") {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing authorization header"})
				return
			}

			claims, err := auth.ParseClaims(jwtSecret, strings.TrimPrefix(header, "Bearer "))
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid token"})
				return
			}

			ctx := context.WithValue(r.Context(), claimsKey, claims)
			ctx = context.WithValue(ctx, tenantIDKey, claims.TenantID)
			ctx = context.WithValue(ctx, userIDKey, claims.UserID)
			ctx = context.WithValue(ctx, roleKey, claims.Role)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// TenantIsolation enforces X-Tenant-ID header matches the authenticated tenant.
func TenantIsolation() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, _ := r.Context().Value(claimsKey).(*auth.Claims)
			if claims == nil {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthenticated"})
				return
			}
			headerTenantID := r.Header.Get("X-Tenant-ID")
			if headerTenantID != "" && headerTenantID != claims.TenantID.String() {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "TENANT_ACCESS_DENIED"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func RequireRole(roles ...string) func(http.Handler) http.Handler {
	allowed := make(map[string]bool, len(roles))
	for _, r := range roles {
		allowed[r] = true
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			role, _ := r.Context().Value(roleKey).(string)
			if !allowed[role] {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "insufficient_role"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func ClaimsFromCtx(ctx context.Context) *auth.Claims {
	c, _ := ctx.Value(claimsKey).(*auth.Claims)
	return c
}

func TenantIDFromCtx(ctx context.Context) uuid.UUID {
	id, _ := ctx.Value(tenantIDKey).(uuid.UUID)
	return id
}

func UserIDFromCtx(ctx context.Context) uuid.UUID {
	id, _ := ctx.Value(userIDKey).(uuid.UUID)
	return id
}

func RoleFromCtx(ctx context.Context) string {
	r, _ := ctx.Value(roleKey).(string)
	return r
}
