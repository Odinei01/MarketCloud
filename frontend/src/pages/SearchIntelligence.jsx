import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const fmt = n => Number(n || 0).toLocaleString('pt-BR', { maximumFractionDigits: 0 })
const pct = n => n === null || n === undefined ? '-' : `${(Number(n || 0) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`
const money = n => Number(n || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
const baValue = n => n === null || n === undefined ? 'pendente BA' : pct(n)

function isoDaysAgo(days) {
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}

function today() {
  return new Date().toISOString().slice(0, 10)
}

function recLabel(s) {
  const map = {
    ESCALAR_ORGANICO_FORTE: 'Escalar',
    ESCALAR_COM_CUIDADO_DEPENDE_ADS: 'Escalar com cuidado',
    REVISAR_MARGEM: 'Revisar margem',
    CORTAR_OU_REVISAR: 'Cortar/revisar',
    MANTER_OBSERVAR: 'Manter',
  }
  return map[s] || s || '-'
}

function recClass(s) {
  if (s === 'ESCALAR_ORGANICO_FORTE') return 'good'
  if (s === 'ESCALAR_COM_CUIDADO_DEPENDE_ADS') return 'warn'
  if (s === 'REVISAR_MARGEM' || s === 'CORTAR_OU_REVISAR') return 'bad'
  return 'neutral'
}

function baCoverageLabel(value) {
  if (value === 'REQUESTED_WAITING_AMAZON') return 'Solicitado - aguardando Amazon'
  if (value === 'NOT_CONFIGURED') return 'Ainda sem linhas oficiais'
  if (value === 'COMPLETE') return 'Completo'
  if (value === 'PARTIAL') return 'Parcial'
  return value || '-'
}

export default function SearchIntelligence({ ctx }) {
  const [from, setFrom] = useState(isoDaysAgo(29))
  const [to, setTo] = useState(today())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [data, setData] = useState({ items: [], totals: {}, coverage: {} })
  const [marketQueries, setMarketQueries] = useState([])
  const [selected, setSelected] = useState(null)
  const [detail, setDetail] = useState([])

  async function load() {
    setLoading(true)
    setError('')
    const res = await api.goldSearchIntelligence(ctx.tenantID, { from, to, limit: 80 })
    if (!res.ok) {
      setError(res.data?.error || 'Falha ao carregar Search Intelligence')
      setLoading(false)
      return
    }
    setData(res.data)
    const first = res.data.items?.[0] || null
    setSelected(first)
    setLoading(false)
    if (first?.asin) loadDetail(first)
    loadMarketQueries()
  }

  async function loadMarketQueries() {
    const res = await api.goldSearchIntelligenceMarketQueries(ctx.tenantID, { from, to, limit: 24 })
    setMarketQueries(res.ok ? (res.data.items || []) : [])
  }

  async function loadDetail(item) {
    setSelected(item)
    const res = await api.goldSearchIntelligenceProduct(ctx.tenantID, item.asin, { from, to })
    setDetail(res.ok ? (res.data.items || []) : [])
  }

  useEffect(() => { load() }, [ctx.tenantID])

  const totals = data.totals || {}
  const items = data.items || []
  const strongest = useMemo(() => items.filter(i => i.ebitda_estimated > 0).slice(0, 5), [items])
  const risk = useMemo(() => items.filter(i => i.ads_spend > 0 && i.gross_sales <= 0).slice(0, 5), [items])
  const selectedEbitdaMargin = selected?.ebitda_margin ?? (
    Number(selected?.gross_sales || 0) > 0
      ? Number(selected?.ebitda_estimated || 0) / Number(selected?.gross_sales || 1)
      : null
  )
  const selectedBA = detail.find(d => d.ba_coverage_status && d.ba_coverage_status !== 'NO_BRAND_ANALYTICS_DATA') || selected || {}
  const selectedQueries = Array.isArray(selectedBA.ba_top_queries)
    ? selectedBA.ba_top_queries.flat().slice(0, 6)
    : []

  return (
    <div className="search-intel">
      <header className="page-head">
        <div>
          <h2>Search Intelligence</h2>
          <p>Produtos, venda total Amazon, Ads vs organico estimado e funil de busca Brand Analytics.</p>
        </div>
        <div className="si-actions">
          <input type="date" value={from} onChange={e => setFrom(e.target.value)} />
          <input type="date" value={to} onChange={e => setTo(e.target.value)} />
          <button className="btn" onClick={load}>Atualizar</button>
        </div>
      </header>

      {error && <div className="alert bad">{error}</div>}

      <section className="si-kpis">
        <div><span>Faturamento</span><b>{money(totals.gross_sales)}</b><small>Sales API total alocada por ASIN</small></div>
        <div><span>Itens vendidos</span><b>{fmt(totals.units)}</b><small>{fmt(totals.orders)} pedidos no periodo</small></div>
        <div><span>Ads</span><b>{money(totals.ads_spend)}</b><small>{money(totals.ads_sales)} atribuida Ads</small></div>
        <div><span>Organico estimado</span><b>{money(totals.organic_sales_estimated)}</b><small>Venda total - Ads atribuido</small></div>
        <div><span>EBITDA estimado</span><b>{money(totals.ebitda_estimated)}</b><small>{pct(totals.ebitda_margin)} de margem EBITDA</small></div>
      </section>

      <section className="si-coverage">
        <div>
          <strong>Brand Analytics</strong>
          <span>{baCoverageLabel(data.coverage?.brand_analytics)}</span>
        </div>
        <p>{fmt(data.coverage?.brand_analytics_items)} produtos com BA - {fmt(data.coverage?.brand_analytics_queries)} queries oficiais. Jobs pendentes: {fmt(data.coverage?.brand_analytics_jobs?.pending)}.</p>
      </section>

      <div className="si-grid">
        <section className="panel">
          <div className="panel-head">
            <h3>Ranking de produtos</h3>
            <span>{loading ? 'carregando...' : `${items.length} produtos`}</span>
          </div>
          <div className="si-table">
            <div className="si-row head">
              <span>Produto</span><span>Receita</span><span>Itens</span><span>Organico</span><span>Ads</span><span>EBITDA</span><span>Decisao</span>
            </div>
            {items.map(item => (
              <button key={item.asin} className={`si-row ${selected?.asin === item.asin ? 'active' : ''}`} onClick={() => loadDetail(item)}>
                <span><b>{item.product_name || item.asin}</b><small>{item.seller_sku || '-'} | {item.asin}</small></span>
                <span>{money(item.gross_sales)}</span>
                <span>{fmt(item.total_units)}<small>{fmt(item.total_orders)} ped.</small></span>
                <span>{pct(item.organic_sales_share)}</span>
                <span>{money(item.ads_spend)}</span>
                <span className={Number(item.ebitda_estimated || 0) >= 0 ? 'pos' : 'neg'}>
                  {money(item.ebitda_estimated)}
                  <small>{pct(item.ebitda_margin)}</small>
                </span>
                <span><i className={recClass(item.recommendation_status)}>{recLabel(item.recommendation_status)}</i></span>
              </button>
            ))}
            {!loading && !items.length && <div className="empty">Nenhum produto no periodo.</div>}
          </div>
        </section>

        <aside className="panel detail">
          <div className="panel-head">
            <h3>{selected?.product_name || 'Produto'}</h3>
            <span>{selected?.asin || '-'}</span>
          </div>

          <div className="mini-grid">
            <div><span>Receita</span><b>{money(selected?.gross_sales)}</b></div>
            <div><span>Itens vendidos</span><b>{fmt(selected?.total_units)}</b><small>{fmt(selected?.total_orders)} pedidos</small></div>
            <div><span>EBITDA</span><b>{money(selected?.ebitda_estimated)}</b><small>{pct(selectedEbitdaMargin)}</small></div>
            <div><span>Organico</span><b>{pct(selected?.organic_sales_share)}</b></div>
            <div><span>Dependencia Ads</span><b>{pct(selected?.ads_sales_share)}</b></div>
          </div>

          <div className="ebitda-card">
            <h4>EBITDA por produto</h4>
            <div className="formula-line total"><span>Receita total</span><b>{money(selected?.gross_sales)}</b></div>
            <div className="formula-line"><span>Itens vendidos</span><b>{fmt(selected?.total_units)} un. / {fmt(selected?.total_orders)} pedidos</b></div>
            <div className="formula-line"><span>CMV ZANOM</span><b>- {money(selected?.cmv_estimated)}</b></div>
            <div className="formula-line"><span>Fees Amazon</span><b>- {money(selected?.amazon_fee_estimated)}</b></div>
            <div className="formula-line"><span>Ads</span><b>- {money(selected?.ads_spend)}</b></div>
            <div className="formula-line"><span>Imposto 4%</span><b>- {money(selected?.tax_estimated)}</b></div>
            <div className="formula-line"><span>COPER 2%</span><b>- {money(selected?.coper_estimated)}</b></div>
            <div className={`formula-line result ${Number(selected?.ebitda_estimated || 0) >= 0 ? 'pos' : 'neg'}`}>
              <span>EBITDA estimado</span><b>{money(selected?.ebitda_estimated)} - {pct(selectedEbitdaMargin)}</b>
            </div>
          </div>

          <div className="funnel">
            <h4>Funil de busca</h4>
            <div className="funnel-row"><span>Impression share</span><b>{baValue(selectedBA.ba_impression_share)}</b></div>
            <div className="funnel-row"><span>Click share</span><b>{baValue(selectedBA.ba_click_share)}</b></div>
            <div className="funnel-row"><span>Cart share</span><b>{baValue(selectedBA.ba_cart_share)}</b></div>
            <div className="funnel-row"><span>Purchase share</span><b>{baValue(selectedBA.ba_purchase_share)}</b></div>
            <div className="funnel-row"><span>Lift compra vs impressao</span><b>{baValue(selectedBA.ba_purchase_share_lift)}</b></div>
            <div className="funnel-row"><span>Conversao busca</span><b>{baValue(selectedBA.ba_search_conversion)}</b></div>
            {selectedQueries.length > 0 && (
              <div className="queries">
                <h4>Queries que puxam o produto</h4>
                {selectedQueries.map((q, idx) => (
                  <div className="query-line" key={`${q.search_query || idx}-${idx}`}>
                    <span>{q.search_query || '-'}</span>
                    <b>rank {q.query_rank || '-'}</b>
                    <small>{fmt(q.clicks)} cliques - {fmt(q.purchases)} compras - share compra {baValue(q.brand_purchase_share)}</small>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="daily">
            <h4>Dia a dia</h4>
            {detail.slice(-12).map(d => (
              <div className="daily-row" key={d.data_date}>
                <span>{String(d.data_date).slice(0, 10)}</span>
                <b>{money(d.gross_sales)}</b>
                <small>{fmt(d.total_units)} un. - EBITDA {money(d.ebitda_estimated)} ({pct(d.ebitda_margin)}) - Ads {money(d.ads_spend)} / Org. {money(d.organic_sales_estimated)}</small>
              </div>
            ))}
          </div>
        </aside>
      </div>

      <section className="si-grid bottom">
        <div className="panel">
          <div className="panel-head"><h3>Top rentaveis</h3></div>
          {strongest.map(p => <div className="simple-line" key={p.asin}><span>{p.product_name}</span><b>{money(p.ebitda_estimated)} <small>{pct(p.ebitda_margin)}</small></b></div>)}
        </div>
        <div className="panel">
          <div className="panel-head"><h3>Queimam Ads sem venda</h3></div>
          {risk.map(p => <div className="simple-line" key={p.asin}><span>{p.product_name}</span><b>{money(p.ads_spend)}</b></div>)}
          {!risk.length && <div className="empty">Nenhum caso critico no periodo.</div>}
        </div>
      </section>

      <section className="panel">
        <div className="panel-head">
          <h3>Demanda de mercado - Brand Analytics</h3>
          <span>{marketQueries.length} queries oficiais</span>
        </div>
        <div className="market-query-grid">
          {marketQueries.map(q => {
            const leaders = Array.isArray(q.top_asins) ? q.top_asins.slice(0, 3) : []
            return (
              <div className="market-query" key={q.search_query}>
                <div>
                  <b>{q.search_query}</b>
                  <small>rank {q.best_rank || '-'} - {fmt(q.asin_count)} ASINs clicados</small>
                </div>
                <div className="market-metrics">
                  <span>click {pct(q.avg_click_share)}</span>
                  <span>conv. {pct(q.avg_purchase_share)}</span>
                  <span>{fmt(q.our_asin_count)} nossos</span>
                </div>
                {leaders.map((a, idx) => (
                  <small className="leader" key={`${q.search_query}-${a.asin}-${idx}`}>
                    {a.asin} - {String(a.item_name || '').slice(0, 72)}
                  </small>
                ))}
              </div>
            )
          })}
          {!marketQueries.length && <div className="empty">Brand Analytics solicitado; aguardando linhas de query.</div>}
        </div>
      </section>

      <style>{`
        .search-intel{display:grid;gap:16px}
        .si-actions{display:flex;gap:10px;align-items:center}
        .si-actions input{background:#101826;border:1px solid var(--line);border-radius:8px;color:var(--text);padding:10px}
        .si-kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px}
        .si-kpis>div,.si-coverage,.panel{border:1px solid var(--line);border-radius:8px;background:rgba(255,255,255,.035);padding:16px}
        .si-kpis span,.mini-grid span{display:block;color:var(--muted);font-size:12px;font-weight:800;text-transform:uppercase;letter-spacing:.04em}
        .si-kpis b{display:block;font-size:26px;margin-top:8px}
        .si-kpis small,.si-coverage p,.si-row small,.mini-grid small{color:var(--muted);font-size:12px}
        .si-coverage{display:flex;align-items:center;justify-content:space-between;gap:16px;border-color:#2d5f9a;background:rgba(30,102,170,.12)}
        .si-coverage strong{display:block}.si-coverage span{color:#9fcbff}
        .si-grid{display:grid;grid-template-columns:minmax(0,1.55fr) minmax(360px,.75fr);gap:16px}
        .si-grid.bottom{grid-template-columns:1fr 1fr}
        .market-query-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
        .market-query{border:1px solid var(--line);border-radius:8px;padding:12px;background:rgba(0,0,0,.14);display:grid;gap:8px}
        .market-query b{font-size:15px}.market-query small{color:var(--muted)}
        .market-metrics{display:flex;gap:8px;flex-wrap:wrap}
        .market-metrics span{border:1px solid rgba(159,203,255,.25);border-radius:999px;padding:4px 8px;color:#9fcbff;font-size:12px;font-weight:800}
        .leader{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .panel-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
        .panel-head h3{margin:0;font-size:16px}.panel-head span{color:var(--muted);font-size:12px}
        .si-table{display:grid;gap:1px;overflow:auto}
        .si-row{display:grid;grid-template-columns:minmax(250px,1.7fr) .7fr .45fr .55fr .55fr .7fr .75fr;gap:12px;align-items:center;width:100%;border:0;border-bottom:1px solid rgba(255,255,255,.07);background:transparent;color:var(--text);text-align:left;padding:13px 10px}
        .si-row.head{color:#a8c7ee;font-size:12px;text-transform:uppercase;letter-spacing:.08em;font-weight:900}
        button.si-row{cursor:pointer}
        button.si-row:hover,button.si-row.active{background:rgba(75,143,255,.12)}
        .pos{color:#22e58a}.neg{color:#ff5d77}
        i{font-style:normal;border-radius:999px;padding:5px 9px;font-size:12px;font-weight:900}
        i.good{background:#0d513b;color:#25e28a} i.warn{background:#4b3518;color:#ffbd66} i.bad{background:#522033;color:#ff6380} i.neutral{background:#263246;color:#b7c7df}
        .mini-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:16px}
        .mini-grid>div{border:1px solid var(--line);border-radius:8px;padding:12px;background:rgba(0,0,0,.12)}
        .mini-grid b{font-size:20px}
        .ebitda-card,.funnel,.daily{border-top:1px solid var(--line);padding-top:14px;margin-top:14px}
        .ebitda-card h4,.funnel h4,.daily h4,.queries h4{margin:0 0 10px}
        .formula-line{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px solid rgba(255,255,255,.055);font-size:13px}
        .formula-line span{color:var(--muted)}
        .formula-line.total span,.formula-line.result span{color:var(--text);font-weight:800}
        .formula-line.result{margin-top:4px;border-top:1px solid rgba(255,255,255,.12);font-size:14px}
        .funnel-row,.daily-row,.simple-line{display:flex;align-items:center;justify-content:space-between;gap:12px;border-bottom:1px solid rgba(255,255,255,.06);padding:10px 0}
        .funnel-row b{color:#ffbd66;font-size:12px;text-transform:uppercase}
        .queries{margin-top:14px;border-top:1px solid rgba(255,255,255,.08);padding-top:12px}
        .query-line{display:grid;grid-template-columns:minmax(0,1.2fr) 70px minmax(0,1fr);gap:10px;align-items:center;padding:8px 0;border-bottom:1px solid rgba(255,255,255,.055)}
        .query-line span{font-weight:800}.query-line b{color:#9fcbff}.query-line small{color:var(--muted)}
        .daily-row{display:grid;grid-template-columns:90px 1fr 1.4fr}.daily-row small{color:var(--muted)}
        .empty{color:var(--muted);padding:18px;text-align:center}
        @media(max-width:1100px){.si-kpis,.si-grid,.si-grid.bottom,.market-query-grid{grid-template-columns:1fr}.si-row{grid-template-columns:1.3fr .7fr .5fr}.si-row span:nth-child(4),.si-row span:nth-child(5),.si-row span:nth-child(7),.si-row.head span:nth-child(4),.si-row.head span:nth-child(5),.si-row.head span:nth-child(7){display:none}}
      `}</style>
    </div>
  )
}
