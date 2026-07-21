import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const DAYPARTS = [
  { label: 'Madrugada', sub: '00h-05h', hours: [0, 1, 2, 3, 4, 5] },
  { label: 'Manha / Pico', sub: '06h-11h', hours: [6, 7, 8, 9, 10, 11] },
  { label: 'Tarde', sub: '12h-17h', hours: [12, 13, 14, 15, 16, 17] },
  { label: 'Noite', sub: '18h-23h', hours: [18, 19, 20, 21, 22, 23] },
]
// cor por bucket (funciona no tema escuro do cockpit)
function bucketColor(pct) {
  if (pct <= 20) return { bg: 'rgba(59,130,246,.22)', bd: 'rgba(59,130,246,.5)' }
  if (pct <= 30) return { bg: 'rgba(139,92,246,.22)', bd: 'rgba(139,92,246,.5)' }
  if (pct <= 50) return { bg: 'rgba(245,158,11,.24)', bd: 'rgba(245,158,11,.55)' }
  if (pct <= 80) return { bg: 'rgba(217,119,6,.30)', bd: 'rgba(217,119,6,.6)' }
  return { bg: 'rgba(34,197,94,.24)', bd: 'rgba(34,197,94,.55)' }
}

const PILOTS = new Set(['42786116647278', '63928923350381', '146896707092851'])

