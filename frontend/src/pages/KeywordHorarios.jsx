import { useCallback, useEffect, useState } from 'react'
import { api } from '../api/client.js'

const BID_ROBOT_API_BASE = import.meta.env.VITE_BID_ROBOT_API_BASE || 'http://localhost:8080'

const actionMeta = {
  BID_UP: { label: 'Subir', color: '#26de81' },
  CUT_HOUR: { label: 'Cortar', color: '#ff5470' },
  BID_DOWN: { label: 'Reduzir', color: '#ff9f43' },
  KEEP_STRONG: { label: 'Manter', color: '#54a0ff' },
}

const confidenceColor = {
  HIGH: '#26de81',
  MEDIUM: '#ff9f43',
  LOW: '#8395a7',
}

function fmt(n, digits = 0) {
  if (n === null || n === undefined) return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

function money(n) {
  if (n === null || n === undefined) return '-'
  return `R$ ${fmt(n, 2)}`
}

export default function KeywordHorarios({ ctx }) {
  const { tenantID } = ctx
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [filter, setFilter] = useState({ action: '', confidence: 'HIGH', source: 'CAMPAIGN_HOUR_INHERITED' })

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    const res = await api.goldKeywordHourlyReal(tenantID, { ...filter, limit: 500 })
    if (res.ok) {
      setItems(res.data.items || [])
    } else {
      setItems([])
      setError(res.data?.error || `Falha ao carregar (${res.status})`)
    }
    setLoading(false)
  }, [tenantID, filter])

  useEffect(() => { load() }, [load])

  const [applyResult, setApplyResult] = useState({})
  const [selected, setSelected] = useState(() => new Set())
  const [progress, setProgress] = useState(null) // {done, total} enquanto aplica

  // So acao de lance da pra aplicar; KEEP_STRONG nao muda nada.
  const isApplicable = (item) => ['BID_UP', 'BID_DOWN', 'CUT_HOUR'].includes(item.campaign_action_type)
  const applicable = items.filter(isApplicable)
  const selectedItems = applicable.filter(i => selected.has(i.keyword_hour_recommendation_id))
  const allSelected = applicable.length > 0 && selectedItems.length === applicable.length

  // Recarregar troca a lista: descarta selecao de linha que sumiu.
  useEffect(() => {
    setSelected(prev => {
      const vivos = new Set(applicable.map(i => i.keyword_hour_recommendation_id))
      const next = new Set([...prev].filter(id => vivos.has(id)))
      return next.size === prev.size ? prev : next
    })
  }, [items]) // eslint-disable-line react-hooks/exhaustive-deps

  const toggleOne = (id) => setSelected(prev => {
    const next = new Set(prev)
    next.has(id) ? next.delete(id) : next.add(id)
    return next
  })
  const toggleAll = () => setSelected(allSelected ? new Set() : new Set(applicable.map(i => i.keyword_hour_recommendation_id)))

  const statusMsg = (st) => ({
    APPLIED: '✅ Aplicado',
    ALREADY_ALIGNED: '↔️ Ja estava nesse valor',
    KEYWORD_NOT_FOUND: '⚠️ Keyword nao existe no robo',
    KEYWORD_NOT_ENABLED: '⚠️ Keyword nao esta ativa',
    PUBLISH_FAILED: '⚠️ Falhou ao publicar a agenda',
  })[st] || `⚠️ ${st}`

  const applyOne = async (item) => {
    const res = await fetch(`${BID_ROBOT_API_BASE}/api/amazon/ads/bid-robot/schedules/apply-suggestion-entity`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        campaign_id: item.campaign_id, ad_group_id: item.ad_group_id,
        keyword_text: item.keyword_text, match_type: item.match_type,
        campaign_name: item.campaign_name,
        hour: Number(item.event_hour),
        suggested_multiplier: Number(item.suggested_hour_multiplier),
        recommendation_id: item.keyword_hour_recommendation_id,
        base_bid: item.base_bid, suggested_effective_bid: item.suggested_effective_bid,
        baseline_impressions: item.impressions, baseline_clicks: item.clicks,
        baseline_spend: item.spend, baseline_orders: item.orders,
        baseline_sales: item.sales, baseline_roas: item.roas,
      }),
    })
    const data = await res.json().catch(() => ({}))
    return data.status || `HTTP ${res.status}`
  }

  const applySelected = async () => {
    if (selectedItems.length === 0 || progress) return
    const ok = window.confirm(
      `Aplicar ${selectedItems.length} ajuste(s) de lance?\n\n` +
      selectedItems.slice(0, 8).map(i =>
        `• ${i.keyword_text} as ${i.event_hour}h -> ${fmt(i.suggested_hour_multiplier, 2)}x (${money(i.suggested_effective_bid)})`
      ).join('\n') +
      (selectedItems.length > 8 ? `\n• ...e mais ${selectedItems.length - 8}` : '') +
      `\n\nCada um cria um override no nivel da KEYWORD (sobrepoe grupo/campanha) e volta como aprendizado pro ML.`
    )
    if (!ok) return

    setProgress({ done: 0, total: selectedItems.length })
    const aplicados = new Set()
    // Sequencial de proposito: publicar em paralelo disputa o mesmo profile.
    for (let i = 0; i < selectedItems.length; i++) {
      const item = selectedItems[i]
      const key = item.keyword_hour_recommendation_id
      try {
        const st = await applyOne(item)
        setApplyResult(prev => ({ ...prev, [key]: statusMsg(st) }))
        if (st === 'APPLIED' || st === 'ALREADY_ALIGNED') aplicados.add(key)
      } catch (e) {
        setApplyResult(prev => ({ ...prev, [key]: '⚠️ ' + (e.message || 'falha') }))
      }
      setProgress({ done: i + 1, total: selectedItems.length })
    }
    // Mantem marcado so o que falhou, pra dar pra tentar de novo.
    setSelected(prev => new Set([...prev].filter(id => !aplicados.has(id))))
    setProgress(null)
  }

  const upCount = items.filter(x => x.campaign_action_type === 'BID_UP').length
  const downCount = items.filter(x => x.campaign_action_type === 'CUT_HOUR' || x.campaign_action_type === 'BID_DOWN').length
  const targetCount = items.filter(x => x.source_grain === 'TARGET_HOUR_OBSERVED').length
  const targetMlCount = items.filter(x => x.target_ml_click_probability !== null && x.target_ml_click_probability !== undefined).length

  return (
    <div className="page keyword-hour-page">
      <div className="page-head">
        <div>
          <h2>Keywords x hora</h2>
          <span className="sub">Base bid do Robo x multiplicador horario real</span>
        </div>
        <button className="btn" onClick={load}>Atualizar</button>
      </div>

      <div className="kpi-row">
        <div className="kpi"><div className="kpi-v">{fmt(items.length)}</div><div className="kpi-l">Recomendacoes</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#26de81' }}>{fmt(upCount)}</div><div className="kpi-l">Subir lance efetivo</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#ff5470' }}>{fmt(downCount)}</div><div className="kpi-l">Reduzir exposicao</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#54a0ff' }}>{fmt(targetMlCount || targetCount)}</div><div className="kpi-l">Com ML target</div></div>
      </div>

      <div className="filters">
        <select value={filter.action} onChange={e => setFilter(f => ({ ...f, action: e.target.value }))}>
          <option value="">Todas as acoes</option>
          <option value="BID_UP">Subir</option>
          <option value="CUT_HOUR">Cortar hora</option>
          <option value="BID_DOWN">Reduzir</option>
        </select>
        <select value={filter.confidence} onChange={e => setFilter(f => ({ ...f, confidence: e.target.value }))}>
          <option value="">Toda confianca</option>
          <option value="HIGH">Alta</option>
          <option value="MEDIUM">Media</option>
          <option value="LOW">Baixa</option>
        </select>
        <select value={filter.source} onChange={e => setFilter(f => ({ ...f, source: e.target.value }))}>
          <option value="">Todas as fontes</option>
          <option value="CAMPAIGN_HOUR_INHERITED">Campanha herdada</option>
          <option value="TARGET_HOUR_OBSERVED">Keyword observada</option>
        </select>
        <span className="count-badge">{items.length} itens</span>
      </div>

      <div className="apply-bar">
        <span className="apply-count">
          {progress
            ? `Aplicando ${progress.done} de ${progress.total}...`
            : selectedItems.length > 0
              ? `${selectedItems.length} selecionado(s) de ${applicable.length} aplicavel(is)`
              : `Marque as linhas na coluna a direita (${applicable.length} aplicavel(is))`}
        </span>
        <button
          className="btn primary"
          disabled={selectedItems.length === 0 || !!progress}
          onClick={applySelected}
        >
          {progress ? `Aplicando ${progress.done}/${progress.total}` : `Aplicar${selectedItems.length ? ` (${selectedItems.length})` : ''}`}
        </button>
      </div>

      {error ? (
        <div className="empty">{error}</div>
      ) : loading ? (
        <div className="empty">Carregando...</div>
      ) : items.length === 0 ? (
        <div className="empty">Nenhuma recomendacao com os filtros atuais.</div>
      ) : (
        <div className="queue">
          <table>
            <thead>
              <tr>
                <th>Keyword</th>
                <th>Campanha</th>
                <th>Hora</th>
                <th>Acao</th>
                <th>Base</th>
                <th>Atual</th>
                <th>Sugerido</th>
                <th>Delta</th>
                <th>ROAS</th>
                <th>ML</th>
                <th>Fonte</th>
                <th>Prio</th>
                <th className="sel-col" title="Marcar todos os aplicaveis">
                  <label className="sel-all">
                    <input
                      type="checkbox"
                      checked={allSelected}
                      ref={el => { if (el) el.indeterminate = selectedItems.length > 0 && !allSelected }}
                      disabled={applicable.length === 0 || !!progress}
                      onChange={toggleAll}
                    />
                    <span>Todos</span>
                  </label>
                </th>
              </tr>
            </thead>
            <tbody>
              {items.map(item => {
                const meta = actionMeta[item.campaign_action_type] || { label: item.campaign_action_type, color: '#8395a7' }
                return (
                  <tr key={item.keyword_hour_recommendation_id}>
                    <td className="camp">
                      {item.keyword_text}
                      <div className="sub2">{item.match_type || '-'} - {item.ad_group_name || item.ad_group_id || '-'}</div>
                    </td>
                    <td className="camp">{item.campaign_name}</td>
                    <td className="num">{String(item.event_hour).padStart(2, '0')}h</td>
                    <td>
                      <span className="action-tag" style={{ color: meta.color, borderColor: meta.color }}>{meta.label}</span>
                      <div className="sub2">{item.advisor_action}</div>
                      {applyResult[item.keyword_hour_recommendation_id] && (
                        <div className="sub2 apply-msg">{applyResult[item.keyword_hour_recommendation_id]}</div>
                      )}
                    </td>
                    <td className="num">{money(item.base_bid)}</td>
                    <td className="num">
                      {money(item.current_effective_bid)}
                      <div className="sub2">{fmt(item.current_hour_multiplier, 2)}x</div>
                    </td>
                    <td className="num">
                      <b>{money(item.suggested_effective_bid)}</b>
                      <div className="sub2">{fmt(item.suggested_hour_multiplier, 2)}x</div>
                    </td>
                    <td className="num" style={{ color: Number(item.effective_bid_delta) >= 0 ? '#26de81' : '#ff5470' }}>
                      {money(item.effective_bid_delta)}
                      <div className="sub2">{fmt(item.effective_bid_delta_percent, 1)}%</div>
                    </td>
                    <td className="num">
                      {fmt(item.roas, 1)}
                      <div className="sub2">{fmt(item.orders)} ped. - {money(item.spend)}</div>
                    </td>
                    <td>
                      <div className="ml-line">
                        <span className="muted">Camp.</span>{' '}
                        {item.ml_agrees === true ? <span className="agree">concorda</span> : item.ml_agrees === false ? <span className="conflict">diverge</span> : <span className="muted">-</span>}
                      </div>
                      {item.ml_expected_roas !== null && item.ml_expected_roas !== undefined && <div className="sub2">ROAS {fmt(item.ml_expected_roas, 1)}</div>}
                      {item.target_ml_click_probability !== null && item.target_ml_click_probability !== undefined && (
                        <div className="target-ml">
                          <span className={item.target_ml_good_hour ? 'agree' : 'muted'}>Target</span>{' '}
                          <span>P(click) {fmt(Number(item.target_ml_click_probability) * 100, 0)}%</span>
                        </div>
                      )}
                    </td>
                    <td>
                      <span className="conf" style={{ background: `${confidenceColor[item.confidence] || '#8395a7'}22`, color: confidenceColor[item.confidence] || '#8395a7' }}>{item.confidence}</span>
                      <div className="sub2">{item.source_grain}</div>
                    </td>
                    <td className="num">{fmt(item.priority_score, 0)}</td>
                    <td className="sel-col">
                      {isApplicable(item) ? (
                        <input
                          type="checkbox"
                          checked={selected.has(item.keyword_hour_recommendation_id)}
                          disabled={!!progress}
                          onChange={() => toggleOne(item.keyword_hour_recommendation_id)}
                        />
                      ) : (
                        <span className="muted" title="Manter: nao ha ajuste a aplicar">-</span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      <style>{`
        .keyword-hour-page .page-head{
          display:flex;
          justify-content:space-between;
          align-items:flex-end;
          gap:16px;
          margin-bottom:14px;
        }
        .keyword-hour-page .page-head h2{
          margin:0;
          font-size:24px;
          line-height:1.15;
          letter-spacing:0;
        }
        .keyword-hour-page .sub{
          display:block;
          margin-top:4px;
          color:var(--muted,#9aa7bd);
          font-size:13px;
        }
        .keyword-hour-page .btn{
          min-width:96px;
          height:38px;
          padding:0 14px;
        }
        .keyword-hour-page .kpi-row{
          display:grid;
          grid-template-columns:repeat(4,minmax(0,1fr));
          gap:12px;
          margin:0 0 14px;
        }
        .keyword-hour-page .kpi{
          background:rgba(255,255,255,.035);
          border:1px solid rgba(148,163,184,.18);
          border-radius:8px;
          padding:12px 14px;
          min-height:78px;
        }
        .keyword-hour-page .kpi-v{
          font-size:24px;
          line-height:1;
          font-weight:850;
          font-variant-numeric:tabular-nums;
        }
        .keyword-hour-page .kpi-l{
          margin-top:7px;
          color:var(--muted,#9aa7bd);
          font-size:12px;
          line-height:1.25;
        }
        .keyword-hour-page .filters{
          display:grid;
          grid-template-columns:minmax(160px,1fr) minmax(150px,190px) minmax(190px,240px) auto;
          gap:10px;
          align-items:center;
          margin-bottom:12px;
        }
        .keyword-hour-page .filters select{
          width:100%;
          height:38px;
          background:rgba(10,16,31,.72);
          border:1px solid rgba(148,163,184,.20);
          border-radius:8px;
          color:inherit;
          padding:0 12px;
          font-size:13px;
          font-weight:650;
        }
        .keyword-hour-page .count-badge{
          justify-self:end;
          color:var(--muted,#9aa7bd);
          font-size:13px;
          white-space:nowrap;
        }
        .keyword-hour-page .queue{
          background:rgba(255,255,255,.025);
          border:1px solid rgba(148,163,184,.16);
          border-radius:8px;
          overflow:auto;
          max-height:calc(100vh - 285px);
        }
        .keyword-hour-page table{
          width:100%;
          min-width:1180px;
          border-collapse:collapse;
          table-layout:fixed;
          font-size:12px;
        }
        .keyword-hour-page th{
          position:sticky;
          top:0;
          z-index:1;
          background:#101626;
          color:#9fb8dc;
          text-align:left;
          padding:10px 12px;
          border-bottom:1px solid rgba(148,163,184,.18);
          font-size:11px;
          letter-spacing:.08em;
          text-transform:uppercase;
          white-space:nowrap;
        }
        .keyword-hour-page td{
          padding:10px 12px;
          border-bottom:1px solid rgba(148,163,184,.10);
          vertical-align:middle;
          line-height:1.25;
        }
        .keyword-hour-page th:nth-child(1){width:220px}
        .keyword-hour-page th:nth-child(2){width:140px}
        .keyword-hour-page th:nth-child(3){width:62px}
        .keyword-hour-page th:nth-child(4){width:118px}
        .keyword-hour-page th:nth-child(5),
        .keyword-hour-page th:nth-child(6),
        .keyword-hour-page th:nth-child(7),
        .keyword-hour-page th:nth-child(8){width:92px}
        .keyword-hour-page th:nth-child(9){width:84px}
        .keyword-hour-page th:nth-child(10){width:96px}
        .keyword-hour-page th:nth-child(11){width:150px}
        .keyword-hour-page th:nth-child(12){width:70px}
        .keyword-hour-page th:nth-child(13){width:74px}
        .keyword-hour-page .apply-bar{
          display:flex;
          justify-content:flex-end;
          align-items:center;
          gap:14px;
          margin-bottom:10px;
        }
        .keyword-hour-page .apply-count{
          color:var(--muted,#9aa7bd);
          font-size:12.5px;
        }
        .keyword-hour-page .btn.primary{
          background:#1d6ff2;
          border-color:#1d6ff2;
          color:#fff;
          font-weight:800;
        }
        .keyword-hour-page .btn.primary:disabled{
          background:rgba(148,163,184,.16);
          border-color:rgba(148,163,184,.20);
          color:var(--muted,#8796ad);
          cursor:not-allowed;
        }
        .keyword-hour-page .sel-col{
          text-align:center;
        }
        .keyword-hour-page .sel-col input{
          width:16px;
          height:16px;
          accent-color:#1d6ff2;
          cursor:pointer;
        }
        .keyword-hour-page .sel-col input:disabled{cursor:not-allowed}
        .keyword-hour-page .sel-all{
          display:inline-flex;
          align-items:center;
          gap:6px;
          cursor:pointer;
        }
        .keyword-hour-page .apply-msg{
          margin-top:5px;
          font-size:11px;
          font-weight:650;
          white-space:normal;
        }
        .keyword-hour-page .camp{
          font-weight:700;
          overflow:hidden;
          text-overflow:ellipsis;
          white-space:nowrap;
        }
        .keyword-hour-page .sub2{
          margin-top:3px;
          color:var(--muted,#8796ad);
          font-size:10.5px;
          font-weight:500;
          overflow:hidden;
          text-overflow:ellipsis;
          white-space:nowrap;
        }
        .keyword-hour-page .num{
          text-align:right;
          font-variant-numeric:tabular-nums;
          white-space:nowrap;
        }
        .keyword-hour-page .action-tag{
          display:inline-flex;
          align-items:center;
          height:22px;
          border:1px solid;
          border-radius:6px;
          padding:0 8px;
          font-size:11px;
          font-weight:800;
          white-space:nowrap;
        }
        .keyword-hour-page .conf{
          display:inline-flex;
          align-items:center;
          height:21px;
          padding:0 8px;
          border-radius:999px;
          font-size:10px;
          font-weight:850;
          letter-spacing:.03em;
        }
        .keyword-hour-page .agree{color:#26de81;font-size:12px;font-weight:750}
        .keyword-hour-page .conflict{color:#ff5470;font-size:12px;font-weight:750}
        .keyword-hour-page .muted{color:var(--muted,#8796ad)}
        .keyword-hour-page .ml-line{white-space:nowrap}
        .keyword-hour-page .target-ml{
          margin-top:3px;
          color:#9fb8dc;
          font-size:11px;
          line-height:1.2;
          white-space:nowrap;
        }
        .keyword-hour-page .empty{
          min-height:220px;
          display:grid;
          place-items:center;
          color:var(--muted,#8796ad);
          font-size:13px;
        }
        @media (max-width: 980px){
          .keyword-hour-page .page-head{align-items:flex-start;flex-direction:column}
          .keyword-hour-page .kpi-row{grid-template-columns:repeat(2,minmax(0,1fr))}
          .keyword-hour-page .filters{grid-template-columns:1fr}
          .keyword-hour-page .count-badge{justify-self:start}
          .keyword-hour-page .queue{max-height:none}
        }
      `}</style>
    </div>
  )
}
