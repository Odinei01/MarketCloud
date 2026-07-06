import { useState, useEffect, useRef } from 'react'
import { api } from '../api/client.js'

const STATUS_COLOR = {
  INSIGHTS_GENERATED: 'green', MODELING_COMPLETED: 'green', SUCCEEDED: 'green',
  RUNNING: 'gold', SUBMITTED: 'gold', QUEUED: 'gold', CREATED: 'gold',
  FAILED: 'red', CANCELLED: 'red',
  RESULT_DOWNLOADED: 'blue', MODELING_STARTED: 'blue',
}

const ACTIVE_STATUSES = new Set(['QUEUED', 'CREATED', 'SUBMITTED', 'RUNNING'])

const OPERATIONS = [
  { code: 'MC_ZANOM_Q001', icon: '🔥', label: 'Dinheiro queimado', description: 'Campanhas com gasto e zero venda direta ou assistida', color: 'red' },
  { code: 'MC_ZANOM_Q002', icon: '🚫', label: 'Termos para negativar', description: 'Keywords que gastam sem converter', color: 'red' },
  { code: 'MC_ZANOM_Q003', icon: '🎯', label: 'Termos para virar exata', description: 'Search terms com conversão para promover a EXACT', color: 'green' },
  { code: 'MC_ZANOM_Q004', icon: '❌', label: 'Negativar search terms', description: 'Termos irrelevantes para adicionar como negativos', color: 'red' },
  { code: 'MC_ZANOM_Q005', icon: '🛡️', label: 'Proteger campanhas assistidas', description: 'ROAS direto ruim mas assist_rate ≥ 30% — não pausar', color: 'purple' },
  { code: 'MC_ZANOM_Q006', icon: '📊', label: 'Funil de keywords', description: 'DISCOVERY / CONSIDERATION / CONVERSION / WASTE', color: 'blue' },
  { code: 'MC_ZANOM_Q007', icon: '🗺️', label: 'Jornada até compra', description: 'Sequência de campanhas tocadas antes da conversão', color: 'blue' },
  { code: 'MC_ZANOM_Q008', icon: '🔁', label: 'Saturação de frequência', description: 'Está mostrando anúncio demais para o mesmo público?', color: 'gold' },
  { code: 'MC_ZANOM_Q009', icon: '💰', label: 'Campanha sem orçamento', description: 'Campanhas boas esgotando budget cedo', color: 'gold' },
  { code: 'MC_ZANOM_Q010', icon: '📍', label: 'Topo de busca vale?', description: 'Top of Search vendendo ou só encarecendo CPC?', color: 'blue' },
  { code: 'MC_ZANOM_Q011', icon: '🕐', label: 'Melhor horário', description: 'Hora-pico de conversão vs hora cara sem retorno', color: 'gold' },
  { code: 'MC_ZANOM_Q012', icon: '📅', label: 'Melhor dia da semana', description: 'Padrão de conversão por dia e produto', color: 'blue' },
  { code: 'MC_ZANOM_Q013', icon: '🚨', label: 'Horário caro sem conversão', description: 'Janelas com gasto alto e zero conversão', color: 'red' },
  { code: 'MC_ZANOM_Q014', icon: '🎯', label: 'ASIN target vencedor', description: 'ASINs de product targeting que convertem', color: 'green' },
  { code: 'MC_ZANOM_Q015', icon: '🗑️', label: 'ASIN target que só rouba clique', description: 'Product targeting com gasto e zero conversão', color: 'red' },
  { code: 'MC_ZANOM_Q016', icon: '🔗', label: 'Cross-sell entre produtos', description: 'Compradores de um produto que compram outro ZANOM', color: 'green' },
  { code: 'MC_ZANOM_Q017', icon: '📄', label: 'Página com clique bom mas não converte', description: 'Alta CTR + baixa CVR = problema na página', color: 'gold' },
  { code: 'MC_ZANOM_Q018', icon: '🌱', label: 'Produto orgânico demais', description: 'Vende bem sem Ads — talvez receba Ads demais', color: 'blue' },
  { code: 'MC_ZANOM_Q019', icon: '🆕', label: 'Novo cliente vs recorrente', description: 'Ads está trazendo cliente novo ou só recomprador?', color: 'green' },
  { code: 'MC_ZANOM_Q020', icon: '⏱️', label: 'Tempo até conversão', description: 'Quanto tempo o cliente leva para comprar', color: 'blue' },
  { code: 'MC_ZANOM_Q021', icon: '🏷️', label: 'Defesa de marca', description: 'Preciso pagar Ads para quem já procura ZANOM?', color: 'purple' },
  { code: 'MC_ZANOM_Q022', icon: '⚔️', label: 'Concorrente roubando venda', description: 'Quais concorrentes interceptam jornadas ZANOM', color: 'red' },
  { code: 'MC_ZANOM_Q023', icon: '🎟️', label: 'Cupom: conversão ou margem?', description: 'Cupom aumenta conversão ou só reduz margem?', color: 'gold' },
  { code: 'MC_ZANOM_Q024', icon: '💸', label: 'CPC caro pelo ticket', description: 'CPC acima do break-even por ticket e margem', color: 'red' },
  { code: 'MC_ZANOM_Q025', icon: '↔️', label: 'Shift de budget', description: 'De onde tirar orçamento e para onde mandar', color: 'green' },
  { code: 'MC_ZANOM_Q026', icon: '📈', label: 'Margem real do produto', description: 'ROAS bom mas presta após custo, taxa e margem?', color: 'blue' },
  { code: 'MC_ZANOM_Q027', icon: '🏆', label: 'Ranking de produtos para Ads', description: 'Qual produto merece mais investimento?', color: 'green' },
  { code: 'MC_ZANOM_Q028', icon: '📦', label: 'Risco de escalar sem estoque', description: 'VMD vs estoque — evitar ruptura por Ads agressivo', color: 'red' },
  { code: 'MC_ZANOM_Q029', icon: '🚚', label: 'FBA vs MFN na conversão', description: 'FBA converte melhor que envio próprio?', color: 'blue' },
  { code: 'MC_ZANOM_Q030', icon: '⛏️', label: 'Mineração em auto campaign', description: 'O que a campanha automática descobriu?', color: 'gold' },
  { code: 'MC_ZANOM_Q031', icon: '🔀', label: 'Termo vazando para exata', description: 'Broad/Phrase capturando termo que deveria ser EXACT', color: 'gold' },
  { code: 'MC_ZANOM_Q032', icon: '📋', label: 'Produto: clique bom, página ruim', description: 'Alta CTR + baixa CVR = diagnóstico de página', color: 'gold' },
  { code: 'MC_ZANOM_Q033', icon: '📦', label: 'Kit vs unitário', description: 'Kit vende melhor que produto unitário?', color: 'blue' },
  { code: 'MC_ZANOM_Q034', icon: '⚡', label: 'Canibalização entre campanhas', description: 'Campanhas competindo pela mesma venda', color: 'red' },
  { code: 'MC_ZANOM_Q035', icon: '🧩', label: 'Produto complementar', description: 'Quais complementares atacar com product targeting?', color: 'green' },
  { code: 'MC_ZANOM_Q036', icon: '💡', label: 'Intenção de uso', description: 'Qual intenção (mala, chave, pet…) converte mais?', color: 'blue' },
  { code: 'MC_ZANOM_Q037', icon: '📐', label: 'Escalabilidade por campanha', description: 'Qual aguenta mais verba sem quebrar ROAS?', color: 'green' },
  { code: 'MC_ZANOM_Q038', icon: '🔭', label: 'Boa mas pequena', description: 'Campanha com ROAS alto e volume baixo — escalar?', color: 'green' },
  { code: 'MC_ZANOM_Q039', icon: '👆', label: 'Muito clique, pouca venda', description: 'Alta CTR de campanha + baixa CVR = problema de oferta', color: 'gold' },
  { code: 'MC_ZANOM_Q040', icon: '📋', label: 'Plano de ação diário', description: 'O que cortar, proteger e escalar hoje', color: 'green' },
]

