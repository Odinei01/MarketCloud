import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const LABEL_COLORS = {
  SCALE_VISIBILITY: '#31d39a', DEFEND: '#31d39a', LONG_TAIL_WINNER: '#22c55e',
  CONVERSION_GAP: '#ffb454', CLICK_GAP: '#ffb454', CART_GAP: '#ffb454', PRICE_TEST_UP: '#6ea8ff',
  DISCOVER: '#b892ff', LOW_SIGNAL: '#94a3b8', WATCH: '#94a3b8',
}
const SIGNAL_ORDER = { VERY_HIGH: 5, HIGH: 4, MEDIUM: 3, LOW: 2, VERY_LOW: 1 }
const CONF_COLORS = { HIGH: '#31d39a', MEDIUM: '#ffb454', LOW: '#94a3b8' }

// §39: filtros do query portfolio. (gaining/losing-share dependem de WoW — sem dado
// multi-semana ainda, ficam de fora ate a marca maturar.)
const PORTFOLIO_FILTERS = [
  ['all', 'Todas'], ['purchased', 'Compraram'], ['carted', 'Carrinho'],
  ['clicked', 'Clicaram'], ['impression-only', 'Só impressão'],
  ['winners', 'Vencedoras'], ['high-volume', 'Alto volume'], ['long-tail', 'Cauda longa'],
]
function matchesPortfolioFilter(q, f) {
  switch (f) {
    case 'purchased': return Number(q.brand_purchases || 0) > 0
    case 'carted': return Number(q.brand_cart_adds || 0) > 0
    case 'clicked': return Number(q.brand_clicks || 0) > 0
    case 'impression-only': return Number(q.brand_impressions || 0) > 0 && Number(q.brand_clicks || 0) === 0
    case 'winners': return ['SCALE_VISIBILITY', 'LONG_TAIL_WINNER', 'DEFEND'].includes(q.funnel_label)
    case 'high-volume': return Number(q.search_query_volume || 0) >= 50
    case 'long-tail': return Number(q.search_query_volume || 0) > 0 && Number(q.search_query_volume || 0) < 50
    default: return true
  }
}

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
  const [qFilter, setQFilter] = useState('all')

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
  const recs = data?.recommendations || []
  const queries = useMemo(() => (data?.queries || [])
    .filter(q => matchesPortfolioFilter(q, qFilter))
    .slice().sort((a, b) => {
      const sd = (SIGNAL_ORDER[b.signal_strength] || 0) - (SIGNAL_ORDER[a.signal_strength] || 0)
      if (sd) return sd
      return (b.brand_purchases || 0) - (a.brand_purchases || 0)
    }), [data, qFilter])

  const absMax = Math.max(Number(p.search_impressions || 0), 1)

  return (
    <section className="bpo">
      <style>{`
        .bpo { display:flex; flex-direction:column; gap:16px; color:var(--text); }
        .bpo-asins { display:flex; gap:8px; flex-wrap:wrap; }
        .bpo-asins button { border:1px solid var(--line); background:var(--panel-2); color:var(--text); border-radius:10px; padding:8px 12px; cursor:pointer; font-size:13px; max-width:280px; text-align:left; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .bpo-asins button:hover { border-color:var(--blue); }
        .bpo-asins button.active { border-color:var(--gold); background:var(--panel-3); }
        .bpo-asins button small { color:var(--muted); }
        .bpo-grid { display:grid; grid-template-columns:repeat(2,minmax(280px,1fr)); gap:14px; }
        .bpo-card { border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); padding:16px; box-shadow:var(--shadow); }
        .bpo-card h3 { margin:0 0 12px; font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.5px; }
        .bpo-kpis { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
        .bpo-kpi span { color:var(--muted); font-size:12px; } .bpo-kpi strong { display:block; font-size:22px; color:var(--text); margin-top:2px; }
        .bpo-funnel-row { display:grid; grid-template-columns:110px 1fr 90px; align-items:center; gap:8px; margin:7px 0; }
        .bpo-funnel-label { font-size:12px; color:var(--muted); } .bpo-funnel-val { font-size:12px; text-align:right; color:var(--text); font-weight:600; }
        .bpo-funnel-track { height:16px; background:var(--panel-3); border-radius:6px; overflow:hidden; }
        .bpo-funnel-fill { height:100%; background:linear-gradient(90deg,var(--gold-2),var(--gold)); }
        .bpo-table-wrap { overflow:auto; border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); }
        table.bpo-table { width:100%; border-collapse:collapse; min-width:1000px; }
        .bpo-table th,.bpo-table td { padding:9px 12px; border-bottom:1px solid var(--line); text-align:right; font-size:13px; white-space:nowrap; color:var(--text); }
        .bpo-table th { background:var(--panel-2); color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.3px; position:sticky; top:0; }
        .bpo-table tbody tr:hover td { background:var(--panel-2); }
        .bpo-table td.q,.bpo-table th.q { text-align:left; max-width:260px; overflow:hidden; text-overflow:ellipsis; }
        .bpo-tag { display:inline-block; padding:3px 9px; border-radius:999px; font-size:11px; font-weight:700; }
        .bpo-sig { font-size:11px; color:var(--muted); }
        .bpo-muted { color:var(--muted); font-size:12px; }
        @media (max-width:820px){ .bpo-grid{grid-template-columns:1fr} .bpo-kpis{grid-template-columns:repeat(2,1fr)} }
      `}</style>

      <div className="bpo-asins">
        {list.map(it => (
          <button key={it.asin} className={asin === it.asin ? 'active' : ''} onClick={() => setAsin(it.asin)} title={`${it.product_name || ''} — ${it.asin}`}>
            {it.product_name ? `${it.product_name} — ${it.asin}` : it.asin}<br /><small>{num(it.search_purchases)} compras</small>
          </button>
        ))}
        {!list.length && <span className="bpo-muted">Nenhum produto de marca com dado de query ainda.</span>}
      </div>

      {error && <div className="bpo-muted" style={{ color: '#b91c1c' }}>{error}</div>}
      {loading && <div className="bpo-muted">Carregando…</div>}

      {data && (
        <>
          <div className="bpo-card">
            <h3>{p.product_name ? `${p.product_name} — ${asin}` : asin} · Funil de busca (semana {p.period_start || '—'})</h3>
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

          {recs.length > 0 && (
            <div className="bpo-card" style={{ padding: '12px 14px' }}>
              <h3 style={{ margin: '0 0 4px' }}>Recomendações <span style={{ fontSize: 11.5, fontWeight: 400, color: 'var(--muted)' }}>· Observe → Explain → Recommend (não executa)</span></h3>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 8 }}>
                {recs.slice(0, 8).map((rc, i) => (
                  <div key={i} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', padding: '8px 10px', borderRadius: 8, background: 'var(--panel-3,#16233c)' }}>
                    <span style={{ width: 8, height: 8, borderRadius: '50%', marginTop: 5, flexShrink: 0, background: CONF_COLORS[rc.rec_confidence] || '#94a3b8' }} />
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontWeight: 700, fontSize: 13 }}>{rc.rec_action}
                        <span style={{ marginLeft: 8, fontSize: 11, color: CONF_COLORS[rc.rec_confidence] || '#94a3b8' }}>{rc.rec_confidence}</span>
                        <span style={{ marginLeft: 8, fontSize: 11.5, color: 'var(--muted)', fontWeight: 400 }}>· “{rc.search_query}”</span>
                      </div>
                      <div style={{ fontSize: 12, color: 'var(--muted,#94a3b8)' }}>{rc.rec_reason}</div>
                      <div style={{ fontSize: 10.5, color: 'var(--muted,#64748b)', fontFamily: 'monospace', marginTop: 2 }}>{rc.rec_evidence}</div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div className="bpo-card" style={{ padding: 0 }}>
            <div style={{ padding: '12px 14px 0', display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <h3 style={{ margin: 0 }}>Query portfolio ({queries.length})</h3>
              <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                {PORTFOLIO_FILTERS.map(([key, label]) => (
                  <button key={key} onClick={() => setQFilter(key)}
                    style={{
                      fontSize: 11.5, padding: '3px 9px', borderRadius: 6, cursor: 'pointer',
                      border: '1px solid var(--border,#2a3550)',
                      background: qFilter === key ? 'var(--gold,#d4a531)' : 'transparent',
                      color: qFilter === key ? '#0b1020' : 'var(--muted,#94a3b8)',
                      fontWeight: qFilter === key ? 700 : 400,
                    }}>{label}</button>
                ))}
              </div>
            </div>
            <div className="bpo-table-wrap">
              <table className="bpo-table">
                <thead>
                  <tr>
                    <th className="q">Query</th><th>Volume</th>
                    <th>Impr</th><th>Clk</th><th>Compras</th>
                    <th>Impr sh</th><th>Click sh</th><th>Cart sh</th><th>Purch sh</th>
                    <th>Purch lift</th><th>Price idx</th>
                    <th>Sinal</th><th className="q">Rótulo</th><th>Conf</th>
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
                      <td>{pct(q.brand_cart_add_share, 2)}</td>
                      <td>{pct(q.brand_purchase_share, 2)}</td>
                      <td>{ratio(q.purchase_share_lift)}</td>
                      <td>{ratio(q.purchase_price_index)}</td>
                      <td className="bpo-sig">{q.signal_strength}</td>
                      <td className="q"><span className="bpo-tag" style={{ background: LABEL_COLORS[q.funnel_label] || '#94a3b8', color: '#0b1020' }}>{q.funnel_label}</span></td>
                      <td style={{ color: CONF_COLORS[q.classification_confidence] || '#94a3b8', fontWeight: 600, fontSize: 11.5 }}>{q.classification_confidence || '—'}</td>
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
