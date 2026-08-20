import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const fmt = n => Number(n || 0).toLocaleString('pt-BR', { maximumFractionDigits: 0 })
const pct = n => n === null || n === undefined ? '-' : `${(Number(n || 0) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`
const money = n => Number(n || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
const baValue = n => n === null || n === undefined ? 'nao veio no report' : pct(n)
const ratio = n => n === null || n === undefined ? '-' : Number(n || 0).toLocaleString('pt-BR', { maximumFractionDigits: 2 })

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
    ESCALAR_ORGANICO_FORTE: 'Tração orgânica',
    ESCALAR_COM_CUIDADO_DEPENDE_ADS: 'Tração com Ads',
    REVISAR_MARGEM: 'Margem pressionada',
    CORTAR_OU_REVISAR: 'Aquisição fraca',
    MANTER_OBSERVAR: 'Observação',
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

function sourceStatusLabel(value) {
  if (value === 'READY') return 'Pronta'
  if (value === 'PARTIAL') return 'Parcial'
  if (value === 'MISSING') return 'Faltando'
  return value || '-'
}

function sourceSummary(source) {
  const e = source?.evidence || {}
  if (source?.source_key === 'FINANCEIRO_ASIN') {
    return `${fmt(e.asins)} ASINs, ${fmt(e.rows_with_sales)} com venda, ${fmt(e.rows_with_cost)} com custo`
  }
  if (source?.source_key === 'SEARCH_CATALOG_PERFORMANCE') {
    return `${fmt(e.asins)} ASINs, ${fmt(e.impressions)} imp., ${fmt(e.clicks)} cliques, ${fmt(e.purchases)} compras`
  }
  if (source?.source_key === 'SEARCH_QUERY_PERFORMANCE') {
    return `${fmt(e.asins)} ASINs, ${fmt(e.impressions)} imp., ${fmt(e.clicks)} cliques, ${fmt(e.purchases)} compras`
  }
  if (source?.source_key === 'BRAND_QUERY_COMPREHENSIVE') {
    return `${fmt(e.queries)} queries, volume ${fmt(e.search_query_volume)}, ${fmt(e.purchases)} compras totais`
  }
  if (source?.source_key === 'ADS_SEARCH_TERMS') {
    return `${fmt(e.search_terms)} termos, ${fmt(e.resolved_asins)} ASINs resolvidos, ${money(e.spend)} gasto`
  }
  return `${fmt(source?.rows)} linhas`
}

function mlExplainLabel(value) {
  const map = {
    ML_SIGNAL_WITH_MARGIN: 'ML com margem',
    ML_SIGNAL_WEAK_ON_PAID_QUERY: 'ML fraco na query paga',
    COMPETITOR_CONTEXT_NO_ML_MATCH: 'Concorrencia sem par no ML',
    ADS_FACT_NO_SALE: 'Ads sem venda no recorte',
    CONTEXT_ONLY: 'Contexto apenas',
  }
  return map[value] || value || '-'
}

function mlExplainClass(value) {
  if (value === 'ML_SIGNAL_WITH_MARGIN') return 'good'
  if (value === 'ML_SIGNAL_WEAK_ON_PAID_QUERY' || value === 'ADS_FACT_NO_SALE') return 'warn'
  if (value === 'COMPETITOR_CONTEXT_NO_ML_MATCH') return 'neutral'
  return 'neutral'
}

function doctorEvidenceLabel(value) {
  const map = {
    ML_COMPETITION_AND_MARKET: 'ML + concorrencia + mercado',
    ML_ONLY: 'ML com dados internos',
    MARKET_COMPETITION_ONLY: 'Mercado/concorrencia sem ML',
    ADS_FACT_ONLY: 'Fato Ads apenas',
    LOW_SIGNAL: 'Sinal baixo',
  }
  return map[value] || value || '-'
}

function doctorEvidenceClass(value) {
  if (value === 'ML_COMPETITION_AND_MARKET') return 'good'
  if (value === 'MARKET_COMPETITION_ONLY' || value === 'ADS_FACT_ONLY') return 'warn'
  return 'neutral'
}

function coverageLabel(value) {
  const map = {
    COBERTURA_COMPLETA: 'Completa',
    COBERTURA_OPERACIONAL_SEM_SQP: 'Operacional sem SQP',
    ADS_E_FINANCEIRO_SEM_BA_COMPLETO: 'Ads + financeiro',
    FINANCEIRO_APENAS: 'Financeiro apenas',
    COBERTURA_INSUFICIENTE: 'Insuficiente',
  }
  return map[value] || value || '-'
}

export default function SearchIntelligence({ ctx }) {
  const [from, setFrom] = useState(isoDaysAgo(29))
  const [to, setTo] = useState(today())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [productFilter, setProductFilter] = useState('ZANOM')
  const [data, setData] = useState({ items: [], totals: {}, coverage: {} })
  const [marketQueries, setMarketQueries] = useState([])
  const [brandQueryData, setBrandQueryData] = useState({ items: [], totals: {} })
  const [competitorData, setCompetitorData] = useState({ items: [], totals: {} })
  const [coverageData, setCoverageData] = useState({ items: [], summary: [] })
  const [queryOpps, setQueryOpps] = useState({ items: [], totals: {} })
  const [selected, setSelected] = useState(null)
  const [detail, setDetail] = useState([])
  const [adsTerms, setAdsTerms] = useState({ items: [], totals: {} })
  const [selectedQueryOpps, setSelectedQueryOpps] = useState({ items: [], totals: {} })
  const [detailOpen, setDetailOpen] = useState(false)

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
    loadMarketQueries()
    loadBrandQueries()
    loadCompetitors()
    loadCoverage()
    loadQueryOpps()
  }

  async function loadMarketQueries() {
    const res = await api.goldSearchIntelligenceMarketQueries(ctx.tenantID, { from, to, limit: 24 })
    setMarketQueries(res.ok ? (res.data.items || []) : [])
  }

  async function loadBrandQueries() {
    const res = await api.goldSearchIntelligenceBrandQueries(ctx.tenantID, { from, to, limit: 80 })
    setBrandQueryData(res.ok ? { items: res.data.items || [], totals: res.data.totals || {} } : { items: [], totals: {} })
  }

  async function loadCompetitors() {
    const res = await api.goldSearchIntelligenceCompetitors(ctx.tenantID, { mode: 'ads', limit: 80 })
    setCompetitorData(res.ok ? { items: res.data.items || [], totals: res.data.totals || {} } : { items: [], totals: {} })
  }

  async function loadCoverage() {
    const res = await api.goldSearchIntelligenceCoverage(ctx.tenantID, { limit: 80 })
    setCoverageData(res.ok ? { items: res.data.items || [], summary: res.data.summary || [] } : { items: [], summary: [] })
  }

  async function loadQueryOpps() {
    const res = await api.goldSearchIntelligenceQueryDoctor(ctx.tenantID, { limit: 40 })
    setQueryOpps(res.ok ? { items: res.data.items || [], totals: res.data.totals || {} } : { items: [], totals: {} })
  }

  async function loadDetail(item) {
    setSelected(item)
    setDetailOpen(true)
    setDetail([])
    setAdsTerms({ items: [], totals: {} })
    setSelectedQueryOpps({ items: [], totals: {} })
    const res = await api.goldSearchIntelligenceProduct(ctx.tenantID, item.asin, { from, to })
    setDetail(res.ok ? (res.data.items || []) : [])
    const termsRes = await api.goldSearchIntelligenceProductAdsTerms(ctx.tenantID, item.asin, { from, to, limit: 60 })
    setAdsTerms(termsRes.ok ? { items: termsRes.data.items || [], totals: termsRes.data.totals || {} } : { items: [], totals: {} })
    const oppsRes = await api.goldSearchIntelligenceProductQueryDoctor(ctx.tenantID, item.asin, { limit: 60 })
    setSelectedQueryOpps(oppsRes.ok ? { items: oppsRes.data.items || [], totals: oppsRes.data.totals || {} } : { items: [], totals: {} })
  }

  useEffect(() => { load() }, [ctx.tenantID])

  const totals = data.totals || {}
  const items = data.items || []
  const zanomItems = useMemo(() => items.filter(i => String(i.brand || '').toUpperCase() === 'ZANOM'), [items])
  const genericItems = useMemo(() => items.filter(i => String(i.brand || '').toUpperCase() !== 'ZANOM'), [items])
  const filteredItems = useMemo(() => {
    if (productFilter === 'ZANOM') return zanomItems
    if (productFilter === 'GENERIC') return genericItems
    return items
  }, [items, zanomItems, genericItems, productFilter])
  const filteredTotals = useMemo(() => filteredItems.reduce((acc, item) => {
    acc.gross_sales += Number(item.gross_sales || 0)
    acc.units += Number(item.total_units || 0)
    acc.orders += Number(item.total_orders || 0)
    acc.ads_spend += Number(item.ads_spend || 0)
    acc.ebitda += Number(item.ebitda_estimated || 0)
    return acc
  }, { gross_sales: 0, units: 0, orders: 0, ads_spend: 0, ebitda: 0 }), [filteredItems])
  const strongest = useMemo(() => filteredItems.filter(i => i.ebitda_estimated > 0).slice(0, 5), [filteredItems])
  const risk = useMemo(() => filteredItems.filter(i => i.ads_spend > 0 && i.gross_sales <= 0).slice(0, 5), [filteredItems])
  const selectedEbitdaMargin = selected?.ebitda_margin ?? (
    Number(selected?.gross_sales || 0) > 0
      ? Number(selected?.ebitda_estimated || 0) / Number(selected?.gross_sales || 1)
      : null
  )
  const selectedBA = detail.find(d => d.ba_coverage_status && d.ba_coverage_status !== 'NO_BRAND_ANALYTICS_DATA') || selected || {}
  const selectedQueries = Array.isArray(selectedBA.ba_top_queries)
    ? selectedBA.ba_top_queries.flat().slice(0, 6)
    : []
  const brandQueries = brandQueryData.items || []
  const brandTotals = brandQueryData.totals || {}
  const competitors = competitorData.items || []
  const competitorTotals = competitorData.totals || {}
  const coverageSummary = coverageData.summary || []
  const coverageItems = coverageData.items || []
  const queryOpportunityItems = queryOpps.items || []
  const queryOpportunityTotals = queryOpps.totals || {}
  const selectedSCPHasPurchase = Number(selectedBA.ba_purchases || 0) > 0
  const selectedSCPCoverage = Number(selectedBA.ba_impressions || 0) > 0 || Number(selectedBA.ba_clicks || 0) > 0
  const minimumSources = data.coverage?.minimum_sources || []
  const minimumMatrix = data.coverage?.minimum_matrix || {}
  const selectedAdsTerms = adsTerms.items || []
  const selectedAdsTermsTotals = adsTerms.totals || {}
  const selectedQueryOpportunityItems = selectedQueryOpps.items || []
  const selectedQueryOpportunityTotals = selectedQueryOpps.totals || {}
  const selectedAvgPrice = selected?.avg_realized_price ?? (
    Number(selected?.total_units || 0) > 0 ? Number(selected?.gross_sales || 0) / Number(selected?.total_units || 1) : null
  )
  const adsRoas = Number(selected?.ads_spend || 0) > 0 ? Number(selected?.ads_sales || 0) / Number(selected?.ads_spend || 1) : null
  const adsAcos = Number(selected?.ads_sales || 0) > 0 ? Number(selected?.ads_spend || 0) / Number(selected?.ads_sales || 1) : null
  const adsCpc = Number(selected?.ads_clicks || 0) > 0 ? Number(selected?.ads_spend || 0) / Number(selected?.ads_clicks || 1) : null
  const adsCvr = Number(selected?.ads_clicks || 0) > 0 ? Number(selected?.ads_orders || 0) / Number(selected?.ads_clicks || 1) : null
  const diagnosis = (() => {
    if (!selected) return { label: '-', text: '' }
    if (Number(selected.ebitda_margin || 0) < 0.12 && Number(selected.ads_spend || 0) > 0) {
      return { label: 'Economia pressionada', text: 'Leitura financeira: margem baixa com Ads no periodo. A decisao operacional deve vir do modelo; aqui ficam as evidencias.' }
    }
    if (Number(selectedBA.ba_conversion_rate ?? selectedBA.ba_search_conversion ?? 0) >= 0.08 && Number(selected.ebitda_margin || 0) > 0.18) {
      return { label: 'Produto com tracao', text: 'Leitura factual: SCP mostra conversao e a economia tem folga. Esse contexto passa a explicar as predicoes do ML.' }
    }
    if (Number(selected.ads_spend || 0) > 0 && Number(adsRoas || 0) < 3) {
      return { label: 'Aquisicao pressionada', text: 'Leitura factual: Ads abaixo do alvo no periodo. A tabela ASIN x Query mostra quais termos sustentam essa leitura.' }
    }
    return { label: 'Leitura aberta', text: 'Combine SCP, Ads, query share e predicao V3 antes de liberar qualquer automacao.' }
  })()

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

      <section className="panel competitor-radar">
        <div className="panel-head">
          <h3>Radar de concorrentes</h3>
          <span>{fmt(competitorTotals.competitors)} ASINs concorrentes / {fmt(competitorTotals.queries)} queries</span>
        </div>
        <div className="section-note">
          Evidencia factual para o ML: ASINs que a Amazon mostrou como top produtos nas queries. A tela nao toma decisao; ela mostra o contexto competitivo que entra no treinamento.
        </div>
        <div className="competitor-kpis">
          <div><span>Concorrentes mapeados</span><b>{fmt(competitorTotals.competitors)}</b><small>{fmt(competitorTotals.with_our_ads)} linhas em queries com Ads ZANOM</small></div>
          <div><span>Queries disputadas</span><b>{fmt(competitorTotals.queries)}</b><small>termos com top ASINs BA</small></div>
          <div><span>Estamos gastando nelas</span><b>{money(competitorTotals.our_spend_on_competed_queries)}</b><small>{money(competitorTotals.our_sales_on_competed_queries)} vendas Ads</small></div>
          <div><span>Concorrente compra e nos nao</span><b>{fmt(competitorTotals.competitor_purchase_while_our_ads_no_sale)}</b><small>feature competitiva para o ML</small></div>
        </div>
        <div className="competitor-table">
          <div className="competitor-row head">
            <span>Query</span><span>Concorrente</span><span>Share conc.</span><span>Nosso Ads</span><span>Evidencia</span>
          </div>
          {competitors.slice(0, 24).map((c, idx) => (
            <div className="competitor-row" key={`${c.search_query}-${c.competitor_asin}-${idx}`}>
              <span><b>{c.search_query}</b><small>nossos ASINs: {(c.our_advertised_asins || []).join(', ') || '-'}</small></span>
              <span><b>{c.competitor_asin}</b><small>{c.competitor_item_name}</small></span>
              <span>click {pct(c.competitor_click_share)}<small>compra {pct(c.competitor_purchase_share)}</small></span>
              <span>{money(c.ads_spend)}<small>ROAS {ratio(c.ads_roas)} / vendas {money(c.ads_sales)}</small></span>
              <span>
                <i className={Number(c.ads_spend || 0) > 0 && Number(c.ads_sales || 0) === 0 && Number(c.competitor_purchase_share || 0) > 0 ? 'bad' : 'neutral'}>
                  {Number(c.ads_spend || 0) > 0 && Number(c.ads_sales || 0) === 0 && Number(c.competitor_purchase_share || 0) > 0 ? 'nos gastamos sem venda' : 'contexto'}
                </i>
                <small>fato para treino, nao recomendacao</small>
              </span>
            </div>
          ))}
          {!competitors.length && <div className="empty">Sem concorrentes cruzados com gasto Ads ZANOM.</div>}
        </div>
      </section>

      <section className="panel ml-query-layer">
        <div className="panel-head">
          <h3>Doutor de Query - SEO e concorrencia</h3>
          <span>{fmt(queryOpportunityTotals.rows)} linhas / {fmt(queryOpportunityTotals.with_ml)} com ML</span>
        </div>
        <div className="section-note">
          Leitura explicativa por ASIN/query: cruza Ads Search Terms, SCP/SQP, concorrentes, mercado e predicoes V3. Nao e action matrix; serve para explicar o que o ML esta enxergando e onde falta dado.
        </div>
        <div className="competitor-kpis">
          <div><span>ASINs no cruzamento</span><b>{fmt(queryOpportunityTotals.asins)}</b><small>{fmt(queryOpportunityTotals.with_brand_query)} com query BA</small></div>
          <div><span>Com predicao ML</span><b>{fmt(queryOpportunityTotals.with_ml)}</b><small>join por campanha + query</small></div>
          <div><span>Com concorrente BA</span><b>{fmt(queryOpportunityTotals.with_competitor)}</b><small>top ASINs da query</small></div>
          <div><span>ML + mercado</span><b>{fmt(queryOpportunityTotals.classes?.ML_COMPETITION_AND_MARKET)}</b><small>linhas com predicao + BA + concorrente</small></div>
        </div>
        <div className="ml-query-table">
          <div className="ml-query-row head">
            <span>ASIN / query</span><span>Campanha</span><span>Leitura</span><span>ML</span><span>BA / concorrencia</span><span>Historico D-1</span>
          </div>
          {queryOpportunityItems.slice(0, 24).map((q, idx) => (
            <div className="ml-query-row" key={`${q.asin}-${q.campaign_id}-${q.query_key}-${idx}`}>
              <span><b>{q.search_query}</b><small>{q.asin} - {q.product_name || '-'}</small></span>
              <span><b>{q.campaign_name || '-'}</b><small>{q.ad_group_name || '-'}</small></span>
              <span>
                <i className={doctorEvidenceClass(q.doctor_evidence_class)}>{doctorEvidenceLabel(q.doctor_evidence_class)}</i>
                <small>{coverageLabel(q.coverage_label)} / SQP {sourceStatusLabel(q.sqp_status)}</small>
              </span>
              <span>
                <i className={mlExplainClass(q.ml_explain_label)}>{mlExplainLabel(q.ml_explain_label)}</i>
                <small>ROAS esp. {ratio(q.ml_max_expected_roas)} / P(conv) {pct(q.ml_max_conversion_probability)} / celulas {fmt(q.ml_cells)}</small>
              </span>
              <span>vol. {fmt(q.search_query_volume)}<small>{fmt(q.competitor_count)} concorrentes / compra share {pct(q.top_competitor_purchase_share)}</small></span>
              <span>{money(q.spend_7d_lag)}<small>7d D-1: {fmt(q.orders_7d_lag)} ped. / Ads {money(q.ads_spend)}</small></span>
            </div>
          ))}
          {!queryOpportunityItems.length && <div className="empty">Sem evidencias do Doutor de Query ainda.</div>}
        </div>
      </section>

      <section className="panel compact-panel">
        <div className="panel-head">
          <h3>Carteira de ASINs</h3>
          <span>{fmt(items.length)} produtos avaliados</span>
        </div>
        <div className="segment-row">
          <button className={productFilter === 'ZANOM' ? 'active' : ''} onClick={() => setProductFilter('ZANOM')}>
            Marca ZANOM <b>{fmt(zanomItems.length)}</b>
          </button>
          <button className={productFilter === 'GENERIC' ? 'active' : ''} onClick={() => setProductFilter('GENERIC')}>
            ASINs genericos/outros <b>{fmt(genericItems.length)}</b>
          </button>
          <button className={productFilter === 'ALL' ? 'active' : ''} onClick={() => setProductFilter('ALL')}>
            Todos <b>{fmt(items.length)}</b>
          </button>
        </div>
        <div className="portfolio-strip">
          <span>Receita filtrada <b>{money(filteredTotals.gross_sales)}</b></span>
          <span>Itens <b>{fmt(filteredTotals.units)}</b></span>
          <span>Pedidos <b>{fmt(filteredTotals.orders)}</b></span>
          <span>Ads <b>{money(filteredTotals.ads_spend)}</b></span>
          <span>EBITDA <b className={filteredTotals.ebitda >= 0 ? 'pos' : 'neg'}>{money(filteredTotals.ebitda)}</b></span>
        </div>
        {productFilter === 'GENERIC' && !genericItems.length && (
          <div className="data-note">
            <b>Por que nao aparecem ASINs genericos?</b>
            <span>Na camada financeira por produto, todos os ASINs atuais estao classificados como marca ZANOM. ASINs concorrentes aparecem hoje no bloco de query/concorrencia, nao no ranking financeiro do portfolio.</span>
          </div>
        )}
      </section>

      <section className="panel">
        <div className="panel-head">
          <h3>Cobertura Brand Analytics e fontes do ML</h3>
          <span>{fmt(minimumMatrix.ready_for_decision)} ASINs prontos / {fmt(minimumMatrix.total_asins)} avaliados</span>
        </div>
        <div className="section-note">
          O objetivo aqui e saber se temos base suficiente para o ML aprender: financeiro do ASIN, SCP, SQP proprietario e Ads Search Terms. O maior gargalo atual aparece explicitamente por fonte.
        </div>
        <div className="source-grid">
          {coverageSummary.map(source => (
            <div className={`source-card ${Number(source.ready_asins || 0) > 0 ? 'ready' : 'missing'}`} key={source.source_key}>
              <span>{source.source_label}</span>
              <b>{fmt(source.ready_asins)} / {fmt(source.total_asins)}</b>
              <small>{source.explanation}</small>
            </div>
          ))}
          {!coverageSummary.length && minimumSources.map(source => (
            <div className={`source-card ${String(source.status || '').toLowerCase()}`} key={source.source_key}>
              <span>{source.source_label}</span>
              <b>{sourceStatusLabel(source.status)}</b>
              <small>{sourceSummary(source)}</small>
            </div>
          ))}
        </div>
        <div className="readiness-line">
          <span>Prontos para decisao: <b>{fmt(minimumMatrix.ready_for_decision)}</b></span>
          <span>Observar apenas: <b>{fmt(minimumMatrix.observe_only)}</b></span>
          <span>Insuficientes: <b>{fmt(minimumMatrix.insufficient_data)}</b></span>
          <span>SCP faltando: <b>{fmt(minimumMatrix.scp_missing)}</b></span>
          <span>SQP faltando: <b>{fmt(minimumMatrix.sqp_missing)}</b></span>
          <span>Ads terms faltando: <b>{fmt(minimumMatrix.ads_search_terms_missing)}</b></span>
        </div>
        <div className="coverage-table">
          <div className="coverage-row head">
            <span>ASIN</span><span>Cobertura</span><span>Financeiro</span><span>SCP</span><span>SQP</span><span>Ads Terms</span><span>Falta</span>
          </div>
          {coverageItems.slice(0, 18).map(item => (
            <div className="coverage-row" key={item.asin}>
              <span><b>{item.product_name || item.asin}</b><small>{item.seller_sku || '-'} / {item.asin}</small></span>
              <span><i className={item.coverage_label === 'COBERTURA_OPERACIONAL_SEM_SQP' ? 'warn' : item.coverage_label === 'COBERTURA_COMPLETA' ? 'good' : 'neutral'}>{coverageLabel(item.coverage_label)}</i></span>
              <span>{sourceStatusLabel(item.finance_status)}</span>
              <span>{sourceStatusLabel(item.scp_status)}<small>{fmt(item.scp_impressions)} imp. / {fmt(item.scp_purchases)} compras</small></span>
              <span>{sourceStatusLabel(item.sqp_status)}<small>{fmt(item.sqp_query_rows)} queries</small></span>
              <span>{sourceStatusLabel(item.ads_search_terms_status)}<small>{fmt(item.ads_search_terms)} termos / {money(item.ads_search_term_spend)}</small></span>
              <span><small>{Object.values(item.missing_sources_json || {}).join(' | ') || 'Sem lacuna critica'}</small></span>
            </div>
          ))}
        </div>
      </section>

      <div className="si-grid single">
        <section className="panel">
          <div className="panel-head">
            <h3>Ranking de produtos</h3>
            <span>{loading ? 'carregando...' : `${filteredItems.length} produtos`}</span>
          </div>
          <div className="si-table">
            <div className="si-row head">
              <span>Produto</span><span>Receita</span><span>Itens</span><span>Organico</span><span>Ads</span><span>EBITDA</span><span>Leitura</span>
            </div>
            {filteredItems.map(item => (
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
            {!loading && !filteredItems.length && <div className="empty">Nenhum produto neste filtro.</div>}
          </div>
        </section>
      </div>

      {detailOpen && (
        <div className="modal-backdrop" onClick={() => setDetailOpen(false)}>
          <aside className="panel detail modal-card" onClick={e => e.stopPropagation()}>
          <div className="panel-head">
            <div>
              <h3>{selected?.product_name || 'Produto'}</h3>
              <span>{selected?.asin || '-'}</span>
            </div>
            <button className="close-btn" onClick={() => setDetailOpen(false)}>Fechar</button>
          </div>

          <div className="mini-grid">
            <div><span>Receita</span><b>{money(selected?.gross_sales)}</b></div>
            <div><span>Itens vendidos</span><b>{fmt(selected?.total_units)}</b><small>{fmt(selected?.total_orders)} pedidos</small></div>
            <div><span>EBITDA</span><b>{money(selected?.ebitda_estimated)}</b><small>{pct(selectedEbitdaMargin)}</small></div>
            <div><span>Organico</span><b>{pct(selected?.organic_sales_share)}</b></div>
            <div><span>Dependencia Ads</span><b>{pct(selected?.ads_sales_share)}</b></div>
          </div>

          <div className="diagnosis-card">
            <b>{diagnosis.label}</b>
            <span>{diagnosis.text}</span>
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

          <div className="decision-grid">
            <div className="decision-card">
              <h4>SCP</h4>
              <div><span>Impressoes</span><b>{fmt(selectedBA.ba_impressions)}</b></div>
              <div><span>Cliques</span><b>{fmt(selectedBA.ba_clicks)}</b></div>
              <div><span>CTR</span><b>{baValue(selectedBA.ba_click_rate)}</b></div>
              <div><span>Carrinhos</span><b>{fmt(selectedBA.ba_cart_adds)}</b></div>
              <div><span>Compras</span><b>{fmt(selectedBA.ba_purchases)}</b></div>
              <div><span>CVR</span><b>{baValue(selectedBA.ba_conversion_rate ?? selectedBA.ba_search_conversion)}</b></div>
            </div>
            <div className="decision-card">
              <h4>Ads</h4>
              <div><span>Receita Ads</span><b>{money(selected?.ads_sales)}</b></div>
              <div><span>Pedidos Ads</span><b>{fmt(selected?.ads_orders)}</b></div>
              <div><span>ACOS</span><b>{baValue(adsAcos)}</b></div>
              <div><span>ROAS</span><b>{ratio(adsRoas)}</b></div>
              <div><span>CPC</span><b>{money(adsCpc)}</b></div>
              <div><span>Cliques</span><b>{fmt(selected?.ads_clicks)}</b></div>
              <div><span>CVR Ads</span><b>{baValue(adsCvr)}</b></div>
            </div>
            <div className="decision-card">
              <h4>Search Query</h4>
              <div><span>Queries do ASIN</span><b>{fmt(selectedQueries.length)}</b></div>
              <div><span>Volume</span><b>{selectedQueries.length ? fmt(selectedQueries.reduce((acc, q) => acc + Number(q.search_query_volume || 0), 0)) : '-'}</b></div>
              <div><span>Impression Share</span><b>{selectedQueries.length ? baValue(selectedQueries[0]?.brand_impression_share ?? selectedQueries[0]?.impression_share) : 'sem query do ASIN'}</b></div>
              <div><span>Click Share</span><b>{selectedQueries.length ? baValue(selectedQueries[0]?.brand_click_share ?? selectedQueries[0]?.click_share) : 'sem query do ASIN'}</b></div>
              <div><span>Cart Share</span><b>{selectedQueries.length ? baValue(selectedQueries[0]?.brand_cart_add_share ?? selectedQueries[0]?.cart_share) : 'sem query do ASIN'}</b></div>
              <div><span>Purchase Share</span><b>{selectedQueries.length ? baValue(selectedQueries[0]?.brand_purchase_share ?? selectedQueries[0]?.purchase_share) : 'sem query do ASIN'}</b></div>
            </div>
            <div className="decision-card">
              <h4>Preco</h4>
              <div><span>Preco atual</span><b>{selected?.current_price ? money(selected.current_price) : 'sem fonte'}</b></div>
              <div><span>Preco medio vendido</span><b>{selectedAvgPrice ? money(selectedAvgPrice) : '-'}</b></div>
              <div><span>Historico de preco</span><b>pendente</b></div>
              <div><span>Promocao/cupom</span><b>pendente</b></div>
              <div><span>Preco mediano SCP</span><b>{selectedSCPHasPurchase ? money(selectedBA.ba_purchase_median_price) : '-'}</b></div>
            </div>
          </div>

          <div className="funnel">
            <div className="funnel-title">
              <div>
                <h4>Funil do produto no Search Catalog Performance</h4>
                <p>Leitura do ASIN selecionado. Aqui entram volume e conversao do produto; share competitivo fica no relatorio por query.</p>
              </div>
              <i className={selectedSCPCoverage ? 'good' : 'warn'}>{selectedSCPCoverage ? 'SCP com sinal' : 'SCP sem sinal'}</i>
            </div>
            <div className="funnel-metrics">
              <div><span>Impressoes</span><b>{fmt(selectedBA.ba_impressions)}</b><small>ASIN apareceu na busca</small></div>
              <div><span>Cliques</span><b>{fmt(selectedBA.ba_clicks)}</b><small>Entradas no detalhe</small></div>
              <div><span>Carrinhos</span><b>{fmt(selectedBA.ba_cart_adds)}</b><small>Intencao de compra</small></div>
              <div><span>Compras</span><b>{fmt(selectedBA.ba_purchases)}</b><small>Compra atribuida ao SCP</small></div>
              <div><span>Vendas SCP</span><b>{money(selectedBA.ba_search_traffic_sales)}</b><small>Receita de busca</small></div>
              <div><span>CTR SCP</span><b>{baValue(selectedBA.ba_click_rate)}</b><small>Cliques / impressoes</small></div>
              <div><span>Conversao SCP</span><b>{baValue(selectedBA.ba_conversion_rate ?? selectedBA.ba_search_conversion)}</b><small>Compras / cliques</small></div>
              <div><span>Preco mediano compra</span><b>{selectedSCPHasPurchase ? money(selectedBA.ba_purchase_median_price) : '-'}</b><small>{selectedSCPHasPurchase ? 'Veio no report' : 'Sem compra no recorte'}</small></div>
            </div>
            <div className="data-note">
              <b>Por que alguns campos ficam vazios?</b>
              <span>Impression share, click share, cart share e purchase share nao sao metricas do SCP por ASIN. Elas dependem do relatorio abrangente por termo de busca, exibido na secao "Exibicao de marca Abrangente". Quando compras SCP = 0, vendas e preco mediano de compra tambem ficam zerados/vazios.</span>
            </div>
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

          <div className="ads-terms">
            <div className="panel-head tight">
              <h4>Termos de busca Ads deste ASIN</h4>
              <span>{fmt(selectedAdsTermsTotals.terms)} termos - {money(selectedAdsTermsTotals.spend)} gasto - ROAS {ratio(selectedAdsTermsTotals.roas)}</span>
            </div>
            <div className="ads-term-table">
              <div className="ads-term-row head">
                <span>Termo</span><span>Campanha / Grupo</span><span>Imp.</span><span>Cliques</span><span>Gasto</span><span>Ped.</span><span>Vendas</span><span>ROAS</span>
              </div>
              {selectedAdsTerms.map(term => (
                <div className="ads-term-row" key={`${term.customer_search_term}-${term.campaign_name}-${term.ad_group_name}`}>
                  <span><b>{term.customer_search_term}</b><small>{term.match_type || '-'} - {term.keyword_or_target || '-'}</small></span>
                  <span><b>{term.campaign_name || '-'}</b><small>{term.ad_group_name || '-'}</small></span>
                  <span>{fmt(term.impressions)}</span>
                  <span>{fmt(term.clicks)}<small>CTR {baValue(term.ctr)}</small></span>
                  <span>{money(term.spend)}<small>CPC {money(term.cpc)}</small></span>
                  <span>{fmt(term.ads_orders)}</span>
                  <span>{money(term.ads_sales)}</span>
                  <span className={Number(term.roas || 0) >= 3 ? 'pos' : 'neg'}>{ratio(term.roas)}</span>
                </div>
              ))}
              {!selectedAdsTerms.length && <div className="empty">Nenhum search term Ads resolvido para este ASIN no periodo.</div>}
            </div>
          </div>

          <div className="ads-terms">
            <div className="panel-head tight">
              <h4>Doutor de Query deste ASIN</h4>
              <span>{fmt(selectedQueryOpportunityTotals.rows)} linhas - {fmt(selectedQueryOpportunityTotals.with_ml)} com ML - {fmt(selectedQueryOpportunityTotals.with_competitor)} com concorrente</span>
            </div>
            <div className="section-note">
              Este quadro nao decide sozinho. Ele mostra, para este ASIN, quais queries tem sinal V3, historico Ads D-1, lacunas SCP/SQP e contexto competitivo oficial da Amazon.
            </div>
            <div className="ml-query-table modal-query-table">
              <div className="ml-query-row head">
                <span>Query</span><span>Campanha / grupo</span><span>Leitura</span><span>ML</span><span>Concorrencia</span><span>Historico</span>
              </div>
              {selectedQueryOpportunityItems.map((q, idx) => (
                <div className="ml-query-row" key={`${q.asin}-${q.campaign_id}-${q.query_key}-${idx}`}>
                  <span><b>{q.search_query}</b><small>{q.match_type || '-'} - {q.keyword_or_target || '-'}</small></span>
                  <span><b>{q.campaign_name || '-'}</b><small>{q.ad_group_name || '-'}</small></span>
                  <span>
                    <i className={doctorEvidenceClass(q.doctor_evidence_class)}>{doctorEvidenceLabel(q.doctor_evidence_class)}</i>
                    <small>{coverageLabel(q.coverage_label)} / SQP {sourceStatusLabel(q.sqp_status)}</small>
                  </span>
                  <span>
                    <i className={mlExplainClass(q.ml_explain_label)}>{mlExplainLabel(q.ml_explain_label)}</i>
                    <small>ROAS esp. {ratio(q.ml_max_expected_roas)} / hora {q.ml_best_hour ?? '-'} / Ads {money(q.ads_spend)}</small>
                  </span>
                  <span>{fmt(q.competitor_count)} ASINs<small>top compra {pct(q.top_competitor_purchase_share)}</small></span>
                  <span>{money(q.spend_7d_lag)}<small>7d D-1: {fmt(q.orders_7d_lag)} ped. / {money(q.sales_7d_lag)}</small></span>
                </div>
              ))}
              {!selectedQueryOpportunityItems.length && <div className="empty">Sem cruzamento ASIN x query para este produto.</div>}
            </div>
          </div>
        </aside>
        </div>
      )}

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
          <h3>Exibicao de marca Abrangente - share por query</h3>
          <span>{brandQueries.length} queries com concorrencia</span>
        </div>
        <div className="section-note">
          Aqui o grao muda: nao e mais produto/ASIN, e sim termo pesquisado. Por isso aparecem share de impressao, clique, carrinho e compra da marca contra o total da query.
        </div>
        <div className="brand-kpis">
          <div><span>Volume consultas</span><b>{fmt(brandTotals.search_query_volume)}</b></div>
          <div><span>Imp. marca</span><b>{fmt(brandTotals.impression_brand_count)}</b><small>{pct(brandTotals.impression_brand_share)}</small></div>
          <div><span>Cliques marca</span><b>{fmt(brandTotals.click_brand_count)}</b><small>{pct(brandTotals.click_brand_share)}</small></div>
          <div><span>Compras marca</span><b>{fmt(brandTotals.purchase_brand_count)}</b><small>{pct(brandTotals.purchase_brand_share)}</small></div>
        </div>
        <div className="brand-query-table">
          <div className="brand-row head">
            <span>Query</span><span>Vol.</span><span>Imp. total / marca</span><span>Cliques total / marca</span><span>Carrinho total / marca</span><span>Compras total / marca</span><span>Share compra</span><span>Precos</span>
          </div>
          {brandQueries.map(q => (
            <div className="brand-row" key={q.search_query}>
              <span><b>{q.search_query}</b><small>score {fmt(q.query_score)}</small></span>
              <span>{fmt(q.search_query_volume)}</span>
              <span>{fmt(q.impression_total_count)} / {fmt(q.impression_brand_count)}<small>{pct(q.impression_brand_share)}</small></span>
              <span>{fmt(q.click_total_count)} / {fmt(q.click_brand_count)}<small>{pct(q.click_brand_share)} - CTR {pct(q.click_rate)}</small></span>
              <span>{fmt(q.cart_add_total_count)} / {fmt(q.cart_add_brand_count)}<small>{pct(q.cart_add_brand_share)} - taxa {pct(q.cart_add_rate)}</small></span>
              <span>{fmt(q.purchase_total_count)} / {fmt(q.purchase_brand_count)}<small>{pct(q.purchase_rate)}</small></span>
              <span className={Number(q.brand_purchase_share_lift || 0) >= 0 ? 'pos' : 'neg'}>{pct(q.purchase_brand_share)}<small>lift {pct(q.brand_purchase_share_lift)}</small></span>
              <span><small>click {money(q.click_brand_avg_price ?? q.click_median_price)}</small><small>compra {money(q.purchase_brand_median_price ?? q.purchase_median_price)}</small></span>
            </div>
          ))}
          {!brandQueries.length && <div className="empty">Sem relatorio abrangente no periodo.</div>}
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
        .si-grid.single{grid-template-columns:1fr}
        .si-grid.bottom{grid-template-columns:1fr 1fr}
        .compact-panel{padding:14px 16px}
        .segment-row{display:flex;gap:10px;flex-wrap:wrap}
        .segment-row button{border:1px solid var(--line);background:#101826;color:var(--text);border-radius:999px;padding:9px 12px;font-weight:900;cursor:pointer}
        .segment-row button.active{border-color:#4b8fff;background:rgba(75,143,255,.18);color:#dceaff}
        .segment-row b{margin-left:8px;color:#9fcbff}
        .portfolio-strip{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px;color:#cfe3ff}
        .portfolio-strip span{border:1px solid rgba(159,203,255,.22);border-radius:999px;padding:6px 10px;font-size:12px}
        .portfolio-strip b{color:#e8f0ff}
        .market-query-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
        .brand-kpis{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-bottom:14px}
        .brand-kpis>div{border:1px solid var(--line);border-radius:8px;padding:12px;background:rgba(0,0,0,.12)}
        .brand-kpis span{display:block;color:var(--muted);font-size:11px;font-weight:900;text-transform:uppercase;letter-spacing:.04em}
        .brand-kpis b{display:block;font-size:20px;margin-top:5px}
        .brand-query-table{display:grid;gap:1px;overflow:auto}
        .brand-row{display:grid;grid-template-columns:minmax(240px,1.3fr) .35fr .75fr .85fr .85fr .85fr .65fr .75fr;gap:10px;align-items:center;border-bottom:1px solid rgba(255,255,255,.07);padding:11px 8px;font-size:13px}
        .brand-row.head{color:#a8c7ee;font-size:11px;text-transform:uppercase;letter-spacing:.08em;font-weight:900}
        .brand-row small{display:block;color:var(--muted);font-size:11px;margin-top:3px}
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
        .modal-backdrop{position:fixed;inset:0;z-index:50;background:rgba(2,6,15,.88);display:flex;align-items:flex-start;justify-content:center;padding:24px;overflow:auto}
        .modal-card{width:min(1240px,calc(100vw - 48px));max-height:calc(100vh - 48px);overflow:auto;background:#121927;box-shadow:0 24px 90px rgba(0,0,0,.62);border-color:#314056}
        .close-btn{border:1px solid var(--line);border-radius:8px;background:#182235;color:#e8f0ff;font-weight:900;padding:9px 12px;cursor:pointer}
        .mini-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:16px}
        .mini-grid>div{border:1px solid var(--line);border-radius:8px;padding:12px;background:rgba(0,0,0,.12)}
        .mini-grid b{font-size:20px}
        .diagnosis-card{border:1px solid rgba(255,189,102,.36);border-radius:8px;background:rgba(255,189,102,.10);padding:13px;margin:4px 0 14px;color:#ffd99c}
        .diagnosis-card b{display:block;color:#ffbd66;font-size:16px;margin-bottom:4px}.diagnosis-card span{font-size:13px;line-height:1.35}
        .decision-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin:14px 0}
        .decision-card{border:1px solid rgba(255,255,255,.08);border-radius:8px;background:rgba(0,0,0,.14);padding:12px}
        .decision-card h4{margin:0 0 10px}.decision-card div{display:flex;justify-content:space-between;gap:10px;border-bottom:1px solid rgba(255,255,255,.055);padding:7px 0;font-size:12px}
        .decision-card span{color:var(--muted)}.decision-card b{text-align:right;color:#e8f0ff}
        .ebitda-card,.funnel,.daily,.ads-terms{border-top:1px solid var(--line);padding-top:14px;margin-top:14px}
        .ebitda-card h4,.funnel h4,.daily h4,.queries h4,.ads-terms h4{margin:0 0 10px}
        .panel-head.tight{margin-bottom:8px}
        .funnel-title{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:12px}
        .funnel-title h4{margin-bottom:4px}.funnel-title p{margin:0;color:var(--muted);font-size:12px;line-height:1.35}
        .funnel-metrics{display:grid;grid-template-columns:1fr 1fr;gap:10px}
        .funnel-metrics>div{border:1px solid rgba(255,255,255,.08);border-radius:8px;background:rgba(0,0,0,.12);padding:12px}
        .funnel-metrics span{display:block;color:var(--muted);font-size:11px;font-weight:900;text-transform:uppercase;letter-spacing:.04em}
        .funnel-metrics b{display:block;font-size:18px;margin-top:5px;color:#e8f0ff}
        .funnel-metrics small{display:block;color:var(--muted);font-size:11px;margin-top:4px}
        .data-note,.section-note{border:1px solid rgba(255,189,102,.35);border-radius:8px;background:rgba(255,189,102,.09);color:#ffd99c;padding:12px;margin:12px 0;font-size:13px;line-height:1.38}
        .data-note b{display:block;margin-bottom:4px;color:#ffbd66}.data-note span{display:block}
        .section-note{border-color:rgba(159,203,255,.28);background:rgba(75,143,255,.10);color:#cfe3ff;margin-bottom:14px}
        .source-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
        .source-card{border:1px solid var(--line);border-radius:8px;background:rgba(0,0,0,.12);padding:13px}
        .source-card span{display:block;color:var(--muted);font-size:11px;font-weight:900;text-transform:uppercase;letter-spacing:.04em}
        .source-card b{display:block;font-size:20px;margin:6px 0}.source-card small{display:block;color:var(--muted);font-size:12px;line-height:1.35}
        .source-card.ready{border-color:rgba(34,229,138,.35);background:rgba(34,229,138,.08)}
        .source-card.partial{border-color:rgba(255,189,102,.35);background:rgba(255,189,102,.08)}
        .source-card.missing{border-color:rgba(255,93,119,.38);background:rgba(255,93,119,.08)}
        .readiness-line{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px;color:#cfe3ff}
        .readiness-line span{border:1px solid rgba(159,203,255,.22);border-radius:999px;padding:6px 10px;font-size:12px}.readiness-line b{color:#e8f0ff}
        .coverage-table{display:grid;gap:1px;margin-top:14px;overflow:auto}
        .coverage-row{display:grid;grid-template-columns:minmax(260px,1.4fr) .7fr .5fr .75fr .65fr .85fr minmax(260px,1.2fr);gap:10px;align-items:center;border-bottom:1px solid rgba(255,255,255,.07);padding:10px 8px;font-size:13px}
        .coverage-row.head{color:#a8c7ee;font-size:11px;text-transform:uppercase;letter-spacing:.08em;font-weight:900}
        .coverage-row b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .coverage-row small{display:block;color:var(--muted);font-size:11px;margin-top:3px;line-height:1.25}
        .competitor-radar{border-color:rgba(255,93,119,.25);background:linear-gradient(180deg,rgba(255,93,119,.06),rgba(255,255,255,.03))}
        .competitor-kpis{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-bottom:14px}
        .competitor-kpis>div{border:1px solid rgba(255,255,255,.08);border-radius:8px;padding:12px;background:rgba(0,0,0,.16)}
        .competitor-kpis span{display:block;color:var(--muted);font-size:11px;font-weight:900;text-transform:uppercase;letter-spacing:.04em}
        .competitor-kpis b{display:block;font-size:24px;margin-top:6px}.competitor-kpis small{color:var(--muted)}
        .competitor-table{display:grid;gap:1px;overflow:auto}
        .competitor-row{display:grid;grid-template-columns:minmax(210px,.9fr) minmax(330px,1.35fr) .55fr .6fr minmax(240px,1fr);gap:12px;align-items:center;border-bottom:1px solid rgba(255,255,255,.07);padding:11px 8px;font-size:13px}
        .competitor-row.head{color:#a8c7ee;font-size:11px;text-transform:uppercase;letter-spacing:.08em;font-weight:900}
        .competitor-row b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.competitor-row small{display:block;color:var(--muted);font-size:11px;margin-top:3px;line-height:1.25}
        .ml-query-layer{border-color:rgba(34,229,138,.25);background:linear-gradient(180deg,rgba(34,229,138,.055),rgba(255,255,255,.03))}
        .ml-query-table{display:grid;gap:1px;overflow:auto}
        .ml-query-row{display:grid;grid-template-columns:minmax(220px,1.15fr) minmax(240px,1fr) minmax(210px,.85fr) .55fr .7fr .65fr;gap:12px;align-items:center;border-bottom:1px solid rgba(255,255,255,.07);padding:11px 8px;font-size:13px}
        .ml-query-row.head{color:#a8c7ee;font-size:11px;text-transform:uppercase;letter-spacing:.08em;font-weight:900}
        .ml-query-row b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .ml-query-row small{display:block;color:var(--muted);font-size:11px;margin-top:4px;line-height:1.25}
        .modal-query-table .ml-query-row{grid-template-columns:minmax(200px,1fr) minmax(230px,1fr) minmax(190px,.8fr) .55fr .55fr .65fr}
        .empty.mini{padding:12px;text-align:left;font-size:12px}
        .formula-line{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px solid rgba(255,255,255,.055);font-size:13px}
        .formula-line span{color:var(--muted)}
        .formula-line.total span,.formula-line.result span{color:var(--text);font-weight:800}
        .formula-line.result{margin-top:4px;border-top:1px solid rgba(255,255,255,.12);font-size:14px}
        .funnel-row,.daily-row,.simple-line{display:flex;align-items:center;justify-content:space-between;gap:12px;border-bottom:1px solid rgba(255,255,255,.06);padding:10px 0}
        .funnel-row b{color:#ffbd66;font-size:12px;text-transform:uppercase}
        .funnel-row:not(.muted) b{font-size:16px;color:#e8f0ff;text-transform:none}
        .funnel-row.muted span,.funnel-row.muted b{color:var(--muted)}
        .queries{margin-top:14px;border-top:1px solid rgba(255,255,255,.08);padding-top:12px}
        .query-line{display:grid;grid-template-columns:minmax(0,1.2fr) 70px minmax(0,1fr);gap:10px;align-items:center;padding:8px 0;border-bottom:1px solid rgba(255,255,255,.055)}
        .query-line span{font-weight:800}.query-line b{color:#9fcbff}.query-line small{color:var(--muted)}
        .daily-row{display:grid;grid-template-columns:90px 1fr 1.4fr}.daily-row small{color:var(--muted)}
        .ads-term-table{display:grid;gap:1px;overflow:auto}
        .ads-term-row{display:grid;grid-template-columns:minmax(220px,1.2fr) minmax(260px,1.4fr) .35fr .45fr .55fr .35fr .55fr .45fr;gap:10px;align-items:center;border-bottom:1px solid rgba(255,255,255,.07);padding:10px 4px;font-size:13px}
        .ads-term-row.head{color:#a8c7ee;font-size:11px;text-transform:uppercase;letter-spacing:.08em;font-weight:900}
        .ads-term-row small{display:block;color:var(--muted);font-size:11px;margin-top:3px}.ads-term-row b{display:block}
        .empty{color:var(--muted);padding:18px;text-align:center}
        @media(max-width:1100px){.si-kpis,.si-grid,.si-grid.bottom,.market-query-grid,.brand-kpis,.source-grid,.decision-grid,.competitor-kpis{grid-template-columns:1fr}.modal-backdrop{padding:12px}.modal-card{width:calc(100vw - 24px);max-height:calc(100vh - 24px)}.brand-row,.ads-term-row,.competitor-row,.ml-query-row,.coverage-row{grid-template-columns:minmax(220px,1fr) .45fr .8fr}.brand-row span:nth-child(n+4),.brand-row.head span:nth-child(n+4),.ads-term-row span:nth-child(n+4),.ads-term-row.head span:nth-child(n+4),.competitor-row span:nth-child(n+4),.competitor-row.head span:nth-child(n+4),.ml-query-row span:nth-child(n+4),.ml-query-row.head span:nth-child(n+4),.coverage-row span:nth-child(n+4),.coverage-row.head span:nth-child(n+4){display:none}.si-row{grid-template-columns:1.3fr .7fr .5fr}.si-row span:nth-child(4),.si-row span:nth-child(5),.si-row span:nth-child(7),.si-row.head span:nth-child(4),.si-row.head span:nth-child(5),.si-row.head span:nth-child(7){display:none}}
      `}</style>
    </div>
  )
}
