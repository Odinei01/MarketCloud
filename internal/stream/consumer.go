package stream

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	appcfg "github.com/zanom/marketcloud/internal/config"
)

const (
	datasetTraffic      = "sp-traffic"
	datasetConversion   = "sp-conversion"
	datasetSDTraffic    = "sd-traffic"
	datasetSDConversion = "sd-conversion"
)

type Consumer struct {
	db  *pgxpool.Pool
	cfg appcfg.Config
	sqs *sqs.Client
	loc *time.Location
}

func NewConsumer(db *pgxpool.Pool, cfg appcfg.Config) *Consumer {
	return &Consumer{db: db, cfg: cfg}
}

func (c *Consumer) Start(ctx context.Context) {
	if !c.cfg.StreamConsumerEnabled {
		log.Printf("[ams-stream] consumidor DESLIGADO (STREAM_CONSUMER_ENABLED!=true)")
		return
	}
	opts := []func(*awscfg.LoadOptions) error{awscfg.WithRegion(c.cfg.AWSRegion)}
	if c.cfg.StreamAWSAccessKeyID != "" && c.cfg.StreamAWSSecretAccessKey != "" {
		opts = append(opts, awscfg.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider(c.cfg.StreamAWSAccessKeyID, c.cfg.StreamAWSSecretAccessKey, "")))
	} else {
		log.Printf("[ams-stream] STREAM_AWS_* nao setado; usando default chain")
	}
	awsConf, err := awscfg.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		log.Printf("[ams-stream] falha ao carregar credenciais AWS: %v (consumidor nao sobe)", err)
		return
	}
	c.sqs = sqs.NewFromConfig(awsConf)
	c.loc = loadLocation(c.cfg.StreamEventTimezone)

	queues := map[string]string{
		datasetTraffic:      c.cfg.StreamSQSURLTraffic,
		datasetConversion:   c.cfg.StreamSQSURLConversion,
		datasetSDTraffic:    c.cfg.StreamSQSURLSDTraffic,
		datasetSDConversion: c.cfg.StreamSQSURLSDConversion,
	}
	started := 0
	for dataset, urlStr := range queues {
		if strings.TrimSpace(urlStr) == "" {
			log.Printf("[ams-stream] fila de %s nao configurada; pulando", dataset)
			continue
		}
		go c.pollLoop(ctx, dataset, urlStr)
		started++
	}
	log.Printf("[ams-stream] consumidor LIGADO region=%s filas=%d timezone=%s", c.cfg.AWSRegion, started, c.loc.String())
}

func (c *Consumer) pollLoop(ctx context.Context, dataset, queueURL string) {
	log.Printf("[ams-stream] long-poll %s queue=%s", dataset, queueURL)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		out, err := c.sqs.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:            &queueURL,
			MaxNumberOfMessages: 10,
			WaitTimeSeconds:     20,
			VisibilityTimeout:   60,
		})
		if err != nil {
			log.Printf("[ams-stream] receive %s erro: %v (retry em 5s)", dataset, err)
			time.Sleep(5 * time.Second)
			continue
		}
		for _, m := range out.Messages {
			if err := c.handleMessage(ctx, dataset, *m.Body); err != nil {
				log.Printf("[ams-stream] processa %s erro: %v (nao apaga -> DLQ)", dataset, err)
				continue
			}
			c.sqs.DeleteMessage(ctx, &sqs.DeleteMessageInput{QueueUrl: &queueURL, ReceiptHandle: m.ReceiptHandle})
		}
	}
}

