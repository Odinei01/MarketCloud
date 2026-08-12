import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const LABEL_COLORS = {
  SCALE_VISIBILITY: '#166534', DEFEND: '#166534',
  CONVERSION_GAP: '#92400e', CLICK_GAP: '#92400e', CART_GAP: '#92400e', PRICE_TEST_UP: '#1d4ed8',
  DISCOVER: '#7c3aed', LOW_SIGNAL: '#64748b', WATCH: '#334155',
}
const SIGNAL_ORDER = { VERY_HIGH: 5, HIGH: 4, MEDIUM: 3, LOW: 2, VERY_LOW: 1 }

function pct(v, d = 2) {
  if (v === null || v === undefined) return '—'
  return `${(Number(v)).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })}%`
}
function num(v, d = 0) {
  if (v === null || v === undefined) return '—'
  return Number(v).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })
}
function ratio(v) {
  if (v === null || v === undefined) return '—'
  return Number(v).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function FunnelBar({ label, value, max, absolute }) {
  const wpc = max > 0 ? Math.max(2, (Number(value || 0) / max) * 100) : 2
  return (
    <div className="bpo-funnel-row">
      <span className="bpo-funnel-label">{label}</span>
      <div className="bpo-funnel-track"><div className="bpo-funnel-fill" style={{ width: `${wpc}%` }} /></div>
      <span className="bpo-funnel-val">{absolute ? num(value) : pct(value * 100, 3)}</span>
    </div>
  )
}

export default function BrandProductOverview({ ctx }) {
  const [list, setList] = useState([])
  const [asin, setAsin] = useState('')
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    (async () => {
      try {
        const res = await api.goldBrandOverview(ctx.tenantID)
        const items = (res.ok ? res.data.items : []) || []
        setList(items)
        if (items.length && !asin) setAsin(items[0].asin)
      } catch (e) { setError(e?.message || 'falha ao carregar produtos') }
    })()
  }, [ctx.tenantID])

  useEffect(() => {
    if (!asin) return
    setLoading(true); setError('')
    api.goldBrandOverviewProduct(ctx.tenantID, asin)
      .then(res => setData(res.ok ? res.data : { product: {}, queries: [] }))
      .catch(e => setError(e?.message || 'falha ao carregar produto'))
      .finally(() => setLoading(false))
  }, [asin, ctx.tenantID])

  const p = data?.product || {}
  const queries = useMemo(() => (data?.queries || []).slice().sort((a, b) => {
    const sd = (SIGNAL_ORDER[b.signal_strength] || 0) - (SIGNAL_ORDER[a.signal_strength] || 0)
    if (sd) return sd
    return (b.brand_purchases || 0) - (a.brand_purchases || 0)
  }), [data])

  const absMax = Math.max(Number(p.search_impressions || 0), 1)

  return (
    <section className="bpo">
      <style>{`
        .bpo { display:flex; flex-direction:column; gap:16px; }
        .bpo-asins { display:flex; gap:8px; flex-wrap:wrap; }
        .bpo-asins button { border:1px solid #cbd5e1; background:#fff; border-radius:8px; padding:8px 12px; cursor:pointer; font-size:13px; }
        .bpo-asins button.active { border-color:#0f172a; background:#0f172a; color:#fff; }
        .bpo-grid { display:grid; grid-template-columns:repeat(2,minmax(280px,1fr)); gap:14px; }
        .bpo-card { border:1px solid #e2e8f0; border-radius:10px; background:#fff; padding:14px; }
        .bpo-card h3 { margin:0 0 10px; font-size:13px; color:#475569; text-transform:uppercase; letter-spacing:.4px; }
        .bpo-kpis { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
        .bpo-kpi span { color:#64748b; font-size:12px; } .bpo-kpi strong { display:block; font-size:20px; color:#0f172a; margin-top:2px; }
        .bpo-funnel-row { display:grid; grid-template-columns:120px 1fr 90px; align-items:center; gap:8px; margin:6px 0; }
        .bpo-funnel-label { font-size:12px; color:#475569; } .bpo-funnel-val { font-size:12px; text-align:right; color:#0f172a; font-weight:600; }
        .bpo-funnel-track { height:16px; background:#f1f5f9; border-radius:4px; overflow:hidden; }
        .bpo-funnel-fill { height:100%; background:linear-gradient(90deg,#2563eb,#60a5fa); }
        .bpo-table-wrap { overflow:auto; border:1px solid #e2e8f0; border-radius:10px; background:#fff; }
        table.bpo-table { width:100%; border-collapse:collapse; min-width:1000px; }
        .bpo-table th,.bpo-table td { padding:8px 10px; border-bottom:1px solid #eef2f7; text-align:right; font-size:13px; white-space:nowrap; }
        .bpo-table th { background:#f8fafc; color:#475569; font-size:12px; position:sticky; top:0; }
        .bpo-table td.q,.bpo-table th.q { text-align:left; max-width:260px; overflow:hidden; text-overflow:ellipsis; }
        .bpo-tag { display:inline-block; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:700; color:#fff; }
        .bpo-sig { font-size:11px; color:#334155; }
        .bpo-muted { color:#64748b; font-size:12px; }
        @media (max-width:820px){ .bpo-grid{grid-template-columns:1fr} .bpo-kpis{grid-template-columns:repeat(2,1fr)} }
      `}</style>

      <div className="bpo-asins">
        {list.map(it => (
          <button key={it.asin} className={asin === it.asin ? 'active' : ''} onClick={() => setAsin(it.asin)}>
            {it.asin} · {num(it.search_purchases)} compras
          </button>
        ))}
        {!list.length && <span className="bpo-muted">Nenhum produto de marca com dado de query ainda.</span>}
      </div>

      {error && <div className="bpo-muted" style={{ color: '#b91c1c' }}>{error}</div>}
      {loading && <div className="bpo-muted">Carregando…</div>}

      {data && (
        <>
          <div className="bpo-card">
            <h3>{asin} — Funil de busca (semana {p.period_start || '—'})</h3>
            <div className="bpo-kpis">
              <div className="bpo-kpi"><span>Queries ativas</span><strong>{num(p.active_queries)}</strong></div>
              <div className="bpo-kpi"><span>Search CTR</span><strong>{pct((p.search_ctr || 0) * 100)}</strong></div>
              <div className="bpo-kpi"><span>Search CVR</span><strong>{pct((p.search_conversion || 0) * 100)}</strong></div>
              <div className="bpo-kpi"><span>Compras (busca)</span><strong>{num(p.search_purchases)}</strong></div>
            </div>
          </div>

          <div className="bpo-grid">
            <div className="bpo-card">
              <h3>Funil de share (weighted)</h3>
              <FunnelBar label="Impression" value={p.weighted_impression_share} max={0.05} />
              <FunnelBar label="Click" value={p.weighted_click_share} max={0.05} />
              <FunnelBar label="Cart" value={p.weighted_cart_share} max={0.05} />
              <FunnelBar label="Purchase" value={p.weighted_purchase_share} max={0.05} />
              <div className="bpo-muted" style={{ marginTop: 8 }}>share ZANOM sobre o mercado, ponderado pelo volume das queries.</div>
            </div>
            <div className="bpo-card">
              <h3>Funil absoluto (marca)</h3>
              <FunnelBar label="Impressions" value={p.search_impressions} max={absMax} absolute />
              <FunnelBar label="Clicks" value={p.search_clicks} max={absMax} absolute />
              <FunnelBar label="Cart adds" value={p.search_cart_adds} max={absMax} absolute />
              <FunnelBar label="Purchases" value={p.search_purchases} max={absMax} absolute />
            </div>
          </div>

          <div className="bpo-card" style={{ padding: 0 }}>
            <div style={{ padding: '12px 14px 0' }}><h3>Query portfolio ({queries.length})</h3></div>
            <div className="bpo-table-wrap">
              <table className="bpo-table">
                <thead>
                  <tr>
                    <th className="q">Query</th><th>Volume</th>
                    <th>Impr</th><th>Clk</th><th>Compras</th>
                    <th>Impr sh</th><th>Click sh</th><th>Purch sh</th>
                    <th>Purch lift</th><th>Price idx</th>
                    <th>Sinal</th><th className="q">Rótulo</th>
                  </tr>
                </thead>
                <tbody>
                  {queries.map((q, i) => (
                    <tr key={i}>
                      <td className="q" title={q.search_query}>{q.search_query}</td>
                      <td>{num(q.search_query_volume)}</td>
                      <td>{num(q.brand_impressions)}</td>
                      <td>{num(q.brand_clicks)}</td>
                      <td>{num(q.brand_purchases)}</td>
                      <td>{pct(q.brand_impression_share, 2)}</td>
                      <td>{pct(q.brand_click_share, 2)}</td>
                      <td>{pct(q.brand_purchase_share, 2)}</td>
                      <td>{ratio(q.purchase_share_lift)}</td>
                      <td>{ratio(q.purchase_price_index)}</td>
                      <td className="bpo-sig">{q.signal_strength}</td>
                      <td className="q"><span className="bpo-tag" style={{ background: LABEL_COLORS[q.funnel_label] || '#334155' }}>{q.funnel_label}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </section>
  )
}
