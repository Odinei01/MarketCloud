import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

function fmt(n, digits = 0) {
  if (n === null || n === undefined || n === '') return '-'
  const v = Number(n)
  if (!Number.isFinite(v)) return '-'
  return v.toLocaleString('pt-BR', { minimumFractionDigits: digits, maximumFractionDigits: digits })
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

function dayHour(row) {
  if (!row?.data_date && row?.last_ams_hour) return row.last_ams_hour
  if (!row?.data_date) return '-'
  return `${row.data_date} ${String(row.event_hour ?? 0).padStart(2, '0')}h`
}

function shortName(name = '') {
  const parts = String(name).split(' - ')
  return parts[parts.length - 1] || name
}

function sourceClass(source) {
  if (source === 'ams') return 'ok'
  if (source === 'reporting') return 'info'
  return 'warn'
}

export default function PartnerCampaignMonitor({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState({ summary: [], hourly: [], targets: [], structure: [], changes: [] })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [updatedAt, setUpdatedAt] = useState(null)

  const load = useCallback(async () => {
    setError('')
    const res = await api.goldPartnerCampaignMonitor(tenantID)
    if (res.ok) {
      setData(res.data || { summary: [], hourly: [], targets: [], structure: [], changes: [] })
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

  const summary = data.summary || []
  const hourly = data.hourly || []
  const targets = data.targets || []
  const structure = data.structure || []
  const changes = data.changes || []

  const totals = useMemo(() => summary.reduce((acc, c) => {
    acc.dailySpend += Number(c.daily_spend || 0)
    acc.dailyOrders += Number(c.daily_orders || 0)
    acc.amsRows += Number(c.ams_rows || 0)
    acc.targetRows += Number(c.target_rows || 0)
    acc.structureRows += Number(c.structure_rows || 0)
    return acc
  }, { dailySpend: 0, dailyOrders: 0, amsRows: 0, targetRows: 0, structureRows: 0 }), [summary])

  return (
    <div className="page partner-monitor">
      <div className="pm-head">
        <div>
          <h2>Monitor m19 Autopilot</h2>
          <span>Quatro campanhas do parceiro, performance horaria, AMS, estrutura e mudancas</span>
        </div>
        <div className="pm-actions">
          <span>Atualizado {updatedAt ? dt(updatedAt) : '-'}</span>
          <button className="btn" onClick={load}>Atualizar</button>
        </div>
      </div>

      {error && <div className="pm-alert">{error}</div>}

      <div className="pm-kpis">
        <div><b>{fmt(summary.length)}</b><span>Campanhas</span></div>
        <div><b>{fmt(totals.amsRows)}</b><span>Linhas AMS campanha</span></div>
        <div><b>{fmt(totals.targetRows)}</b><span>Linhas AMS target</span></div>
        <div><b>{money(totals.dailySpend)}</b><span>Gasto diario parceiro</span></div>
        <div><b>{fmt(totals.dailyOrders)}</b><span>Pedidos diario parceiro</span></div>
      </div>

      <section className="pm-section">
        <div className="pm-section-head">
          <h3>Campanhas monitoradas</h3>
          <span>{loading ? 'Carregando...' : `${summary.length} campanhas`}</span>
        </div>
        <div className="pm-cards">
          {summary.map(c => (
            <article className="pm-card" key={c.campaign_name}>
              <div className="pm-card-top">
                <div>
                  <a href={c.console_url} target="_blank" rel="noreferrer">{c.label}</a>
                  <h4>{shortName(c.campaign_name)}</h4>
                </div>
                <span className={`pm-pill ${c.campaign_status === 'ENABLED' ? 'ok' : 'warn'}`}>{c.campaign_status || 'sem status'}</span>
              </div>
              <div className="pm-meta">
                <span>ID Ads: {c.campaign_id || '-'}</span>
                <span>Console: {c.console_campaign_id}</span>
                <span>{c.targeting_type || '-'} / {c.bidding_strategy || '-'}</span>
              </div>
              <div className="pm-metrics">
                <div><span>Daily</span><b>{fmt(c.daily_impressions)}</b><small>imp</small></div>
                <div><span>Clicks</span><b>{fmt(c.daily_clicks)}</b><small>{money(c.daily_spend)}</small></div>
                <div><span>Orders</span><b>{fmt(c.daily_orders)}</b><small>{money(c.daily_sales)}</small></div>
                <div><span>AMS</span><b>{fmt(c.ams_rows)}</b><small>{fmt(c.ams_clicks)} clicks</small></div>
                <div><span>Targets</span><b>{fmt(c.target_entities)}</b><small>{fmt(c.target_rows)} linhas</small></div>
                <div><span>Estrutura</span><b>{fmt(c.structure_rows)}</b><small>{fmt(c.keywords)} kw / {fmt(c.targets)} tgt</small></div>
              </div>
              <div className="pm-foot">
                <span>Ultimo daily: {dt(c.last_daily_sync)}</span>
                <span>Ultimo AMS: {dt(c.last_ams_update || c.last_target_update)}</span>
                {Number(c.structure_rows || 0) === 0 && <strong>Estrutura ainda nao sincronizada no inventario local.</strong>}
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="pm-section">
        <div className="pm-section-head">
          <h3>Performance hora a hora</h3>
          <span>{hourly.length} linhas</span>
        </div>
        <div className="pm-table">
          <table>
            <thead>
              <tr>
                <th>Hora</th>
                <th>Fonte</th>
                <th>Campanha</th>
                <th>Imp.</th>
                <th>Cliques</th>
                <th>Gasto</th>
                <th>Pedidos</th>
                <th>Vendas</th>
                <th>Atualizado</th>
              </tr>
            </thead>
            <tbody>
              {hourly.map((r, i) => (
                <tr key={`${r.source}-${r.campaign_name}-${r.data_date}-${r.event_hour}-${i}`}>
                  <td>{dayHour(r)}</td>
                  <td><span className={`pm-pill ${sourceClass(r.source)}`}>{r.source}</span></td>
                  <td>{shortName(r.campaign_name)}</td>
                  <td className="num">{fmt(r.impressions)}</td>
                  <td className="num">{fmt(r.clicks)}</td>
                  <td className="num">{money(r.spend)}</td>
                  <td className="num">{fmt(r.orders)}</td>
                  <td className="num">{money(r.sales)}</td>
                  <td>{dt(r.updated_at)}</td>
                </tr>
              ))}
              {!hourly.length && <tr><td colSpan="9" className="empty-cell">Sem performance horaria ainda.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      <section className="pm-section two">
        <div>
          <div className="pm-section-head">
            <h3>Targets e keywords AMS</h3>
            <span>{targets.length} linhas</span>
          </div>
          <div className="pm-table small">
            <table>
              <thead>
                <tr>
                  <th>Hora</th>
                  <th>Campanha</th>
                  <th>Target</th>
                  <th>Match</th>
                  <th>Imp.</th>
                  <th>Cliques</th>
                  <th>Gasto</th>
                </tr>
              </thead>
              <tbody>
                {targets.map((r, i) => (
                  <tr key={`${r.campaign_id}-${r.data_date}-${r.event_hour}-${r.target_text}-${i}`}>
                    <td>{dayHour(r)}</td>
                    <td>{shortName(r.campaign_name)}</td>
                    <td className="strong">{r.target_text}</td>
                    <td>{r.match_type || '-'}</td>
                    <td className="num">{fmt(r.impressions)}</td>
                    <td className="num">{fmt(r.clicks)}</td>
                    <td className="num">{money(r.spend)}</td>
                  </tr>
                ))}
                {!targets.length && <tr><td colSpan="7" className="empty-cell">AMS target ainda nao recebeu linhas dessas campanhas.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
        <div>
          <div className="pm-section-head">
            <h3>Mudancas detectadas</h3>
            <span>{changes.length} snapshots</span>
          </div>
          <div className="pm-table small">
            <table>
              <thead>
                <tr>
                  <th>Data</th>
                  <th>Campanha</th>
                  <th>Tipo</th>
                  <th>Budget</th>
                  <th>Estrategia</th>
                </tr>
              </thead>
              <tbody>
                {changes.map((r, i) => (
                  <tr key={`${r.campaign_name}-${r.date}-${i}`}>
                    <td>{r.date}</td>
                    <td>{shortName(r.campaign_name)}</td>
                    <td><span className={`pm-pill ${r.change_type === 'CONFIG_CHANGED' ? 'warn' : 'info'}`}>{r.change_type}</span></td>
                    <td className="num">{money(r.budget_amount)}</td>
                    <td>{r.bidding_strategy || '-'}</td>
                  </tr>
                ))}
                {!changes.length && <tr><td colSpan="5" className="empty-cell">Sem snapshots de mudanca.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section className="pm-section">
        <div className="pm-section-head">
          <h3>Estrutura sincronizada</h3>
          <span>{structure.length} entidades</span>
        </div>
        <div className="pm-table">
          <table>
            <thead>
              <tr>
                <th>Campanha</th>
                <th>Ad group</th>
                <th>Tipo</th>
                <th>Entidade</th>
                <th>Match</th>
                <th>Bid</th>
                <th>Status</th>
                <th>Sync</th>
              </tr>
            </thead>
            <tbody>
              {structure.map((r, i) => (
                <tr key={`${r.campaign_id}-${r.entity_id}-${i}`}>
                  <td>{shortName(r.campaign_name)}</td>
                  <td>{r.ad_group_name || '-'}</td>
                  <td>{r.entity_type || '-'}</td>
                  <td className="strong">{r.entity_text}</td>
                  <td>{r.match_type || '-'}</td>
                  <td className="num">{money(r.bid)}</td>
                  <td>{r.state || r.serving_status || '-'}</td>
                  <td>{dt(r.last_sync_at || r.updated_at)}</td>
                </tr>
              ))}
              {!structure.length && (
                <tr>
                  <td colSpan="8" className="empty-cell">
                    Nenhuma entidade dessas campanhas no inventario local ainda. O monitor vai exibir assim que o SWARM sincronizar keywords, product targets ou negativas.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      <style>{`
        .partner-monitor .pm-head{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;margin-bottom:14px}
        .partner-monitor h2{margin:0;font-size:24px;line-height:1.15;letter-spacing:0}
        .partner-monitor .pm-head span{display:block;margin-top:4px;color:var(--muted);font-size:13px}
        .partner-monitor .pm-actions{display:flex;align-items:center;gap:12px;color:var(--muted);font-size:12px}
        .partner-monitor .pm-kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin-bottom:14px}
        .partner-monitor .pm-kpis div{border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.035);padding:12px}
        .partner-monitor .pm-kpis b{display:block;font-size:22px;line-height:1;color:#6ea8ff;font-variant-numeric:tabular-nums}
        .partner-monitor .pm-kpis span{display:block;margin-top:7px;color:var(--muted);font-size:12px}
        .partner-monitor .pm-section{margin-top:16px;border-top:1px solid rgba(148,163,184,.14);padding-top:14px}
        .partner-monitor .pm-section.two{display:grid;grid-template-columns:minmax(0,1.25fr) minmax(380px,.75fr);gap:16px}
        .partner-monitor .pm-section-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:9px;color:var(--muted);font-size:12px}
        .partner-monitor .pm-section-head h3{margin:0;color:#9fb8dc;font-size:12px;text-transform:uppercase;letter-spacing:.08em}
        .partner-monitor .pm-cards{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
        .partner-monitor .pm-card{border:1px solid rgba(148,163,184,.16);border-radius:8px;background:rgba(255,255,255,.035);padding:14px;min-width:0}
        .partner-monitor .pm-card-top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
        .partner-monitor .pm-card a{color:#6ea8ff;text-transform:uppercase;letter-spacing:.08em;font-size:11px;font-weight:800;text-decoration:none}
        .partner-monitor .pm-card h4{margin:5px 0 0;font-size:15px;line-height:1.25;color:#fff;letter-spacing:0}
        .partner-monitor .pm-meta{display:flex;flex-wrap:wrap;gap:6px;margin:10px 0;color:var(--muted);font-size:11px}
        .partner-monitor .pm-meta span{border:1px solid rgba(148,163,184,.12);border-radius:6px;padding:4px 6px;background:rgba(0,0,0,.12)}
        .partner-monitor .pm-metrics{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:8px}
        .partner-monitor .pm-metrics div{border:1px solid rgba(148,163,184,.12);border-radius:7px;padding:8px;background:rgba(0,0,0,.12);min-width:0}
        .partner-monitor .pm-metrics span,.partner-monitor .pm-metrics small{display:block;color:var(--muted);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .partner-monitor .pm-metrics b{display:block;margin:4px 0;font-size:16px;color:#fff;font-variant-numeric:tabular-nums}
        .partner-monitor .pm-foot{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px;color:var(--muted);font-size:11px}
        .partner-monitor .pm-foot strong{color:#ffb454;font-weight:800}
        .partner-monitor .pm-table{border:1px solid rgba(148,163,184,.16);border-radius:8px;overflow:auto;background:rgba(255,255,255,.025);max-height:380px}
        .partner-monitor .pm-table.small{max-height:340px}
        .partner-monitor table{width:100%;min-width:900px;border-collapse:collapse;font-size:12px}
        .partner-monitor th{position:sticky;top:0;background:#101626;color:#9fb8dc;text-align:left;padding:10px 12px;text-transform:uppercase;letter-spacing:.08em;font-size:11px}
        .partner-monitor td{padding:10px 12px;border-top:1px solid rgba(148,163,184,.10);vertical-align:middle}
        .partner-monitor .num{text-align:right;font-variant-numeric:tabular-nums}
        .partner-monitor .strong{font-weight:800;color:#fff}
        .partner-monitor .pm-pill{display:inline-flex;align-items:center;min-height:22px;padding:0 8px;border-radius:999px;font-size:11px;font-weight:850;white-space:nowrap}
        .partner-monitor .pm-pill.ok{background:rgba(38,222,129,.14);color:#26de81}
        .partner-monitor .pm-pill.warn{background:rgba(255,159,67,.15);color:#ffb86b}
        .partner-monitor .pm-pill.info{background:rgba(110,168,255,.14);color:#9cc6ff}
        .partner-monitor .pm-alert,.partner-monitor .empty-cell{color:var(--muted);text-align:center;padding:26px 12px}
        @media (max-width: 1120px){.partner-monitor .pm-kpis{grid-template-columns:repeat(2,minmax(0,1fr))}.partner-monitor .pm-cards,.partner-monitor .pm-section.two{grid-template-columns:1fr}.partner-monitor .pm-metrics{grid-template-columns:repeat(3,minmax(0,1fr))}}
        @media (max-width: 760px){.partner-monitor .pm-head{align-items:flex-start;flex-direction:column}.partner-monitor .pm-kpis,.partner-monitor .pm-metrics{grid-template-columns:1fr}.partner-monitor .pm-actions{width:100%;justify-content:space-between}}
      `}</style>
    </div>
  )
}
