import { useState, useEffect, useCallback } from 'react'
import { api } from '../api/client.js'

const BID_ROBOT_API_BASE = import.meta.env.VITE_BID_ROBOT_API_BASE || 'http://localhost:8080'

const ACTION_META = {
  BID_UP: { label: 'Subir lance', color: '#26de81', hint: 'Hora boa com agenda ainda baixa' },
  CUT_HOUR: { label: 'Cortar hora', color: '#ff5470', hint: 'Gasta com bid cheio sem retorno' },
  BID_DOWN: { label: 'Amaciar', color: '#ff9f43', hint: 'Hora fraca com bid cheio' },
  KEEP_STRONG: { label: 'Manter forte', color: '#54a0ff', hint: 'Hora boa ja ampliada' },
}

const CONF_COLOR = { HIGH: '#26de81', MEDIUM: '#ff9f43', LOW: '#8395a7' }
const MATURITY = {
  MATURE:   { color: '#26de81', label: 'maduro', hint: 'Conversão atribuída (>=7d) — ROAS confiável' },
  MIXED:    { color: '#ff9f43', label: 'misto', hint: 'Parte madura, parte ainda em atribuição' },
  IMMATURE: { color: '#8395a7', label: 'imaturo', hint: 'Conversão ainda em atribuição — NÃO ler ROAS 0 como ruim' },
}
const SCHEDULE_META = {
  PARTIALLY_CORRECTED: { label: 'Ajuste incompleto', color: '#ff9f43' },
  NEEDS_CHANGE: { label: 'Ainda pendente', color: '#ff5470' },
  OVERLAPPED_ALIGNED: { label: 'Sobreposta', color: '#54a0ff' },
  SINGLE_RULE: { label: '1 regra', color: '#8395a7' },
}

function fmt(n, d = 0) {
  if (n === null || n === undefined) return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })
}

function scheduleMeta(it) {
  return SCHEDULE_META[it.schedule_overlap_status] || SCHEDULE_META.SINGLE_RULE
}

function ruleLabel(rule) {
  const hour = rule.hour_start != null && rule.hour_end != null ? `${String(rule.hour_start).padStart(2, '0')}h-${String(rule.hour_end).padStart(2, '0')}h` : '-'
  const group = rule.ad_group_name || rule.ad_group_id || 'Campanha inteira'
  return { hour, group }
}

function scheduleStateLabel(it) {
  const pending = Number(it.rules_still_need_change || 0)
  const total = Number(it.overlap_rule_count || 0)
  if (it.schedule_overlap_status === 'PARTIALLY_CORRECTED' && total > 1) {
    return `${fmt(pending)} de ${fmt(total)} abaixo`
  }
  return scheduleMeta(it).label
}

function scheduleExplanation(it) {
  const pending = Number(it.rules_still_need_change || 0)
  const aligned = Number(it.rules_already_aligned || 0)
  const total = Number(it.overlap_rule_count || 0)
  if (it.schedule_overlap_status === 'PARTIALLY_CORRECTED' && total > 1) {
    return `${fmt(aligned)} ja cobrem a sugestao; ${fmt(pending)} ainda estao menores.`
  }
  if (it.schedule_overlap_status === 'NEEDS_CHANGE') return 'A agenda atual ainda esta abaixo da sugestao.'
  if (it.schedule_overlap_status === 'OVERLAPPED_ALIGNED') return 'Ha regras sobrepostas, mas elas ja cobrem a sugestao.'
  return 'Regra unica para esta campanha/hora.'
}

function pendingProfileIDs(it) {
  return [...new Set((it?.overlap_rule_details || [])
    .filter(rule => rule.status === 'PENDING' && rule.profile_id)
    .map(rule => String(rule.profile_id)))]
}

function recommendationKey(it) {
  return it?.recommendation_id || `${it?.campaign_name || ''}-${it?.event_hour || ''}-${it?.action_type || ''}`
}