func (c *Consumer) handleMessage(ctx context.Context, dataset, body string) error {
	var env struct {
		Type         string `json:"Type"`
		Message      string `json:"Message"`
		SubscribeURL string `json:"SubscribeURL"`
	}
	inner := body
	if json.Unmarshal([]byte(body), &env) == nil && env.Type != "" {
		if env.Type == "SubscriptionConfirmation" && env.SubscribeURL != "" {
			resp, err := http.Get(env.SubscribeURL)
			if err != nil {
				return fmt.Errorf("confirm SNS: %w", err)
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			log.Printf("[ams-stream] SNS SubscriptionConfirmation confirmada (%s)", dataset)
			return nil
		}
		inner = env.Message
	}

	trimmed := strings.TrimSpace(inner)
	// DEBUG: captura o payload AMS cru p/ validar delta-vs-absoluto e nomes de
	// campo reais (§10.6/§41.2). Gated por env; desligar após inspecionar.
	if rawDebugEnabled(dataset) {
		n := len(trimmed)
		if n > 2500 {
			n = 2500
		}
		log.Printf("[ams-stream][RAW] dataset=%s body=%s", dataset, trimmed[:n])
	}
	var records []map[string]any
	if strings.HasPrefix(trimmed, "[") {
		if err := json.Unmarshal([]byte(trimmed), &records); err != nil {
			return fmt.Errorf("parse array: %w", err)
		}
	} else {
		var one map[string]any
		if err := json.Unmarshal([]byte(trimmed), &one); err != nil {
			return fmt.Errorf("parse record: %w", err)
		}
		records = []map[string]any{one}
	}

	processed := 0
	for _, rec := range records {
		ok, err := c.upsertRecord(ctx, dataset, rec)
		if err != nil {
			return err
		}
		if ok {
			processed++
		}
	}
	if processed > 0 {
		if err := c.refreshHourlyBridge(ctx); err != nil {
			return err
		}
	}
	return nil
}

// adProductFor: de qual produto de anuncio o dataset fala. Sem isso a bronze
// horaria nao sabe dizer o que e SP e o que e SD depois de misturado.
func adProductFor(dataset string) string {
	switch dataset {
	case datasetSDTraffic, datasetSDConversion:
		return "SPONSORED_DISPLAY"
	default:
		return "SPONSORED_PRODUCTS"
	}
}

// rawDebugEnabled: log do payload cru, por dataset.
//
//	STREAM_DEBUG_RAW_DATASETS=sd-traffic,sd-conversion  -> so esses
//	STREAM_DEBUG_RAW=true                               -> todos (PERIGOSO)
//
// O modo "todos" ligado em conta cheia foi o que encheu 194GB de disco em
// 12/07. Prefira sempre a lista por dataset.
func rawDebugEnabled(dataset string) bool {
	if list := strings.TrimSpace(os.Getenv("STREAM_DEBUG_RAW_DATASETS")); list != "" {
		for _, d := range strings.Split(list, ",") {
			if strings.EqualFold(strings.TrimSpace(d), dataset) {
				return true
			}
		}
		return false
	}
	return os.Getenv("STREAM_DEBUG_RAW") == "true"
}

func (c *Consumer) upsertRecord(ctx context.Context, dataset string, rec map[string]any) (bool, error) {
	campaignID := str(rec, "campaignId", "campaign_id")
	if campaignID == "" {
		return false, nil
	}
	date, hour := c.dateHour(rec)
	if date == "" {
		return false, nil
	}
	// DEDUP por idempotency_id: cada evento AMS é um delta único; o SQS é
	// at-least-once, então sem dedup a soma (abaixo) duplicaria. Se já visto, pula.
	if idem := str(rec, "idempotency_id", "idempotencyId"); idem != "" {
		var dummy bool
		err := c.db.QueryRow(ctx,
			`INSERT INTO marketcloud_bronze.ams_seen_events(idempotency_id) VALUES ($1)
			 ON CONFLICT DO NOTHING RETURNING true`, idem).Scan(&dummy)
		if err == pgx.ErrNoRows {
			return false, nil // já processado -> dedup
		}
		if err != nil {
			return false, err
		}
	}
	msgTime := str(rec, "time", "timeWindowStart", "time_window_start", "startTime")
	adProduct := adProductFor(dataset)

	switch dataset {
	case datasetTraffic, datasetSDTraffic:
		_, err := c.db.Exec(ctx, `
			INSERT INTO marketcloud_bronze.bronze_ams_hourly
				(data_date, event_hour, campaign_id, campaign_name, ad_group_id,
				 impressions, clicks, spend, last_traffic_at, traffic_msg_time, updated_at, ad_product)
			VALUES ($1::date,$2,$3,$4,$5,$6,$7,$8,NOW(),$9,NOW(),$10)
			ON CONFLICT (data_date, event_hour, campaign_id) DO UPDATE SET
				campaign_name = COALESCE(EXCLUDED.campaign_name, bronze_ams_hourly.campaign_name),
				ad_group_id   = COALESCE(EXCLUDED.ad_group_id, bronze_ams_hourly.ad_group_id),
				ad_product    = EXCLUDED.ad_product,
				-- ACUMULA: cada keyword×hora é um delta; soma dá o total da campanha×hora
				impressions   = bronze_ams_hourly.impressions + EXCLUDED.impressions,
				clicks        = bronze_ams_hourly.clicks + EXCLUDED.clicks,
				spend         = bronze_ams_hourly.spend + EXCLUDED.spend,
				last_traffic_at  = NOW(),
				traffic_msg_time = EXCLUDED.traffic_msg_time,
				updated_at    = NOW()
		`, date, hour, campaignID, strNil(rec, "campaignName", "campaign_name"), strNil(rec, "adGroupId", "ad_group_id"),
			num(rec, "impressions"), num(rec, "clicks"), num(rec, "cost", "spend"), tsNil(msgTime), adProduct)
		if err != nil {
			return false, err
		}
		if err := c.upsertTargetRecord(ctx, dataset, rec, date, hour, campaignID, msgTime); err != nil {
			return false, err
		}
		return true, nil

	case datasetConversion, datasetSDConversion:
		_, err := c.db.Exec(ctx, `
			INSERT INTO marketcloud_bronze.bronze_ams_hourly
				(data_date, event_hour, campaign_id, campaign_name, ad_group_id,
				 orders_1d, sales_1d, orders_7d, sales_7d, orders_14d, sales_14d,
				 last_conversion_at, conversion_msg_time, updated_at, ad_product)
			VALUES ($1::date,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW(),$12,NOW(),$13)
			ON CONFLICT (data_date, event_hour, campaign_id) DO UPDATE SET
				campaign_name = COALESCE(EXCLUDED.campaign_name, bronze_ams_hourly.campaign_name),
				ad_group_id   = COALESCE(EXCLUDED.ad_group_id, bronze_ams_hourly.ad_group_id),
				ad_product    = EXCLUDED.ad_product,
				orders_1d  = EXCLUDED.orders_1d,  sales_1d  = EXCLUDED.sales_1d,
				orders_7d  = EXCLUDED.orders_7d,  sales_7d  = EXCLUDED.sales_7d,
				orders_14d = EXCLUDED.orders_14d, sales_14d = EXCLUDED.sales_14d,
				last_conversion_at  = NOW(),
				conversion_msg_time = EXCLUDED.conversion_msg_time,
				updated_at = NOW()
		`, date, hour, campaignID, strNil(rec, "campaignName", "campaign_name"), strNil(rec, "adGroupId", "ad_group_id"),
			num(rec, "attributedConversions1d", "attributed_conversions_1d", "purchases1d", "purchases_1d"), num(rec, "attributedSales1d", "attributed_sales_1d", "sales1d", "sales_1d"),
			num(rec, "attributedConversions7d", "attributed_conversions_7d", "purchases7d", "purchases_7d"), num(rec, "attributedSales7d", "attributed_sales_7d", "sales7d", "sales_7d"),
			num(rec, "attributedConversions14d", "attributed_conversions_14d", "purchases14d", "purchases_14d"), num(rec, "attributedSales14d", "attributed_sales_14d", "sales14d", "sales_14d"),
			tsNil(msgTime), adProduct)
		if err != nil {
			return false, err
		}
		if err := c.upsertTargetRecord(ctx, dataset, rec, date, hour, campaignID, msgTime); err != nil {
			return false, err
		}
		return true, nil
	}
	return false, nil
}

func (c *Consumer) upsertTargetRecord(ctx context.Context, dataset string, rec map[string]any, date string, hour int, campaignID string, msgTime string) error {
	// O grao keyword x hora e de SP. SD segmenta por audiencia/contexto, nao por
	// keyword: deixar um target de SD entrar aqui poluiria a tela Keywords x hora
	// com linha que nao tem keyword nem lance pra ajustar. SD fica no grao
	// campanha x hora (bronze_ams_hourly), que e o que o ML horario usa.
	if dataset == datasetSDTraffic || dataset == datasetSDConversion {
		return nil
	}
	target, ok := targetEntity(rec)
	if !ok {
		return nil
	}
	raw, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("marshal raw target payload: %w", err)
	}

	switch dataset {
	case datasetTraffic:
		_, err = c.db.Exec(ctx, `
			INSERT INTO marketcloud_bronze.bronze_ams_hourly_target
				(data_date, event_hour, campaign_id, target_entity_key,
				 campaign_name, ad_group_id, ad_group_name, keyword_id, target_id,
				 keyword_text, targeting, match_type,
				 impressions, clicks, spend, last_traffic_at, traffic_msg_time, raw_traffic_payload, updated_at)
			VALUES ($1::date,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NOW(),$16,$17::jsonb,NOW())
			ON CONFLICT (data_date, event_hour, campaign_id, target_entity_key) DO UPDATE SET
				campaign_name = COALESCE(EXCLUDED.campaign_name, bronze_ams_hourly_target.campaign_name),
				ad_group_id = COALESCE(EXCLUDED.ad_group_id, bronze_ams_hourly_target.ad_group_id),
				ad_group_name = COALESCE(EXCLUDED.ad_group_name, bronze_ams_hourly_target.ad_group_name),
				keyword_id = COALESCE(EXCLUDED.keyword_id, bronze_ams_hourly_target.keyword_id),
				target_id = COALESCE(EXCLUDED.target_id, bronze_ams_hourly_target.target_id),
				keyword_text = COALESCE(EXCLUDED.keyword_text, bronze_ams_hourly_target.keyword_text),
				targeting = COALESCE(EXCLUDED.targeting, bronze_ams_hourly_target.targeting),
				match_type = COALESCE(EXCLUDED.match_type, bronze_ams_hourly_target.match_type),
				-- ACUMULA: soma os deltas de restatement do mesmo keyword×hora
				impressions = bronze_ams_hourly_target.impressions + EXCLUDED.impressions,
				clicks = bronze_ams_hourly_target.clicks + EXCLUDED.clicks,
				spend = bronze_ams_hourly_target.spend + EXCLUDED.spend,
				last_traffic_at = NOW(),
				traffic_msg_time = EXCLUDED.traffic_msg_time,
				raw_traffic_payload = EXCLUDED.raw_traffic_payload,
				updated_at = NOW()
		`, date, hour, campaignID, target.Key,
			strNil(rec, "campaignName", "campaign_name"), strNil(rec, "adGroupId", "ad_group_id"), strNil(rec, "adGroupName", "ad_group_name"),
			nullable(target.KeywordID), nullable(target.TargetID), nullable(target.KeywordText), nullable(target.Targeting), nullable(target.MatchType),
			num(rec, "impressions"), num(rec, "clicks"), num(rec, "cost", "spend"), tsNil(msgTime), string(raw))
		return err
	case datasetConversion:
		_, err = c.db.Exec(ctx, `
			INSERT INTO marketcloud_bronze.bronze_ams_hourly_target
				(data_date, event_hour, campaign_id, target_entity_key,
				 campaign_name, ad_group_id, ad_group_name, keyword_id, target_id,
				 keyword_text, targeting, match_type,
				 orders_1d, sales_1d, orders_7d, sales_7d, orders_14d, sales_14d,
				 last_conversion_at, conversion_msg_time, raw_conversion_payload, updated_at)
			VALUES ($1::date,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,NOW(),$19,$20::jsonb,NOW())
			ON CONFLICT (data_date, event_hour, campaign_id, target_entity_key) DO UPDATE SET
				campaign_name = COALESCE(EXCLUDED.campaign_name, bronze_ams_hourly_target.campaign_name),
				ad_group_id = COALESCE(EXCLUDED.ad_group_id, bronze_ams_hourly_target.ad_group_id),
				ad_group_name = COALESCE(EXCLUDED.ad_group_name, bronze_ams_hourly_target.ad_group_name),
				keyword_id = COALESCE(EXCLUDED.keyword_id, bronze_ams_hourly_target.keyword_id),
				target_id = COALESCE(EXCLUDED.target_id, bronze_ams_hourly_target.target_id),
				keyword_text = COALESCE(EXCLUDED.keyword_text, bronze_ams_hourly_target.keyword_text),
				targeting = COALESCE(EXCLUDED.targeting, bronze_ams_hourly_target.targeting),
				match_type = COALESCE(EXCLUDED.match_type, bronze_ams_hourly_target.match_type),
				orders_1d = EXCLUDED.orders_1d,
				sales_1d = EXCLUDED.sales_1d,
				orders_7d = EXCLUDED.orders_7d,
				sales_7d = EXCLUDED.sales_7d,
				orders_14d = EXCLUDED.orders_14d,
				sales_14d = EXCLUDED.sales_14d,
				last_conversion_at = NOW(),
				conversion_msg_time = EXCLUDED.conversion_msg_time,
				raw_conversion_payload = EXCLUDED.raw_conversion_payload,
				updated_at = NOW()
		`, date, hour, campaignID, target.Key,
			strNil(rec, "campaignName", "campaign_name"), strNil(rec, "adGroupId", "ad_group_id"), strNil(rec, "adGroupName", "ad_group_name"),
			nullable(target.KeywordID), nullable(target.TargetID), nullable(target.KeywordText), nullable(target.Targeting), nullable(target.MatchType),
			num(rec, "attributedConversions1d", "attributed_conversions_1d", "purchases1d", "purchases_1d"), num(rec, "attributedSales1d", "attributed_sales_1d", "sales1d", "sales_1d"),
			num(rec, "attributedConversions7d", "attributed_conversions_7d", "purchases7d", "purchases_7d"), num(rec, "attributedSales7d", "attributed_sales_7d", "sales7d", "sales_7d"),
			num(rec, "attributedConversions14d", "attributed_conversions_14d", "purchases14d", "purchases_14d"), num(rec, "attributedSales14d", "attributed_sales_14d", "sales14d", "sales_14d"),
			tsNil(msgTime), string(raw))
		return err
	}
	return nil
}

