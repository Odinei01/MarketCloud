import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

function fmt(n, digits = 0) {
  if (n === null || n === undefined || n === '') return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

function money(n) {
  if (n === null || n === undefined || n === '') return '-'
  return `R$ ${fmt(n, 2)}`
}

function dt(v) {
  if (!v) return '-'
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return '-'
  return d.toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })
}

function dateOnly(v) {
  if (!v) return '-'
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return String(v).slice(0, 10)
  return d.toLocaleDateString('pt-BR')
}

function statusClass(status) {
  if (status === 'COMPLETED' || status === 'TRAINED') return 'ok'
  if (status === 'PARTIAL' || status === 'INSUFFICIENT_DATA') return 'warn'
  return 'bad'
}

function friendlyError(error) {
  if (!error) return ''
  if (/missing authorization header/i.test(error)) {
    return 'A sessao da API esta sem autorizacao em algum bloco. Atualize o login se os dados pararem de mudar; o painel abaixo usa o ultimo retorno valido.'
  }
  return error
}

function runNote(run) {
  if (!run) return '-'
  if (run.status === 'COMPLETED') return 'Rodou completo e escreveu predicoes.'
  if (run.status === 'PARTIAL') {
    return 'Rodou, mas ainda faltam exemplos positivos para todos os modelos deste grao.'
  }
  return 'Precisa de investigacao.'
}

function modelNote(model) {
  if (model.status === 'TRAINED') return 'Modelo apto a entrar nas recomendacoes.'
  if (model.status === 'INSUFFICIENT_DATA') return 'Ainda sem volume positivo suficiente para treinar com confianca.'
  return 'Status tecnico do registro de modelo.'
}

function outcomeClass(label) {
  if (label === 'IMPROVED') return 'ok'
  if (label === 'NEUTRAL' || label === 'NO_DATA') return 'warn'
  return 'bad'
}

function outcomeText(label) {
  if (label === 'IMPROVED') return 'Ganhou ROAS'
  if (label === 'WORSENED') return 'Perdeu ROAS'
  if (label === 'NO_DATA') return 'Sem dado AMS'
  return 'Neutro'
}

function verdictText(verdict) {
  if (verdict === 'MODEL_RIGHT') return 'modelo acertou'
  if (verdict === 'MODEL_WRONG') return 'modelo errou'
  return 'inconclusivo'
}

// Veredito sintetico do aprendizado: conclui pelo operador, honesto sobre
// tamanho de amostra. Impede ler "7 pioraram x 2 melhoraram" fora de contexto.
function learningVerdict(s) {
  const conclusive = Number(s.conclusive || 0)
  const net = Number(s.net_delta_sales || 0)
  if (s.sample === 'PEQUENA' || s.verdict === 'INCONCLUSIVO') {
    return {
      cls: 'warn',
      title: 'Amostra ainda pequena — nao conclua',
      body: `So ${conclusive} medicoes conclusivas em 24h (${fmt(s.neutral)} neutras). Poucas mudancas fecharam janela; espere volume antes de mexer no robo.`,
    }
  }
  if (s.verdict === 'POSITIVO') {
    return { cls: 'ok', title: 'Efeito liquido POSITIVO', body: `${fmt(s.improved)} melhoraram x ${fmt(s.worsened)} pioraram em 24h; venda liquida ${money(net)}.` }
  }
  if (s.verdict === 'NEGATIVO') {
    return { cls: 'bad', title: 'Efeito liquido NEGATIVO — revisar', body: `${fmt(s.worsened)} pioraram x ${fmt(s.improved)} melhoraram em 24h; venda liquida ${money(net)}. Verifique holdout antes de culpar o robo.` }
  }
  return { cls: 'warn', title: 'Efeito liquido neutro', body: `${fmt(s.improved)} melhoraram x ${fmt(s.worsened)} pioraram; venda liquida ${money(net)}.` }
}

function auditClass(result) {
  if (result === 'WINNING') return 'ok'
  if (result === 'LOSING') return 'bad'
  return 'warn'
}

function auditText(result) {
  if (result === 'WINNING') return 'ganhando'
  if (result === 'LOSING') return 'perdendo'
  if (result === 'NEUTRAL') return 'neutro'
  return 'aguardando AMS'
}

function auditModelText(result) {
  if (result === 'MODEL_RIGHT') return 'modelo acertou'
  if (result === 'MODEL_WRONG') return 'modelo errou'
  return 'sem conclusao'
}

function decisionClass(decision) {
  if (decision === 'APLICAR' || decision === 'APLICAR_SEGURANCA') return 'ok'
  if (decision === 'TESTAR_CONTROLADO' || decision === 'AGUARDAR_DADOS') return 'warn'
  return 'bad'
}

function decisionText(decision) {
  if (decision === 'APLICAR') return 'Aplicar'
  if (decision === 'APLICAR_SEGURANCA') return 'Aplicar seguranca'
  if (decision === 'TESTAR_CONTROLADO') return 'Teste controlado'
  if (decision === 'AGUARDAR_DADOS') return 'Aguardar dados'
  if (decision === 'BLOQUEAR') return 'Bloquear'
  return decision || '-'
}

function qualityClass(status) {
  if (status === 'MATURE_RECONCILED' || status === 'DELTA_ONLY') return 'ok'
  if (status === 'FRESH' || status === 'ATTRIBUTING') return 'warn'
  return 'bad'
}

function qualityText(status) {
  if (status === 'MATURE_RECONCILED') return 'Maduro OK'
  if (status === 'DELTA_ONLY') return 'Delta AMS'
  if (status === 'FRESH') return 'Fresco'
  if (status === 'ATTRIBUTING') return 'Atribuindo'
  if (status === 'ADS_MISSING') return 'Ads faltando'
  if (status === 'DIVERGENT') return 'Divergente'
  return status || '-'
}

function windowCell(row, suffix) {
  const label = row[`outcome_label_${suffix}`]
  const before = row[`baseline_roas_${suffix}`]
  const after = row[`eval_roas_${suffix}`]
  const delta = row[`delta_roas_${suffix}`]
  if (!label) return <span className="muted">pendente</span>
  return (
    <div className="window-cell">
      <span className={`pill ${outcomeClass(label)}`}>{outcomeText(label)}</span>
      <small>{fmt(before, 2)} {'->'} {fmt(after, 2)} <b className={Number(delta || 0) >= 0 ? 'delta-pos' : 'delta-neg'}>{fmt(delta, 2)}</b></small>
    </div>
  )
}

function latestRun(runs, kind) {
  return runs.find(r => r.run_kind === kind)
}

function metric(model, key) {
  const raw = model?.metrics_json
  if (!raw) return null
  let obj = raw
  if (typeof raw === 'string') {
    try {
      obj = JSON.parse(raw || '{}')
    } catch {
      obj = {}
    }
  }
  return obj?.[key]
}

const DEFAULT_STATUS_DATA = { totals: {}, models: [], ml_runs: [], ams_hours: [], learning_outcomes: [], audit_360: [], audit_360_summary: {}, full_control_360_summary: {}, full_control_360: [], ams_quality_summary: [], ams_quality_divergences: [], ads_reprocess_requests: [], ads_reprocess_health: [], ml_training_volume: [], ams_target_quality_summary: [], ams_target_quality_divergences: [], operational_alerts: [] }

