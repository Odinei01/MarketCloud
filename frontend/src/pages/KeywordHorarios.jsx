import { useCallback, useEffect, useState } from 'react'
import { api } from '../api/client.js'

const confidenceColor = {
  HIGH: '#26de81',
  MEDIUM: '#ff9f43',
  LOW: '#8395a7',
}

const actionMeta = {
  BID_UP: { label: 'Subir', color: '#26de81' },
  CUT_HOUR: { label: 'Cortar', color: '#ff5470' },
  BID_DOWN: { label: 'Reduzir', color: '#ff9f43' },
  KEEP_STRONG: { label: 'Manter', color: '#54a0ff' },
}

function fmt(n, digits = 0) {
  if (n === null || n === undefined) return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: digits, maximumFractionDigits: digits })
}

function money(n) {
  if (n === null || n === undefined) return '-'
  return `R$ ${fmt(n, 2)}`
}

function pct(n, digits = 0) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '-'
  return `${fmt(Number(n) * 100, digits)}%`
}

function num(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return null
  return Number(n)
}

function parseMaybeJson(value) {
  if (!value) return {}
  if (typeof value === 'object') return value
  try {
    return JSON.parse(value)
  } catch {
    return {}
  }
}

export default function KeywordHorarios({ ctx }) {
  const { tenantID } = ctx
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  // confidence '' (todas) por padrao: no grao keyword x hora quase nada chega a
  // HIGH (dado esparso), entao 'HIGH' escondia praticamente toda recomendacao
  // real (BID_DOWN/BID_UP MEDIUM/LOW). O usuario filtra pra cima se quiser.
  const [filter, setFilter] = useState({ action: '', confidence: '', source: 'CAMPAIGN_HOUR_INHERITED' })

  // O finally e o que importa aqui: sem ele, qualquer excecao deixava a tela em
  // "Carregando..." pra sempre, sem dizer o motivo; foi assim que uma query
  // lenta (4min) virou "a tela travou" em 15/07.
  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const res = await api.goldKeywordHourlyReal(tenantID, { ...filter, limit: 500 })
      if (res.ok) {
        setItems(res.data.items || [])
      } else {
        setItems([])
        setError(res.data?.error || `Falha ao carregar (${res.status})`)
      }
    } catch (e) {
      setItems([])
      setError(e?.message || 'Falha de rede ao carregar')
    } finally {
      setLoading(false)
    }
  }, [tenantID, filter])

  useEffect(() => { load() }, [load])

  const [applyResult, setApplyResult] = useState({})
  const [selected, setSelected] = useState(() => new Set())
  const [progress, setProgress] = useState(null) // {done, total} enquanto aplica
  const [detailItem, setDetailItem] = useState(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [detailError, setDetailError] = useState('')

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

  // Passa pelo MarketCloud (nao chama o Robo direto): o endpoint chama o Robo E
  // grava a decisao em recommendation_decisions, fechando o loop no MarketCloud
  // e nao so no SWARM (achado P1 da auditoria 17/07).
  const applyOne = async (item) => {
    const res = await api.goldKeywordApply(tenantID, {
      recommendation_id: item.keyword_hour_recommendation_id,
    })
    if (!res.ok) return res.data?.error || `HTTP ${res.status}`
    return res.data?.status || `HTTP ${res.status}`
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

    // O snapshot SWARM->bronze so atualiza de hora em hora: sem forcar aqui, a
    // tela seguiria mostrando o que voce acabou de aplicar, como se nada tivesse
    // acontecido. Recarrega depois, ja com o efeito do clique visivel.
    if (aplicados.size > 0) {
      setProgress({ done: selectedItems.length, total: selectedItems.length, syncing: true })
      try { await api.refreshSwarmState(tenantID) } catch { /* recarrega mesmo assim */ }
      await load()
    }
    setProgress(null)
  }

  const openDetail = async (item) => {
    setDetailItem(item)
    setDetailError('')
    if (item.explanation_json) return
    setDetailLoading(true)
    try {
      const res = await api.goldKeywordHourlyExplain(tenantID, item.keyword_hour_recommendation_id)
      if (res.ok) {
        setDetailItem(current => current?.keyword_hour_recommendation_id === item.keyword_hour_recommendation_id
          ? { ...current, explanation_json: res.data.explanation_json }
          : current)
      } else {
        setDetailError(res.data?.error || `Falha ao carregar detalhe (${res.status})`)
      }
    } catch (e) {
      setDetailError(e?.message || 'Falha de rede ao carregar detalhe')
    } finally {
      setDetailLoading(false)
    }
  }

  const upCount = items.filter(x => x.campaign_action_type === 'BID_UP').length
  const downCount = items.filter(x => x.campaign_action_type === 'CUT_HOUR' || x.campaign_action_type === 'BID_DOWN').length
  const targetCount = items.filter(x => x.source_grain === 'TARGET_HOUR_OBSERVED').length
  const targetMlCount = items.filter(x => x.target_ml_click_probability !== null && x.target_ml_click_probability !== undefined).length
  const detail = detailItem ? (() => {
    const explanation = parseMaybeJson(detailItem.explanation_json)
    const currentMult = num(detailItem.current_hour_multiplier)
    const suggestedMult = num(detailItem.suggested_hour_multiplier)
    const multRatio = currentMult && suggestedMult ? suggestedMult / currentMult : null
    const spend = num(detailItem.spend) || 0
    const sales = num(detailItem.sales) || 0
    const campaignRoasTarget = num(detailItem.ml_target_roas) ?? num(detailItem.ml_expected_roas)
    const targetRoas = num(detailItem.target_ml_expected_roas)
    const anchorRoas = num(detailItem.ml_roas_ancora)
    const targetDisagrees = targetRoas !== null && campaignRoasTarget !== null && targetRoas < campaignRoasTarget * 0.75
    const projectedSpend = multRatio ? spend * multRatio : null
    const projectedSalesCampaign = projectedSpend !== null && campaignRoasTarget !== null ? projectedSpend * campaignRoasTarget : null
    const projectedSalesTarget = projectedSpend !== null && targetRoas !== null ? projectedSpend * targetRoas : null
    const projectedSales = projectedSalesTarget !== null && targetDisagrees ? projectedSalesTarget : projectedSalesCampaign
    const salesRange = projectedSalesCampaign !== null && projectedSalesTarget !== null
      ? [Math.min(projectedSalesCampaign, projectedSalesTarget), Math.max(projectedSalesCampaign, projectedSalesTarget)]
      : null
    return {
      multRatio,
      campaignRoasTarget,
      targetRoas,
      anchorRoas,
      targetDisagrees,
      projectedSpend,
      projectedSales,
      projectedSalesCampaign,
      projectedSalesTarget,
      salesRange,
      deltaSpend: projectedSpend !== null ? projectedSpend - spend : null,
      deltaSales: projectedSales !== null ? projectedSales - sales : null,
      deltaRoasVsCurrent: campaignRoasTarget !== null && num(detailItem.roas) !== null ? campaignRoasTarget - Number(detailItem.roas) : null,
      explanation,
      commercial: explanation.commercial || {},
      calendar: explanation.calendar || {},
      experiment: explanation.experiment || {},
      coverage: explanation.coverage || {},
    }
  })() : null

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
        <button
          className="btn primary"
          disabled={selectedItems.length === 0 || !!progress}
          onClick={applySelected}
        >
          {progress ? `Aplicando ${progress.done}/${progress.total}` : `Aplicar${selectedItems.length ? ` (${selectedItems.length})` : ''}`}
        </button>
        <span className="apply-count">
          {progress?.syncing
            ? 'Aplicado. Atualizando a lista com o resultado...'
            : progress
            ? `Aplicando ${progress.done} de ${progress.total}...`
            : selectedItems.length > 0
              ? `${selectedItems.length} selecionado(s) de ${applicable.length} aplicavel(is)`
              : `Marque as linhas na coluna a direita (${applicable.length} aplicavel(is))`}
        </span>
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
                <th>ROAS</th>
                <th>ML</th>
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
                      <div className="kw-meta">
                        <span
                          className="conf"
                          title={`Confianca ${item.confidence}`}
                          style={{ background: `${confidenceColor[item.confidence] || '#8395a7'}22`, color: confidenceColor[item.confidence] || '#8395a7' }}
                        >{item.confidence}</span>
                        <span className="sub2">{item.match_type || '-'} - {item.ad_group_name || item.ad_group_id || '-'}</span>
                      </div>
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
                      {item.target_ml_expected_roas !== null && item.target_ml_expected_roas !== undefined && item.ml_target_roas !== null && Number(item.target_ml_expected_roas) < Number(item.ml_target_roas) * 0.75 && (
                        <div className="target-warning">Target alerta ROAS {fmt(item.target_ml_expected_roas, 1)}</div>
                      )}
                      <button className="detail-btn" type="button" onClick={() => openDetail(item)}>Detalhes</button>
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

      {detailItem && (
        <div className="modal-backdrop" onMouseDown={() => setDetailItem(null)}>
          <div className="ml-detail-modal" role="dialog" aria-modal="true" onMouseDown={e => e.stopPropagation()}>
            <div className="modal-head">
              <div>
                <h3>{detailItem.keyword_text} - {String(detailItem.event_hour).padStart(2, '0')}h</h3>
                <p>{detailItem.campaign_name} / {detailItem.ad_group_name || detailItem.ad_group_id || 'grupo nao identificado'}</p>
              </div>
              <button className="close-btn" type="button" onClick={() => setDetailItem(null)}>Fechar</button>
            </div>

            <div className="modal-callout">
              <strong>{detail?.targetDisagrees ? 'Leitura com conflito' : 'Leitura do modelo'}</strong>
              <span>
                {detail?.targetDisagrees
                  ? `A campanha/hora sustenta o alvo ${fmt(detailItem.suggested_hour_multiplier, 2)}x, mas o modelo da keyword/target esta abaixo da campanha. Trate como teste controlado, nao como ganho garantido.`
                  : `O alvo sugerido e ${fmt(detailItem.suggested_hour_multiplier, 2)}x. A leitura atual combina o ROAS real da hora, o ROAS previsto pelo ML e a ancora da propria campanha. A projecao abaixo e uma estimativa, nao uma promessa.`}
              </span>
            </div>

            {(detailLoading || detailError) && (
              <div className={`modal-note ${detailError ? 'warning-note' : ''}`}>
                {detailError || 'Carregando contexto detalhado...'}
              </div>
            )}

            <div className="detail-grid">
              <div className="detail-card">
                <span>Bid efetivo</span>
                <strong>{money(detailItem.current_effective_bid)} para {money(detailItem.suggested_effective_bid)}</strong>
                <small>{fmt(detailItem.current_hour_multiplier, 2)}x para {fmt(detailItem.suggested_hour_multiplier, 2)}x / {fmt(detailItem.effective_bid_delta_percent, 0)}%</small>
              </div>
              <div className="detail-card">
                <span>ROAS alvo campanha</span>
                <strong>{fmt(detail?.campaignRoasTarget, 1)}</strong>
                <small>Atual {fmt(detailItem.roas, 1)} / ancora campanha {fmt(detailItem.ml_roas_ancora, 1)}</small>
              </div>
              <div className="detail-card">
                <span>Gasto estimado</span>
                <strong>{money(detail?.projectedSpend)}</strong>
                <small>Delta {money(detail?.deltaSpend)} se trafego responder ao multiplicador</small>
              </div>
              <div className="detail-card">
                <span>{detail?.salesRange ? 'Venda estimada faixa' : 'Venda estimada'}</span>
                <strong>{detail?.salesRange ? `${money(detail.salesRange[0])} a ${money(detail.salesRange[1])}` : money(detail?.projectedSales)}</strong>
                <small>{detail?.targetDisagrees ? 'piso target / teto campanha' : `Delta ${money(detail?.deltaSales)} usando ROAS alvo`}</small>
              </div>
            </div>

            <div className="detail-columns">
              <section>
                <h4>O que sustenta a recomendacao</h4>
                <dl>
                  <div><dt>ROAS observado na hora</dt><dd>{fmt(detailItem.ml_roas_observado ?? detailItem.roas, 2)}</dd></div>
                  <div><dt>Gasto observado pelo modelo</dt><dd>{money(detailItem.ml_gasto_observado ?? detailItem.spend)}</dd></div>
                  <div><dt>Dias observados</dt><dd>{fmt(detailItem.days_observed)}</dd></div>
                  <div><dt>Impressoes / cliques / pedidos</dt><dd>{fmt(detailItem.impressions)} / {fmt(detailItem.clicks)} / {fmt(detailItem.orders)}</dd></div>
                  <div><dt>Fonte do sinal</dt><dd>{detailItem.source_grain || '-'}</dd></div>
                  <div><dt>Escopo atual da agenda</dt><dd>{detailItem.current_multiplier_scope || '-'}</dd></div>
                </dl>
              </section>

              <section>
                <h4>Predicao ML</h4>
                <dl>
                  <div><dt>Campanha concorda?</dt><dd>{detailItem.ml_agrees === true ? 'Sim' : detailItem.ml_agrees === false ? 'Nao' : '-'}</dd></div>
                  <div><dt>P(conversao) campanha</dt><dd>{pct(detailItem.ml_conversion_probability)}</dd></div>
                  <div><dt>ROAS previsto campanha</dt><dd>{fmt(detailItem.ml_expected_roas, 2)}</dd></div>
                  <div><dt>P(click) keyword/target</dt><dd>{pct(detailItem.target_ml_click_probability)}</dd></div>
                  <div><dt>P(conversao) keyword/target</dt><dd>{pct(detailItem.target_ml_conversion_probability)}</dd></div>
                  <div><dt>ROAS previsto keyword/target</dt><dd className={detail?.targetDisagrees ? 'warn-value' : ''}>{fmt(detailItem.target_ml_expected_roas, 2)}</dd></div>
                </dl>
              </section>

              <section>
                <h4>Contexto comercial</h4>
                <dl>
                  <div><dt>Preco / custo</dt><dd>{money(detail?.commercial.sale_price_brl)} / {money(detail?.commercial.unit_cost_brl)}</dd></div>
                  <div><dt>Margem bruta</dt><dd>{detail?.commercial.gross_margin_pct != null ? `${fmt(detail.commercial.gross_margin_pct * 100, 1)}%` : '-'}</dd></div>
                  <div><dt>Estoque / cobertura</dt><dd>{fmt(detail?.commercial.stock_available)} un. / {fmt(detail?.commercial.stock_days_of_cover, 1)} dias</dd></div>
                  <div><dt>Preco concorrente</dt><dd>{detail?.coverage.competitor_price_available ? 'Disponivel' : 'Nao disponivel'}</dd></div>
                  <div><dt>BSR</dt><dd>{detail?.coverage.bsr_available ? 'Disponivel' : 'Nao disponivel'}</dd></div>
                </dl>
              </section>

              <section>
                <h4>Calendario e teste</h4>
                <dl>
                  <div><dt>Fim de semana</dt><dd>{pct(detail?.calendar.weekend_share)}</dd></div>
                  <div><dt>Janela pagamento</dt><dd>{pct(detail?.calendar.paycheck_window_share)}</dd></div>
                  <div><dt>Pre-evento 7/14/30d</dt><dd>{pct(detail?.calendar.pre_event_7d_share)} / {pct(detail?.calendar.pre_event_14d_share)} / {pct(detail?.calendar.pre_event_30d_share)}</dd></div>
                  <div><dt>Evento / pos-evento</dt><dd>{pct(detail?.calendar.event_day_share)} / {pct(detail?.calendar.post_event_7d_share)}</dd></div>
                  <div><dt>Politica</dt><dd>{detail?.experiment.policy || '-'}</dd></div>
                  <div><dt>Fatia de teste</dt><dd>{pct(detail?.experiment.suggested_test_fraction)}</dd></div>
                  <div><dt>Multiplicador capado</dt><dd>{detail?.experiment.capped_test_multiplier ? `${fmt(detail.experiment.capped_test_multiplier, 2)}x` : '-'}</dd></div>
                </dl>
              </section>
            </div>

            {detail?.experiment.reason && (
              <div className="modal-note experiment-note">
                Politica de teste: {detail.experiment.reason}
              </div>
            )}

            {detail?.targetDisagrees ? (
              <div className="modal-note warning-note">
                Interpretacao: a campanha/hora esta boa, mas esta keyword/target nao confirma a mesma eficiencia.
                O sistema deve tratar isso como oportunidade com risco, priorizando teste pequeno/holdout ou aguardando mais evidencia no grao do target.
              </div>
            ) : (
              <div className="modal-note">
                Quando a probabilidade/ROAS do target vier zerada, significa que o V3 ainda tem pouco dado de conversao nesse grao.
                Nesse caso a recomendacao usa mais a campanha/hora e o target entra como sinal de clique.
              </div>
            )}
          </div>
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
          min-width:104px;
          height:38px;
          padding:0 16px;
          display:inline-flex;
          align-items:center;
          justify-content:center;
          gap:7px;
          border-radius:9px;
          border:1px solid rgba(148,163,184,.22);
          background:rgba(255,255,255,.045);
          color:#dbe6f7;
          font-size:13px;
          font-weight:700;
          letter-spacing:.01em;
          cursor:pointer;
          transition:background .16s ease, border-color .16s ease, transform .06s ease, box-shadow .16s ease;
        }
        .keyword-hour-page .btn:hover:not(:disabled){
          background:rgba(255,255,255,.085);
          border-color:rgba(148,163,184,.38);
        }
        .keyword-hour-page .btn:active:not(:disabled){transform:translateY(1px)}
        .keyword-hour-page .btn:focus-visible{
          outline:none;
          box-shadow:0 0 0 3px rgba(56,124,255,.38);
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
        /* 11 colunas somando 100% exatos. Misturar % com px (o checkbox era 64px)
           estourava a largura e trazia o scroll lateral de volta. */
        .keyword-hour-page th:nth-child(1){width:20%}  /* Keyword  */
        .keyword-hour-page th:nth-child(2){width:13%}  /* Campanha */
        .keyword-hour-page th:nth-child(3){width:5%}   /* Hora     */
        .keyword-hour-page th:nth-child(4){width:12%}  /* Acao     */
        .keyword-hour-page th:nth-child(5){width:8%}   /* Base     */
        .keyword-hour-page th:nth-child(6){width:9%}   /* Atual    */
        .keyword-hour-page th:nth-child(7){width:9%}   /* Sugerido */
        .keyword-hour-page th:nth-child(8){width:7%}   /* ROAS     */
        .keyword-hour-page th:nth-child(9){width:8%}   /* ML       */
        .keyword-hour-page th:nth-child(10){width:4%}  /* Prio     */
        .keyword-hour-page th:nth-child(11){width:5%}  /* checkbox */
        .keyword-hour-page .queue{overflow-x:hidden}
        .keyword-hour-page .kw-meta{
          display:flex;
          align-items:center;
          gap:6px;
          margin-top:4px;
          min-width:0;
        }
        .keyword-hour-page .kw-meta .sub2{
          margin-top:0;
          min-width:0;
        }
        .keyword-hour-page .apply-bar{
          display:flex;
          justify-content:flex-start;
          align-items:center;
          gap:14px;
          margin-bottom:12px;
        }
        .keyword-hour-page .apply-count{
          color:var(--muted,#9aa7bd);
          font-size:12.5px;
        }
        .keyword-hour-page .btn.primary{
          background:linear-gradient(180deg,#3d8bff 0%,#1f6ae8 100%);
          border-color:#1f6ae8;
          color:#fff;
          font-weight:800;
          box-shadow:0 1px 0 rgba(255,255,255,.16) inset, 0 6px 16px -6px rgba(31,106,232,.85);
        }
        .keyword-hour-page .btn.primary:hover:not(:disabled){
          background:linear-gradient(180deg,#4d97ff 0%,#2a75f5 100%);
          border-color:#2a75f5;
          box-shadow:0 1px 0 rgba(255,255,255,.2) inset, 0 8px 22px -6px rgba(31,106,232,.95);
        }
        .keyword-hour-page .btn.primary:disabled{
          background:rgba(148,163,184,.10);
          border-color:rgba(148,163,184,.18);
          color:rgba(148,163,184,.75);
          box-shadow:none;
          cursor:not-allowed;
        }
        .keyword-hour-page .sel-col{
          text-align:center;
        }
        .keyword-hour-page .sel-col input[type=checkbox]{
          appearance:none;
          -webkit-appearance:none;
          width:17px;
          height:17px;
          margin:0;
          border:1.5px solid rgba(148,163,184,.5);
          border-radius:5px;
          background:rgba(10,16,31,.6);
          cursor:pointer;
          position:relative;
          transition:background .14s ease, border-color .14s ease;
        }
        .keyword-hour-page .sel-col input[type=checkbox]:hover:not(:disabled){border-color:#4d97ff}
        .keyword-hour-page .sel-col input[type=checkbox]:checked{
          background:linear-gradient(180deg,#3d8bff 0%,#1f6ae8 100%);
          border-color:#1f6ae8;
        }
        .keyword-hour-page .sel-col input[type=checkbox]:checked::after{
          content:'';
          position:absolute;
          left:5px;
          top:1px;
          width:4px;
          height:9px;
          border:solid #fff;
          border-width:0 2px 2px 0;
          transform:rotate(45deg);
        }
        .keyword-hour-page .sel-col input[type=checkbox]:indeterminate{
          background:linear-gradient(180deg,#3d8bff 0%,#1f6ae8 100%);
          border-color:#1f6ae8;
        }
        .keyword-hour-page .sel-col input[type=checkbox]:indeterminate::after{
          content:'';
          position:absolute;
          left:3px;
          top:6.5px;
          width:9px;
          height:2px;
          background:#fff;
          border-radius:1px;
        }
        .keyword-hour-page .sel-col input[type=checkbox]:focus-visible{
          outline:none;
          box-shadow:0 0 0 3px rgba(56,124,255,.38);
        }
        .keyword-hour-page .sel-col input:disabled{cursor:not-allowed;opacity:.45}
        .keyword-hour-page .sel-all{
          display:inline-flex;
          align-items:center;
          gap:7px;
          cursor:pointer;
          user-select:none;
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
        .keyword-hour-page .target-warning{
          margin-top:3px;
          color:#ffb86b;
          font-size:10.5px;
          line-height:1.2;
          font-weight:800;
          white-space:nowrap;
        }
        .keyword-hour-page .detail-btn{
          margin-top:6px;
          height:22px;
          padding:0 8px;
          border:1px solid rgba(84,160,255,.45);
          border-radius:6px;
          background:rgba(84,160,255,.10);
          color:#a8c7ff;
          font-size:10.5px;
          font-weight:750;
          cursor:pointer;
        }
        .keyword-hour-page .detail-btn:hover{background:rgba(84,160,255,.18)}
        .keyword-hour-page .modal-backdrop{
          position:fixed;
          inset:0;
          z-index:50;
          display:flex;
          align-items:center;
          justify-content:center;
          padding:28px;
          background:rgba(2,8,23,.72);
          backdrop-filter:blur(6px);
        }
        .keyword-hour-page .ml-detail-modal{
          width:min(920px,calc(100vw - 36px));
          max-height:calc(100vh - 56px);
          overflow:auto;
          background:#111827;
          border:1px solid rgba(148,163,184,.22);
          border-radius:10px;
          box-shadow:0 24px 70px rgba(0,0,0,.45);
          color:#e5eefb;
        }
        .keyword-hour-page .modal-head{
          display:flex;
          justify-content:space-between;
          gap:16px;
          align-items:flex-start;
          padding:18px 20px;
          border-bottom:1px solid rgba(148,163,184,.15);
        }
        .keyword-hour-page .modal-head h3{
          margin:0;
          font-size:21px;
          letter-spacing:0;
        }
        .keyword-hour-page .modal-head p{
          margin:5px 0 0;
          color:#9fb0ca;
          font-size:13px;
        }
        .keyword-hour-page .close-btn{
          height:34px;
          padding:0 12px;
          border:1px solid rgba(148,163,184,.28);
          border-radius:8px;
          background:rgba(255,255,255,.04);
          color:#dbe6f7;
          font-weight:750;
          cursor:pointer;
        }
        .keyword-hour-page .modal-callout{
          margin:16px 20px 0;
          padding:13px 14px;
          border:1px solid rgba(255,159,67,.35);
          border-radius:8px;
          background:rgba(255,159,67,.08);
          display:grid;
          gap:5px;
        }
        .keyword-hour-page .modal-callout strong{color:#ffd08a}
        .keyword-hour-page .modal-callout span{color:#f6d9aa;font-size:13px;line-height:1.4}
        .keyword-hour-page .detail-grid{
          display:grid;
          grid-template-columns:repeat(4,minmax(0,1fr));
          gap:10px;
          padding:16px 20px 0;
        }
        .keyword-hour-page .detail-card{
          min-height:88px;
          padding:12px;
          border:1px solid rgba(148,163,184,.16);
          border-radius:8px;
          background:rgba(255,255,255,.035);
        }
        .keyword-hour-page .detail-card span{
          display:block;
          color:#9fb0ca;
          font-size:11px;
          font-weight:750;
          text-transform:uppercase;
          letter-spacing:.04em;
        }
        .keyword-hour-page .detail-card strong{
          display:block;
          margin-top:8px;
          font-size:20px;
          line-height:1.1;
        }
        .keyword-hour-page .detail-card small{
          display:block;
          margin-top:8px;
          color:#9fb0ca;
          font-size:11.5px;
          line-height:1.3;
        }
        .keyword-hour-page .detail-columns{
          display:grid;
          grid-template-columns:1fr 1fr;
          gap:14px;
          padding:16px 20px 0;
        }
        .keyword-hour-page .detail-columns section{
          border:1px solid rgba(148,163,184,.16);
          border-radius:8px;
          background:rgba(255,255,255,.025);
          padding:14px;
        }
        .keyword-hour-page .detail-columns h4{
          margin:0 0 11px;
          font-size:14px;
        }
        .keyword-hour-page .detail-columns dl{
          margin:0;
          display:grid;
          gap:8px;
        }
        .keyword-hour-page .detail-columns dl div{
          display:flex;
          justify-content:space-between;
          gap:16px;
          border-bottom:1px solid rgba(148,163,184,.08);
          padding-bottom:7px;
        }
        .keyword-hour-page .detail-columns dt{
          color:#9fb0ca;
          font-size:12px;
        }
        .keyword-hour-page .detail-columns dd{
          margin:0;
          text-align:right;
          font-size:12px;
          font-weight:800;
          font-variant-numeric:tabular-nums;
        }
        .keyword-hour-page .detail-columns dd.warn-value{color:#ffb86b}
        .keyword-hour-page .modal-note{
          margin:16px 20px 20px;
          color:#9fb0ca;
          font-size:12.5px;
          line-height:1.45;
        }
        .keyword-hour-page .warning-note{
          color:#ffd7a1;
          border:1px solid rgba(255,184,107,.28);
          border-radius:8px;
          padding:12px 14px;
          background:rgba(255,184,107,.07);
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
          .keyword-hour-page .detail-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
          .keyword-hour-page .detail-columns{grid-template-columns:1fr}
        }
      `}</style>
    </div>
  )
}