export default function DaypartingCalibration({ ctx }) {
  const { tenantID } = ctx
  const [data, setData] = useState({ recommendations: [], keywords: 0, kw_com_rec: 0 })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [sel, setSel] = useState('')
  const [applyRes, setApplyRes] = useState(null)
  const [applying, setApplying] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const res = await api.goldDaypartingCalibration(tenantID)
      if (!res?.ok) throw new Error(res?.data?.error || 'falha')
      setData(res.data || {})
    } catch (e) {
      setError(e?.message || 'Falha ao carregar')
    } finally { setLoading(false) }
  }, [tenantID])
  useEffect(() => { load() }, [load])

  const byKw = useMemo(() => {
    const g = {}
    ;(data.recommendations || []).forEach(r => { (g[r.keyword_text] = g[r.keyword_text] || {})[r.event_hour] = r })
    return g
  }, [data])
  const kwList = useMemo(() => Object.keys(byKw).sort(), [byKw])
  useEffect(() => { if (!sel && kwList.length) setSel(kwList[0]) }, [kwList, sel])

  const curve = byKw[sel] || {}
  const nChanges = Object.values(curve).filter(r => r.action !== 'HOLD').length
  const kwId = String((Object.values(curve)[0] || {}).keyword_id || '')
  const isPilot = PILOTS.has(kwId)

  const doApply = useCallback(async (dry) => {
    if (!kwId) return
    setApplying(true); setApplyRes(null)
    try {
      const res = await api.goldDaypartingApply(tenantID, kwId, dry)
      setApplyRes(res?.data || { error: 'falha' })
      if (res?.data?.applied) load()
    } catch (e) {
      setApplyRes({ error: e?.message || 'falha' })
    } finally { setApplying(false) }
  }, [kwId, tenantID, load])
  useEffect(() => { setApplyRes(null) }, [sel])

  const baseScope = (Object.values(curve)[0] || {}).baseline_scope || ''
  const scopeTxt = { ENTITY: 'schedule proprio', CAMPAIGN: 'herda da campanha', GLOBAL: 'herda do global', AD_GROUP: 'herda do grupo', HARDCODED: 'padrao' }[baseScope] || baseScope
  const candidates = data.candidates || []
  const muted = { color: 'var(--muted,#8aa0c0)' }

  return (
    <div style={{ maxWidth: 1080, color: 'var(--fg,#e6edf7)' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
        <div>
          <h2 style={{ margin: 0 }}>Calibracao de Dayparting</h2>
          <p style={{ ...muted, fontSize: 12.5, marginTop: 4 }}>
            Grao keyword (keyword&rarr;campanha&rarr;global via shrinkage). Sugestao sobre a <b>sua curva publicada</b>, com prova.
            <b> Advisory — nao aplica.</b>
          </p>
        </div>
        <button className="btn" onClick={load} style={{ fontSize: 12 }}>Atualizar</button>
      </div>

      {loading && <p style={muted}>Carregando...</p>}
      {error && <div style={{ padding: 10, borderRadius: 8, background: 'rgba(220,60,60,.15)', color: '#fca5a5', fontSize: 13 }}>{error}</div>}

      {!loading && !error && (
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, margin: '14px 0' }}>
            <select value={sel} onChange={e => setSel(e.target.value)}
              style={{ padding: '8px 12px', borderRadius: 8, border: '1px solid var(--border,#2a3550)', background: 'var(--card-bg,#0b1220)', color: 'inherit', fontSize: 14, minWidth: 320 }}>
              {kwList.length === 0 && <option>— sem recomendacao —</option>}
              {kwList.map(k => <option key={k} value={k}>{k}</option>)}
            </select>
            <span style={muted}>{kwList.length} keyword(s) · <b style={{ color: 'var(--fg)' }}>{nChanges}</b> hora(s) mudam{baseScope && <> · baseline: <b style={{ color: 'var(--fg)' }}>{scopeTxt}</b></>}</span>
          </div>

          {kwList.length === 0 && (
            <div style={{ padding: 16, border: '1px solid var(--border,#2a3550)', borderRadius: 10, ...muted }}>
              Nenhuma recomendacao com prova forte agora — suas curvas seguem como estao. Medindo p/ aprender.
            </div>
          )}

          {sel && (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
              {DAYPARTS.map(dp => (
                <div key={dp.label} style={{ border: '1px solid var(--border,#2a3550)', borderRadius: 12, padding: 14 }}>
                  <div style={{ marginBottom: 10 }}>
                    <b>{dp.sub}</b> <span style={muted}>{dp.label}</span>
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6,1fr)', gap: 8 }}>
                    {dp.hours.map(h => {
                      const r = curve[h]
                      const changed = r && r.action !== 'HOLD'
                      const pct = r ? (changed ? r.sugerido_pct : r.atual_pct) : null
                      const col = pct === null ? { bg: 'transparent', bd: 'var(--border,#2a3550)' } : bucketColor(pct)
                      return (
                        <div key={h} title={r ? r.reason : 'sem dado'}
                          style={{ borderRadius: 10, padding: '8px 4px', textAlign: 'center', background: col.bg, border: `${changed ? 2 : 1}px solid ${col.bd}` }}>
                          <div style={{ ...muted, fontSize: 11 }}>{String(h).padStart(2, '0')}</div>
                          <div style={{ fontSize: 18, fontWeight: 700 }}>{pct === null ? '—' : pct}<span style={{ fontSize: 11, fontWeight: 400 }}>%</span></div>
                          {changed
                            ? <div style={{ fontSize: 10, color: r.action === 'DOWN' ? '#fca5a5' : '#86efac' }}>{r.action === 'DOWN' ? '▼' : '▲'} era {r.atual_pct}%</div>
                            : <div style={{ fontSize: 10, ...muted }}>{r ? 'mantem' : ''}</div>}
                        </div>
                      )
                    })}
                  </div>
                </div>
              ))}
            </div>
          )}

          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 14, marginTop: 14, ...muted, fontSize: 12 }}>
            <span>Legenda:</span>
            {[20, 30, 50, 80, 100].map(p => (
              <span key={p} style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                <span style={{ width: 12, height: 12, borderRadius: 3, background: bucketColor(p).bg, border: `1px solid ${bucketColor(p).bd}` }} />{p}%
              </span>
            ))}
            <span>· borda grossa = mudanca sugerida (passe o mouse p/ a prova)</span>
          </div>

          {sel && (
            <div style={{ marginTop: 16, border: `1px solid ${isPilot ? 'var(--accent,#3b82f6)' : 'var(--border,#2a3550)'}`, borderRadius: 10, padding: '12px 14px' }}>
              {isPilot ? (
                <>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                    <b>Aplicar no schedule (piloto)</b>
                    <span style={{ ...muted, fontSize: 12 }}>{nChanges} hora(s) mudam · escreve a curva recomendada na sua Agenda de BIDs</span>
                    <div style={{ flex: 1 }} />
                    <button className="btn" disabled={applying || nChanges === 0} onClick={() => doApply(true)} style={{ fontSize: 13 }}>Ver o que aplicaria</button>
                    <button className="btn" disabled={applying || nChanges === 0} onClick={() => doApply(false)}
                      style={{ fontSize: 13, borderColor: 'var(--accent,#3b82f6)', color: 'var(--accent,#93c5fd)' }}>Aprovar e aplicar</button>
                  </div>
                  {applyRes && (
                    <div style={{ marginTop: 10, fontSize: 13 }}>
                      {applyRes.error && <span style={{ color: '#fca5a5' }}>Erro: {applyRes.error}</span>}
                      {applyRes.status === 'DRY_RUN' && <span style={muted}>Dry-run: aplicaria <b style={{ color: 'var(--fg)' }}>{applyRes.hours_changed}</b> hora(s). Kill-switch <b style={{ color: applyRes.kill_switch ? '#86efac' : '#fca5a5' }}>{applyRes.kill_switch ? 'ON' : 'OFF'}</b> — {applyRes.kill_switch ? 'clique "Aprovar e aplicar" p/ escrever' : 'escrita travada (nao aplicou nada)'}.</span>}
                      {applyRes.status === 'APPLIED' && <span style={{ color: '#86efac' }}>✅ Aplicado: {applyRes.hours_changed} hora(s) escritas no schedule.</span>}
                      {applyRes.status && !['DRY_RUN', 'APPLIED'].includes(applyRes.status) && <span style={{ color: '#fca5a5' }}>Status: {applyRes.status}</span>}
                    </div>
                  )}
                </>
              ) : (
                <span style={{ ...muted, fontSize: 13 }}>Esta keyword nao e piloto de dayparting. Aplicacao habilitada so para os 3 pilotos (tag rastreador android, abridor de vinho, seladora a vacuo para alimentos).</span>
              )}
            </div>
          )}

          <div style={{ marginTop: 18, border: '1px solid var(--border,#2a3550)', borderRadius: 10, padding: '10px 14px' }}>
            <h3 style={{ margin: '0 0 6px' }}>Candidatas a schedule proprio <span style={{ ...muted, fontWeight: 400, fontSize: 12 }}>(sem schedule proprio, mas ja com dado)</span></h3>
            {candidates.length === 0
              ? <p style={{ ...muted, margin: 0, fontSize: 13 }}>Nenhuma ainda — as sem schedule proprio herdam campanha/global. Aparecem aqui quando acumularem dado suficiente pra valer a pena criar uma propria.</p>
              : (
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                  <thead><tr style={{ ...muted, textAlign: 'left' }}><th style={{ padding: '3px 8px' }}>Keyword</th><th>Herda de</th><th>Cliques</th><th>Horas c/ rec</th></tr></thead>
                  <tbody>
                    {candidates.map((c, i) => (
                      <tr key={i} style={{ borderTop: '1px solid var(--border,#22304a)' }}>
                        <td style={{ padding: '3px 8px' }}>{c.keyword_text}</td>
                        <td style={muted}>{c.herda_de}</td>
                        <td>{c.clicks_total}</td>
                        <td>{c.horas_com_rec}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
          </div>

          {sel && nChanges > 0 && (
            <div style={{ marginTop: 18 }}>
              <h3 style={{ margin: '0 0 8px' }}>Prova das mudancas — {sel}</h3>
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                  <thead><tr style={{ ...muted, textAlign: 'left' }}>
                    <th style={{ padding: '3px 8px' }}>Hora</th><th>Atual</th><th>Sugerido</th><th>Scope</th><th>ROAS</th><th>Ref</th><th>Sem</th><th>Prova</th>
                  </tr></thead>
                  <tbody>
                    {Object.values(curve).filter(r => r.action !== 'HOLD').sort((a, b) => a.event_hour - b.event_hour).map((r, i) => (
                      <tr key={i} style={{ borderTop: '1px solid var(--border,#22304a)' }}>
                        <td style={{ padding: '3px 8px' }}>{String(r.event_hour).padStart(2, '0')}h</td>
                        <td>{r.atual_pct}%</td>
                        <td style={{ fontWeight: 700, color: r.action === 'DOWN' ? '#fca5a5' : '#86efac' }}>{r.action === 'DOWN' ? '▼' : '▲'} {r.sugerido_pct}%</td>
                        <td style={muted}>{r.scope}</td>
                        <td>{(r.roas ?? 0).toFixed(1)}</td>
                        <td style={muted}>{(r.ref_roas ?? 0).toFixed(1)}</td>
                        <td>{r.weeks_of_data}</td>
                        <td style={{ ...muted, maxWidth: 340, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} title={r.reason}>{r.reason}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
