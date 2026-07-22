import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const METRICS = [
  { key: 'roas', label: 'ROAS', fmt: v => (v ?? 0).toFixed(2), betterUp: true },
  { key: 'tacos', label: 'TACOS %', fmt: v => (v ?? 0).toFixed(1) + '%', betterUp: false },
  { key: 'acos', label: 'ACOS %', fmt: v => (v ?? 0).toFixed(1) + '%', betterUp: false },
  { key: 'vendas', label: 'Vendas', fmt: v => 'R$ ' + Math.round(v || 0).toLocaleString('pt-BR'), betterUp: true },
  { key: 'cvr', label: 'Conversao %', fmt: v => (v ?? 0).toFixed(1) + '%', betterUp: true },
  { key: 'cpc', label: 'CPC R$', fmt: v => 'R$ ' + (v ?? 0).toFixed(2), betterUp: false },
]
// heat termico p/ ROAS (vermelho ruim -> verde bom, meta 3), opacidade = gasto
function heatColor(roas, spend, maxSpend) {
  if (!spend || spend <= 0) return 'transparent'
  const op = Math.max(0.12, Math.min(1, Math.sqrt(spend / maxSpend)))
  let r, g, b
  if (roas <= 0) { r = 138; g = 136; b = 128 }
  else if (roas < 3) { const t = Math.min(1, roas / 3); r = 208; g = Math.round(59 + t * 120); b = 45 }
  else { const t = Math.min(1, (roas - 3) / 6); r = Math.round(180 - t * 160); g = Math.round(179 + t * 20); b = 45 }
  return `rgba(${r},${g},${b},${op})`
}

function LineChart({ series, mkey, color }) {
  const w = 900, h = 260, pad = { l: 44, r: 12, t: 12, b: 26 }
  const pts = series.map((d, i) => ({ i, x: d.date, y: Number(d[mkey]) })).filter(p => Number.isFinite(p.y))
  if (pts.length < 2) return <div style={{ color: 'var(--muted,#8aa0c0)', padding: 20 }}>Dados insuficientes.</div>
  const ys = pts.map(p => p.y)
  const ymin = Math.min(...ys), ymax = Math.max(...ys)
  const range = ymax - ymin || 1
  const px = i => pad.l + (i / (pts.length - 1)) * (w - pad.l - pad.r)
  const py = y => pad.t + (1 - (y - ymin) / range) * (h - pad.t - pad.b)
  const path = pts.map((p, i) => `${i === 0 ? 'M' : 'L'}${px(i).toFixed(1)},${py(p.y).toFixed(1)}`).join(' ')
  const gridY = [ymin, ymin + range / 2, ymax]
  const lastIdx = Math.max(0, pts.length - 5)
  return (
    <svg viewBox={`0 0 ${w} ${h}`} style={{ width: '100%', height: 'auto' }} role="img" aria-label={`Serie de ${mkey}`}>
      {gridY.map((gy, k) => (
        <g key={k}>
          <line x1={pad.l} x2={w - pad.r} y1={py(gy)} y2={py(gy)} stroke="var(--border,#2a3550)" strokeWidth="1" />
          <text x={pad.l - 6} y={py(gy) + 3} textAnchor="end" fontSize="10" fill="var(--muted,#8aa0c0)">{gy.toFixed(gy < 10 ? 2 : 0)}</text>
        </g>
      ))}
      {pts.filter((_, i) => i % Math.ceil(pts.length / 8) === 0 || i === pts.length - 1).map((p, k) => (
        <text key={k} x={px(p.i)} y={h - 8} textAnchor="middle" fontSize="9.5" fill="var(--muted,#8aa0c0)">{p.x.slice(5)}</text>
      ))}
      <path d={path} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />
      {pts.slice(lastIdx).map((p) => <circle key={p.i} cx={px(p.i)} cy={py(p.y)} r="2.5" fill={color} />)}
      <circle cx={px(pts.length - 1)} cy={py(pts[pts.length - 1].y)} r="4" fill={color} stroke="var(--card-bg,#0b1220)" strokeWidth="1.5" />
    </svg>
  )
}

function Delta({ label, cur, prev, betterUp, fmt }) {
  const muted = { color: 'var(--muted,#8aa0c0)' }
  let pct = null, good = null
  if (Number.isFinite(cur) && Number.isFinite(prev) && prev !== 0) {
    pct = ((cur - prev) / Math.abs(prev)) * 100
    good = betterUp ? pct >= 0 : pct <= 0
  }
  return (
    <div style={{ background: 'var(--card-bg,#1e1e2e)', borderRadius: 8, padding: '8px 12px', minWidth: 96 }}>
      <div style={{ fontSize: 11, ...muted }}>{label}</div>
      <div style={{ fontSize: 15, fontWeight: 700 }}>{Number.isFinite(prev) ? fmt(prev) : '—'}</div>
      {pct === null ? <div style={{ fontSize: 11, ...muted }}>—</div>
        : <div style={{ fontSize: 11, color: good ? '#86efac' : '#fca5a5' }}>{pct >= 0 ? '▲' : '▼'} {Math.abs(pct).toFixed(0)}%</div>}
    </div>
  )
}