func (c *Consumer) refreshHourlyBridge(ctx context.Context) error {
	var upserted, unresolved int64
	err := c.db.QueryRow(ctx, `SELECT rows_upserted, rows_unresolved FROM marketcloud_bronze.refresh_ams_to_hourly()`).Scan(&upserted, &unresolved)
	if err != nil {
		return fmt.Errorf("refresh_ams_to_hourly: %w", err)
	}
	log.Printf("[ams-stream] refresh_ams_to_hourly rows_upserted=%d rows_unresolved=%d", upserted, unresolved)
	return nil
}

func str(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s := strings.TrimSpace(fmt.Sprintf("%v", v)); s != "" && s != "<nil>" {
				return s
			}
		}
	}
	return ""
}

func strNil(m map[string]any, keys ...string) any {
	if s := str(m, keys...); s != "" {
		return s
	}
	return nil
}

func nullable(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func num(m map[string]any, keys ...string) float64 {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			switch t := v.(type) {
			case float64:
				return t
			case string:
				if f, err := strconv.ParseFloat(strings.TrimSpace(t), 64); err == nil {
					return f
				}
			}
		}
	}
	return 0
}

func tsNil(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func (c *Consumer) dateHour(rec map[string]any) (string, int) {
	s := str(rec, "time", "timeWindowStart", "time_window_start", "startTime", "date")
	if s == "" {
		return "", 0
	}
	loc := c.loc
	if loc == nil {
		loc = time.UTC
	}
	if t, ok := parseEventTime(s, loc); ok {
		t = t.In(loc)
		return t.Format("2006-01-02"), t.Hour()
	}
	if len(s) >= 10 {
		date := s[:10]
		hour := 0
		if idx := strings.IndexAny(s, "T "); idx >= 0 && len(s) >= idx+3 {
			if n, err := strconv.Atoi(s[idx+1 : idx+3]); err == nil {
				hour = n
			}
		}
		return date, hour
	}
	return "", 0
}

func loadLocation(name string) *time.Location {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "America/Sao_Paulo"
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		log.Printf("[ams-stream] timezone invalido %q, usando UTC: %v", name, err)
		return time.UTC
	}
	return loc
}

