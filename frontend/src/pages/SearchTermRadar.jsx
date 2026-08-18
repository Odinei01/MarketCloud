import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

// Radar de Search Term — ESPELHA o feed do cérebro ZM19 (mercado-data-app) via FDW.
// NÃO recalcula (um cérebro só). Vive na tela de Calibração de Dayparting (:3001),
// ao lado do blend ML×dayparting: é a outra decisão do mesmo cérebro (qual termo).
const ACTION_META = {
  BREAKEVEN_NEGATIVE: { label: 'Perde dinheiro (ACoS > breakeven)', tone: '#ef4444' },
  PRUNE: { label: 'Desperdício (0 venda)', tone: '#f97316' },
  HARVEST_PROMOTE: { label: 'Vencedor → graduar p/ exact', tone: '#22c55e' },
  ADD_NEGATIVE: { label: 'Negativar na origem (rotear)', tone: '#eab308' },
  BID_HOLD: { label: 'Segurar lance', tone: '#94a3b8' },
  BID_PROBE: { label: 'Sondar lance', tone: '#60a5fa' },
  REALLOC_BUDGET: { label: 'Realocar orçamento', tone: '#a78bfa' },
}
const fmtBRL = (v) => (v == null ? '—' : Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))

export default function SearchTermRadar({ ctx }) {
  const [data, setData] = useState({ items: [], counts: {}, total: 0 })
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState('WASTE')

  const load = () => {
    setLoading(true)
    api.goldSearchTermRadar(ctx.tenantID)
      .then((res) => setData(res.ok ? res.data : { items: [], counts: {}, total: 0 }))
      .catch(() => setData({ items: [], counts: {}, total: 0 }))
      .finally(() => setLoading(false))
  }
  useEffect(() => { load() }, [ctx.tenantID])

  const waste = ['BREAKEVEN_NEGATIVE', 'PRUNE']
  const shown = useMemo(() => (data.items || []).filter((r) =>
    filter === 'ALL' ? true : filter === 'WASTE' ? waste.includes(r.action) : r.action === filter), [data, filter])
  const wasteCount = (data.counts?.BREAKEVEN_NEGATIVE || 0) + (data.counts?.PRUNE || 0)
  const muted = { color: 'var(--muted,#9fb0c8)' }

  return (
    <div style={{ border: '1px solid var(--border,#2a3550)', borderRadius: 12, padding: 14, marginBottom: 16 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', marginBottom: 10 }}>
        <b style={{ fontSize: 15 }}>Radar de Search Term</b>
        <span style={{ ...muted, fontSize: 12 }}>cérebro ZM19 (via FDW) · advisory (SHADOW, não aplica)</span>
        {wasteCount > 0 && (
          <span style={{ background: '#ef444422', color: '#f87171', borderRadius: 20, padding: '2px 10px', fontSize: 12, fontWeight: 700 }}>🔴 {wasteCount} termos queimando</span>
        )}
        <div style={{ flex: 1 }} />
        <button className="btn" onClick={load} style={{ fontSize: 12 }}>Atualizar</button>
      </div>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 10 }}>
        {[['WASTE', 'Desperdício'], ['ALL', 'Tudo'], ['HARVEST_PROMOTE', 'Vencedores'], ['ADD_NEGATIVE', 'Rotear'], ['BID_HOLD', 'Lances']].map(([k, l]) => (
          <button key={k} onClick={() => setFilter(k)} style={{
            fontSize: 12, padding: '4px 10px', borderRadius: 6, cursor: 'pointer', border: '1px solid var(--border,#2a3550)',
            background: filter === k ? 'var(--gold,#d4a531)' : 'transparent',
            color: filter === k ? '#0b1020' : 'var(--muted,#9fb0c8)', fontWeight: filter === k ? 700 : 400,
          }}>{l}</button>
        ))}
      </div>
      {loading ? <div style={muted}>Carregando…</div>
        : !shown.length ? <div style={{ ...muted, fontSize: 12.5 }}>Nada nesta categoria. O cérebro (mercado) roda de hora em hora; se acabou de ativar, aguarde o próximo ciclo.</div>
        : (
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
              <thead><tr style={{ ...muted, textAlign: 'left' }}>
                <th style={{ padding: '4px 8px' }}>Ação</th><th>Campanha</th><th>Termo</th><th>ACoS</th><th>Gasto</th><th>Venda</th><th>Cliques</th>
              </tr></thead>
              <tbody>
                {shown.map((r, i) => {
                  const m = ACTION_META[r.action] || { label: r.action, tone: '#94a3b8' }
                  const e = r.evidence || {}
                  return (
                    <tr key={i} style={{ borderTop: '1px solid var(--border,#22304a)' }}>
                      <td style={{ padding: '5px 8px' }}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', background: m.tone, marginRight: 6 }} />{m.label}</td>
                      <td style={muted}>{r.campaign_name}</td>
                      <td style={{ fontWeight: 600 }}>{r.search_term}</td>
                      <td style={{ color: e.acos_pct > 31 ? '#f87171' : 'inherit', fontWeight: 700 }}>{e.acos_pct != null ? `${e.acos_pct}%` : '—'}</td>
                      <td>{fmtBRL(e.cost)}</td>
                      <td>{fmtBRL(e.sales)}</td>
                      <td>{e.clicks ?? '—'}</td>
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
