import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

function num(v) { return v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR') }

// cor da celula pela razao impressoes/baseline daquela hora.
function cellColor(impr, base) {
  if (!base || base < 3) return { bg: 'var(--panel-3)', fg: 'var(--muted)', tag: 'morta' }   // hora naturalmente fraca
  const r = impr / base
  if (r >= 0.8) return { bg: 'rgba(49,211,154,.22)', fg: '#31d39a', tag: 'ok' }               // >=80% baseline
  if (r >= 0.4) return { bg: 'rgba(255,180,84,.22)', fg: '#ffb454', tag: 'baixa' }             // 40-80%
  return { bg: 'rgba(255,107,107,.28)', fg: '#ff6b6b', tag: 'anomala' }                        // <40% numa hora ativa
}

export default function HourlyDeliveryRadar({ ctx }) {
  const [days, setDays] = useState(7)
  const [campaign, setCampaign] = useState('')
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    setLoading(true); setError('')
    api.goldHourlyDeliveryRadar(ctx.tenantID, { days, campaign })
      .then(res => setData(res.ok ? res.data : null))
      .catch(e => setError(e?.message || 'falha ao carregar'))
      .finally(() => setLoading(false))
  }, [days, campaign, ctx.tenantID])

  const baseByHour = useMemo(() => {
    const m = {}
    for (const b of data?.baseline || []) m[b.event_hour] = b.baseline_impr || 0
    return m
  }, [data])

  const grid = useMemo(() => {
    // { date: { hour: {impr,clk,spend} } }
    const g = {}
    for (const c of data?.grid || []) {
      g[c.data_date] = g[c.data_date] || {}
      g[c.data_date][c.event_hour] = c
    }
    return g
  }, [data])

  const dates = useMemo(() => Object.keys(grid).sort().reverse(), [grid])
  const hours = Array.from({ length: 24 }, (_, i) => i)
  const campaigns = data?.campaigns || []

  // quantas celulas anomalas (queda em hora ativa) — o titular do insight
  const anomalias = useMemo(() => {
    let n = 0
    for (const d of dates) for (const hh of hours) {
      const cell = grid[d]?.[hh]
      const base = baseByHour[hh]
      if (cell && base >= 3 && (cell.impressions / base) < 0.4) n++
    }
    return n
  }, [dates, grid, baseByHour])

  return (
    <section className="hdr">
      <style>{`
        .hdr { display:flex; flex-direction:column; gap:14px; color:var(--text); }
        .hdr-tools { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
        .hdr-tools select { border:1px solid var(--line); background:var(--panel-2); color:var(--text); border-radius:10px; padding:7px 10px; font-size:13px; }
        .hdr-note { color:var(--muted); font-size:12px; }
        .hdr-legend { display:flex; gap:14px; flex-wrap:wrap; font-size:12px; color:var(--muted); }
        .hdr-legend b { display:inline-block; width:12px; height:12px; border-radius:3px; margin-right:5px; vertical-align:-1px; }
        .hdr-wrap { overflow:auto; border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); box-shadow:var(--shadow); }
        table.hdr-t { border-collapse:collapse; min-width:900px; }
        .hdr-t th,.hdr-t td { padding:5px 6px; text-align:center; font-size:11px; border-bottom:1px solid var(--line); }
        .hdr-t th { background:var(--panel-2); color:var(--muted); position:sticky; top:0; }
        .hdr-t td.d { text-align:left; color:var(--text); white-space:nowrap; font-weight:600; background:var(--panel-2); position:sticky; left:0; }
        .hdr-cell { border-radius:4px; min-width:30px; }
        .hdr-base td { color:var(--muted); font-style:italic; background:var(--panel); }
        .hdr-kpi { border:1px solid var(--line); border-radius:12px; background:var(--panel); padding:12px 16px; display:inline-block; }
        .hdr-kpi span { color:var(--muted); font-size:12px; } .hdr-kpi strong { display:block; font-size:22px; }
      `}</style>

      <div className="hdr-tools">
        <select value={days} onChange={e => setDays(Number(e.target.value))}>
          <option value={7}>7 dias</option><option value={14}>14 dias</option><option value={30}>30 dias</option>
        </select>
        <select value={campaign} onChange={e => setCampaign(e.target.value)}>
          <option value="">Conta inteira</option>
          {campaigns.map(c => <option key={c.campaign_name} value={c.campaign_name}>{c.campaign_name} · {num(c.impressions)} impr</option>)}
        </select>
        {loading && <span className="hdr-note">Carregando…</span>}
        {error && <span className="hdr-note" style={{ color: '#ff6b6b' }}>{error}</span>}
      </div>

      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <div className="hdr-kpi"><span>Horas anômalas (queda &lt;40% da hora normal)</span><strong style={{ color: anomalias > 0 ? '#ff6b6b' : '#31d39a' }}>{anomalias}</strong></div>
        <div className="hdr-legend">
          <span><b style={{ background: 'rgba(49,211,154,.6)' }} />normal (≥80%)</span>
          <span><b style={{ background: 'rgba(255,180,84,.6)' }} />baixa (40–80%)</span>
          <span><b style={{ background: 'rgba(255,107,107,.7)' }} />anômala (&lt;40%)</span>
          <span><b style={{ background: 'var(--panel-3)' }} />hora morta natural</span>
        </div>
      </div>
      <div className="hdr-note">Célula = impressões daquela hora vs o baseline (mediana 28d) da MESMA hora. Vermelho = seu anúncio entregou bem menos que o normal ali (perdeu leilão / bid baixo), não é hora fraca. Impression share por hora a Amazon não fornece — este é o proxy honesto de entrega.</div>

      <div className="hdr-wrap">
        <table className="hdr-t">
          <thead>
            <tr><th className="d">Dia \ Hora</th>{hours.map(hh => <th key={hh}>{String(hh).padStart(2, '0')}</th>)}</tr>
          </thead>
          <tbody>
            <tr className="hdr-base"><td className="d">baseline (28d)</td>{hours.map(hh => <td key={hh}>{baseByHour[hh] ?? 0}</td>)}</tr>
            {dates.map(d => (
              <tr key={d}>
                <td className="d">{d.slice(5)}</td>
                {hours.map(hh => {
                  const cell = grid[d]?.[hh]
                  const impr = cell?.impressions ?? 0
                  const base = baseByHour[hh] ?? 0
                  const c = cellColor(impr, base)
                  return (
                    <td key={hh}>
                      <div className="hdr-cell" style={{ background: c.bg, color: c.fg, padding: '4px 2px' }}
                        title={`${d} ${String(hh).padStart(2, '0')}h · ${impr} impr (baseline ${base}) · ${cell?.clicks ?? 0} cliques · R$${cell?.spend ?? 0}`}>
                        {impr}
                      </div>
                    </td>
                  )
                })}
              </tr>
            ))}
            {!dates.length && !loading && <tr><td className="d" colSpan={25}>Sem dado horário no período.</td></tr>}
          </tbody>
        </table>
      </div>
    </section>
  )
}
