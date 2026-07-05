package query

import (
	"encoding/json"
	"time"

	"github.com/google/uuid"
)

type QueryTemplate struct {
	ID                     uuid.UUID       `json:"id"`
	Name                   string          `json:"name"`
	Code                   string          `json:"code"`
	Description            string          `json:"description,omitempty"`
	QueryFamily            string          `json:"query_family"`
	QueryGoal              string          `json:"query_goal"`
	SQLTemplate            string          `json:"sql_template,omitempty"`
	ParametersSchema       json.RawMessage `json:"parameters_schema"`
	MinLookbackDays        int             `json:"min_lookback_days"`
	MaxLookbackDays        int             `json:"max_lookback_days"`
	SupportedCampaignTypes []string        `json:"supported_campaign_types"`
	SupportedMarketplaces  []string        `json:"supported_marketplaces"`
	Version                int             `json:"version"`
	Status                 string          `json:"status"`
}

type QueryRun struct {
	ID                       uuid.UUID       `json:"id"`
	TenantID                 uuid.UUID       `json:"tenant_id"`
	StoreID                  uuid.UUID       `json:"store_id"`
	AMCInstanceID            uuid.UUID       `json:"amc_instance_id"`
	QueryTemplateID          uuid.UUID       `json:"query_template_id"`
	RunType                  string          `json:"run_type"`
	ParametersJSON           json.RawMessage `json:"parameters"`
	IdempotencyKey           string          `json:"idempotency_key,omitempty"`
	Status                   string          `json:"status"`
	SubmittedAt              *time.Time      `json:"submitted_at,omitempty"`
	StartedAt                *time.Time      `json:"started_at,omitempty"`
	FinishedAt               *time.Time      `json:"finished_at,omitempty"`
	ExternalQueryExecutionID *string         `json:"external_query_execution_id,omitempty"`
	ResultObjectPath         *string         `json:"result_object_path,omitempty"`
	ErrorCode                *string         `json:"error_code,omitempty"`
	ErrorMessage             *string         `json:"error_message,omitempty"`
	CreatedAt                time.Time       `json:"created_at"`
	UpdatedAt                *time.Time      `json:"updated_at,omitempty"`
}
