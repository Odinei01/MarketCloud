package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/zanom/marketcloud/internal/amazon"
	"github.com/zanom/marketcloud/internal/audit"
	"github.com/zanom/marketcloud/internal/config"
	"github.com/zanom/marketcloud/internal/database"
	"github.com/zanom/marketcloud/internal/middleware"
	"github.com/zanom/marketcloud/internal/query"
	"github.com/zanom/marketcloud/internal/store"
	"github.com/zanom/marketcloud/internal/stream"
	"github.com/zanom/marketcloud/internal/tenant"
)

func main() {
	cfg := config.Load()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	db, err := database.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()
	log.Println("database connected")

	auditLogger := audit.New(db)

	tenantH := tenant.NewHandler(db, auditLogger, cfg.JWTSecret)
	storeH := store.NewHandler(db, auditLogger)
	queryH := query.NewHandler(db, auditLogger)
	oauthH := amazon.NewOAuthHandler(db, cfg, auditLogger)
	streamH := stream.NewHandler(db, cfg)

	// Amazon Marketing Stream â€” consumidor SQS (hora-a-hora). Dormente atÃ©
	// STREAM_CONSUMER_ENABLED=true + filas configuradas. NÃ£o bloqueia o boot.
	stream.NewConsumer(db, cfg).Start(context.Background())

	auth := middleware.Auth(cfg.JWTSecret)
	tenantIso := middleware.TenantIsolation()
	adminOnly := middleware.RequireRole("SUPER_ADMIN")
	managerUp := middleware.RequireRole("SUPER_ADMIN", "TENANT_ADMIN", "AGENCY_MANAGER", "STORE_MANAGER")

	r := chi.NewRouter()
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)
	r.Use(chimw.RealIP)
	r.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-Service", "marketcloud-api")
			next.ServeHTTP(w, r)
		})
	})

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(r.Context()); err != nil {
			http.Error(w, "db unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte(`{"status":"ok","service":"marketcloud-api"}`))
	})

	// --- Auth (public) ---
	r.Route("/api/v1/auth", func(r chi.Router) {
		r.Post("/login", tenantH.Login)
		r.Post("/register", tenantH.Register)
		r.Post("/refresh", tenantH.Refresh)
		r.With(auth).Get("/me", tenantH.Me)
	})

	// --- Tenants ---
	r.Route("/api/v1/tenants", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.With(adminOnly).Post("/", tenantH.Create)
		r.Get("/{id}", tenantH.Get)
	})

	// --- Amazon OAuth ---
	r.Route("/api/v1/connections/amazon", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Post("/oauth/start", oauthH.Start)
		r.Get("/oauth/callback", oauthH.Callback)
		r.Get("/status", oauthH.ConnectionStatus)
	})

	// --- Amazon Ads profiles ---
	r.With(auth, tenantIso).Get("/api/v1/amazon/profiles", oauthH.ListProfiles)

	// --- Stores ---
	r.Route("/api/v1/stores", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.With(managerUp).Post("/", storeH.Create)
		r.Get("/", storeH.List)
		r.Get("/{store_id}", storeH.Get)
		r.Post("/{store_id}/amazon-profiles", storeH.RegisterAmazonProfile)
		r.Get("/{store_id}/amazon-profiles", storeH.ListAmazonProfiles)
		r.Post("/{store_id}/amc/instances", storeH.RegisterAMCInstance)
		r.Get("/{store_id}/amc/instances", storeH.ListAMCInstances)
	})

	// --- Query catalog + runs ---
	r.Route("/api/v1/query-templates", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Get("/", queryH.ListTemplates)
		r.Get("/{id}", queryH.GetTemplate)
	})

	r.Route("/api/v1/query-runs", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Post("/", queryH.CreateRun)
		r.Get("/", queryH.ListRuns)
		r.Get("/{id}", queryH.GetRun)
	})

	// --- Insights + Recommendations ---
	r.Route("/api/v1/insights", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Get("/", queryH.ListInsights)
	})

	r.Route("/api/v1/recommendations", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Get("/", queryH.ListRecommendations)
		r.Post("/{id}/approve", queryH.ApproveRecommendation)
		r.Post("/{id}/reject", queryH.RejectRecommendation)
	})

	// --- Gold Layer V2 cockpit + feedback loop ---
	r.Route("/api/v1/gold", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Get("/review-queue", queryH.GoldReviewQueue)
		r.Get("/action-summary", queryH.GoldActionSummary)
		r.Get("/campaign-plans", queryH.GoldCampaignPlans)
		r.Get("/hourly-real", queryH.GoldHourlyReal)
		r.Get("/keyword-hourly-real", queryH.GoldKeywordHourlyReal)
		r.With(managerUp).Post("/refresh-swarm-state", queryH.RefreshSwarmState)
		r.Get("/ml-ams-status", queryH.GoldMLAmsStatus)
		r.Get("/ml-full-auto-campaigns", queryH.GoldMLFullAutoCampaigns)
		r.Put("/ml-full-auto-campaigns", queryH.GoldSetMLFullAutoCampaign)
		r.Get("/partner-campaign-monitor", queryH.GoldPartnerCampaignMonitor)
		r.Get("/amc-alerts", queryH.GoldAMCAlerts)
		r.Get("/robot-today", queryH.RobotToday)
		r.Post("/review-queue/{id}/decision", queryH.GoldDecide)
	})

	// --- Config Center / seller health ---
	r.Route("/api/v1/settings", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Get("/tenant", queryH.TenantSettings)
		r.With(managerUp).Put("/tenant", queryH.SetTenantSettings)
		r.Get("/health", queryH.TenantHealth)
		r.Get("/full-control-products", queryH.FullControlProducts)
		r.Get("/full-control-governance", queryH.FullControlGovernance)
		r.Get("/full-control-monitoring", queryH.FullControlMonitoring)
		r.With(managerUp).Put("/full-control-pilot", queryH.SetFullControlPilot)
	})
	// --- Amazon Marketing Stream: gerÃªncia de subscriptions (Fase 2) ---
	r.Route("/api/v1/stream/subscriptions", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.With(managerUp).Post("/", streamH.CreateSubscription)
		r.Get("/", streamH.ListSubscriptions)
		r.With(managerUp).Delete("/{id}", func(w http.ResponseWriter, req *http.Request) {
			streamH.DeleteSubscription(w, req, chi.URLParam(req, "id"))
		})
	})

	// --- External API (API clients / SWARM) ---
	r.Route("/api/v1/external", func(r chi.Router) {
		r.Use(auth, tenantIso)
		r.Get("/recommendations/actions", queryH.ExternalActions)
	})

	addr := ":" + cfg.Port
	log.Printf("marketcloud-api listening on %s", addr)
	srv := &http.Server{
		Addr:         addr,
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
