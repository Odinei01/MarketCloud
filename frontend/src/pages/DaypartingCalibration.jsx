import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

// Cor de heatmap termica p/ ROAS (baixo->alto): azul -> ciano -> verde -> amarelo -> vermelho? Nao:
// para eficiencia usamos frio=ruim, quente=bom NAO e intuitivo. Usamos: vermelho(ruim)
// -> amarelo -> verde(bom), com meta ~3. Opacidade = confianca do gasto.
function heat(roas, spend, maxSpend) {
  if (!spend || spend <= 0) return 'transparent'
  const op = Math.max(0.12, Math.min(1, Math.sqrt(spend / maxSpend)))
  let r, g, b
  if (roas <= 0) { r = 138; g = 136; b = 128 }
  else if (roas < 3) { const t = Math.min(1, roas / 3); r = 208; g = Math.round(59 + t * 120); b = 45 }
  else { const t = Math.min(1, (roas - 3) / 6); r = Math.round(180 - t * 160); g = Math.round(179 + t * 20); b = 45 }
  return `rgba(${r},${g},${b},${op})`
}

export default function DaypartingCalibration({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState({ recommendations: [], heatmap: [], keywords: 0, kw_com_rec: 0 })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [kwFilter, setKwFilter] = useState('')

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const res = await api.goldDaypartingCalibration(tenantID)
      setData(res || { recommendations: [], heatmap: [] })
    } catch (e) {
      setError(e?.message || 'Falha ao carregar calibracao')
    } finally {
      setLoading(false)
    }
  }, [tenantID])
  useEffect(() => { load() }, [load])

  const hm = data.heatmap || []
  const weeks = useMemo(() => [...new Set(hm.map(r => r.semana))].sort(), [hm])
  const cellMap = useMemo(() => {
    const m = {}; hm.forEach(r => { m[`${r.semana}_${r.hora}`] = r }); return m
  }, [hm])
  const maxSpend = useMemo(() => Math.max(1, ...hm.map(r => r.spend || 0)), [hm])
  const media = useMemo(() => {
    const out = {}
    for (let h = 0; h < 24; h++) {
      let s = 0, v = 0
      weeks.forEach(w => { const c = cellMap[`${w}_${h}`]; if (c) { s += c.spend || 0; v += c.sales || 0 } })
      out[h] = s > 0 ? v / s : null
    }
    return out
  }, [weeks, cellMap])

  const recs = data.recommendations || []
  const recsByKw = useMemo(() => {
    const g = {}
    recs.filter(r => !kwFilter || (r.keyword_text || '').toLowerCase().includes(kwFilter.toLowerCase()))
      .forEach(r => { (g[r.keyword_text] = g[r.keyword_text] || []).push(r) })
    return g
  }, [recs, kwFilter])

  const cw = 26, lw = 58
  const label = { fontSize: 11, color: 'var(--muted, #8aa0c0)' }

  return (
    <div style={{ maxWidth: 1080, color: 'var(--fg, #e6edf7)' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12 }}>
        <div>
          <h2 style={{ margin: 0 }}>Calibracao de Dayparting</h2>
          <p style={{ ...label, marginTop: 4 }}>
            Grao keyword (hierarquia keyword&rarr;campanha&rarr;global via shrinkage). Baseline = sua curva publicada.
            So recomenda com prova; senao mantem seu %. <b>Advisory — nao aplica.</b>
          </p>
        </div>
        <button className="btn" onClick={load} style={{ fontSize: 12 }}>Atualizar</button>
      </div>

      {loading && <p style={label}>Carregando...</p>}
      {error && <div style={{ padding: 10, borderRadius: 8, background: 'rgba(220,60,60,.15)', color: '#fca5a5', fontSize: 13 }}>{error}</div>}

      {!loading && !error && (
        <>
          <div style={{ display: 'flex', gap: 16, margin: '10px 0 18px' }}>
            <Metric label="Keywords" value={data.keywords} />
            <Metric label="Com recomendacao (prova forte)" value={data.kw_com_rec} />
            <Metric label="Advisory" value="nao aplica" />
          </div>

          <h3 style={{ margin: '0 0 8px' }}>Eficiencia por hora &times; semana</h3>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, ...label, marginBottom: 8 }}>
            <span><span style={{ display: 'inline-block', width: 11, height: 11, background: 'rgba(208,59,45,.9)', borderRadius: 2, marginRight: 4 }} />ROAS &lt; 3</span>
            <span><span style={{ display: 'inline-block', width: 11, height: 11, background: 'rgba(180,179,45,.9)', borderRadius: 2, marginRight: 4 }} />&asymp; 3</span>
            <span><span style={{ display: 'inline-block', width: 11, height: 11, background: 'rgba(20,199,65,.9)', borderRadius: 2, marginRight: 4 }} />&gt; 3</span>
            <span>opacidade = gasto (fraco = pouco dinheiro, nao confie)</span>
          </div>
          <div style={{ overflowX: 'auto', marginBottom: 22 }}>
            <div style={{ display: 'grid', gridTemplateColumns: `${lw}px repeat(24, ${cw}px)`, gap: 2, minWidth: lw + 24 * (cw + 2) }}>
              <div />
              {Array.from({ length: 24 }, (_, h) => <div key={h} style={{ ...label, textAlign: 'center' }}>{String(h).padStart(2, '0')}</div>)}
              {weeks.map(w => (
                <FragmentRow key={w} w={w} cw={cw} cellMap={cellMap} maxSpend={maxSpend} label={label} />
              ))}
              <div style={{ fontSize: 11, fontWeight: 700, display: 'flex', alignItems: 'center' }}>Media</div>
              {Array.from({ length: 24 }, (_, h) => {
                const m = media[h]
                return <div key={h} title={m === null ? 'sem dado' : `ROAS ${m.toFixed(1)}`}
                  style={{ height: 24, borderRadius: 3, background: m === null ? 'transparent' : heat(m, maxSpend, maxSpend), border: '1px solid var(--border,#333)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10 }}>
                  {m === null ? '' : m.toFixed(1)}
                </div>
              })}
            </div>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
            <h3 style={{ margin: 0 }}>Recomendacoes por keyword (com prova)</h3>
            <input placeholder="filtrar keyword..." value={kwFilter} onChange={e => setKwFilter(e.target.value)}
              style={{ padding: '6px 10px', borderRadius: 8, border: '1px solid var(--border,#333)', background: 'var(--card-bg,#0b1220)', color: 'inherit', fontSize: 13 }} />
          </div>
          {Object.keys(recsByKw).length === 0 && <p style={label}>Nenhuma recomendacao com prova forte agora — mantem suas curvas. Medindo p/ aprender.</p>}
          {Object.entries(recsByKw).slice(0, 40).map(([kw, items]) => (
            <div key={kw} style={{ border: '1px solid var(--border,#2a3550)', borderRadius: 10, padding: '10px 14px', marginTop: 10 }}>
              <div style={{ fontWeight: 700, marginBottom: 6 }}>{kw} <span style={{ ...label, fontWeight: 400 }}>· {items.length} hora(s)</span></div>
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                  <thead><tr style={{ ...label, textAlign: 'left' }}>
                    <th style={{ padding: '3px 8px' }}>Hora</th><th>Atual</th><th>Sugerido</th><th>Scope</th><th>ROAS</th><th>Ref</th><th>Sem</th><th>Prova</th>
                  </tr></thead>
                  <tbody>
                    {items.map((r, i) => (
                      <tr key={i} style={{ borderTop: '1px solid var(--border,#22304a)' }}>
                        <td style={{ padding: '3px 8px' }}>{String(r.event_hour).padStart(2, '0')}h</td>
                        <td>{r.atual_pct}%</td>
                        <td style={{ fontWeight: 700, color: r.action === 'DOWN' ? '#fca5a5' : '#86efac' }}>{r.action === 'DOWN' ? '↓' : '↑'} {r.sugerido_pct}%</td>
                        <td style={{ ...label }}>{r.scope}</td>
                        <td>{(r.roas ?? 0).toFixed(1)}</td>
                        <td style={{ ...label }}>{(r.ref_roas ?? 0).toFixed(1)}</td>
                        <td>{r.weeks_of_data}</td>
                        <td style={{ ...label, maxWidth: 320, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} title={r.reason}>{r.reason}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          ))}
        </>
      )}
    </div>
  )
}

function FragmentRow({ w, cw, cellMap, maxSpend, label }) {
  return (
    <>
      <div style={{ ...label, display: 'flex', alignItems: 'center' }}>Sem {w}</div>
      {Array.from({ length: 24 }, (_, h) => {
        const c = cellMap[`${w}_${h}`]
        return <div key={h} title={c ? `Sem ${w} ${String(h).padStart(2, '0')}h\nGasto R$ ${(c.spend || 0).toFixed(2)} · ROAS ${c.roas > 0 ? c.roas.toFixed(2) : 'sem venda'}` : ''}
          style={{ height: 22, borderRadius: 3, background: c ? heat(c.roas, c.spend, maxSpend) : 'transparent', border: '1px solid var(--border,#22304a)' }} />
      })}
    </>
  )
}

function Metric({ label, value }) {
  return (
    <div style={{ background: 'var(--card-bg,#1e1e2e)', borderRadius: 8, padding: '10px 14px', minWidth: 120 }}>
      <div style={{ fontSize: 11, color: 'var(--muted,#8aa0c0)' }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700, marginTop: 2 }}>{value}</div>
    </div>
  )
}