func parseEventTime(s string, loc *time.Location) (time.Time, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, true
	}
	for _, layout := range []string{
		"2006-01-02 15:04:05",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04",
		"2006-01-02T15:04",
		"2006-01-02",
	} {
		if t, err := time.ParseInLocation(layout, s, loc); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

type targetRecordKey struct {
	Key         string
	KeywordID   string
	TargetID    string
	KeywordText string
	Targeting   string
	MatchType   string
}

func targetEntity(rec map[string]any) (targetRecordKey, bool) {
	adGroupID := str(rec, "adGroupId", "ad_group_id")
	keywordID := str(rec, "keywordId", "keyword_id")
	targetID := str(rec, "targetId", "target_id", "targetingId", "targeting_id")
	keywordText := str(rec, "keywordText", "keyword_text", "keyword", "searchTerm", "search_term")
	targeting := str(rec, "targeting", "targetingText", "targeting_text", "targetExpression")
	matchType := str(rec, "matchType", "match_type")
	switch strings.ToUpper(strings.TrimSpace(matchType)) {
	case "TARGETING_EXPRESSION", "TARGETING_EXPRESSION_PREDEFINED":
		if targetID == "" {
			targetID = keywordID
		}
		keywordID = ""
		if targeting == "" {
			targeting = keywordText
		}
		keywordText = ""
	case "BROAD", "PHRASE", "EXACT":
		// AMS usa keyword_id para keywords e targets; match_type separa o tipo.
	}

	key := ""
	switch {
	case keywordID != "":
		key = "adg:" + adGroupID + "|kwid:" + keywordID
	case targetID != "":
		key = "adg:" + adGroupID + "|tid:" + targetID
	case keywordText != "":
		key = "adg:" + adGroupID + "|kw:" + strings.ToLower(strings.TrimSpace(keywordText)) + "|match:" + strings.ToLower(strings.TrimSpace(matchType))
	case targeting != "":
		key = "adg:" + adGroupID + "|target:" + strings.ToLower(strings.TrimSpace(targeting)) + "|match:" + strings.ToLower(strings.TrimSpace(matchType))
	default:
		return targetRecordKey{}, false
	}

	return targetRecordKey{
		Key:         key,
		KeywordID:   keywordID,
		TargetID:    targetID,
		KeywordText: keywordText,
		Targeting:   targeting,
		MatchType:   matchType,
	}, true
}
