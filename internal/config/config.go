package config

import (
	"os"
	"strconv"
)

type Config struct {
	DatabaseURL         string
	RedisURL            string
	JWTSecret           string
	Port                string
	Env                 string
	AmazonLWAClientID   string
	AmazonLWAClientSecret string
	AmazonAdsRedirectURI  string
	AmazonAdsAPIURL       string
	AmazonLWATokenURL     string
	AmazonAdsAuthURL      string
	AMCAPIURL             string
	ConnectorURL          string
}

func Load() Config {
	return Config{
		DatabaseURL:           env("DATABASE_URL", "postgres://mcadmin:mcsecret@localhost:5433/marketcloud?sslmode=disable"),
		RedisURL:              env("REDIS_URL", "redis://localhost:6380"),
		JWTSecret:             env("JWT_SECRET", "dev-secret-change-in-production!!"),
		Port:                  env("PORT", "8090"),
		Env:                   env("ENV", "development"),
		AmazonLWAClientID:     env("AMAZON_LWA_CLIENT_ID", ""),
		AmazonLWAClientSecret: env("AMAZON_LWA_CLIENT_SECRET", ""),
		AmazonAdsRedirectURI:  env("AMAZON_ADS_REDIRECT_URI", "http://localhost:8091/api/v1/connections/amazon/oauth/callback"),
		AmazonAdsAPIURL:       env("AMAZON_ADS_API_URL", "https://advertising-api.amazon.com"),
		AmazonLWATokenURL:     env("AMAZON_LWA_TOKEN_URL", "https://api.amazon.com/auth/o2/token"),
		AmazonAdsAuthURL:      env("AMAZON_ADS_AUTH_URL", "https://www.amazon.com/ap/oa"),
		AMCAPIURL:             env("AMC_API_URL", "https://advertising-api.amazon.com/amc/reporting"),
		ConnectorURL:          env("CONNECTOR_URL", "http://localhost:8091"),
	}
}

func (c Config) IsDevelopment() bool { return c.Env == "development" }

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func EnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
