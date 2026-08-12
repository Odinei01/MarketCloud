import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const CLASS_COLORS = {
  HIGHLY_CONCENTRATED: '#991b1b', CONCENTRATED: '#b45309',
  FRAGMENTED: '#166534', HIGHLY_FRAGMENTED: '#065f46',
}
function num(v, d = 0) { return v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d }) }
function pct(v, d = 2) { return v === null || v === undefined ? '—' : `${(Number(v) * 100).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })}%` }
function ratio(v) { return v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }

export default function BrandMarketMatrix({ ctx }) {
  const [tab, setTab] = useState('matrix')
  const [matrix, setMatrix] = useState([])
  const [market, setMarket] = useState([])
  const [cls, setCls] = useState('')
  const [q, setQ] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    setLoading(true); setError('')
    Promise.all([
      api.goldBrandMatrix(ctx.tenantID),
      api.goldMarketSearch(ctx.tenantID, { limit: 300 }),
    ]).then(([m, s]) => {
      setMatrix((m.ok ? m.data.items : []) || [])
      setMarket((s.ok ? s.data.items : []) || [])
    }).catch(e => setError(e?.message || 'falha ao carregar'))
      .finally(() => setLoading(false))
  }, [ctx.tenantID])

  const matrixSorted = useMemo(() => matrix.slice().sort((a, b) => (b.search_purchases || 0) - (a.search_purchases || 0)), [matrix])
  const marketFiltered = useMemo(() => {
    const term = q.trim().toLowerCase()
    return market.filter(m => (!cls || m.market_concentration_class === cls) && (!term || String(m.search_query || '').toLowerCase().includes(term)))
  }, [market, cls, q])

  return (
    <section className="bmm">
      <style>{`
        .bmm { display:flex; flex-direction:column; gap:14px; }
        .bmm-tabs { display:flex; gap:8px; }
        .bmm-tabs button { border:1px solid #cbd5e1; background:#fff; border-radius:8px; padding:8px 14px; cursor:pointer; font-size:13px; }
        .bmm-tabs button.active { background:#0f172a; color:#fff; border-color:#0f172a; }
        .bmm-tools { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
        .bmm-tools select,.bmm-tools input { border:1px solid #cbd5e1; border-radius:8px; padding:7px 10px; font-size:13px; }
        .bmm-wrap { overflow:auto; border:1px solid #e2e8f0; border-radius:10px; background:#fff; }
        table.bmm-t { width:100%; border-collapse:collapse; min-width:900px; }
        .bmm-t th,.bmm-t td { padding:8px 10px; border-bottom:1px solid #eef2f7; text-align:right; font-size:13px; white-space:nowrap; }
        .bmm-t th { background:#f8fafc; color:#475569; font-size:12px; position:sticky; top:0; }
        .bmm-t td.l,.bmm-t th.l { text-align:left; }
        .bmm-tag { display:inline-block; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:700; color:#fff; }
        .bmm-muted { color:#64748b; font-size:12px; }
      `}</style>

      <div className="bmm-tabs">
        <button className={tab === 'matrix' ? 'active' : ''} onClick={() => setTab('matrix')}>Matriz de produtos</button>
        <button className={tab === 'market' ? 'active' : ''} onClick={() => setTab('market')}>Mercado (search terms)</button>
      </div>

      {error && <div className="bmm-muted" style={{ color: '#b91c1c' }}>{error}</div>}
      {loading && <div className="bmm-muted">Carregando…</div>}

      {tab === 'matrix' && (
        <div className="bmm-wrap">
          <table className="bmm-t">
            <thead><tr>
              <th className="l">ASIN</th><th>Queries</th><th>Ativas</th><th>Compras</th>
              <th>Impr sh</th><th>Click sh</th><th>Purch sh</th><th>Purch lift</th><th>CTR</th><th>CVR</th><th className="l">Top query (compra)</th>
            </tr></thead>
            <tbody>
              {matrixSorted.map((m, i) => (
                <tr key={i}>
                  <td className="l">{m.asin}</td>
                  <td>{num(m.queries_count)}</td>
                  <td>{num(m.active_queries)}</td>
                  <td>{num(m.search_purchases)}</td>
                  <td>{pct(m.weighted_impression_share, 3)}</td>
                  <td>{pct(m.weighted_click_share, 3)}</td>
                  <td>{pct(m.weighted_purchase_share, 3)}</td>
                  <td>{ratio(m.purchase_share_lift)}</td>
                  <td>{pct(m.search_ctr)}</td>
                  <td>{pct(m.search_conversion)}</td>
                  <td className="l">{m.top_query_by_purchase || '—'}</td>
                </tr>
              ))}
              {!matrixSorted.length && !loading && <tr><td className="l bmm-muted" colSpan={11}>Sem produtos de marca com dado de query ainda.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === 'market' && (
        <>
          <div className="bmm-tools">
            <select value={cls} onChange={e => setCls(e.target.value)}>
              <option value="">Todas as classes</option>
              <option value="HIGHLY_CONCENTRATED">Muito concentrado</option>
              <option value="CONCENTRATED">Concentrado</option>
              <option value="FRAGMENTED">Fragmentado</option>
              <option value="HIGHLY_FRAGMENTED">Muito fragmentado</option>
            </select>
            <input placeholder="filtrar termo" value={q} onChange={e => setQ(e.target.value)} />
            <span className="bmm-muted">{marketFiltered.length} termos</span>
          </div>
          <div className="bmm-wrap">
            <table className="bmm-t">
              <thead><tr>
                <th>Freq rank</th><th className="l">Search term</th>
                <th className="l">Top1 ASIN</th><th>Top1 click sh</th>
                <th>Top3 concentração</th><th className="l">Classe</th><th>Δ rank WoW</th>
              </tr></thead>
              <tbody>
                {marketFiltered.map((m, i) => (
                  <tr key={i}>
                    <td>{num(m.search_frequency_rank)}</td>
                    <td className="l">{m.search_query}</td>
                    <td className="l">{m.top1_asin || '—'}</td>
                    <td>{pct(m.top1_click_share)}</td>
                    <td>{pct(m.top3_click_concentration)}</td>
                    <td className="l"><span className="bmm-tag" style={{ background: CLASS_COLORS[m.market_concentration_class] || '#334155' }}>{m.market_concentration_class}</span></td>
                    <td>{m.rank_change_wow === null || m.rank_change_wow === undefined ? '—' : num(m.rank_change_wow)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </section>
  )
}