function applyScheduleResultToItem(it, result) {
  if (!it || !result || Number(result.updated_count || 0) <= 0) return it

  const updatedProfiles = new Set((result.updated || []).map(row => String(row.profile_id)))
  if (updatedProfiles.size === 0) return it

  const suggested = Number(it.suggested_multiplier)
  const nextRules = (it.overlap_rule_details || []).map(rule => {
    if (!updatedProfiles.has(String(rule.profile_id))) return rule
    return {
      ...rule,
      status: 'ALIGNED',
      multiplier: suggested,
      label: `BID ${Math.round(suggested * 100)}%`,
    }
  })
  const pending = nextRules.filter(rule => rule.status === 'PENDING').length
  const aligned = nextRules.length - pending
  const multipliers = nextRules.map(rule => Number(rule.multiplier)).filter(Number.isFinite)
  const minMultiplier = multipliers.length ? Math.min(...multipliers) : it.current_multiplier
  const maxMultiplier = multipliers.length ? Math.max(...multipliers) : it.overlap_mult_max

  return {
    ...it,
    overlap_rule_details: nextRules,
    rules_still_need_change: pending,
    rules_already_aligned: aligned,
    current_multiplier: minMultiplier,
    overlap_mult_min: minMultiplier,
    overlap_mult_max: maxMultiplier,
    schedule_overlap_status: pending === 0 ? 'OVERLAPPED_ALIGNED' : it.schedule_overlap_status,
  }
}

