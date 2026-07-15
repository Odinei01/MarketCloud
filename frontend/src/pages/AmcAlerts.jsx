import { useState, useEffect, useCallback } from 'react'
import { api } from '../api/client'

const VERDICT_STYLE = {
  MATAR:      { bg: '#3a1414', border: '#c0392b', label: '🔴 MATAR' },
  ESCALAR:    { bg: '#12331c', border: '#27ae60', label: '🟢 ESCALAR' },
  MONITORAR:  { bg: '#33300f', border: '#e0b000', label: '🟡 MONITORAR' },
  BAIXO_SINAL:{ bg: '#20242b', border: '#555',    label: '⚪ BAIXO SINAL' },
}

export default function AmcAlerts({ ctx }) {
  const { tenantID } = ctx
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    setLoading(true); setErr('')
    try {
      const r = await api.amcAlerts(tenantID)
      if (r.ok) setItems(r.data?.items || [])
      else setErr(r.data?.error || `Falha ao carregar (${r.status})`)
    } catch (e) { setErr(String(e)) }
    setLoading(false)
  }, [tenantID])

  useEffect(() => { load() }, [load])

  const brl = (v) => (v == null ? '—' : `R$ ${Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 0 })}`)

  return (
    <div style={{ padding: 24, maxWidth: 980 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 12 }}>
        <h1 style={{ margin: 0 }}>Alertas AMC — Retargeting</h1>
        <button className="btn" style={{ fontSize: 12 }} onClick={load}>Atualizar</button>
      </div>
      <p style={{ opacity: 0.7, marginTop: 6 }}>
        O sistema avalia sozinho o público reimpactado (SD) vs baseline e recomenda ação. Atualiza diário.
      </p>

      {loading && <p>Carregando…</p>}
      {err && <p style={{ color: '#e74c3c' }}>Erro: {err}</p>}
      {!loading && !err && items.length === 0 && <p style={{ opacity: 0.6 }}>Sem dados ainda — aguardando o run diário do AMC.</p>}

      <div style={{ display: 'grid', gap: 12, marginTop: 12 }}>
        {items.map((a, i) => {
          const s = VERDICT_STYLE[a.verdict] || VERDICT_STYLE.BAIXO_SINAL
          return (
            <div key={i} style={{ background: s.bg, border: `1px solid ${s.border}`, borderRadius: 10, padding: '14px 16px' }}>
              <div style={{ fontWeight: 600, fontSize: 15 }}>{a.alerta}</div>
              <div style={{ display: 'flex', gap: 18, marginTop: 8, fontSize: 13, opacity: 0.85, flexWrap: 'wrap' }}>
                <span>Reimpactados: <b>{a.engaged_users}</b></span>
                <span>Compradores: <b>{a.buyers}</b></span>
                <span>Conversão: <b>{a.conversion_rate != null ? (a.conversion_rate * 100).toFixed(1) + '%' : '—'}</b></span>
                <span>Lift: <b>{a.lift_vs_baseline != null ? a.lift_vs_baseline.toFixed(1) + '×' : '—'}</b></span>
                <span>Receita: <b>{brl(a.product_revenue)}</b></span>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