const COLOR_BORDER = {
  green: 'var(--green)', red: 'var(--red)', blue: 'var(--blue)',
  purple: '#b35bff', gold: '#f5a623',
}

function statusIcon(status) {
  if (['SUCCEEDED', 'INSIGHTS_GENERATED', 'MODELING_COMPLETED'].includes(status)) return '✓'
  if (['QUEUED', 'CREATED'].includes(status)) return '⏳'
  if (['SUBMITTED', 'RUNNING'].includes(status)) return '⟳'
  if (status === 'FAILED') return '✗'
  return '·'
}

export default function Queries({ ctx }) {
  const { tenantID, storeID } = ctx
  const [templates, setTemplates] = useState([])
  const [runs, setRuns]           = useState([])
  const [loadingT, setLoadingT]   = useState(true)
  const [creating, setCreating]   = useState({})
  const [runningAll, setRunningAll] = useState(false)
  const [runAllProgress, setRunAllProgress] = useState(null)
  const [dateStart, setDateStart] = useState('2026-05-31')
  const [dateEnd, setDateEnd]     = useState('2026-07-05')
  const pollRef = useRef(null)

  const loadRuns = async () => {
    const r = await api.listRuns(tenantID, storeID)
    if (r.ok) {
      const items = r.data.items || r.data || []
      setRuns(items)
      return items
    }
    return []
  }

  useEffect(() => {
    if (!tenantID) return
    api.listTemplates(tenantID).then(r => {
      if (r.ok) setTemplates(r.data.items || r.data || [])
      setLoadingT(false)
    })
    loadRuns()
  }, [tenantID, storeID])

  // Auto-refresh while there are active runs
  useEffect(() => {
    const hasActive = runs.some(r => ACTIVE_STATUSES.has(r.status))
    if (hasActive && !pollRef.current) {
      pollRef.current = setInterval(() => loadRuns(), 15000)
    } else if (!hasActive && pollRef.current) {
      clearInterval(pollRef.current)
      pollRef.current = null
    }
    return () => { if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null } }
  }, [runs])

  const periodParams = () => ({ period_start: dateStart, period_end: dateEnd })

  const runByCode = async (code) => {
    if (!storeID) return
    const tpl = templates.find(t => t.code === code)
    if (!tpl) return
    setCreating(c => ({ ...c, [code]: true }))
    await api.createRun(tenantID, {
      store_id: storeID,
      template_id: tpl.id,
      parameters: periodParams(),
    })
    setCreating(c => { const n = { ...c }; delete n[code]; return n })
    loadRuns()
  }

  const runAll = async () => {
    if (!storeID || runningAll) return
    const confirm = window.confirm(`Enfileirar todas as ${templates.length} queries?\nPeríodo: ${dateStart} → ${dateEnd}\nO AMC vai processar em lotes de 5.`)
    if (!confirm) return

    setRunningAll(true)
    setRunAllProgress({ done: 0, total: templates.length, errors: 0 })

    for (let i = 0; i < templates.length; i++) {
      const tpl = templates[i]
      const r = await api.createRun(tenantID, {
        store_id: storeID,
        template_id: tpl.id,
        parameters: periodParams(),
      })
      setRunAllProgress(p => ({
        ...p,
        done: i + 1,
        errors: p.errors + (r.ok ? 0 : 1),
      }))
      // small pause to not overwhelm the API
      await new Promise(res => setTimeout(res, 80))
    }

    setRunningAll(false)
    setRunAllProgress(null)
    loadRuns()
  }

  const runsByCode = {}
  runs.forEach(run => {
    const tpl = templates.find(t => t.id === run.template_id)
    if (tpl?.code && !runsByCode[tpl.code]) runsByCode[tpl.code] = run
  })

  const activeCount  = runs.filter(r => ACTIVE_STATUSES.has(r.status)).length
  const doneCount    = runs.filter(r => ['SUCCEEDED','INSIGHTS_GENERATED','MODELING_COMPLETED'].includes(r.status)).length
  const failedCount  = runs.filter(r => r.status === 'FAILED').length

  return (
    <div>
      {/* ── Header ─────────────────────────────────────────────────── */}
      <div className="topbar">
        <div>
          <h2>AMC Queries</h2>
          <p>
            {templates.length} templates
            {runs.length > 0 && (
              <>
                {' • '}
                {activeCount > 0 && <span style={{ color: '#f5a623' }}>{activeCount} rodando</span>}
                {activeCount > 0 && (doneCount > 0 || failedCount > 0) && ' • '}
                {doneCount > 0 && <span style={{ color: 'var(--green)' }}>{doneCount} concluídos</span>}
                {failedCount > 0 && <span style={{ color: 'var(--red)', marginLeft: 4 }}>{failedCount} com erro</span>}
              </>
            )}
          </p>
        </div>
        <div className="actions" style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--muted)' }}>
            <label style={{ fontWeight: 600, color: 'var(--fg)' }}>De</label>
            <input
              type="date"
              value={dateStart}
              onChange={e => setDateStart(e.target.value)}
              style={{ padding: '5px 8px', fontSize: 12, borderRadius: 6, border: '1px solid var(--line)', background: 'var(--card)', color: 'var(--fg)' }}
            />
            <label style={{ fontWeight: 600, color: 'var(--fg)' }}>até</label>
            <input
              type="date"
              value={dateEnd}
              onChange={e => setDateEnd(e.target.value)}
              style={{ padding: '5px 8px', fontSize: 12, borderRadius: 6, border: '1px solid var(--line)', background: 'var(--card)', color: 'var(--fg)' }}
            />
          </div>
          {runAllProgress ? (
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 13, color: 'var(--muted)' }}>
              <span style={{ color: '#f5a623' }}>Enfileirando… {runAllProgress.done}/{runAllProgress.total}</span>
              <div style={{ width: 120, height: 4, background: 'var(--line)', borderRadius: 2 }}>
                <div style={{ width: `${(runAllProgress.done / runAllProgress.total) * 100}%`, height: '100%', background: '#f5a623', borderRadius: 2, transition: 'width .2s' }} />
              </div>
            </div>
          ) : (
            <button
              className="btn primary"
              onClick={runAll}
              disabled={!storeID || loadingT || runningAll}
              style={{ fontSize: 12 }}
            >
              ▶ Executar Todas ({templates.length})
            </button>
          )}
        </div>
      </div>

      {/* ── Status rápido ────────────────────────────────────────── */}
      {runs.length > 0 && (
        <div style={{ display: 'flex', gap: 10, marginBottom: 20, flexWrap: 'wrap' }}>
          {activeCount > 0 && (
            <div className="card" style={{ flex: '0 0 auto', padding: '10px 18px', minWidth: 120 }}>
              <div className="k">Rodando / Na fila</div>
              <div className="v" style={{ color: '#f5a623' }}>{activeCount}</div>
            </div>
          )}
          {doneCount > 0 && (
            <div className="card" style={{ flex: '0 0 auto', padding: '10px 18px', minWidth: 120 }}>
              <div className="k">Concluídos</div>
              <div className="v" style={{ color: 'var(--green)' }}>{doneCount}</div>
            </div>
          )}
          {failedCount > 0 && (
            <div className="card" style={{ flex: '0 0 auto', padding: '10px 18px', minWidth: 120 }}>
              <div className="k">Com erro</div>
              <div className="v" style={{ color: 'var(--red)' }}>{failedCount}</div>
            </div>
          )}
          {activeCount > 0 && (
            <div style={{ display: 'flex', alignItems: 'center', fontSize: 12, color: 'var(--muted)', paddingLeft: 4 }}>
              ↻ atualizando a cada 15s
            </div>
          )}
        </div>
      )}

      {/* ── Grid de todas as 40 queries ──────────────────────────── */}
      <div className="panel" style={{ marginBottom: 20 }}>
        <div className="panel-head" style={{ marginBottom: 16 }}>
          <h3>Todas as queries ZANOM</h3>
          <span className="pill blue" style={{ fontSize: 11 }}>{OPERATIONS.length} queries</span>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 10 }}>
          {OPERATIONS.map(op => {
            const run  = runsByCode[op.code]
            const busy = creating[op.code]
            const hasTpl = templates.some(t => t.code === op.code)
            const status = run?.status
            return (
              <div
                key={op.code}
                style={{
                  border: `1px solid var(--line)`,
                  borderLeft: `3px solid ${COLOR_BORDER[op.color] || 'var(--line)'}`,
                  borderRadius: 10,
                  padding: '12px 14px',
                  background: status && ['SUCCEEDED','INSIGHTS_GENERATED'].includes(status)
                    ? 'rgba(52,211,153,.04)'
                    : ACTIVE_STATUSES.has(status)
                    ? 'rgba(245,166,35,.04)'
                    : 'rgba(255,255,255,.02)',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 6,
                }}
              >
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
                  <span style={{ fontSize: 18, flexShrink: 0 }}>{op.icon}</span>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 700, fontSize: 12, lineHeight: 1.3, marginBottom: 3 }}>{op.label}</div>
                    <div style={{ color: 'var(--muted)', fontSize: 10, lineHeight: 1.4 }}>{op.description}</div>
                  </div>
                </div>

                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 2 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                    <span className="pill" style={{ fontSize: 9, padding: '1px 5px' }}>{op.code}</span>
                    {status && (
                      <span
                        className={`pill ${STATUS_COLOR[status] || 'gold'}`}
                        style={{ fontSize: 9, padding: '1px 5px' }}
                        title={run?.created_at ? new Date(run.created_at).toLocaleString('pt-BR') : ''}
                      >
                        {statusIcon(status)} {status.replace(/_/g, ' ')}
                      </span>
                    )}
                  </div>
                  <button
                    className="btn"
                    style={{
                      fontSize: 10,
                      padding: '4px 10px',
                      borderColor: COLOR_BORDER[op.color],
                      color: COLOR_BORDER[op.color],
                    }}
                    disabled={busy || !storeID || loadingT || ACTIVE_STATUSES.has(status)}
                    onClick={() => runByCode(op.code)}
                  >
                    {busy ? '…' : ACTIVE_STATUSES.has(status) ? '⟳' : hasTpl ? 'Run' : '?'}
                  </button>
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* ── Histórico de Runs ─────────────────────────────────────── */}
      {runs.length > 0 && (
        <div className="panel">
          <div className="panel-head">
            <h3>Histórico de Runs</h3>
            <span className="pill">{runs.length}</span>
          </div>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Query</th>
                  <th>Status</th>
                  <th>Criado em</th>
                  <th>Concluído</th>
                </tr>
              </thead>
              <tbody>
                {runs.slice().reverse().map(run => {
                  const tpl = templates.find(t => t.id === run.template_id)
                  const op  = OPERATIONS.find(o => o.code === tpl?.code)
                  return (
                    <tr key={run.id}>
                      <td style={{ fontSize: 11 }}>
                        {op?.icon && <span style={{ marginRight: 5 }}>{op.icon}</span>}
                        {tpl?.code || run.template_id?.substring(0, 8) + '…'}
                      </td>
                      <td>
                        <span className={`pill ${STATUS_COLOR[run.status] || 'gold'}`} style={{ fontSize: 10 }}>
                          {statusIcon(run.status)} {run.status.replace(/_/g, ' ')}
                        </span>
                      </td>
                      <td style={{ color: 'var(--muted)', fontSize: 11 }}>
                        {run.created_at ? new Date(run.created_at).toLocaleString('pt-BR') : '—'}
                      </td>
                      <td style={{ color: 'var(--muted)', fontSize: 11 }}>
                        {run.finished_at ? new Date(run.finished_at).toLocaleString('pt-BR') : '—'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  )
}
