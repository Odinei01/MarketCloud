import { useState, useEffect, useCallback } from 'react'
import { api } from '../api/client.js'

const BUCKET_COLORS = {
  P0_CRITICAL: '#ff5470', P1_HIGH: '#ff9f43', P2_MEDIUM: '#54a0ff', P3_LOW: '#8395a7',
}
const RISK_COLORS = { HIGH: '#ff5470', MEDIUM: '#ff9f43', LOW: '#26de81', WATCH: '#8395a7' }

function fmt(n, d = 0) {
  if (n === null || n === undefined) return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })
}

export default function ReviewQueue({ ctx }) {
  const { tenantID } = ctx
  const [summary, setSummary] = useState([])
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState({ bucket: '', decision: '', only_new: 'true' })
  const [busy, setBusy] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    const [sumR, qR] = await Promise.all([
      api.goldActionSummary(tenantID),
      api.goldReviewQueue(tenantID, { ...filter, limit: 300 }),
    ])
    if (sumR.ok) setSummary(sumR.data.items || [])
    if (qR.ok) setItems(qR.data.items || [])
    setLoading(false)
  }, [tenantID, filter])

  useEffect(() => { load() }, [load])

  const decide = async (rec, decision, execution_status) => {
    setBusy(rec.recommendation_id)
    const r = await api.goldDecide(tenantID, rec.recommendation_id, { decision, execution_status })
    if (r.ok) {
      setItems(prev => prev.map(it => it.recommendation_id === rec.recommendation_id
        ? { ...it, human_decision_status: decision, execution_status: execution_status || it.execution_status } : it))
    } else {
      alert('Falha: ' + (r.data?.error || r.status))
    }
    setBusy('')
  }

  // KPIs agregados
  const totalRecs = summary.reduce((a, s) => a + Number(s.recommendations_count || 0), 0)
  const p0 = summary.reduce((a, s) => a + Number(s.p0_count || 0), 0)
  const conflicts = summary.reduce((a, s) => a + Number(s.conflict_count || 0), 0)
  const spendAtRisk = summary.filter(s => ['CUT_HOUR', 'BID_DOWN', 'REDUCE_BID', 'PAUSE_TARGET', 'CUT_CAMPAIGN_BUDGET', 'ADD_NEGATIVE_EXACT', 'ADD_NEGATIVE_PHRASE'].includes(s.final_action_type))
    .reduce((a, s) => a + Number(s.total_spend || 0), 0)

  const byAction = Object.values(summary.reduce((acc, s) => {
    const k = s.final_action_type
    if (!acc[k]) acc[k] = { action: k, count: 0, spend: 0, p0: 0 }
    acc[k].count += Number(s.recommendations_count || 0)
    acc[k].spend += Number(s.total_spend || 0)
    acc[k].p0 += Number(s.p0_count || 0)
    return acc
  }, {})).sort((a, b) => b.count - a.count)

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h2>Cockpit de Recomendacoes</h2>
          <span className="sub">Gold V2 | priorizado | Gold x ML | revisao humana</span>
        </div>
        <button className="btn" onClick={load}>Atualizar</button>
      </div>

      {/* KPIs */}
      <div className="kpi-row">
        <div className="kpi"><div className="kpi-v">{fmt(totalRecs)}</div><div className="kpi-l">Recomendacoes</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: BUCKET_COLORS.P0_CRITICAL }}>{fmt(p0)}</div><div className="kpi-l">P0 Criticas</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#ff9f43' }}>R$ {fmt(spendAtRisk, 0)}</div><div className="kpi-l">Gasto em risco</div></div>
        <div className="kpi"><div className="kpi-v" style={{ color: '#54a0ff' }}>{fmt(conflicts)}</div><div className="kpi-l">Conflitos Gold x ML</div></div>
      </div>

      {/* Resumo por acao */}
      <div className="action-cards">
        {byAction.map(a => (
          <div key={a.action} className="action-card" onClick={() => setFilter(f => ({ ...f, bucket: '' }))}>
            <div className="ac-count">{fmt(a.count)}</div>
            <div className="ac-action">{a.action}</div>
            <div className="ac-meta">R$ {fmt(a.spend, 0)}{a.p0 > 0 ? ` | ${a.p0} P0` : ''}</div>
          </div>
        ))}
      </div>

      {/* Filtros */}
      <div className="filters">
        <select value={filter.bucket} onChange={e => setFilter(f => ({ ...f, bucket: e.target.value }))}>
          <option value="">Todas prioridades</option>
          <option value="P0_CRITICAL">P0 Critica</option>
          <option value="P1_HIGH">P1 Alta</option>
          <option value="P2_MEDIUM">P2 Media</option>
          <option value="P3_LOW">P3 Baixa</option>
        </select>
        <select value={filter.decision} onChange={e => setFilter(f => ({ ...f, decision: e.target.value }))}>
          <option value="">Todas decisoes</option>
          <option value="NOT_DECIDED">Pendentes</option>
          <option value="APPROVED">Aprovadas</option>
          <option value="REJECTED">Rejeitadas</option>
        </select>
        <label className="toggle" title="Esconde o que o Robo ZANOM ja fez">
          <input type="checkbox" checked={filter.only_new === 'true'}
            onChange={e => setFilter(f => ({ ...f, only_new: e.target.checked ? 'true' : '' }))} />
          so acoes novas
        </label>
        <span className="count-badge">{items.length} itens</span>
      </div>

      {/* Fila */}
      {loading ? <div className="empty">Carregando...</div> : (
        <div className="queue">
          <table>
            <thead>
              <tr>
                <th>#</th><th>Prio</th><th>Entidade</th><th>Alvo</th><th>Acao</th>
                <th>Gasto</th><th>ROAS</th><th>Risco</th><th>Gold x ML</th><th>Conf.</th><th>Decisao</th>
              </tr>
            </thead>
            <tbody>
              {items.map((it, idx) => {
                const decided = it.human_decision_status && it.human_decision_status !== 'NOT_DECIDED'
                return (
                  <tr key={`${it.recommendation_id || 'rec'}-${it.priority_rank || idx}-${idx}`} className={decided ? 'decided' : ''}>
                    <td className="rank">{it.priority_rank}</td>
                    <td><span className="pill" style={{ background: BUCKET_COLORS[it.priority_bucket] }}>{it.priority_bucket?.replace('_', ' ')}</span>
                      <div className="prio-score">{fmt(it.priority_score, 0)}</div></td>
                    <td className="ent">{it.entity_type?.replace(/_/g, ' ').toLowerCase()}</td>
                    <td className="target">
                      <div className="camp">{it.campaign_name || '-'}</div>
                      <div className="sub2">
                        {it.event_hour != null ? `${String(it.event_hour).padStart(2, '0')}h` : ''}
                        {it.ad_group_name ? ` | ${it.ad_group_name}` : ''}
                        {it.customer_search_term ? `"${it.customer_search_term}"` : ''}
                      </div>
                    </td>
                    <td>
                      <span className="action-tag">{it.final_action_type}</span>
                      {it.target_bid != null && (
                        <div className="sub2">bid R$ {fmt(it.campaign_avg_bid, 2)} para <b>R$ {fmt(it.target_bid, 2)}</b></div>
                      )}
                      {it.swarm_state && it.swarm_state !== 'NEW' && (
                        <div className="already">{it.swarm_state === 'ALREADY_NEGATIVE' ? 'ja negativada' : `hora ja em ${fmt(it.current_hour_multiplier, 2)}x`}</div>
                      )}
                    </td>
                    <td className="num">R$ {fmt(it.spend, 1)}</td>
                    <td className="num">{fmt(it.roas, 2)}</td>
                    <td><span className="risk-dot" style={{ background: RISK_COLORS[it.final_risk_level] }} />{it.final_risk_level}</td>
                    <td>{it.agreement === null ? <span className="muted">-</span>
                      : it.agreement ? <span className="agree">concorda</span>
                        : <span className="conflict">conflito</span>}</td>
                    <td className="num">{fmt((it.final_confidence_score || 0) * 100, 0)}%</td>
                    <td className="decide-cell">
                      {decided
                        ? <span className={`decision-badge ${it.human_decision_status}`}>{it.human_decision_status}</span>
                        : (
                          <div className="decide-btns">
                            <button disabled={busy === it.recommendation_id} className="btn-approve"
                              onClick={() => decide(it, 'APPROVED', 'EXECUTED')} title="Aprovar e marcar executado">OK</button>
                            <button disabled={busy === it.recommendation_id} className="btn-reject"
                              onClick={() => decide(it, 'REJECTED')} title="Rejeitar">X</button>
                            <button disabled={busy === it.recommendation_id} className="btn-snooze"
                              onClick={() => decide(it, 'SNOOZED')} title="Adiar">Adiar</button>
                          </div>
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
        .page-head{display:flex;justify-content:space-between;align-items:flex-end;margin-bottom:18px}
        .page-head h2{margin:0;font-size:22px}
        .sub{color:var(--muted,#8395a7);font-size:13px}
        .kpi-row{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:16px}
        .kpi{background:var(--card,#161b26);border:1px solid var(--border,#232a38);border-radius:12px;padding:16px}
        .kpi-v{font-size:24px;font-weight:800}
        .kpi-l{color:var(--muted,#8395a7);font-size:12px;margin-top:4px}
        .action-cards{display:flex;gap:10px;overflow-x:auto;padding-bottom:6px;margin-bottom:16px}
        .action-card{min-width:130px;background:var(--card,#161b26);border:1px solid var(--border,#232a38);border-radius:10px;padding:12px;cursor:pointer}
        .ac-count{font-size:20px;font-weight:800}
        .ac-action{font-size:11px;color:var(--gold,#e8b339);margin-top:2px;font-weight:700}
        .ac-meta{font-size:11px;color:var(--muted,#8395a7);margin-top:4px}
        .filters{display:flex;gap:10px;align-items:center;margin-bottom:12px}
        .filters select{background:var(--card,#161b26);border:1px solid var(--border,#232a38);color:inherit;padding:7px 10px;border-radius:8px}
        .count-badge{color:var(--muted,#8395a7);font-size:13px;margin-left:auto}
        .queue{background:var(--card,#161b26);border:1px solid var(--border,#232a38);border-radius:12px;overflow:hidden}
        .queue table{width:100%;border-collapse:collapse;font-size:13px}
        .queue th{text-align:left;padding:10px 12px;color:var(--muted,#8395a7);font-size:11px;text-transform:uppercase;border-bottom:1px solid var(--border,#232a38)}
        .queue td{padding:10px 12px;border-bottom:1px solid var(--border,#1c2230);vertical-align:middle}
        .queue tr.decided{opacity:.5}
        .rank{color:var(--muted,#8395a7);font-weight:700}
        .pill{padding:2px 8px;border-radius:20px;font-size:10px;font-weight:800;color:#0b0e14}
        .prio-score{font-size:11px;color:var(--muted,#8395a7);margin-top:3px}
        .ent{font-size:11px;color:var(--muted,#8395a7)}
        .camp{font-weight:600}
        .sub2{font-size:11px;color:var(--muted,#8395a7);margin-top:2px}
        .action-tag{background:#232a38;padding:3px 8px;border-radius:6px;font-size:11px;font-weight:700}
        .num{text-align:right;font-variant-numeric:tabular-nums}
        .risk-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
        .agree{color:#26de81;font-size:12px}
        .conflict{color:#ff5470;font-size:12px;font-weight:700}
        .muted{color:var(--muted,#8395a7)}
        .decide-btns{display:flex;gap:4px}
        .decide-btns button{min-width:32px;height:28px;padding:0 7px;border-radius:6px;border:1px solid var(--border,#232a38);cursor:pointer;font-size:12px;background:#1c2230;color:inherit}
        .btn-approve:hover{background:#26de81;color:#0b0e14}
        .btn-reject:hover{background:#ff5470;color:#0b0e14}
        .btn-snooze:hover{background:#54a0ff;color:#0b0e14}
        .decision-badge{padding:3px 10px;border-radius:6px;font-size:11px;font-weight:700}
        .decision-badge.APPROVED{background:#26de8133;color:#26de81}
        .decision-badge.REJECTED{background:#ff547033;color:#ff5470}
        .decision-badge.SNOOZED{background:#54a0ff33;color:#54a0ff}
        .toggle{display:flex;align-items:center;gap:6px;font-size:13px;color:var(--muted,#8395a7);cursor:pointer}
        .already{font-size:11px;color:#26de81;margin-top:3px}
        .empty{padding:40px;text-align:center;color:var(--muted,#8395a7)}
      `}</style>
    </div>
  )
}