// uma linha do heatmap: nome da keyword (sticky) + 24 celulas hora
function FragmentKwRow({ kw, cells, max, muted }) {
  return (
    <>
      <div title={kw} style={{ position: 'sticky', left: 0, background: 'var(--card-bg,#0b1220)', zIndex: 1, fontSize: 10.5, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', paddingRight: 6, lineHeight: '20px' }}>{kw}</div>
      {Array.from({ length: 24 }, (_, h) => {
        const c = cells[h]
        const roas = c ? Number(c.roas) : 0
        const spend = c ? Number(c.spend) : 0
        return (
          <div key={h}
            title={c ? `${kw} · ${String(h).padStart(2, '0')}h\nROAS ${roas.toFixed(2)} · gasto R$ ${spend.toFixed(2)} · vendas R$ ${Number(c.sales || 0).toFixed(2)}` : `${String(h).padStart(2, '0')}h · sem gasto`}
            style={{ height: 20, borderRadius: 2, background: heatColor(roas, spend, max), border: '1px solid var(--border,#1a2238)' }} />
        )
      })}
    </>
  )
}

export default function MetricasDayparting({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState({ series: [], campaigns: [] })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [mkey, setMkey] = useState('roas')
  const [campaign, setCampaign] = useState('')

  const [heat, setHeat] = useState({ cells: [] })
  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const res = await api.goldDaypartingMetrics(tenantID, campaign)
      if (!res?.ok) throw new Error(res?.data?.error || 'falha')
      setData(res.data || { series: [] })
    } catch (e) { setError(e?.message || 'Falha ao carregar') } finally { setLoading(false) }
  }, [tenantID, campaign])
  useEffect(() => { load() }, [load])
  useEffect(() => {
    let alive = true
    api.goldDaypartingKeywordHeatmap(tenantID).then(r => { if (alive && r?.ok) setHeat(r.data || { cells: [] }) }).catch(() => {})
    return () => { alive = false }
  }, [tenantID])

  const metric = METRICS.find(m => m.key === mkey)
  const series = data.series || []
  // DoD/WoW/MoM computados da propria serie (ultimo dia vs D-1, D-7, D-30)
  const L = useMemo(() => {
    if (!series.length) return {}
    const byDate = {}; series.forEach(d => { byDate[d.date] = d })
    const last = series[series.length - 1]
    const shift = (days) => {
      const dt = new Date(last.date); dt.setDate(dt.getDate() - days)
      return byDate[dt.toISOString().slice(0, 10)]
    }
    const out = { date: last.date }
    METRICS.forEach(m => {
      out[m.key] = Number(last[m.key])
      out[m.key + '_dod'] = Number(shift(1)?.[m.key])
      out[m.key + '_wow'] = Number(shift(7)?.[m.key])
      out[m.key + '_mom'] = Number(shift(30)?.[m.key])
    })
    return out
  }, [series])
  const color = { roas: '#3987e5', tacos: '#eb6834', acos: '#d55181', vendas: '#199e70', cvr: '#1baf7a', cpc: '#eda100' }[mkey]
  const muted = { color: 'var(--muted,#8aa0c0)' }
  const cur = Number(L[mkey])

  const kwHeat = useMemo(() => {
    const cells = heat.cells || []
    const max = Math.max(1, ...cells.map(c => c.spend || 0))
    const byKw = {}, order = []
    cells.forEach(c => {
      if (!byKw[c.keyword_text]) { byKw[c.keyword_text] = {}; order.push(c.keyword_text) }
      byKw[c.keyword_text][c.event_hour] = c
    })
    return { order, byKw, max }
  }, [heat])

  return (
    <div style={{ maxWidth: 1000, color: 'var(--fg,#e6edf7)' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
        <div>
          <h2 style={{ margin: 0 }}>Medicao — Resultado do Dayparting</h2>
          <p style={{ ...muted, fontSize: 12.5, marginTop: 4 }}>Historico diario global. ROAS, TACOS, Conversao, CPC. Comparativo DoD / WoW / MoM. Base do aprendizado semanal.</p>
        </div>
        <button className="btn" onClick={load} style={{ fontSize: 12 }}>Atualizar</button>
      </div>

      {loading && <p style={muted}>Carregando...</p>}
      {error && <div style={{ padding: 10, borderRadius: 8, background: 'rgba(220,60,60,.15)', color: '#fca5a5', fontSize: 13 }}>{error}</div>}

      {!loading && !error && (
        <>
          <div style={{ display: 'flex', gap: 10, margin: '14px 0', alignItems: 'center', flexWrap: 'wrap' }}>
            <select value={campaign} onChange={e => setCampaign(e.target.value)}
              style={{ padding: '7px 10px', borderRadius: 8, border: '1px solid var(--border,#2a3550)', background: 'var(--card-bg,#0b1220)', color: 'inherit', fontSize: 13, minWidth: 220 }}>
              <option value="">Global (todas as campanhas)</option>
              {(data.campaigns || []).map(c => <option key={c.campaign_name} value={c.campaign_name}>{c.campaign_name}</option>)}
            </select>
            <div style={{ display: 'flex', gap: 8 }}>
              {METRICS.map(m => {
                const disabled = campaign && m.key === 'tacos'
                return (
                  <button key={m.key} className="btn" disabled={disabled} onClick={() => setMkey(m.key)} title={disabled ? 'TACOS so no nivel global (precisa da venda total da conta)' : ''}
                    style={{ fontSize: 13, borderColor: mkey === m.key ? 'var(--accent,#3b82f6)' : undefined, color: mkey === m.key ? 'var(--accent,#93c5fd)' : undefined }}>{m.label}</button>
                )
              })}
            </div>
          </div>

          <div style={{ display: 'flex', alignItems: 'baseline', gap: 14, marginBottom: 6 }}>
            <span style={muted}>Hoje ({L.date || '—'}):</span>
            <span style={{ fontSize: 26, fontWeight: 700, color }}>{Number.isFinite(cur) ? metric.fmt(cur) : '—'}</span>
            <div style={{ display: 'flex', gap: 10 }}>
              <Delta label="DoD (ontem)" cur={cur} prev={Number(L[mkey + '_dod'])} betterUp={metric.betterUp} fmt={metric.fmt} />
              <Delta label="WoW (7d)" cur={cur} prev={Number(L[mkey + '_wow'])} betterUp={metric.betterUp} fmt={metric.fmt} />
              <Delta label="MoM (30d)" cur={cur} prev={Number(L[mkey + '_mom'])} betterUp={metric.betterUp} fmt={metric.fmt} />
            </div>
          </div>

          <div style={{ border: '1px solid var(--border,#2a3550)', borderRadius: 12, padding: 12 }}>
            <LineChart series={series} mkey={mkey} color={color} />
          </div>

          <div style={{ ...muted, fontSize: 11.5, marginTop: 8 }}>
            {series.length} dia(s) · a linha e o valor diario; os cards comparam hoje com ontem (DoD), 7 dias (WoW) e 30 dias (MoM).
            Verde = melhorou ({metric.betterUp ? 'maior' : 'menor'} e melhor).
          </div>

          <h3 style={{ margin: '24px 0 6px' }}>Heatmap geral — todas as keywords &times; hora <span style={{ ...muted, fontWeight: 400, fontSize: 12 }}>(ROAS, trailing 28d)</span></h3>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, ...muted, fontSize: 11.5, marginBottom: 8 }}>
            <span><span style={{ display: 'inline-block', width: 11, height: 11, background: 'rgba(208,59,45,.9)', borderRadius: 2, marginRight: 4 }} />ROAS &lt; 3</span>
            <span><span style={{ display: 'inline-block', width: 11, height: 11, background: 'rgba(180,179,45,.9)', borderRadius: 2, marginRight: 4 }} />&asymp; 3</span>
            <span><span style={{ display: 'inline-block', width: 11, height: 11, background: 'rgba(20,199,65,.9)', borderRadius: 2, marginRight: 4 }} />&gt; 3</span>
            <span>opacidade = gasto · {kwHeat.order.length} keyword(s)</span>
          </div>
          <div style={{ overflow: 'auto', maxHeight: 540, border: '1px solid var(--border,#2a3550)', borderRadius: 10 }}>
            <div style={{ display: 'grid', gridTemplateColumns: `180px repeat(24, 24px)`, gap: 1, minWidth: 180 + 24 * 25, padding: 6 }}>
              <div style={{ position: 'sticky', left: 0, background: 'var(--card-bg,#0b1220)', zIndex: 2 }} />
              {Array.from({ length: 24 }, (_, h) => <div key={h} style={{ ...muted, fontSize: 9.5, textAlign: 'center' }}>{String(h).padStart(2, '0')}</div>)}
              {kwHeat.order.map(kw => (
                <FragmentKwRow key={kw} kw={kw} cells={kwHeat.byKw[kw]} max={kwHeat.max} muted={muted} />
              ))}
            </div>
          </div>
          <p style={{ ...muted, fontSize: 11, marginTop: 6 }}>Ordenado por gasto. Célula = ROAS daquela keyword×hora; passe o mouse para gasto/ROAS. Verde forte = hora que converte bem (candidata a bid cheio); vermelho = hora fraca (candidata a corte).</p>
        </>
      )}
    </div>
  )
}
