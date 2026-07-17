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

export default function StatusAmsMl({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState({ totals: {}, models: [], ml_runs: [], ams_hours: [], learning_outcomes: [], audit_360: [], audit_360_summary: {}, full_control_360_summary: {}, full_control_360: [] })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [updatedAt, setUpdatedAt] = useState(null)

  const load = useCallback(async () => {
    setError('')
    const res = await api.goldMlAmsStatus(tenantID)
    if (res.ok) {
      setData(res.data || { totals: {}, models: [], ml_runs: [], ams_hours: [], learning_outcomes: [], audit_360: [], audit_360_summary: {}, full_control_360_summary: {}, full_control_360: [] })
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

  const latest = useMemo(() => ({
    campaign: latestRun(runs, 'hourly_real_v2'),
    target: latestRun(runs, 'hourly_target_real_v3'),
  }), [runs])

  const targetModelsPending = models.filter(m => String(m.model_name || '').includes('HourlyTarget') && m.status === 'INSUFFICIENT_DATA')
  const hasAms = Number(totals.campaign_rows || 0) > 0 && Number(totals.target_rows || 0) > 0
  const hasConversions = Number(totals.ams_orders_7d || 0) > 0 || Number(totals.ams_sales_7d || 0) > 0
  const targetMlReady = targetModelsPending.length === 0
  const authError = friendlyError(error)

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

      <section className="ops-grid">
        <div className={`ops-card ${hasAms ? 'ok' : 'bad'}`}>
          <span className="ops-label">1. AMS Stream</span>
          <b>{hasAms ? 'Chegando' : 'Sem dados'}</b>
          <small>{fmt(totals.campaign_rows)} linhas campanha / {fmt(totals.target_rows)} linhas keyword-target</small>
        </div>
        <div className={`ops-card ${hasConversions ? 'ok' : 'warn'}`}>
          <span className="ops-label">2. Conversoes AMS</span>
          <b>{fmt(totals.ams_orders_7d)} pedidos 7d</b>
          <small>{money(totals.ams_sales_7d)} em vendas 7d - ultima msg {dt(totals.last_conversion_msg_time)}</small>
        </div>
        <div className={`ops-card ${Number(totals.campaign_conversion_rows || 0) > 0 ? 'ok' : 'warn'}`}>
          <span className="ops-label">3. Parser + Lake</span>
          <b>{fmt(totals.campaign_conversion_rows)} linhas com conversao</b>
          <small>Parser gravando snake_case/camelCase - ultima gravacao {dt(totals.last_conversion_at)}</small>
        </div>
        <div className={`ops-card ${targetMlReady ? 'ok' : 'warn'}`}>
          <span className="ops-label">4. ML Target V3</span>
          <b>{targetMlReady ? 'Completo' : 'Parcial'}</b>
          <small>{fmt(totals.target_predictions)} predicoes - {fmt(totals.keyword_recommendations_with_target_ml)} recomendacoes usando ML target</small>
        </div>
      </section>

      <section className="readout">
        <h3>Leitura rapida</h3>
        <ul>
          <li><b>AMS esta funcionando:</b> trafego e target estao entrando no lake; a ultima atualizacao de campanha foi {dt(totals.last_ams_update)}.</li>
          <li><b>Conversao ja apareceu:</b> {fmt(totals.ams_orders_1d)} pedidos 1d, {fmt(totals.ams_orders_7d)} pedidos 7d e {fmt(totals.ams_orders_14d)} pedidos 14d.</li>
          <li><b>Campanha/hora:</b> o modelo hourly_real_v2 esta {latest.campaign?.status || '-'} e usa o consolidado por campanha.</li>
          <li><b>Keyword-target/hora:</b> o V3 esta {latest.target?.status || '-'}; quando aparece PARTIAL, clique treinou, mas pedido/ROAS ainda nao tem positivo suficiente por target.</li>
        </ul>
      </section>

      <div className="kpi-row">
        <div className="kpi"><div className="kpi-v">{fmt(totals.campaign_rows)}</div><div className="kpi-l">Linhas AMS campanha</div></div>
        <div className="kpi"><div className="kpi-v">{fmt(totals.target_rows)}</div><div className="kpi-l">Linhas AMS keyword-target</div></div>
        <div className="kpi"><div className="kpi-v">{fmt(totals.ams_orders_7d)}</div><div className="kpi-l">Pedidos AMS 7d</div></div>
        <div className="kpi"><div className="kpi-v">{money(totals.ams_sales_7d)}</div><div className="kpi-l">Vendas AMS 7d</div></div>
      </div>

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

      <section className="section-band">
        <div className="section-head">
          <div>
            <h3>Aprendizado pos-acao</h3>
            <p>Fecha o ciclo proposta, aplicado e AMS medido. Cada linha mostra o resultado depois de 1h, 3h ou 24h da primeira ocorrencia da hora alterada.</p>
          </div>
          <span>{learning.length ? `${learning.length} medicoes` : 'sem medicoes'}</span>
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
              {learning.map((row, idx) => {
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
              {!learning.length && <tr><td colSpan="12" className="empty-cell">Ainda nao ha acoes executadas com janela AMS fechada para medir.</td></tr>}
            </tbody>
          </table>
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

      <style>{`
        .status-page .page-head{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;margin-bottom:14px}
        .status-page h2{margin:0;font-size:24px;line-height:1.15;letter-spacing:0}
        .status-page .sub{display:block;margin-top:4px;color:var(--muted,#9aa7bd);font-size:13px}
        .status-page .head-actions{display:flex;align-items:center;gap:12px}
        .status-page .last{color:var(--muted,#9aa7bd);font-size:12px;white-space:nowrap}
        .status-page .btn{height:38px;min-width:96px;padding:0 14px}
        .status-page .notice{border:1px solid rgba(255,159,67,.35);background:rgba(255,159,67,.10);color:#ffcf96;border-radius:8px;padding:10px 12px;margin-bottom:12px;font-size:13px}
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
        .status-page .section-band{margin-top:14px;border-top:1px solid rgba(148,163,184,.14);padding-top:14px}
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
        .status-page .verdict-banner{border-radius:8px;padding:11px 14px;margin-bottom:10px;border:1px solid}
        .status-page .verdict-banner b{display:block;font-size:14px;margin-bottom:3px}
        .status-page .verdict-banner span{font-size:12px;line-height:1.4;color:#cbd5e5}
        .status-page .verdict-banner.ok{border-color:rgba(38,222,129,.35);background:rgba(38,222,129,.08)}
        .status-page .verdict-banner.ok b{color:#26de81}
        .status-page .verdict-banner.warn{border-color:rgba(255,159,67,.35);background:rgba(255,159,67,.08)}
        .status-page .verdict-banner.warn b{color:#ffb86b}
        .status-page .verdict-banner.bad{border-color:rgba(255,84,112,.35);background:rgba(255,84,112,.08)}
        .status-page .verdict-banner.bad b{color:#ff5470}
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
        @media (max-width: 1100px){.status-page .ops-grid,.status-page .kpi-row{grid-template-columns:repeat(2,minmax(0,1fr))}.status-page .audit-score{grid-template-columns:repeat(3,minmax(0,1fr))}.status-page .two-col{grid-template-columns:1fr}}
        @media (max-width: 720px){.status-page .page-head{align-items:flex-start;flex-direction:column}.status-page .ops-grid,.status-page .kpi-row,.status-page .audit-score{grid-template-columns:1fr}.status-page .head-actions{width:100%;justify-content:space-between}}
      `}</style>
    </div>
  )
}




