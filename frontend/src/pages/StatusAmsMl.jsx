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
function latestRun(runs, kind) {
  return runs.find(r => r.run_kind === kind)
}

export default function StatusAmsMl({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState({ totals: {}, models: [], ml_runs: [], ams_hours: [], learning_outcomes: [] })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [updatedAt, setUpdatedAt] = useState(null)

  const load = useCallback(async () => {
    setError('')
    const res = await api.goldMlAmsStatus(tenantID)
    if (res.ok) {
      setData(res.data || { totals: {}, models: [], ml_runs: [], ams_hours: [], learning_outcomes: [] })
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
            <h3>Aprendizado pos-acao</h3>
            <p>Fecha o ciclo proposta, aplicado e AMS medido. Cada linha mostra o resultado depois de 1h, 3h ou 24h da primeira ocorrencia da hora alterada.</p>
          </div>
          <span>{learning.length ? `${learning.length} medicoes` : 'sem medicoes'}</span>
        </div>
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
                <th>ROAS antes</th>
                <th>ROAS depois</th>
                <th>Delta</th>
                <th>Resultado</th>
                <th>Leitura</th>
              </tr>
            </thead>
            <tbody>
              {learning.map((row, idx) => (
                <tr key={`${row.recommendation_id}-${row.outcome_window}-${idx}`}>
                  <td><b>{row.campaign_name || '-'}</b><span className="row-sub">{row.ad_group_name || '-'}</span></td>
                  <td className="num">{row.event_hour !== null && row.event_hour !== undefined ? `${String(row.event_hour).padStart(2, '0')}h` : '-'}</td>
                  <td>{row.recommended_action || '-'} <span className="muted">{fmt(Number(row.recommended_bid_multiplier || 0) * 100)}%</span></td>
                  <td>{row.decided_action || row.recommended_action || '-'} <span className="muted">{row.decided_bid_multiplier ? `${fmt(Number(row.decided_bid_multiplier) * 100)}%` : ''}</span></td>
                  <td>{dt(row.executed_at)}</td>
                  <td><span className="pill warn">{row.outcome_window}</span></td>
                  <td className="num">{fmt(row.baseline_roas, 2)}</td>
                  <td className="num">{fmt(row.eval_roas, 2)}</td>
                  <td className={`num ${Number(row.delta_roas || 0) >= 0 ? 'delta-pos' : 'delta-neg'}`}>{fmt(row.delta_roas, 2)}</td>
                  <td><span className={`pill ${outcomeClass(row.outcome_label)}`}>{outcomeText(row.outcome_label)}</span></td>
                  <td>{verdictText(row.model_verdict)}</td>
                </tr>
              ))}
              {!learning.length && <tr><td colSpan="11" className="empty-cell">Ainda nao ha acoes executadas com janela AMS fechada para medir.</td></tr>}
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
        .status-page table{width:100%;min-width:1080px;border-collapse:collapse;font-size:12px}
        .status-page th{position:sticky;top:0;background:#101626;color:#9fb8dc;text-align:left;padding:10px 12px;text-transform:uppercase;letter-spacing:.08em;font-size:11px}
        .status-page td{padding:10px 12px;border-top:1px solid rgba(148,163,184,.10);vertical-align:middle}
        .status-page .num{text-align:right;font-variant-numeric:tabular-nums}
        .status-page .strong{font-weight:800;color:#fff}
        .status-page .muted{color:var(--muted,#8796ad)}
        .status-page .note-cell{min-width:260px;color:#b7c7de}
        .status-page .pill{display:inline-flex;align-items:center;min-height:22px;padding:0 8px;border-radius:999px;font-size:11px;font-weight:850;letter-spacing:.02em}
        .status-page .pill.ok{background:rgba(38,222,129,.14);color:#26de81}
        .status-page .pill.warn{background:rgba(255,159,67,.15);color:#ffb86b}
        .status-page .pill.bad{background:rgba(255,84,112,.15);color:#ff5470}
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
        @media (max-width: 1100px){.status-page .ops-grid,.status-page .kpi-row{grid-template-columns:repeat(2,minmax(0,1fr))}.status-page .two-col{grid-template-columns:1fr}}
        @media (max-width: 720px){.status-page .page-head{align-items:flex-start;flex-direction:column}.status-page .ops-grid,.status-page .kpi-row{grid-template-columns:1fr}.status-page .head-actions{width:100%;justify-content:space-between}}
      `}</style>
    </div>
  )
}