export default function HorariosReais({ ctx }) {
  const { tenantID } = ctx
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState({ action: '', confidence: '' })
  const [detailItem, setDetailItem] = useState(null)
  const [applyBusy, setApplyBusy] = useState('')
  const [applyResult, setApplyResult] = useState(null)

  const load = useCallback(async () => {
    setLoading(true)
    const r = await api.goldHourlyReal(tenantID, { ...filter, limit: 300 })
    if (r.ok) setItems(r.data.items || [])
    setLoading(false)
  }, [tenantID, filter])

  useEffect(() => { load() }, [load])

  const openDetail = (it) => {
    setApplyResult(null)
    setDetailItem(it)
  }

  const applySuggestion = async (it) => {
    const profile_ids = pendingProfileIDs(it)
    if (!profile_ids.length) return
    const busyKey = it.recommendation_id || `${it.campaign_name}-${it.event_hour}`
    setApplyBusy(busyKey)
    setApplyResult(null)
    try {
      const res = await fetch(`${BID_ROBOT_API_BASE}/api/amazon/ads/bid-robot/schedules/apply-suggestion`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          recommendation_id: it.recommendation_id,
          campaign_name: it.campaign_name,
          hour: Number(it.event_hour),
          suggested_multiplier: Number(it.suggested_multiplier),
          profile_ids,
        }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(data.error || data.message || `HTTP ${res.status}`)
      if (Number(data.updated_count || 0) > 0) {
        const key = recommendationKey(it)
        setItems(prev => prev.map(row => (
          recommendationKey(row) === key ? applyScheduleResultToItem(row, data) : row
        )))
        setDetailItem(prev => (
          prev && recommendationKey(prev) === key ? applyScheduleResultToItem(prev, data) : prev
        ))
      }
      setApplyResult({
        ...data,
        status: Number(data.updated_count || 0) > 0 ? 'APLICADO' : (data.status || 'SEM_ALTERACAO'),
        message: data.message || (
          Number(data.updated_count || 0) > 0
            ? `${fmt(data.updated_count)} regras atualizadas. A tela ja refletiu a mudanca; o espelho oficial sincroniza em seguida.`
            : 'Nenhuma regra foi alterada pelo backend.'
        ),
      })
    } catch (err) {
      setApplyResult({ status: 'FAILED', message: err.message || 'Falha ao aplicar sugestao' })
    } finally {
      setApplyBusy('')
    }
  }

  const win = items[0]
  const bidUp = items.filter(i => i.action_type === 'BID_UP')
  const cut = items.filter(i => i.action_type === 'CUT_HOUR' || i.action_type === 'BID_DOWN')
  const partial = items.filter(i => i.schedule_overlap_status === 'PARTIALLY_CORRECTED').length
  const highConf = items.filter(i => i.confidence === 'HIGH').length

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h2>Horarios - Dado Real</h2>
          <span className="sub">
            Relatorio da conta (sem supressao) x agenda do Robo
            {win ? ` - janela ${win.window_from} -> ${win.window_to}` : ''}
          </span>
        </div>
        <button className="btn" onClick={load}>Atualizar</button>
      </div>

      <div className="warn">
        Como ler: Acao e a recomendacao do painel. Estado da agenda mostra se o Robo ja chegou la.
        Quando aparecer "X de Y abaixo", existem Y regras cobrindo aquela hora e X ainda estao com multiplicador menor que o sugerido.
        O ML aparece como concorda/discorda.
      </div>

      <div className="kpi-row">
        <div className="kpi"><div className="kpi-v">{fmt(items.length)}</div><div className="kpi-l">Oportunidades</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#26de81' }}>{fmt(bidUp.length)}</div><div className="kpi-l">Horas boas estranguladas</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#ff9f43' }}>{fmt(partial)}</div><div className="kpi-l">Com regras ainda abaixo</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#54a0ff' }}>{fmt(highConf)}</div><div className="kpi-l">Alta confianca</div></div>
      </div>

      <div className="filters">
        <select value={filter.action} onChange={e => setFilter(f => ({ ...f, action: e.target.value }))}>
          <option value="">Todas as acoes</option>
          <option value="BID_UP">Subir lance</option>
          <option value="CUT_HOUR">Cortar hora</option>
          <option value="BID_DOWN">Amaciar</option>
        </select>
        <select value={filter.confidence} onChange={e => setFilter(f => ({ ...f, confidence: e.target.value }))}>
          <option value="">Toda confianca</option>
          <option value="HIGH">Alta</option>
          <option value="MEDIUM">Media</option>
          <option value="LOW">Baixa</option>
        </select>
        <span className="count-badge">{items.length} itens</span>
      </div>

      {loading ? <div className="empty">Carregando...</div> : items.length === 0 ? (
        <div className="empty">Nenhuma oportunidade com os filtros atuais.</div>
      ) : (
        <div className="queue">
          <table>
            <thead>
              <tr>
                <th>Campanha</th><th>Hora</th><th>Acao recomendada</th><th>Estado da agenda</th>
                <th>ROAS</th><th>Fonte</th><th>Gasto</th><th>Ped.</th><th>ML</th><th>Conf.</th><th>Prio</th>
              </tr>
            </thead>
            <tbody>
              {items.map(it => {
                const action = ACTION_META[it.action_type] || { label: it.action_type, color: '#8395a7', hint: '' }
                const sched = scheduleMeta(it)
                return (
                  <tr key={it.recommendation_id} className={it.schedule_overlap_status === 'PARTIALLY_CORRECTED' ? 'row-partial' : ''}>
                    <td className="camp">{it.campaign_name}</td>
                    <td className="num">{String(it.event_hour).padStart(2, '0')}h</td>
                    <td>
                      <span className="action-tag" style={{ color: action.color, borderColor: action.color }}>{action.label}</span>
                      <div className="sub2">{action.hint}</div>
                    </td>
                    <td className="schedule-cell" title={it.overlap_labels ? `Regras: ${it.overlap_labels}` : ''}>
                      <div className="schedule-top">
                        <span className="schedule-badge" style={{ background: sched.color + '22', color: sched.color }}>
                          {scheduleStateLabel(it)}
                        </span>
                        {Number(it.overlap_rule_count || 0) > 1 && (
                          <><span className="schedule-count">{fmt(it.overlap_rule_count)} regras</span><button className="icon-btn" title="Ver regras pendentes" onClick={() => openDetail(it)}>i</button></>
                        )}
                      </div>
                      <div className="schedule-mults">
                        <b>{it.has_schedule ? `${fmt(it.current_multiplier, 2)}x` : 's/ agenda'}</b>
                        <span>{' -> '}</span>
                        <b>{it.has_schedule ? `${fmt(it.suggested_multiplier, 2)}x` : '-'}</b>
                      </div>
                      {Number(it.overlap_rule_count || 0) > 1 && (
                        <div className="sub2">
                          {scheduleExplanation(it)}
                        </div>
                      )}
                    </td>
                    <td className="num" style={{ fontWeight: 700, color: it.roas >= 4 ? '#26de81' : it.roas < 1 ? '#ff5470' : 'inherit' }}>{fmt(it.roas, 1)}</td>
                    <td title={(MATURITY[it.conversion_maturity]?.hint || '') + (it.traffic_source ? ` · tráfego: ${it.traffic_source === 'AMS_STREAM' ? 'AMS (fresco)' : 'reporting'}` : '')}>
                      {it.conversion_maturity
                        ? <span className="conf" style={{ background: (MATURITY[it.conversion_maturity]?.color || '#8395a7') + '22', color: MATURITY[it.conversion_maturity]?.color || '#8395a7' }}>{MATURITY[it.conversion_maturity]?.label || it.conversion_maturity}</span>
                        : <span className="muted">-</span>}
                      <div className="sub2">{it.traffic_source === 'AMS_STREAM' ? 'AMS' : 'report'}</div>
                    </td>
                    <td className="num">R$ {fmt(it.spend, 0)}</td>
                    <td className="num">{fmt(it.orders)}</td>
                    <td title={it.ml_expected_roas != null ? `ML: P(pedido) ${fmt((it.ml_conversion_probability || 0) * 100, 0)}% - ROAS esp. ${fmt(it.ml_expected_roas, 1)}` : 'sem predicao ML'}>
                      {it.ml_agrees === true ? <span className="agree">concorda</span>
                        : it.ml_agrees === false ? <span className="conflict">discorda</span>
                        : <span className="muted">-</span>}
                    </td>
                    <td><span className="conf" style={{ background: CONF_COLOR[it.confidence] + '22', color: CONF_COLOR[it.confidence] }}>{it.confidence}</span></td>
                    <td className="num">{fmt(it.priority_score, 0)}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {detailItem && (
        <div className="modal-backdrop" onClick={() => setDetailItem(null)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-head">
              <div>
                <h3>{detailItem.campaign_name} - {String(detailItem.event_hour).padStart(2, '0')}h</h3>
                <span className="sub">Por que esta recomendacao ainda aparece</span>
              </div>
              <button className="icon-btn close" onClick={() => setDetailItem(null)}>x</button>
            </div>
            <div className="modal-summary">
              <span>{fmt(detailItem.rules_still_need_change)} ainda pendentes</span>
              <span>{fmt(detailItem.rules_already_aligned)} ja alinhadas</span>
              <span>{fmt(detailItem.overlap_rule_count)} regras ativas</span>
            </div>
            <div className="modal-meaning">
              <b>Traducao:</b> o painel recomenda {fmt(detailItem.suggested_multiplier, 2)}x para esta campanha/hora.
              Existem {fmt(detailItem.overlap_rule_count)} regras do Robo cobrindo esse horario.
              {` ${fmt(detailItem.rules_already_aligned)} ja estao em ${fmt(detailItem.suggested_multiplier, 2)}x ou acima, mas ${fmt(detailItem.rules_still_need_change)} ainda estao abaixo. `}
              Por isso a oportunidade continua aparecendo.
            </div>
            <div className="modal-actions">
              <button
                className="btn btn-apply"
                disabled={applyBusy === (detailItem.recommendation_id || `${detailItem.campaign_name}-${detailItem.event_hour}`) || pendingProfileIDs(detailItem).length === 0}
                onClick={() => applySuggestion(detailItem)}
              >
                {applyBusy === (detailItem.recommendation_id || `${detailItem.campaign_name}-${detailItem.event_hour}`)
                  ? 'Atualizando...'
                  : pendingProfileIDs(detailItem).length === 0
                    ? 'Tudo alinhado nesta hora'
                    : `Atualizar ${fmt(pendingProfileIDs(detailItem).length)} pendentes para ${fmt(detailItem.suggested_multiplier, 2)}x`}
              </button>
              <span>Atualiza somente esta hora nas regras abaixo da sugestao. O Cycle B aplica na proxima rodada horaria.</span>
            </div>
            {applyResult && (
              <div className={applyResult.status === 'FAILED' ? 'apply-result error' : 'apply-result'}>
                <b>{applyResult.status}</b>
                <span>{applyResult.message || `${fmt(applyResult.updated_count || 0)} regras atualizadas.`}</span>
              </div>
            )}
            <div className="rule-list">
              {(detailItem.overlap_rule_details || []).map((rule, idx) => {
                const info = ruleLabel(rule)
                const pending = rule.status === 'PENDING'
                return (
                  <div className={`rule-row ${pending ? 'pending' : 'aligned'}`} key={`${rule.profile_id || idx}-${idx}`}>
                    <div>
                      <b>{info.group}</b>
                      <div className="sub2">{rule.profile_id || '-'} - {info.hour}</div>
                    </div>
                    <div className="num"><b>{fmt(rule.multiplier, 2)}x</b><div className="sub2">{rule.label || '-'}</div></div>
                    <span className={pending ? 'rule-pending' : 'rule-ok'}>{pending ? 'abaixo' : 'cobre'}</span>
                  </div>
                )
              })}
            </div>
          </div>
        </div>
      )}

      <style>{`
        .page-head{display:flex;justify-content:space-between;align-items:flex-end;margin-bottom:14px}
        .page-head h2{margin:0;font-size:22px}
        .sub{color:var(--muted,#8395a7);font-size:13px}
        .warn{background:#54a0ff14;border:1px solid #54a0ff44;border-radius:10px;padding:10px 14px;font-size:12px;color:#9fc3ff;margin-bottom:16px;line-height:1.5}
        .kpi-row{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:16px}
        .kpi{background:var(--card,#161b26);border:1px solid var(--border,#232a38);border-radius:12px;padding:16px}
        .kpi-v{font-size:24px;font-weight:800}
        .kpi-l{color:var(--muted,#8395a7);font-size:12px;margin-top:4px}
        .filters{display:flex;gap:10px;align-items:center;margin-bottom:12px}
        .filters select{background:var(--card,#161b26);border:1px solid var(--border,#232a38);color:inherit;padding:7px 10px;border-radius:8px}
        .count-badge{color:var(--muted,#8395a7);font-size:13px;margin-left:auto}
        .queue{background:var(--card,#161b26);border:1px solid var(--border,#232a38);border-radius:12px;overflow:hidden}
        .queue table{width:100%;border-collapse:collapse;font-size:13px}
        .queue th{text-align:left;padding:10px 12px;color:var(--muted,#8395a7);font-size:11px;text-transform:uppercase;border-bottom:1px solid var(--border,#232a38);white-space:nowrap}
        .queue td{padding:10px 12px;border-bottom:1px solid var(--border,#1c2230);vertical-align:middle}
        .queue tr.row-partial{background:rgba(255,159,67,.055)}
        .queue tr.row-partial td:first-child{border-left:3px solid #ff9f43}
        .camp{font-weight:600}
        .sub2{font-size:11px;color:var(--muted,#8395a7);margin-top:2px;white-space:nowrap}
        .action-tag{background:transparent;border:1px solid;padding:3px 8px;border-radius:6px;font-size:11px;font-weight:700;white-space:nowrap}
        .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
        .muted{color:var(--muted,#8395a7);font-size:11px}
        .agree{color:#26de81;font-size:12px;font-weight:600}
        .conflict{color:#ff5470;font-size:12px;font-weight:700}
        .conf{padding:2px 8px;border-radius:20px;font-size:10px;font-weight:800}
        .schedule-cell{min-width:210px}
        .schedule-top{display:flex;align-items:center;gap:6px;margin-bottom:3px}
        .schedule-badge{display:inline-flex;align-items:center;white-space:nowrap;padding:2px 8px;border-radius:20px;font-size:10px;font-weight:800;text-transform:uppercase}
        .schedule-count{color:var(--muted,#8395a7);font-size:11px}
        .schedule-mults{font-size:13px;font-variant-numeric:tabular-nums;white-space:nowrap}
        .icon-btn{border:1px solid var(--border,#232a38);background:#111827;color:#9fc3ff;border-radius:999px;width:22px;height:22px;font-size:12px;font-weight:800;cursor:pointer;margin-left:4px}.icon-btn:hover{border-color:#54a0ff;color:#fff}.modal-backdrop{position:fixed;inset:0;background:rgba(2,6,23,.72);display:flex;align-items:center;justify-content:center;z-index:50;padding:24px}.modal{width:min(760px,96vw);max-height:82vh;overflow:auto;background:var(--card,#161b26);border:1px solid var(--border,#232a38);border-radius:12px;box-shadow:0 24px 80px rgba(0,0,0,.45)}.modal-head{display:flex;justify-content:space-between;gap:16px;padding:16px 18px;border-bottom:1px solid var(--border,#232a38)}.modal-head h3{margin:0;font-size:18px}.close{flex:0 0 auto}.modal-summary{display:flex;gap:10px;flex-wrap:wrap;padding:12px 18px;border-bottom:1px solid var(--border,#232a38)}.modal-summary span{font-size:12px;color:#c7d2fe;background:#54a0ff18;border:1px solid #54a0ff33;border-radius:999px;padding:4px 10px}.modal-meaning{margin:12px 18px 4px;padding:12px 14px;border:1px solid rgba(255,159,67,.28);border-radius:8px;background:rgba(255,159,67,.08);color:#f4d7b1;font-size:13px;line-height:1.45}.modal-actions{display:flex;align-items:center;gap:12px;margin:12px 18px;padding:12px 14px;border:1px solid rgba(38,222,129,.22);border-radius:8px;background:rgba(38,222,129,.06)}.modal-actions span{font-size:12px;color:var(--muted,#8395a7);line-height:1.35}.btn-apply{background:#26de81;color:#06131a;border-color:#26de81;font-weight:800}.btn-apply:disabled{opacity:.55;cursor:not-allowed}.apply-result{display:flex;gap:8px;align-items:center;margin:0 18px 8px;padding:8px 12px;border-radius:8px;background:rgba(84,160,255,.12);border:1px solid rgba(84,160,255,.24);font-size:12px;color:#b9d5ff}.apply-result.error{background:rgba(255,84,112,.1);border-color:rgba(255,84,112,.3);color:#ffb8c4}.rule-list{padding:8px 0}.rule-row{display:grid;grid-template-columns:minmax(240px,1fr) 100px 120px;gap:12px;align-items:center;padding:10px 18px;border-bottom:1px solid var(--border,#1c2230)}.rule-row.pending{background:rgba(255,84,112,.055)}.rule-row.aligned{background:rgba(38,222,129,.035)}.rule-pending,.rule-ok{justify-self:end;border-radius:999px;padding:3px 9px;font-size:10px;font-weight:800;text-transform:uppercase}.rule-pending{color:#ff5470;background:#ff547022}.rule-ok{color:#26de81;background:#26de8122}.empty{padding:40px;text-align:center;color:var(--muted,#8395a7)}
      `}</style>
    </div>
  )
}



