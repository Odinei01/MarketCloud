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
// heat termico p/ ROAS (vermelho ruim -> verde bom, meta 3), opacidade = gasto.
// ROAS<=0 (gastou e nao vendeu, ou reembolso) = PIOR caso = vermelho forte.
function heatColor(roas, spend, maxSpend) {
  if (!spend || spend <= 0) return 'transparent'
  const op = Math.max(0.3, Math.min(1, Math.sqrt(spend / maxSpend)))
  let r, g, b
  if (roas < 3) {
    // 0 (ou negativo) = vermelho puro; sobe pra amarelo conforme chega em 3
    const t = Math.max(0, Math.min(1, roas / 3))
    r = 208; g = Math.round(45 + t * 145); b = 45
  } else {
    // 3 = amarelo-esverdeado; sobe pra verde forte
    const t = Math.min(1, (roas - 3) / 6)
    r = Math.round(190 - t * 170); g = Math.round(190 + t * 20); b = 45
  }
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

// motor deterministico de "esverdear": placar (% verde hoje -> potencial) + acoes
const ACTION_STYLE = {
  FEED: { bg: '#14c741', fg: '#062', label: 'ALIMENTAR' },
  CUT: { bg: '#d03b2d', fg: '#fff', label: 'CORTAR' },
  KEEP: { bg: '#3987e5', fg: '#fff', label: 'MANTER' },
  HOLD: { bg: '#5a6b85', fg: '#fff', label: 'AGUARDAR' },
}
const KWFLAG_STYLE = {
  MATAR: { bg: '#8b1a1a', fg: '#fff', label: 'MATAR KW' },
  VIGIAR: { bg: '#b8860b', fg: '#fff', label: 'VIGIAR KW' },
}
function Chip({ s }) {
  return <span style={{ background: s.bg, color: s.fg, fontSize: 10.5, fontWeight: 700, padding: '2px 7px', borderRadius: 5, whiteSpace: 'nowrap' }}>{s.label}</span>
}
function GreeningPanel({ sb, actions, muted }) {
  const hoje = Number(sb.pct_verde_hoje) || 0
  const pot = Number(sb.pct_verde_potencial) || 0
  const card = { background: 'var(--card-bg,#1e1e2e)', borderRadius: 10, padding: '10px 14px', minWidth: 120 }
  return (
    <div style={{ marginTop: 22, border: '1px solid var(--border,#2a3550)', borderRadius: 12, padding: 14 }}>
      <h3 style={{ margin: '0 0 2px' }}>Motor de esverdeamento <span style={{ ...muted, fontWeight: 400, fontSize: 12 }}>(deterministico · janela madura 28-7d · meta ROAS 3)</span></h3>
      <p style={{ ...muted, fontSize: 11.5, margin: '0 0 12px' }}>Regra fixa por celula. Mesma entrada = mesma saida. So recomenda — nao gasta.</p>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'stretch' }}>
        <div style={{ ...card, flex: '1 1 260px' }}>
          <div style={{ fontSize: 11.5, ...muted }}>% do gasto em hora verde (ROAS &ge; 3)</div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginTop: 4 }}>
            <span style={{ fontSize: 30, fontWeight: 800, color: '#14c741' }}>{hoje.toFixed(0)}%</span>
            <span style={{ ...muted }}>hoje &nbsp;&rarr;&nbsp; <b style={{ color: '#8fe3a5' }}>{pot.toFixed(0)}%</b> potencial (cortando o morto)</span>
          </div>
          <div style={{ marginTop: 8, height: 10, borderRadius: 6, background: 'var(--border,#2a3550)', overflow: 'hidden', position: 'relative' }}>
            <div style={{ position: 'absolute', inset: 0, width: pot + '%', background: 'rgba(20,199,65,.28)' }} />
            <div style={{ position: 'absolute', inset: 0, width: hoje + '%', background: '#14c741' }} />
          </div>
        </div>
        <div style={card}><div style={{ fontSize: 11.5, ...muted }}>A cortar (morto)</div><div style={{ fontSize: 20, fontWeight: 700, color: '#fca5a5' }}>R$ {Number(sb.gasto_a_cortar || 0).toFixed(0)}</div><div style={{ fontSize: 10.5, ...muted }}>{sb.n_cortar} hora(s)</div></div>
        <div style={card}><div style={{ fontSize: 11.5, ...muted }}>A alimentar (vencedor)</div><div style={{ fontSize: 20, fontWeight: 700, color: '#8fe3a5' }}>R$ {Number(sb.gasto_a_alimentar || 0).toFixed(0)}</div><div style={{ fontSize: 10.5, ...muted }}>{sb.n_alimentar} hora(s)</div></div>
        <div style={card}><div style={{ fontSize: 11.5, ...muted }}>Aguardando dado</div><div style={{ fontSize: 20, fontWeight: 700 }}>{sb.n_aguardar}</div><div style={{ fontSize: 10.5, ...muted }}>celulas fracas</div></div>
        <div style={card}><div style={{ fontSize: 11.5, ...muted }}>Keywords</div><div style={{ fontSize: 20, fontWeight: 700, color: '#eab308' }}>{sb.n_keywords_matar} / {sb.n_keywords_vigiar}</div><div style={{ fontSize: 10.5, ...muted }}>matar / vigiar</div></div>
      </div>

      {actions?.length > 0 && (
        <div style={{ marginTop: 12, overflow: 'auto', maxHeight: 320 }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead><tr style={{ ...muted, textAlign: 'left' }}>
              <th style={{ padding: '4px 8px' }}>Acao</th><th style={{ padding: '4px 8px' }}>Keyword</th>
              <th style={{ padding: '4px 8px' }}>Hora</th><th style={{ padding: '4px 8px', textAlign: 'right' }}>ROAS</th>
              <th style={{ padding: '4px 8px', textAlign: 'right' }}>Gasto</th><th style={{ padding: '4px 8px', textAlign: 'right' }}>Mult.</th>
              <th style={{ padding: '4px 8px' }}>Motivo</th>
            </tr></thead>
            <tbody>
              {actions.map((a, i) => {
                const as = ACTION_STYLE[a.action] || ACTION_STYLE.HOLD
                const kf = KWFLAG_STYLE[a.kw_flag]
                return (
                  <tr key={i} style={{ borderTop: '1px solid var(--border,#1a2238)' }}>
                    <td style={{ padding: '4px 8px', display: 'flex', gap: 4, alignItems: 'center' }}><Chip s={as} />{kf && <Chip s={kf} />}</td>
                    <td style={{ padding: '4px 8px' }}>{a.keyword_text}</td>
                    <td style={{ padding: '4px 8px' }}>{String(a.event_hour).padStart(2, '0')}h</td>
                    <td style={{ padding: '4px 8px', textAlign: 'right' }}>{Number(a.shrunk_roas).toFixed(1)}</td>
                    <td style={{ padding: '4px 8px', textAlign: 'right' }}>R$ {Number(a.spend).toFixed(2)}</td>
                    <td style={{ padding: '4px 8px', textAlign: 'right' }}>{a.suggested_multiplier == null ? '—' : a.suggested_multiplier + '%'}</td>
                    <td style={{ padding: '4px 8px', ...muted, fontSize: 11 }}>{a.reason}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

// 3 alavancas sobre o mesmo sinal de demanda, governadas pela estabilidade da janela
const READY_STYLE = { READY: { bg: '#14c741', fg: '#062' }, EMERGING: { bg: '#b8860b', fg: '#fff' }, THIN: { bg: '#5a6b85', fg: '#fff' } }
function WindowsPanel({ win, muted }) {
  const card = { background: 'var(--card-bg,#1e1e2e)', borderRadius: 10, padding: '10px 14px' }
  const th = { padding: '4px 8px', textAlign: 'left' }
  const readyCount = (win.stability || []).find(s => s.readiness === 'READY')?.janelas || 0
  const emergCount = (win.stability || []).find(s => s.readiness === 'EMERGING')?.janelas || 0
  const thinCount = (win.stability || []).find(s => s.readiness === 'THIN')?.janelas || 0
  return (
    <div style={{ marginTop: 18, border: '1px solid var(--border,#2a3550)', borderRadius: 12, padding: 14 }}>
      <h3 style={{ margin: '0 0 2px' }}>Janelas &amp; alavancas <span style={{ ...muted, fontWeight: 400, fontSize: 12 }}>(dia &times; daypart · 6 semanas · deterministico)</span></h3>
      <p style={{ ...muted, fontSize: 11.5, margin: '0 0 12px' }}>Uma janela so libera dinheiro (bid, primeira pagina, preco) quando converte alto <b>e repete</b> entre semanas. Enquanto e magra/instavel, fica em espera. So recomenda.</p>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
        <div style={{ ...card, borderLeft: '3px solid #14c741' }}><div style={{ fontSize: 11, ...muted }}>Prontas (READY)</div><div style={{ fontSize: 20, fontWeight: 800, color: '#14c741' }}>{readyCount}</div></div>
        <div style={{ ...card, borderLeft: '3px solid #b8860b' }}><div style={{ fontSize: 11, ...muted }}>Emergindo</div><div style={{ fontSize: 20, fontWeight: 800, color: '#eab308' }}>{emergCount}</div></div>
        <div style={{ ...card, borderLeft: '3px solid #5a6b85' }}><div style={{ fontSize: 11, ...muted }}>Em espera (magra)</div><div style={{ fontSize: 20, fontWeight: 800 }}>{thinCount}</div></div>
      </div>

      <div style={{ fontSize: 12.5, fontWeight: 700, margin: '6px 0 4px' }}>🟦 Primeira pagina (top-of-search) — candidatas <span style={{ ...muted, fontWeight: 400, fontSize: 11 }}>· executor gated OFF</span></div>
      {(win.placement || []).length === 0
        ? <div style={{ ...muted, fontSize: 12, padding: '4px 8px' }}>Nenhuma janela madura o bastante ainda. Acumulando dado.</div>
        : <div style={{ overflow: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead><tr style={muted}><th style={th}>Campanha</th><th style={th}>Daypart</th><th style={th}>Dia</th><th style={{ ...th, textAlign: 'right' }}>ROAS</th><th style={{ ...th, textAlign: 'center' }}>Semanas verdes</th><th style={{ ...th, textAlign: 'center' }}>Prontidao</th><th style={{ ...th, textAlign: 'right' }}>Boost 1a pag.</th></tr></thead>
            <tbody>{win.placement.map((p, i) => { const rs = READY_STYLE[p.readiness] || READY_STYLE.THIN; return (
              <tr key={i} style={{ borderTop: '1px solid var(--border,#1a2238)' }}>
                <td style={th}>{p.campaign_name || '(sem nome)'}</td><td style={th}>{p.daypart}</td><td style={th}>{p.day_bucket === 'fim_semana' ? 'fim sem.' : 'util'}</td>
                <td style={{ ...th, textAlign: 'right' }}>{Number(p.roas).toFixed(1)}</td><td style={{ ...th, textAlign: 'center' }}>{p.weeks_green}</td>
                <td style={{ ...th, textAlign: 'center' }}><span style={{ background: rs.bg, color: rs.fg, fontSize: 10, fontWeight: 700, padding: '1px 6px', borderRadius: 4 }}>{p.readiness}</span></td>
                <td style={{ ...th, textAlign: 'right', color: '#8fe3a5', fontWeight: 700 }}>+{p.suggested_tos_boost_pct}%</td>
              </tr>) })}</tbody>
          </table></div>}

      <div style={{ fontSize: 12.5, fontWeight: 700, margin: '14px 0 4px' }}>💲 Pricing — candidatas a teste de premio <span style={{ ...muted, fontWeight: 400, fontSize: 11 }}>· alimenta o robo de preco · nao mexe preco</span></div>
      {(win.pricing || []).length === 0
        ? <div style={{ ...muted, fontSize: 12, padding: '4px 8px' }}>Nenhuma janela estavel o bastante p/ testar preco (precisa READY + ROAS &ge; 6, repetido). Correto: nao se sobe preco em pico de 1 semana.</div>
        : <div style={{ overflow: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead><tr style={muted}><th style={th}>Keyword</th><th style={th}>Daypart</th><th style={th}>Dia</th><th style={{ ...th, textAlign: 'center' }}>Semanas verdes</th><th style={{ ...th, textAlign: 'right' }}>ROAS</th></tr></thead>
            <tbody>{win.pricing.map((p, i) => (
              <tr key={i} style={{ borderTop: '1px solid var(--border,#1a2238)' }}>
                <td style={th}>{p.keyword_text}</td><td style={th}>{p.daypart}</td><td style={th}>{p.day_bucket === 'fim_semana' ? 'fim sem.' : 'util'}</td>
                <td style={{ ...th, textAlign: 'center' }}>{p.weeks_green}</td><td style={{ ...th, textAlign: 'right' }}>{Number(p.roas).toFixed(1)}</td>
              </tr>))}</tbody>
          </table></div>}
    </div>
  )
}

// heatmap AUTORITATIVO: campanha x hora na fonte rica (desde 31/05) + curva global
function RichCurvePanel({ rich, muted }) {
  const cells = rich.campaign || []
  const gl = rich.global || []
  const max = Math.max(1, ...cells.map(c => Number(c.spend) || 0))
  const byCamp = {}, order = []
  cells.forEach(c => {
    if (!byCamp[c.campaign_name]) { byCamp[c.campaign_name] = {}; order.push(c.campaign_name) }
    byCamp[c.campaign_name][c.event_hour] = c
  })
  const glMax = Math.max(1, ...gl.map(g => Number(g.spend) || 0))
  return (
    <div style={{ marginTop: 22, border: '1px solid var(--border,#2a3550)', borderRadius: 12, padding: 14 }}>
      <h3 style={{ margin: '0 0 2px' }}>Dayparting real — campanha &times; hora <span style={{ color: '#14c741', fontWeight: 700, fontSize: 12 }}>(fonte rica, desde 31/05)</span></h3>
      <p style={{ ...muted, fontSize: 11.5, margin: '0 0 12px' }}>Base autoritativa (~3257 cliques, cobre campanhas auto). Cor = ROAS (verde &ge;3), opacidade = gasto.</p>

      {/* curva global 24h */}
      <div style={{ marginBottom: 10 }}>
        <div style={{ ...muted, fontSize: 11, marginBottom: 3 }}>GLOBAL (todas as campanhas empilhadas)</div>
        <div style={{ display: 'grid', gridTemplateColumns: `repeat(24, 1fr)`, gap: 1 }}>
          {gl.map(g => (
            <div key={g.event_hour} title={`${String(g.event_hour).padStart(2,'0')}h · ROAS ${Number(g.roas).toFixed(1)} · ${g.clicks} cl · R$ ${Number(g.spend).toFixed(0)}`}
              style={{ height: 26, borderRadius: 2, background: heatColor(Number(g.roas), Number(g.spend), glMax), border: '1px solid var(--border,#1a2238)', fontSize: 8, textAlign: 'center', lineHeight: '26px', color: 'rgba(255,255,255,.6)' }}>
              {g.event_hour}
            </div>
          ))}
        </div>
      </div>

      <div style={{ overflow: 'auto', maxHeight: 460, border: '1px solid var(--border,#2a3550)', borderRadius: 10 }}>
        <div style={{ display: 'grid', gridTemplateColumns: `160px repeat(24, 22px)`, gap: 1, minWidth: 160 + 24 * 23, padding: 6 }}>
          <div style={{ position: 'sticky', left: 0, background: 'var(--card-bg,#0b1220)', zIndex: 2 }} />
          {Array.from({ length: 24 }, (_, h) => <div key={h} style={{ ...muted, fontSize: 9, textAlign: 'center' }}>{String(h).padStart(2, '0')}</div>)}
          {order.map(camp => (
            <FragmentCampRow key={camp} camp={camp} cells={byCamp[camp]} max={max} muted={muted} />
          ))}
        </div>
      </div>
    </div>
  )
}
function FragmentCampRow({ camp, cells, max, muted }) {
  return (
    <>
      <div title={camp} style={{ position: 'sticky', left: 0, background: 'var(--card-bg,#0b1220)', zIndex: 1, fontSize: 10, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', paddingRight: 6, lineHeight: '18px' }}>{camp}</div>
      {Array.from({ length: 24 }, (_, h) => {
        const c = cells[h]
        const roas = c ? Number(c.roas) : 0
        const spend = c ? Number(c.spend) : 0
        return (
          <div key={h}
            title={c ? `${camp} · ${String(h).padStart(2, '0')}h\nROAS ${roas.toFixed(2)} · ${c.clicks} cl · gasto R$ ${spend.toFixed(2)}` : `${String(h).padStart(2, '0')}h · sem gasto`}
            style={{ height: 18, borderRadius: 2, background: heatColor(roas, spend, max), border: '1px solid var(--border,#1a2238)' }} />
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
  const [dow, setDow] = useState('')
  const [green, setGreen] = useState({ scoreboard: null, actions: [] })
  const [win, setWin] = useState({ stability: [], placement: [], pricing: [] })
  const [rich, setRich] = useState({ campaign: [], global: [] })
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
    api.goldDaypartingKeywordHeatmap(tenantID, dow).then(r => { if (alive && r?.ok) setHeat(r.data || { cells: [] }) }).catch(() => {})
    return () => { alive = false }
  }, [tenantID, dow])
  useEffect(() => {
    let alive = true
    api.goldDaypartingGreening(tenantID).then(r => { if (alive && r?.ok) setGreen(r.data || { scoreboard: null, actions: [] }) }).catch(() => {})
    return () => { alive = false }
  }, [tenantID])
  useEffect(() => {
    let alive = true
    api.goldDaypartingWindows(tenantID).then(r => { if (alive && r?.ok) setWin(r.data || { stability: [], placement: [], pricing: [] }) }).catch(() => {})
    return () => { alive = false }
  }, [tenantID])
  useEffect(() => {
    let alive = true
    api.goldDaypartCurveRich(tenantID).then(r => { if (alive && r?.ok) setRich(r.data || { campaign: [], global: [] }) }).catch(() => {})
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

          {green.scoreboard && <GreeningPanel sb={green.scoreboard} actions={green.actions} muted={muted} />}

          <WindowsPanel win={win} muted={muted} />

          <RichCurvePanel rich={rich} muted={muted} />

          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, margin: '24px 0 6px', flexWrap: 'wrap' }}>
            <h3 style={{ margin: 0 }}>Heatmap keyword &times; hora <span style={{ ...muted, fontWeight: 400, fontSize: 12 }}>(stream esparso desde 19/06 — baixa confianca, so ~3 keywords com dado)</span></h3>
            <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
              {[['', 'Tudo'], ['weekday', 'Uteis'], ['weekend', 'Fim de semana'], ['1', 'Seg'], ['2', 'Ter'], ['3', 'Qua'], ['4', 'Qui'], ['5', 'Sex'], ['6', 'Sab'], ['7', 'Dom']].map(([v, lbl]) => (
                <button key={v || 'all'} onClick={() => setDow(v)}
                  style={{ fontSize: 11.5, padding: '4px 9px', borderRadius: 7, cursor: 'pointer',
                    border: '1px solid var(--border,#2a3550)',
                    background: dow === v ? '#3987e5' : 'var(--card-bg,#0b1220)',
                    color: dow === v ? '#fff' : 'inherit', fontWeight: dow === v ? 700 : 400 }}>{lbl}</button>
              ))}
            </div>
          </div>
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
