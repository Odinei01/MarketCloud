package main

import (
	"context"
	"log"
	"os"
	"strings"
	"time"
)

// pinOutcomeMeasureMarker identifica este worker no log.
const pinOutcomeMeasureMarker = "marketcloud-pin-outcome-measure-v1"

// runPinOutcomeMeasureLoop mede o resultado de cada pin de keyword x hora e
// escreve de volta no SWARM, fechando o loop de aprendizado do ML.
//
// Existe porque o medidor do SWARM parte de amazon_ads_automation_execution_items
// e o pin da tela nunca cria execution item: em 15/07 havia 53 pins com 0 medidos,
// enquanto as 28.308 mudancas do proprio robo tinham 24.200 medidas. Os cliques
// do dono nao voltavam pro modelo.
//
// Roda a cada 6h: o dado que ele espera (AMS da hora alvo em dias novos) chega
// devagar, entao nao adianta martelar de minuto em minuto.
func (o *orchestrator) runPinOutcomeMeasureLoop(ctx context.Context) {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("PIN_OUTCOME_MEASURE_ENABLED")), "false") {
		log.Printf("[pin-measure] desligado por env marker=%s", pinOutcomeMeasureMarker)
		return
	}
	interval := 6 * time.Hour
	if v := envInt("PIN_OUTCOME_MEASURE_INTERVAL_MINUTES", 0); v > 0 {
		interval = time.Duration(v) * time.Minute
	}
	log.Printf("[pin-measure] loop up interval=%s marker=%s", interval, pinOutcomeMeasureMarker)

	// Primeira passada logo apos subir, pra nao esperar 6h depois de um restart.
	o.measurePinOutcomes(ctx)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.measurePinOutcomes(ctx)
		}
	}
}

func (o *orchestrator) measurePinOutcomes(ctx context.Context) {
	var medidos, pendentes int64
	err := o.db.QueryRow(ctx,
		`SELECT medidos, sem_dado_ainda FROM marketcloud_gold.measure_keyword_pin_outcomes()`,
	).Scan(&medidos, &pendentes)
	if err != nil {
		log.Printf("[pin-measure] falhou: %v", err)
		return
	}
	if medidos > 0 {
		log.Printf("[pin-measure] %d pin(s) medidos e devolvidos ao ML; %d ainda sem volume na hora alvo", medidos, pendentes)
		return
	}
	log.Printf("[pin-measure] nada novo pra medir; %d aguardando volume na hora alvo", pendentes)
}