export default function StatusAmsMl({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState(DEFAULT_STATUS_DATA)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [updatedAt, setUpdatedAt] = useState(null)
  const [activeTab, setActiveTab] = useState('overview')

  const load = useCallback(async () => {
    setError('')
    const res = await api.goldMlAmsStatus(tenantID)
    if (res.ok) {
      setData(res.data || DEFAULT_STATUS_DATA)
      setUpdatedAt(new Date())
    } else {
      setError(res.data?.error || `Falha ao carregar (${res.status})`)
    }
    setLoading(false)
  }, [tenantID])

  useEffect(() => {
    load()
    const t = setInterval(load, 60000)
    return () => clearInterval(t)
  }, [load])

  const totals = data.totals || {}
  const runs = data.ml_runs || []
  const hours = data.ams_hours || []
  const models = data.models || []
  const learning = data.learning_outcomes || []
  const audit360 = data.audit_360 || []
  const auditSummary = data.audit_360_summary || {}
  const fc360Summary = data.full_control_360_summary || {}
  const fullControl360 = data.full_control_360 || []
  const learningSummary = data.learning_summary || {}
  const holdout = data.holdout || {}
  const qualitySummary = data.ams_quality_summary || []
  const qualityDivergences = data.ams_quality_divergences || []
  const reprocessRequests = data.ads_reprocess_requests || []
  const reprocessHealth = data.ads_reprocess_health || []
  const trainingVolume = data.ml_training_volume || []
  const targetQualitySummary = data.ams_target_quality_summary || []
  const targetQualityDivergences = data.ams_target_quality_divergences || []
  const operationalAlerts = data.operational_alerts || []

  const latest = useMemo(() => ({
    campaign: latestRun(runs, 'hourly_real_v2'),
    target: latestRun(runs, 'hourly_target_real_v3'),
  }), [runs])

  const targetModelsPending = models.filter(m => String(m.model_name || '').includes('HourlyTarget') && m.status === 'INSUFFICIENT_DATA')
  const hasAms = Number(totals.campaign_rows || 0) > 0 && Number(totals.target_rows || 0) > 0
  const hasConversions = Number(totals.ams_orders_7d || 0) > 0 || Number(totals.ams_sales_7d || 0) > 0
  const targetMlReady = targetModelsPending.length === 0
  const authError = friendlyError(error)
  const volumeBySource = useMemo(() => {
    const map = {}
    trainingVolume.forEach(row => { map[row.source] = row })
    return map
  }, [trainingVolume])
  const campaignGold = volumeBySource.campaign_hour_gold || {}
  const targetReconciled = volumeBySource.target_hour_reconciled || {}
  const amcContext = volumeBySource.amc_daily_total_context || {}
  const targetClickModel = models.find(m => m.model_name === 'HourlyTargetClickRealV3')
  const targetConversionModel = models.find(m => m.model_name === 'HourlyTargetConversionRealV3')
  const targetRoasModel = models.find(m => m.model_name === 'HourlyTargetExpectedRoasRealV3')
  const campaignConversionModel = models.find(m => m.model_name === 'HourlyConversionRealV2')
  const campaignRoasModel = models.find(m => m.model_name === 'HourlyExpectedRoasRealV2')
  const targetOrderAuc = metric(targetConversionModel, 'roc_auc')
  const targetOrderBaseline = metric(targetConversionModel, 'baseline_hourrate_auc')
  const targetRoasMae = metric(targetRoasModel, 'mae')
  const targetRoasBaseline = metric(targetRoasModel, 'baseline_hourmean_mae')
  const campaignOrderAuc = metric(campaignConversionModel, 'roc_auc')
  const campaignRoasMae = metric(campaignRoasModel, 'mae')
  const hasLearningSignal = useCallback(row => Number(row.eval_spend || 0) >= 5 || Number(row.eval_orders || 0) > 0 || Math.abs(Number(row.delta_roas || 0)) >= 0.5, [])
  const usefulLearning = learning.filter(hasLearningSignal)
  const noisyLearning = learning.filter(row => !hasLearningSignal(row))
  const totalQualityRows = qualitySummary.reduce((acc, r) => acc + Number(r.rows || 0), 0)
  const criticalQualityRows = qualitySummary
    .filter(r => ['DIVERGENT', 'ADS_MISSING', 'LOW_CONFIDENCE'].includes(r.data_quality_status))
    .reduce((acc, r) => acc + Number(r.rows || 0), 0)
  const completedReportGrains = reprocessHealth.filter(r => r.grain_status === 'COMPLETED').length
  const criticalTargetRows = targetQualitySummary
    .filter(r => ['DIVERGENT', 'ADS_TARGETING_MISSING'].includes(r.target_quality_status))
    .reduce((acc, r) => acc + Number(r.rows || 0), 0)
  const criticalOpsAlerts = operationalAlerts.filter(a => a.severity === 'critical').length
  const tabs = [
    { id: 'overview', label: 'Visao geral', note: 'saude' },
    { id: 'ams', label: 'AMS / Dados', note: `${fmt(totalQualityRows)} dias` },
    { id: 'robot', label: 'Robo / Acoes', note: `${fmt(auditSummary.total || 0)} acoes` },
    { id: 'ml', label: 'ML / Aprendizado', note: `${fmt(learning.length)} medicoes` },
    { id: 'audit', label: 'Auditoria tecnica', note: `${fmt(runs.length)} runs` },
  ]

  return (
    <div className="page status-page">
      <div className="page-head">
        <div>
          <h2>Status AMS + ML</h2>
          <span className="sub">O que chegou da Amazon, o que foi gravado no lake e o que o ML usou na ultima hora</span>
        </div>
        <div className="head-actions">
          <span className="last">Atualizado {updatedAt ? dt(updatedAt) : '-'}</span>
          <button className="btn" onClick={load}>Atualizar</button>
        </div>
      </div>

      {authError && <div className="notice warn">{authError}</div>}

      <nav className="status-tabs" aria-label="Status AMS ML secoes">
        {tabs.map(tab => (
          <button
            key={tab.id}
            type="button"
            className={`status-tab ${activeTab === tab.id ? 'active' : ''}`}
            onClick={() => setActiveTab(tab.id)}
          >
            <span>{tab.label}</span>
            <small>{tab.note}</small>
          </button>
        ))}
      </nav>

      <section className="section-band compact-alerts">
        <div className="section-head">
          <div>
            <h3>Alertas operacionais</h3>
            <p>Reprocessamento oficial, qualidade target e frescor do ML.</p>
          </div>
          <span>{fmt(operationalAlerts.length)} ativos</span>
        </div>
        <div className="alert-list">
          {operationalAlerts.slice(0, 6).map(alert => (
            <div className={`alert-row ${alert.severity === 'critical' ? 'bad' : 'warn'}`} key={alert.alert_key}>
              <span className={`pill ${alert.severity === 'critical' ? 'bad' : 'warn'}`}>{alert.severity}</span>
              <b>{alert.title}</b>
              <small>{alert.detail}</small>
            </div>
          ))}
          {!operationalAlerts.length && (
            <div className="alert-row ok">
              <span className="pill ok">ok</span>
              <b>Sem alerta operacional ativo</b>
              <small>Reports oficiais completos, ML fresco e sem divergencia critica aberta.</small>
            </div>
          )}
        </div>
      </section>

      {activeTab === 'overview' && (
        <>
      <section className="ops-grid">
        <div className={`ops-card ${Number(targetReconciled.orders || 0) > 0 ? 'ok' : 'warn'}`}>
          <span className="ops-label">1. Treino target V3</span>
          <b>{fmt(latest.target?.training_rows || targetConversionModel?.training_rows)} células</b>
          <small>{fmt(latest.target?.positive_order_rows || metric(targetConversionModel, 'positives'))} células com pedido / {fmt(latest.target?.positive_click_rows || metric(targetClickModel, 'positives'))} com clique</small>
        </div>
        <div className={`ops-card ${Number(campaignGold.orders || 0) > 0 ? 'ok' : 'warn'}`}>
          <span className="ops-label">2. Campanha/hora Gold</span>
          <b>{fmt(campaignGold.orders)} pedidos</b>
          <small>{fmt(campaignGold.rows)} linhas / {money(campaignGold.sales)} vendas atribuídas Ads</small>
        </div>
        <div className={`ops-card ${Number(targetReconciled.orders || 0) > 0 ? 'ok' : 'warn'}`}>
          <span className="ops-label">3. Target/hora reconciliado</span>
          <b>{fmt(targetReconciled.orders)} pedidos</b>
          <small>{fmt(targetReconciled.targets)} targets / {money(targetReconciled.sales)} vendas para treino granular</small>
        </div>
        <div className={`ops-card ${targetMlReady ? 'ok' : 'warn'}`}>
          <span className="ops-label">4. ML Target V3</span>
          <b>{targetMlReady ? 'Completo' : 'Parcial'}</b>
          <small>AUC pedido {fmt(metric(targetConversionModel, 'roc_auc'), 3)} vs baseline {fmt(metric(targetConversionModel, 'baseline_hourrate_auc'), 3)} - {fmt(totals.target_predictions)} predições</small>
        </div>
      </section>

      <section className="readout">
        <h3>Leitura rapida</h3>
        <ul>
          <li><b>O ML nao depende mais só do AMS cru:</b> antes de 13/07 ele usa Ads Reporting v3 como backfill; depois disso usa AMS target horário.</li>
          <li><b>Campanha/hora:</b> {fmt(campaignGold.orders)} pedidos atribuídos Ads no Gold; o modelo {latest.campaign?.status || '-'} escreveu {fmt(latest.campaign?.predictions_written)} predições.</li>
          <li><b>Keyword-target/hora:</b> {fmt(targetReconciled.orders)} pedidos granulares reconciliados; o V3 {latest.target?.status || '-'} escreveu {fmt(latest.target?.predictions_written)} predições.</li>
          <li><b>AMC total:</b> {fmt(amcContext.orders)} pedidos ficam como contexto/calibração diária; não viram label de keyword/hora sem atribuição segura.</li>
        </ul>
      </section>

      <div className="kpi-row">
        <div className="kpi"><div className="kpi-v">{fmt(targetReconciled.rows)}</div><div className="kpi-l">Linhas target/hora reconciliadas antes da agregação</div></div>
        <div className="kpi"><div className="kpi-v">{fmt(latest.target?.positive_order_rows)}</div><div className="kpi-l">Células target/hora com pedido usadas no V3</div></div>
        <div className="kpi"><div className="kpi-v">{fmt(amcContext.orders)}</div><div className="kpi-l">Pedidos AMC totais usados como contexto</div></div>
        <div className="kpi"><div className="kpi-v">{money(targetReconciled.sales)}</div><div className="kpi-l">Vendas granulares para treino target</div></div>
      </div>

      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Base que o ML esta usando</h3>
            <p>Separa label treinável de contexto. Assim não misturamos AMS fresco, Ads report e AMC total como se fossem a mesma coisa.</p>
          </div>
          <span>{fmt(trainingVolume.length)} fontes</span>
        </div>
        <div className="training-grid">
          {trainingVolume.map(row => (
            <div className="training-card" key={row.source}>
              <span>{row.source === 'campaign_hour_gold' ? 'Campanha/hora' : row.source === 'target_hour_reconciled' ? 'Keyword-target/hora' : 'AMC total diário'}</span>
              <b>{fmt(row.orders)} pedidos</b>
              <small>{fmt(row.rows)} linhas · {fmt(row.campaigns)} campanhas · {fmt(row.targets)} targets · {dateOnly(row.min_date)} a {dateOnly(row.max_date)}</small>
            </div>
          ))}
        </div>
      </section>

      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Confianca dos modelos</h3>
            <p>Compara o ML contra uma regra simples por hora. Quanto maior o AUC, melhor a separação; quanto menor o MAE, menor o erro de ROAS.</p>
          </div>
          <span>última rodada</span>
        </div>
        <div className="model-metrics-grid">
          <div className="metric-card ok"><span>Target clique</span><b>AUC {fmt(metric(targetClickModel, 'roc_auc'), 3)}</b><small>baseline {fmt(metric(targetClickModel, 'baseline_hourrate_auc'), 3)} · {fmt(metric(targetClickModel, 'positives'))} positivos</small></div>
          <div className="metric-card ok"><span>Target pedido</span><b>AUC {fmt(metric(targetConversionModel, 'roc_auc'), 3)}</b><small>baseline {fmt(metric(targetConversionModel, 'baseline_hourrate_auc'), 3)} · {fmt(metric(targetConversionModel, 'positives'))} positivos</small></div>
          <div className="metric-card ok"><span>Target ROAS</span><b>MAE {fmt(metric(targetRoasModel, 'mae'), 3)}</b><small>baseline {fmt(metric(targetRoasModel, 'baseline_hourmean_mae'), 3)} · {fmt(metric(targetRoasModel, 'nonzero'))} nonzero</small></div>
          <div className="metric-card ok"><span>Campanha pedido</span><b>AUC {fmt(metric(campaignConversionModel, 'roc_auc'), 3)}</b><small>baseline {fmt(metric(campaignConversionModel, 'baseline_hourrate_auc'), 3)} · {fmt(metric(campaignConversionModel, 'positives'))} positivos</small></div>
          <div className="metric-card ok"><span>Campanha ROAS</span><b>MAE {fmt(metric(campaignRoasModel, 'mae'), 3)}</b><small>baseline {fmt(metric(campaignRoasModel, 'baseline_hourmean_mae'), 3)}</small></div>
        </div>
      </section>
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Alertas para decidir agora</h3>
            <p>Resumo executivo. Use as abas quando precisar investigar a causa.</p>
          </div>
          <span>{fmt(criticalQualityRows + criticalOpsAlerts)} alertas de dados</span>
        </div>
        <div className="decision-grid">
          <div className={`decision-card ${criticalQualityRows > 0 ? 'warn' : 'ok'}`}>
            <span>Dados Amazon</span>
            <b>{criticalQualityRows > 0 ? 'Revisar divergencias' : 'Sem alerta critico'}</b>
            <small>{fmt(criticalQualityRows)} campanha-dias precisam de reprocessamento/investigacao.</small>
          </div>
          <div className={`decision-card ${Number(auditSummary.losing || 0) > 0 ? 'warn' : 'ok'}`}>
            <span>Robo</span>
            <b>{fmt(auditSummary.winning)} ganhando / {fmt(auditSummary.losing)} perdendo</b>
            <small>{fmt(auditSummary.pending)} acoes ainda aguardam janela AMS.</small>
          </div>
          <div className={`decision-card ${learningSummary.sample === 'PEQUENA' ? 'warn' : 'ok'}`}>
            <span>Aprendizado</span>
            <b>{learningSummary.verdict || 'Sem veredito'}</b>
            <small>{fmt(learningSummary.conclusive)} medicoes conclusivas em 24h.</small>
          </div>
        </div>
      </section>
        </>
      )}

      {activeTab === 'ams' && (
        <>
      <section className="tab-brief">
        <div className="brief-card ok">
          <span>Fonte bruta AMS</span>
          <b>{fmt(totals.campaign_rows)} campanha / {fmt(totals.target_rows)} target</b>
          <small>Ultima campanha {dt(totals.last_ams_update)}; ultima target {dt(totals.last_target_update)}</small>
        </div>
        <div className={`brief-card ${Number(campaignGold.orders || 0) > 0 ? 'ok' : 'warn'}`}>
          <span>Gold campanha/hora</span>
          <b>{fmt(campaignGold.orders)} pedidos</b>
          <small>{fmt(campaignGold.rows)} linhas reconciliadas; {money(campaignGold.sales)} vendas Ads</small>
        </div>
        <div className={`brief-card ${Number(targetReconciled.orders || 0) > 0 ? 'ok' : 'warn'}`}>
          <span>Gold target/hora</span>
          <b>{fmt(targetReconciled.orders)} pedidos</b>
          <small>{fmt(targetReconciled.targets)} targets; {money(targetReconciled.sales)} vendas para treino granular</small>
        </div>
        <div className={`brief-card ${criticalQualityRows + criticalTargetRows > 0 ? 'warn' : 'ok'}`}>
          <span>Qualidade</span>
          <b>{fmt(criticalQualityRows + criticalTargetRows)} alertas</b>
          <small>{fmt(completedReportGrains)} reports oficiais completos no health atual</small>
        </div>
      </section>
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Qualidade AMS x Ads</h3>
            <p>Compara AMS com a fonte Ads diaria existente. Fresh/atribuindo pode mudar; divergente ou Ads faltando exige reprocessamento oficial.</p>
          </div>
          <span>{fmt(qualitySummary.reduce((acc, r) => acc + Number(r.rows || 0), 0))} campanha-dias</span>
        </div>
        <div className="quality-grid">
          {qualitySummary.map(row => (
            <div className={`quality-card ${qualityClass(row.data_quality_status)}`} key={`${row.data_quality_status}-${row.operator_action}`}>
              <span>{qualityText(row.data_quality_status)}</span>
              <b>{fmt(row.rows)}</b>
              <small>score {fmt(row.avg_quality_score, 1)} - delta gasto {money(row.delta_ads_spend)} - acao: {row.operator_action}</small>
            </div>
          ))}
          {!qualitySummary.length && <div className="empty-cell">Sem score AMS x Ads ainda.</div>}
        </div>
        <div className="table-wrap quality-table">
          <table>
            <thead>
              <tr>
                <th>Data</th>
                <th>Campanha</th>
                <th>Status</th>
                <th>Score</th>
                <th>AMS gasto</th>
                <th>Ads gasto</th>
                <th>Delta gasto</th>
                <th>AMS ped.</th>
                <th>Ads ped.</th>
                <th>Acao</th>
              </tr>
            </thead>
            <tbody>
              {qualityDivergences.map(row => (
                <tr key={`${row.data_date}-${row.campaign_id}-${row.data_quality_status}`}>
                  <td>{dateOnly(row.data_date)}</td>
                  <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.campaign_id}</span></td>
                  <td><span className={`pill ${qualityClass(row.data_quality_status)}`}>{qualityText(row.data_quality_status)}</span></td>
                  <td className="num">{fmt(row.data_quality_score)}</td>
                  <td className="num">{money(row.ams_spend)}</td>
                  <td className="num">{money(row.ads_spend)}</td>
                  <td className={`num ${Number(row.delta_ads_spend || 0) >= 0 ? 'delta-pos' : 'delta-neg'}`}>{money(row.delta_ads_spend)}</td>
                  <td className="num">{fmt(row.ams_orders_7d)}</td>
                  <td className="num">{fmt(row.ads_orders)}</td>
                  <td>{row.operator_action}</td>
                </tr>
              ))}
              {!qualityDivergences.length && <tr><td colSpan="10" className="empty-cell">Sem divergencias criticas abertas.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="table-wrap reprocess-table">
          <table>
            <thead>
              <tr>
                <th>Janela</th>
                <th>Data</th>
                <th>Status</th>
                <th>Motivo</th>
                <th>Atualizado</th>
              </tr>
            </thead>
            <tbody>
              {reprocessRequests.map(row => (
                <tr key={row.id}>
                  <td><b>{row.window_label}</b></td>
                  <td>{dateOnly(row.data_date)}</td>
                  <td><span className={`pill ${row.status === 'COMPLETED' ? 'ok' : row.status === 'RUNNING' ? 'warn' : 'bad'}`}>{row.status}</span></td>
                  <td>{row.reason}</td>
                  <td>{dt(row.updated_at)}</td>
                </tr>
              ))}
              {!reprocessRequests.length && <tr><td colSpan="5" className="empty-cell">Sem janelas D-1/D-3/D-7/D-14 registradas.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="section-head subhead">
          <div>
            <h3>Reports oficiais por grao</h3>
            <p>Mostra se cada janela ja fechou campanha, grupo, keyword e target no Ads Reporting v3.</p>
          </div>
          <span>{fmt(completedReportGrains)} de {fmt(reprocessHealth.length)} completos</span>
        </div>
        <div className="table-wrap reprocess-health-table">
          <table>
            <thead>
              <tr>
                <th>Janela</th>
                <th>Data</th>
                <th>Grao</th>
                <th>Status grao</th>
                <th>Linhas</th>
                <th>Report ID</th>
                <th>Atualizado</th>
              </tr>
            </thead>
            <tbody>
              {reprocessHealth.map(row => (
                <tr key={`${row.id}-${row.grain}`}>
                  <td><b>{row.window_label}</b></td>
                  <td>{dateOnly(row.data_date)}</td>
                  <td>{row.grain}</td>
                  <td><span className={`pill ${row.grain_status === 'COMPLETED' ? 'ok' : row.grain_status === 'PENDING' || row.grain_status === 'RUNNING' ? 'warn' : 'bad'}`}>{row.grain_status || '-'}</span></td>
                  <td className="num">{fmt(row.rows_ingested)}</td>
                  <td><span className="row-sub">{row.report_id || '-'}</span></td>
                  <td>{dt(row.updated_at)}</td>
                </tr>
              ))}
              {!reprocessHealth.length && <tr><td colSpan="7" className="empty-cell">Sem health por grao ainda.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Qualidade keyword/target</h3>
            <p>Compara AMS keyword-target com Ads Reporting v3 targeting. Isso alimenta a confianca do ML target.</p>
          </div>
          <span>{fmt(criticalTargetRows)} alertas finos</span>
        </div>
        <div className="quality-grid">
          {targetQualitySummary.map(row => (
            <div className={`quality-card ${qualityClass(row.target_quality_status === 'MATCH' ? 'MATURE_RECONCILED' : row.target_quality_status === 'ADS_TARGETING_MISSING' ? 'ADS_MISSING' : row.target_quality_status)}`} key={`${row.target_quality_status}-${row.ads_report_grain}`}>
              <span>{row.ads_report_grain}</span>
              <b>{fmt(row.rows)}</b>
              <small>{row.target_quality_status} - score {fmt(row.avg_quality_score, 1)} - delta gasto {money(row.delta_spend)}</small>
            </div>
          ))}
          {!targetQualitySummary.length && <div className="empty-cell">Sem score keyword/target ainda.</div>}
        </div>
        <div className="table-wrap quality-table">
          <table>
            <thead>
              <tr>
                <th>Data</th>
                <th>Campanha</th>
                <th>Grupo</th>
                <th>Keyword/Target</th>
                <th>Status</th>
                <th>AMS gasto</th>
                <th>Ads gasto</th>
                <th>Delta</th>
                <th>AMS ped.</th>
                <th>Ads ped.</th>
              </tr>
            </thead>
            <tbody>
              {targetQualityDivergences.map(row => (
                <tr key={`${row.data_date}-${row.campaign_id}-${row.ad_group_id}-${row.target_entity_key}`}>
                  <td>{dateOnly(row.data_date)}</td>
                  <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.campaign_id}</span></td>
                  <td>{row.ad_group_name || row.ad_group_id || '-'}</td>
                  <td><b>{row.target_text || row.target_entity_key || '-'}</b><span className="row-sub">{row.match_type} / {row.ads_report_grain}</span></td>
                  <td><span className={`pill ${row.target_quality_status === 'DIVERGENT' || row.target_quality_status === 'ADS_TARGETING_MISSING' ? 'bad' : 'warn'}`}>{row.target_quality_status}</span></td>
                  <td className="num">{money(row.ams_spend)}</td>
                  <td className="num">{money(row.ads_spend)}</td>
                  <td className={`num ${Number(row.delta_spend || 0) >= 0 ? 'delta-pos' : 'delta-neg'}`}>{money(row.delta_spend)}</td>
                  <td className="num">{fmt(row.ams_orders)}</td>
                  <td className="num">{fmt(row.ads_orders)}</td>
                </tr>
              ))}
              {!targetQualityDivergences.length && <tr><td colSpan="10" className="empty-cell">Sem divergencias finas abertas.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>
        </>
      )}

      {activeTab === 'robot' && (
        <>
      <section className="tab-brief">
        <div className={`brief-card ${Number(auditSummary.losing || 0) > 0 ? 'warn' : 'ok'}`}>
          <span>Bid auto aplicado</span>
          <b>{fmt(auditSummary.winning)} ganhando / {fmt(auditSummary.losing)} perdendo</b>
          <small>{fmt(auditSummary.pending)} aguardam a janela AMS fechar para medir</small>
        </div>
        <div className={`brief-card ${Number(fc360Summary.bloquear || 0) > 0 ? 'warn' : 'ok'}`}>
          <span>Full Control 360</span>
          <b>{fmt(fc360Summary.aplicar)} aplicar / {fmt(fc360Summary.testar)} testar</b>
          <small>{fmt(fc360Summary.bloquear)} bloqueadas por guardrail; {fmt(fc360Summary.pending_execution)} pendentes de execucao</small>
        </div>
        <div className="brief-card ok">
          <span>Dado usado para medir</span>
          <b>{fmt(campaignGold.orders)} pedidos campanha</b>
          <small>{fmt(targetReconciled.orders)} pedidos target; efeito vem do Gold, nao do AMS cru</small>
        </div>
        <div className="brief-card warn">
          <span>Regra de leitura</span>
          <b>So conta depois da janela</b>
          <small>1h e 3h sao sinais rapidos; 24h e 7d sao mais confiaveis para decisao.</small>
        </div>
      </section>
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>360 Full-auto</h3>
            <p>Uma linha por alteracao feita pelo ML: proposta, bid aplicado e resultado AMS depois de 1h, 3h e 24h.</p>
          </div>
          <span>{fmt(auditSummary.total)} alteracoes</span>
        </div>
        <div className="audit-score">
          <div><span>Pendentes</span><b>{fmt(auditSummary.pending)}</b></div>
          <div><span>Ganhando</span><b className="good">{fmt(auditSummary.winning)}</b></div>
          <div><span>Perdendo</span><b className="bad-text">{fmt(auditSummary.losing)}</b></div>
          <div><span>Modelo acertou</span><b>{fmt(auditSummary.model_right)}</b></div>
          <div><span>Modelo errou</span><b>{fmt(auditSummary.model_wrong)}</b></div>
        </div>
        <div className="table-wrap audit-table">
          <table>
            <thead>
              <tr>
                <th>Campanha</th>
                <th>Hora</th>
                <th>Modelo sugeriu</th>
                <th>Robo aplicou</th>
                <th>Quando</th>
                <th>1h</th>
                <th>3h</th>
                <th>24h</th>
                <th>Status</th>
                <th>Leitura</th>
              </tr>
            </thead>
            <tbody>
              {audit360.map(row => (
                <tr key={row.recommendation_id}>
                  <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.recommendation_id}</span></td>
                  <td className="num">{row.event_hour !== null && row.event_hour !== undefined ? `${String(row.event_hour).padStart(2, '0')}h` : '-'}</td>
                  <td>{row.recommended_action || '-'} <span className="muted">{row.recommended_bid_multiplier ? `${fmt(Number(row.recommended_bid_multiplier) * 100)}%` : ''}</span></td>
                  <td>{row.decided_action || '-'} <span className="muted">{row.decided_bid_multiplier ? `${fmt(Number(row.decided_bid_multiplier) * 100)}%` : ''}</span></td>
                  <td>{dt(row.executed_at)}</td>
                  <td>{windowCell(row, '1h')}</td>
                  <td>{windowCell(row, '3h')}</td>
                  <td>{windowCell(row, '24h')}</td>
                  <td><span className={`pill ${auditClass(row.audit_result)}`}>{auditText(row.audit_result)}</span></td>
                  <td>{auditModelText(row.model_result)}</td>
                </tr>
              ))}
              {!audit360.length && <tr><td colSpan="10" className="empty-cell">Ainda nao ha alteracoes full-auto registradas.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>ML 360 proposto</h3>
            <p>Budget, stop-loss e placement com classificacao operacional: aplicar, testar, aguardar ou bloquear. So vira medicao quando um executor real registrar EXECUTED.</p>
          </div>
          <span>{fmt(fullControl360.length)} propostas</span>
        </div>
        <div className="audit-score">
          <div><span>Aplicar</span><b className="good">{fmt(fc360Summary.aplicar)}</b></div>
          <div><span>Testar</span><b>{fmt(fc360Summary.testar)}</b></div>
          <div><span>Aguardar</span><b>{fmt(fc360Summary.aguardar)}</b></div>
          <div><span>Bloquear</span><b className="bad-text">{fmt(fc360Summary.bloquear)}</b></div>
          <div><span>Executar</span><b>{fmt(fc360Summary.pending_execution)}</b></div>
        </div>
        <div className="table-wrap audit-table">
          <table>
            <thead>
              <tr>
                <th>Campanha</th>
                <th>Hora</th>
                <th>Acao 360</th>
                <th>Decisao</th>
                <th>Atual</th>
                <th>Sugerido</th>
                <th>ROAS ML</th>
                <th>P(conv.)</th>
                <th>Delta esperado</th>
                <th>Conf.</th>
                <th>Guardrail</th>
                <th>Execucao</th>
                <th>Resultado</th>
              </tr>
            </thead>
            <tbody>
              {fullControl360.map(row => (
                <tr key={row.recommendation_id}>
                  <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.recommendation_id}</span></td>
                  <td className="num">{row.event_hour !== null && row.event_hour !== undefined ? `${String(row.event_hour).padStart(2, '0')}h` : '-'}</td>
                  <td>{row.action_type}</td>
                  <td><span className={`pill ${decisionClass(row.operator_decision)}`}>{decisionText(row.operator_decision)}</span><span className="row-sub">{row.data_sufficiency || '-'}</span></td>
                  <td className="num">{fmt(row.current_value, 2)}</td>
                  <td className="num">{fmt(row.recommended_value, 2)}</td>
                  <td className="num">{fmt(row.expected_roas, 2)}</td>
                  <td className="num">{fmt(Number(row.conversion_probability || 0) * 100, 1)}%</td>
                  <td className="num">
                    <b className={Number(row.expected_delta_sales || 0) >= 0 ? 'delta-pos' : 'delta-neg'}>{money(row.expected_delta_sales)}</b>
                    <span className="row-sub">gasto {money(row.expected_delta_spend)} / ROAS {fmt(row.expected_delta_roas, 2)}</span>
                  </td>
                  <td><span className={`pill ${row.confidence === 'HIGH' ? 'ok' : row.confidence === 'LOW' ? 'bad' : 'warn'}`}>{row.confidence}</span></td>
                  <td><span className={`pill ${row.guardrail_status === 'READY' ? 'ok' : 'warn'}`}>{row.guardrail_status}</span></td>
                  <td><span className={`pill ${row.execution_status === 'EXECUTED' ? 'ok' : 'warn'}`}>{row.execution_status || 'NOT_EXECUTED'}</span><span className="row-sub">{row.execution_strategy}</span></td>
                  <td><span className={`pill ${auditClass(row.audit_result)}`}>{auditText(row.audit_result)}</span><span className="row-sub">{row.operator_reason || row.reason || '-'}</span></td>
                </tr>
              ))}
              {!fullControl360.length && <tr><td colSpan="13" className="empty-cell">Ainda nao ha recomendacoes 360 de budget/placement/stop-loss.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>
        </>
      )}

      {activeTab === 'ml' && (
        <>
      <section className="tab-brief">
        <div className="brief-card ok">
          <span>Treino target V3</span>
          <b>{fmt(latest.target?.training_rows || targetConversionModel?.training_rows)} celulas</b>
          <small>{fmt(latest.target?.positive_order_rows || metric(targetConversionModel, 'positives'))} com pedido; {fmt(latest.target?.positive_click_rows || metric(targetClickModel, 'positives'))} com clique</small>
        </div>
        <div className="brief-card ok">
          <span>Pedido target</span>
          <b>AUC {fmt(targetOrderAuc, 3)}</b>
          <small>Baseline {fmt(targetOrderBaseline, 3)}. Quanto maior, melhor separa horas com pedido.</small>
        </div>
        <div className="brief-card ok">
          <span>ROAS target</span>
          <b>MAE {fmt(targetRoasMae, 3)}</b>
          <small>Baseline {fmt(targetRoasBaseline, 3)}. Quanto menor, menor erro medio.</small>
        </div>
        <div className={`brief-card ${learningSummary.sample === 'PEQUENA' ? 'warn' : 'ok'}`}>
          <span>Medicao util pos-acao</span>
          <b>{fmt(usefulLearning.length)} de {fmt(learning.length)}</b>
          <small>{fmt(noisyLearning.length)} sem gasto/pedido suficiente; holdout {fmt(holdout.control_cells)} controle / {fmt(holdout.treatment_cells)} robo</small>
        </div>
      </section>
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Aprendizado pos-acao util</h3>
            <p>Mostra apenas janelas com gasto, pedido ou mudanca material de ROAS. Eventos sem volume ficam separados para nao parecerem aprendizado real.</p>
          </div>
          <span>{fmt(usefulLearning.length)} uteis / {fmt(noisyLearning.length)} sem sinal</span>
        </div>
        {learningSummary.verdict && (() => {
          const v = learningVerdict(learningSummary)
          return (
            <div className={`verdict-banner ${v.cls}`}>
              <b>{v.title}</b>
              <span>{v.body}</span>
            </div>
          )
        })()}
        {!usefulLearning.length && (
          <div className="no-learning-signal">
            <b>Nenhuma medicao conclusiva ainda</b>
            <span>As alteracoes registradas nesta amostra cairam em janelas sem gasto/pedido suficiente. O robô aplicou, mas o AMS ainda nao trouxe sinal economico para dizer se ganhou ou perdeu.</span>
            <small>Acao pratica: nao mudar regra por essa tabela; aguardar novas horas com trafego ou revisar se as campanhas full-auto estao recebendo impressao suficiente.</small>
          </div>
        )}
        <div className="table-wrap learning-table">
          <table>
            <thead>
              <tr>
                <th>Campanha</th>
                <th>Hora</th>
                <th>Proposta do modelo</th>
                <th>Acao aplicada</th>
                <th>Aplicado em</th>
                <th>Janela</th>
                <th>Volume (gasto/pedidos)</th>
                <th>ROAS antes</th>
                <th>ROAS depois</th>
                <th>Delta</th>
                <th>Resultado</th>
                <th>Leitura</th>
              </tr>
            </thead>
            <tbody>
              {usefulLearning.map((row, idx) => {
                // Volume por tras do ROAS: separa sinal de ruido. Poucos cliques/
                // gasto -> a "melhora/piora" de ROAS pode ser so barulho.
                const lowVol = Number(row.eval_spend || 0) < 5 && Number(row.eval_orders || 0) < 1
                return (
                <tr key={`${row.recommendation_id}-${row.outcome_window}-${idx}`}>
                  <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.ad_group_name || '-'}</span></td>
                  <td className="num">{row.event_hour !== null && row.event_hour !== undefined ? `${String(row.event_hour).padStart(2, '0')}h` : '-'}</td>
                  <td>{row.recommended_action || '-'} <span className="muted">{fmt(Number(row.recommended_bid_multiplier || 0) * 100)}%</span></td>
                  <td>{row.decided_action || row.recommended_action || '-'} <span className="muted">{row.decided_bid_multiplier ? `${fmt(Number(row.decided_bid_multiplier) * 100)}%` : ''}</span></td>
                  <td>{dt(row.executed_at)}</td>
                  <td><span className="pill warn">{row.outcome_window}</span></td>
                  <td className="num">{money(row.eval_spend)} / {fmt(row.eval_orders)}{lowVol && <span className="pill bad" title="Volume baixo: ROAS pode ser ruido">ruido</span>}</td>
                  <td className="num">{fmt(row.baseline_roas, 2)}</td>
                  <td className="num">{fmt(row.eval_roas, 2)}</td>
                  <td className={`num ${Number(row.delta_roas || 0) >= 0 ? 'delta-pos' : 'delta-neg'}`}>{fmt(row.delta_roas, 2)}</td>
                  <td><span className={`pill ${lowVol ? 'warn' : outcomeClass(row.outcome_label)}`}>{lowVol ? 'inconclusivo' : outcomeText(row.outcome_label)}</span></td>
                  <td>{verdictText(row.model_verdict)}</td>
                </tr>
              )})}
              {!usefulLearning.length && <tr><td colSpan="12" className="empty-cell">Sem medicao util para auditar ainda.</td></tr>}
            </tbody>
          </table>
        </div>
        {!!noisyLearning.length && (
          <details className="noise-details">
            <summary>{fmt(noisyLearning.length)} eventos sem sinal economico suficiente</summary>
            <div className="table-wrap learning-table noise-table">
              <table>
                <thead>
                  <tr>
                    <th>Campanha</th>
                    <th>Hora</th>
                    <th>Acao aplicada</th>
                    <th>Aplicado em</th>
                    <th>Janela</th>
                    <th>Gasto / pedidos</th>
                    <th>ROAS antes</th>
                    <th>ROAS depois</th>
                    <th>Leitura</th>
                  </tr>
                </thead>
                <tbody>
                  {noisyLearning.map((row, idx) => (
                    <tr key={`noise-${row.recommendation_id}-${row.outcome_window}-${idx}`}>
                      <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.ad_group_name || '-'}</span></td>
                      <td className="num">{row.event_hour !== null && row.event_hour !== undefined ? `${String(row.event_hour).padStart(2, '0')}h` : '-'}</td>
                      <td>{row.decided_action || row.recommended_action || '-'} <span className="muted">{row.decided_bid_multiplier ? `${fmt(Number(row.decided_bid_multiplier) * 100)}%` : ''}</span></td>
                      <td>{dt(row.executed_at)}</td>
                      <td><span className="pill warn">{row.outcome_window}</span></td>
                      <td className="num">{money(row.eval_spend)} / {fmt(row.eval_orders)}</td>
                      <td className="num">{fmt(row.baseline_roas, 2)}</td>
                      <td className="num">{fmt(row.eval_roas, 2)}</td>
                      <td><span className="pill warn">sem sinal</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </details>
        )}
      </section>
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Holdout — robo x deixar quieto</h3>
            <p>Controle = horas que o robo NAO toca (mesmo mercado, sem robo). Tratamento = horas geridas. Compara o ROAS dos dois pra separar o efeito do robo do efeito do mercado.</p>
          </div>
          <span>{fmt(holdout.control_cells)} controle / {fmt(holdout.treatment_cells)} tratamento</span>
        </div>
        {holdout.treatment_roas !== undefined && (
          <>
            <div className="holdout-grid">
              <div className="holdout-card ctrl">
                <span className="ops-label">Deixar quieto (controle)</span>
                <b>ROAS {fmt(holdout.control_roas, 2)}</b>
                <small>{money(holdout.control_spend)} gasto - {money(holdout.control_sales)} venda - {fmt(holdout.control_cells)} celulas</small>
              </div>
              <div className="holdout-card trat">
                <span className="ops-label">Robo (tratamento)</span>
                <b>ROAS {fmt(holdout.treatment_roas, 2)}</b>
                <small>{money(holdout.treatment_spend)} gasto - {money(holdout.treatment_sales)} venda - {fmt(holdout.treatment_cells)} celulas</small>
              </div>
              <div className={`holdout-card lift ${Number(holdout.lift_pct || 0) >= 0 ? 'pos' : 'neg'}`}>
                <span className="ops-label">Lift do robo</span>
                <b>{Number(holdout.lift_pct || 0) >= 0 ? '+' : ''}{fmt(holdout.lift_pct, 1)}%</b>
                <small>ROAS tratamento vs controle</small>
              </div>
            </div>
            <div className="verdict-banner warn">
              <b>Leitura DIRECIONAL — ainda nao e prova causal</b>
              <span>O controle vive o mesmo mercado sem o robo, entao a diferenca aponta para o robo. MAS: o robo comecou 16/07 e o dado maduro (atribuicao 7d) desse periodo ainda nao existe — hoje isso reflete muito o equilibrio ORIGINAL dos grupos, nao o efeito recente. Prova causal real (diff-in-diff antes/depois) so quando o pos-robo maturar.</span>
            </div>
          </>
        )}
        {holdout.treatment_roas === undefined && <div className="empty-cell">Sem dado de holdout ainda.</div>}
      </section>
        </>
      )}

      {activeTab === 'audit' && (
        <>
      <section className="tab-brief">
        <div className={`brief-card ${latest.target?.status === 'COMPLETED' ? 'ok' : 'warn'}`}>
          <span>Ultimo target V3</span>
          <b>{latest.target?.status || '-'}</b>
          <small>{fmt(latest.target?.predictions_written)} predicoes; fim {dt(latest.target?.finished_at)}</small>
        </div>
        <div className={`brief-card ${latest.campaign?.status === 'COMPLETED' ? 'ok' : 'warn'}`}>
          <span>Ultimo campanha V2</span>
          <b>{latest.campaign?.status || '-'}</b>
          <small>{fmt(latest.campaign?.predictions_written)} predicoes; fim {dt(latest.campaign?.finished_at)}</small>
        </div>
        <div className="brief-card ok">
          <span>Metricas atuais</span>
          <b>Target AUC {fmt(targetOrderAuc, 3)}</b>
          <small>Campanha AUC {fmt(campaignOrderAuc, 3)}; campanha ROAS MAE {fmt(campaignRoasMae, 3)}</small>
        </div>
        <div className="brief-card ok">
          <span>Volume reconciliado</span>
          <b>{fmt(targetReconciled.rows)} target/hora</b>
          <small>{fmt(campaignGold.rows)} campanha/hora; AMC total {fmt(amcContext.orders)} pedidos contexto</small>
        </div>
      </section>
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Rodadas do ML</h3>
            <p>COMPLETED = tudo treinou. PARTIAL = rodou e escreveu predicoes, mas algum modelo ficou sem exemplos positivos suficientes.</p>
          </div>
          <span>{loading ? 'Carregando...' : `${runs.length} registros`}</span>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Fim</th>
                <th>Worker</th>
                <th>Grao</th>
                <th>Status</th>
                <th>Leitura</th>
                <th>Treino</th>
                <th>Cliques +</th>
                <th>Pedidos +</th>
                <th>Predicoes</th>
              </tr>
            </thead>
            <tbody>
              {runs.map(r => (
                <tr key={r.id}>
                  <td>{dt(r.finished_at)}</td>
                  <td className="strong">{r.run_kind}</td>
                  <td>{r.grain}</td>
                  <td><span className={`pill ${statusClass(r.status)}`}>{r.status}</span></td>
                  <td className="note-cell">{runNote(r)}</td>
                  <td className="num">{fmt(r.training_rows)}</td>
                  <td className="num">{fmt(r.positive_click_rows)}</td>
                  <td className="num">{fmt(r.positive_order_rows)}</td>
                  <td className="num">{fmt(r.predictions_written)}</td>
                </tr>
              ))}
              {!runs.length && <tr><td colSpan="9" className="empty-cell">Sem historico ML ainda.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      <section className="section-band two-col">
        <div>
          <div className="section-head"><div><h3>Modelos atuais</h3><p>Mostra quais modelos podem participar das recomendacoes agora.</p></div><span>{models.length} modelos</span></div>
          <div className="model-list">
            {models.map(m => (
              <div className="model-row" key={`${m.model_name}-${m.model_version}`}>
                <div>
                  <b>{m.model_name}</b>
                  <span>{m.target_name} - {m.model_type}</span>
                  <small>{modelNote(m)}</small>
                </div>
                <span className={`pill ${statusClass(m.status)}`}>{m.status}</span>
              </div>
            ))}
          </div>
        </div>
        <div>
          <div className="section-head"><div><h3>Ultimas atualizacoes</h3><p>Relogios principais da operacao.</p></div><span>AMS/ML</span></div>
          <div className="timeline">
            <div><span>AMS campanha</span><b>{dt(totals.last_ams_update)}</b></div>
            <div><span>AMS target</span><b>{dt(totals.last_target_update)}</b></div>
            <div><span>Ultima msg trafego</span><b>{dt(totals.last_traffic_msg_time)}</b></div>
            <div><span>Ultima msg conversao</span><b>{dt(totals.last_conversion_msg_time)}</b></div>
            <div><span>Ultimo ML</span><b>{dt(totals.last_ml_run)}</b></div>
          </div>
        </div>
      </section>

        </>
      )}

      {activeTab === 'ams' && (
      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Horas AMS recebidas</h3>
            <p>Campanhas e targets recebidos da Amazon por hora. Pedidos podem chegar depois como delta de conversao.</p>
          </div>
          <span>{hours.length} horas</span>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Data</th>
                <th>Hora</th>
                <th>Camp.</th>
                <th>Targets</th>
                <th>Imp.</th>
                <th>Cliques</th>
                <th>Spend</th>
                <th>Pedidos</th>
                <th>Vendas</th>
                <th>Atualizado</th>
              </tr>
            </thead>
            <tbody>
              {hours.map(h => (
                <tr key={`${h.data_date}-${h.event_hour}`}>
                  <td>{dateOnly(h.data_date)}</td>
                  <td className="num">{String(h.event_hour).padStart(2, '0')}h</td>
                  <td className="num">{fmt(h.campaign_rows)}</td>
                  <td className="num">{fmt(h.target_rows)} <span className="muted">/{fmt(h.target_entities)}</span></td>
                  <td className="num">{fmt(h.campaign_impressions)}</td>
                  <td className="num">{fmt(h.campaign_clicks)}</td>
                  <td className="num">{money(h.campaign_spend)}</td>
                  <td className="num">{fmt(h.campaign_orders)}</td>
                  <td className="num">{money(h.campaign_sales)}</td>
                  <td>{dt(h.last_update)}</td>
                </tr>
              ))}
              {!hours.length && <tr><td colSpan="10" className="empty-cell">Sem horas AMS recebidas.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>
      )}

      <style>{`
        .status-page .page-head{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;margin-bottom:14px}
        .status-page h2{margin:0;font-size:24px;line-height:1.15;letter-spacing:0}
        .status-page .sub{display:block;margin-top:4px;color:var(--muted,#9aa7bd);font-size:13px}
        .status-page .head-actions{display:flex;align-items:center;gap:12px}
        .status-page .last{color:var(--muted,#9aa7bd);font-size:12px;white-space:nowrap}
        .status-page .btn{height:38px;min-width:96px;padding:0 14px}
        .status-page .notice{border:1px solid rgba(255,159,67,.35);background:rgba(255,159,67,.10);color:#ffcf96;border-radius:8px;padding:10px 12px;margin-bottom:12px;font-size:13px}
        .status-page .status-tabs{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:8px;margin:12px 0 14px}
        .status-page .status-tab{display:flex;align-items:flex-start;justify-content:space-between;gap:8px;min-height:54px;padding:10px 12px;border:1px solid rgba(148,163,184,.18);border-radius:8px;background:rgba(255,255,255,.025);color:#d9e7ff;text-align:left;cursor:pointer}
        .status-page .status-tab:hover{border-color:rgba(84,160,255,.45);background:rgba(84,160,255,.07)}
        .status-page .status-tab.active{border-color:rgba(84,160,255,.75);background:rgba(84,160,255,.14);box-shadow:inset 0 0 0 1px rgba(84,160,255,.16)}
        .status-page .status-tab span{font-weight:850;font-size:13px;line-height:1.2}
        .status-page .status-tab small{color:#9fb8dc;font-size:11px;white-space:nowrap}
        .status-page .tab-brief{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin:0 0 14px}
        .status-page .brief-card{border:1px solid rgba(148,163,184,.18);border-radius:8px;background:rgba(255,255,255,.03);padding:12px 14px;min-height:104px}
        .status-page .brief-card.ok{border-color:rgba(38,222,129,.30);background:rgba(38,222,129,.06)}
        .status-page .brief-card.warn{border-color:rgba(255,159,67,.35);background:rgba(255,159,67,.07)}
        .status-page .brief-card.bad{border-color:rgba(255,84,112,.35);background:rgba(255,84,112,.07)}
        .status-page .brief-card span{display:block;color:#9fb8dc;text-transform:uppercase;letter-spacing:.08em;font-size:10px;font-weight:850}
        .status-page .brief-card b{display:block;margin-top:8px;color:#fff;font-size:19px;line-height:1.15}
        .status-page .brief-card small{display:block;margin-top:8px;color:#b7c7de;font-size:11px;line-height:1.35}
        .status-page .ops-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:12px}
        .status-page .ops-card{border:1px solid rgba(148,163,184,.18);border-radius:8px;padding:13px 14px;background:rgba(255,255,255,.035);min-height:116px}
        .status-page .ops-card.ok{border-color:rgba(38,222,129,.30);background:rgba(38,222,129,.06)}
        .status-page .ops-card.warn{border-color:rgba(255,159,67,.35);background:rgba(255,159,67,.07)}
        .status-page .ops-card.bad{border-color:rgba(255,84,112,.35);background:rgba(255,84,112,.07)}
        .status-page .ops-label{display:block;color:#9fb8dc;text-transform:uppercase;letter-spacing:.08em;font-size:11px;font-weight:800}
        .status-page .ops-card b{display:block;margin-top:10px;font-size:22px;line-height:1.05;color:#fff}
        .status-page .ops-card small{display:block;margin-top:8px;color:var(--muted,#9aa7bd);font-size:12px;line-height:1.35}
        .status-page .readout{border:1px solid rgba(84,160,255,.25);background:rgba(84,160,255,.08);border-radius:8px;padding:12px 14px;margin-bottom:14px}
        .status-page .readout h3{margin:0 0 8px;color:#cfe3ff;font-size:13px;text-transform:uppercase;letter-spacing:.08em}
        .status-page .readout ul{margin:0;padding-left:18px;color:#d9e7ff;font-size:13px;line-height:1.5}
        .status-page .readout li+li{margin-top:4px}
        .status-page .kpi-row{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:14px}
        .status-page .kpi{background:rgba(255,255,255,.035);border:1px solid rgba(148,163,184,.18);border-radius:8px;padding:12px 14px;min-height:78px}
        .status-page .kpi-v{font-size:23px;line-height:1;font-weight:850;font-variant-numeric:tabular-nums;color:#54a0ff}
        .status-page .kpi-l{margin-top:7px;color:var(--muted,#9aa7bd);font-size:12px;line-height:1.25}
        .status-page .training-grid,.status-page .model-metrics-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
        .status-page .model-metrics-grid{grid-template-columns:repeat(5,minmax(0,1fr))}
        .status-page .training-card,.status-page .metric-card{border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.025);padding:12px 14px;min-height:94px}
        .status-page .training-card{border-color:rgba(84,160,255,.24);background:rgba(84,160,255,.06)}
        .status-page .metric-card.ok{border-color:rgba(38,222,129,.28);background:rgba(38,222,129,.06)}
        .status-page .training-card span,.status-page .metric-card span{display:block;color:#9fb8dc;text-transform:uppercase;letter-spacing:.08em;font-size:10px;font-weight:850}
        .status-page .training-card b,.status-page .metric-card b{display:block;margin-top:8px;font-size:20px;line-height:1.1;color:#fff}
        .status-page .training-card small,.status-page .metric-card small{display:block;margin-top:8px;color:#b7c7de;font-size:11px;line-height:1.35}
        .status-page .section-band{margin-top:14px;border-top:1px solid rgba(148,163,184,.14);padding-top:14px}
        .status-page .compact-alerts{border:1px solid rgba(148,163,184,.14);border-radius:8px;background:rgba(255,255,255,.02);padding:12px;margin:0 0 14px}
        .status-page .alert-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
        .status-page .alert-row{display:grid;grid-template-columns:auto minmax(120px,.8fr) minmax(180px,1.2fr);align-items:center;gap:10px;border:1px solid rgba(148,163,184,.14);border-radius:8px;padding:9px 10px;background:rgba(255,255,255,.025)}
        .status-page .alert-row.ok{border-color:rgba(38,222,129,.28);background:rgba(38,222,129,.06)}
        .status-page .alert-row.warn{border-color:rgba(255,159,67,.30);background:rgba(255,159,67,.07)}
        .status-page .alert-row.bad{border-color:rgba(255,84,112,.32);background:rgba(255,84,112,.07)}
        .status-page .alert-row b{color:#fff;font-size:13px;line-height:1.2}
        .status-page .alert-row small{color:#b7c7de;font-size:12px;line-height:1.25}
        .status-page .two-col{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(280px,.7fr);gap:18px}
        .status-page .section-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:9px;color:var(--muted,#9aa7bd);font-size:12px}
        .status-page .section-head h3{margin:0;color:inherit;font-size:13px;text-transform:uppercase;letter-spacing:.08em}
        .status-page .section-head p{margin:4px 0 0;color:var(--muted,#8796ad);font-size:12px;line-height:1.35}
        .status-page .table-wrap{border:1px solid rgba(148,163,184,.16);border-radius:8px;overflow:auto;background:rgba(255,255,255,.025);max-height:380px}
        .status-page .audit-table{max-height:440px}
        .status-page table{width:100%;min-width:1080px;border-collapse:collapse;font-size:12px}
        .status-page .audit-table table{min-width:1260px}
        .status-page th{position:sticky;top:0;background:#101626;color:#9fb8dc;text-align:left;padding:10px 12px;text-transform:uppercase;letter-spacing:.08em;font-size:11px}
        .status-page td{padding:10px 12px;border-top:1px solid rgba(148,163,184,.10);vertical-align:middle}
        .status-page .num{text-align:right;font-variant-numeric:tabular-nums}
        .status-page .strong{font-weight:800;color:#fff}
        .status-page .muted{color:var(--muted,#8796ad)}
        .status-page .row-sub{display:block;margin-top:4px;color:var(--muted,#8796ad);font-size:11px;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .status-page .note-cell{min-width:260px;color:#b7c7de}
        .status-page .pill{display:inline-flex;align-items:center;min-height:22px;padding:0 8px;border-radius:999px;font-size:11px;font-weight:850;letter-spacing:.02em}
        .status-page .pill.ok{background:rgba(38,222,129,.14);color:#26de81}
        .status-page .pill.warn{background:rgba(255,159,67,.15);color:#ffb86b}
        .status-page .pill.bad{background:rgba(255,84,112,.15);color:#ff5470}
        .status-page .delta-pos{color:#26de81}
        .status-page .delta-neg{color:#ff5470}
        .status-page .good{color:#26de81}
        .status-page .bad-text{color:#ff5470}
        .status-page .audit-score{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin-bottom:10px}
        .status-page .audit-score div{border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.025);padding:10px 12px}
        .status-page .audit-score span{display:block;color:#9fb8dc;text-transform:uppercase;letter-spacing:.08em;font-size:10px;font-weight:850}
        .status-page .audit-score b{display:block;margin-top:6px;font-size:20px;line-height:1;color:#fff}
        .status-page .decision-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
        .status-page .decision-card{border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.025);padding:12px 14px;min-height:104px}
        .status-page .decision-card.ok{border-color:rgba(38,222,129,.30);background:rgba(38,222,129,.06)}
        .status-page .decision-card.warn{border-color:rgba(255,159,67,.35);background:rgba(255,159,67,.07)}
        .status-page .decision-card span{display:block;color:#9fb8dc;text-transform:uppercase;letter-spacing:.08em;font-size:10px;font-weight:850}
        .status-page .decision-card b{display:block;margin-top:8px;font-size:18px;line-height:1.15;color:#fff}
        .status-page .decision-card small{display:block;margin-top:8px;color:#b7c7de;font-size:12px;line-height:1.35}
        .status-page .quality-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-bottom:10px}
        .status-page .quality-card{border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.025);padding:10px 12px;min-height:92px}
        .status-page .quality-card.ok{border-color:rgba(38,222,129,.30);background:rgba(38,222,129,.06)}
        .status-page .quality-card.warn{border-color:rgba(255,159,67,.35);background:rgba(255,159,67,.07)}
        .status-page .quality-card.bad{border-color:rgba(255,84,112,.35);background:rgba(255,84,112,.07)}
        .status-page .quality-card span{display:block;color:#9fb8dc;text-transform:uppercase;letter-spacing:.08em;font-size:10px;font-weight:850}
        .status-page .quality-card b{display:block;margin-top:7px;font-size:24px;line-height:1;color:#fff}
        .status-page .quality-card small{display:block;margin-top:7px;color:#b7c7de;font-size:11px;line-height:1.35}
        .status-page .quality-table{max-height:300px;margin-bottom:10px}
        .status-page .quality-table table{min-width:1120px}
        .status-page .reprocess-table{max-height:220px}
        .status-page .reprocess-table table{min-width:900px}
        .status-page .verdict-banner{border-radius:8px;padding:11px 14px;margin-bottom:10px;border:1px solid}
        .status-page .verdict-banner b{display:block;font-size:14px;margin-bottom:3px}
        .status-page .verdict-banner span{font-size:12px;line-height:1.4;color:#cbd5e5}
        .status-page .verdict-banner.ok{border-color:rgba(38,222,129,.35);background:rgba(38,222,129,.08)}
        .status-page .verdict-banner.ok b{color:#26de81}
        .status-page .verdict-banner.warn{border-color:rgba(255,159,67,.35);background:rgba(255,159,67,.08)}
        .status-page .verdict-banner.warn b{color:#ffb86b}
        .status-page .verdict-banner.bad{border-color:rgba(255,84,112,.35);background:rgba(255,84,112,.08)}
        .status-page .verdict-banner.bad b{color:#ff5470}
        .status-page .no-learning-signal{display:grid;gap:6px;border:1px solid rgba(255,159,67,.36);background:rgba(255,159,67,.08);border-radius:8px;padding:13px 14px;margin-bottom:10px;color:#d9e7ff}
        .status-page .no-learning-signal b{color:#ffcf96;font-size:15px}
        .status-page .no-learning-signal span{font-size:13px;line-height:1.4;color:#d9e7ff}
        .status-page .no-learning-signal small{font-size:12px;line-height:1.35;color:#b7c7de}
        .status-page .noise-details{margin-top:10px;border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.025);overflow:hidden}
        .status-page .noise-details summary{cursor:pointer;list-style:none;padding:11px 13px;color:#9fb8dc;font-weight:850;text-transform:uppercase;letter-spacing:.06em;font-size:11px}
        .status-page .noise-details summary::-webkit-details-marker{display:none}
        .status-page .noise-details summary:after{content:'+';float:right;color:#54a0ff;font-size:16px;line-height:1}
        .status-page .noise-details[open] summary:after{content:'-'}
        .status-page .noise-table{border:0;border-top:1px solid rgba(148,163,184,.14);border-radius:0;max-height:260px}
        .status-page .noise-table table{min-width:980px}
        .status-page .holdout-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-bottom:10px}
        .status-page .holdout-card{border:1px solid rgba(148,163,184,.18);border-radius:8px;padding:13px 14px;background:rgba(255,255,255,.035)}
        .status-page .holdout-card b{display:block;margin-top:8px;font-size:22px;color:#fff}
        .status-page .holdout-card small{display:block;margin-top:8px;color:var(--muted,#9aa7bd);font-size:12px;line-height:1.35}
        .status-page .holdout-card.ctrl{border-color:rgba(148,163,184,.30)}
        .status-page .holdout-card.trat{border-color:rgba(84,160,255,.35);background:rgba(84,160,255,.07)}
        .status-page .holdout-card.lift.pos{border-color:rgba(38,222,129,.35);background:rgba(38,222,129,.07)}
        .status-page .holdout-card.lift.pos b{color:#26de81}
        .status-page .holdout-card.lift.neg{border-color:rgba(255,84,112,.35);background:rgba(255,84,112,.07)}
        .status-page .holdout-card.lift.neg b{color:#ff5470}
        @media(max-width:900px){.status-page .holdout-grid{grid-template-columns:1fr}}
        .status-page .window-cell{display:grid;gap:5px;min-width:118px}
        .status-page .window-cell small{color:#b7c7de;font-size:11px;white-space:nowrap}
        .status-page .model-list{display:grid;gap:8px}
        .status-page .model-row{display:flex;justify-content:space-between;gap:12px;align-items:center;padding:10px 12px;border:1px solid rgba(148,163,184,.14);border-radius:8px;background:rgba(255,255,255,.025)}
        .status-page .model-row b{display:block;font-size:12px;color:#fff}
        .status-page .model-row span:not(.pill){display:block;margin-top:3px;color:var(--muted,#8796ad);font-size:11px}
        .status-page .model-row small{display:block;margin-top:5px;color:#b7c7de;font-size:12px;line-height:1.35}
        .status-page .timeline{display:grid;gap:8px}
        .status-page .timeline div{padding:10px 12px;border:1px solid rgba(148,163,184,.14);border-radius:8px;background:rgba(255,255,255,.025)}
        .status-page .timeline span{display:block;color:var(--muted,#8796ad);font-size:11px;text-transform:uppercase;letter-spacing:.08em}
        .status-page .timeline b{display:block;margin-top:5px;font-size:13px;color:#fff}
        .status-page .empty,.status-page .empty-cell{color:var(--muted,#8796ad);text-align:center;padding:28px 12px}
        @media (max-width: 1100px){.status-page .status-tabs{grid-template-columns:repeat(3,minmax(0,1fr))}.status-page .tab-brief,.status-page .ops-grid,.status-page .kpi-row,.status-page .quality-grid,.status-page .decision-grid,.status-page .training-grid,.status-page .model-metrics-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.status-page .audit-score{grid-template-columns:repeat(3,minmax(0,1fr))}.status-page .two-col{grid-template-columns:1fr}}
        @media (max-width: 720px){.status-page .page-head{align-items:flex-start;flex-direction:column}.status-page .status-tabs,.status-page .tab-brief,.status-page .ops-grid,.status-page .kpi-row,.status-page .audit-score,.status-page .quality-grid,.status-page .decision-grid,.status-page .training-grid,.status-page .model-metrics-grid{grid-template-columns:1fr}.status-page .head-actions{width:100%;justify-content:space-between}}
      `}</style>
    </div>
  )
}




