import { useState, useEffect } from 'react'
import { api } from '../api/client.js'

const STATUS_COLOR = {
  INSIGHTS_GENERATED: 'green', MODELING_COMPLETED: 'green', MODELING_STARTED: 'blue',
  SUCCEEDED: 'blue', RUNNING: 'gold', SUBMITTED: 'gold', QUEUED: 'gold',
  CREATED: 'gold', FAILED: 'red', RESULT_DOWNLOADED: 'blue',
}

// 12 operational buttons — each maps to one or more query codes
const OPERATIONS = [
  {
    code: 'MC_ZANOM_Q001',
    icon: '🔥',
    label: 'Encontrar dinheiro queimado',
    description: 'Campanhas com gasto e zero venda direta ou assistida',
    color: 'red',
    params: { lookback_days: 14, min_spend: 30 },
  },
  {
    code: 'MC_ZANOM_Q002',
    icon: '🚫',
    label: 'Encontrar termos para negativar',
    description: 'Keywords e search terms que gastam sem converter',
    color: 'red',
    params: { lookback_days: 14, min_spend: 20, min_clicks: 8 },
  },
  {
    code: 'MC_ZANOM_Q003',
    icon: '🎯',
    label: 'Encontrar termos para virar exata',
    description: 'Search terms convertendo via broad/phrase — promover para EXACT',
    color: 'green',
    params: { lookback_days: 14, target_roas: 5.0, min_orders_exact: 1 },
  },
  {
    code: 'MC_ZANOM_Q005',
    icon: '🛡️',
    label: 'Proteger campanhas que assistem venda',
    description: 'Campanhas com ROAS direto ruim mas assist_rate ≥ 30%',
    color: 'purple',
    params: { lookback_days: 14, target_roas: 5.0, assist_rate_threshold: 0.30 },
  },
  {
    code: 'MC_ZANOM_Q006',
    icon: '📊',
    label: 'Classificar keywords por funil',
    description: 'Cada keyword: DISCOVERY / CONSIDERATION / CONVERSION / WASTE',
    color: 'blue',
    params: { lookback_days: 14, min_spend: 15 },
  },
  {
    code: 'MC_ZANOM_Q007',
    icon: '🗺️',
    label: 'Ver jornada até compra',
    description: 'Sequência de campanhas tocadas antes da conversão',
    color: 'blue',
    params: { lookback_days: 30 },
  },
  {
    code: 'MC_ZANOM_Q013',
    icon: '🕐',
    label: 'Ver horário ruim',
    description: 'Horários com gasto alto e zero conversão — base para circuit breaker',
    color: 'gold',
    params: { lookback_days: 7, min_spend_hour: 5 },
  },
  {
    code: 'MC_ZANOM_Q009',
    icon: '💰',
    label: 'Ver campanha sem orçamento',
    description: 'Campanhas boas esgotando budget cedo — oportunidade de escalar',
    color: 'gold',
    params: { lookback_days: 7, target_roas: 5.0 },
  },
  {
    code: 'MC_ZANOM_Q010',
    icon: '📍',
    label: 'Ver topo de busca',
    description: 'Top of Search está vendendo ou só encarecendo CPC?',
    color: 'blue',
    params: { lookback_days: 14, target_roas: 5.0 },
  },
  {
    code: 'MC_ZANOM_Q024',
    icon: '💸',
    label: 'Ver CPC caro pelo ticket',
    description: 'CPC acima do break-even por ticket e margem do produto',
    color: 'red',
    params: { lookback_days: 14 },
  },
  {
    code: 'MC_ZANOM_Q028',
    icon: '📦',
    label: 'Ver risco de escalar sem estoque',
    description: 'Cruzar VMD com estoque — evitar ruptura por Ads agressivo',
    color: 'red',
    params: { lookback_days: 7 },
  },
  {
    code: 'MC_ZANOM_Q040',
    icon: '📋',
    label: 'Gerar plano de ação diário',
    description: 'Resumo executivo: o que cortar, proteger e escalar hoje',
    color: 'green',
    params: { lookback_days: 1 },
  },
]

const COLOR_BORDER = {
  green: 'var(--green)',
  red: 'var(--red)',
  blue: 'var(--blue)',
  purple: '#b35bff',
  gold: '#f5a623',
}

export default function Queries({ ctx }) {
  const { tenantID, storeID } = ctx
  const [templates, setTemplates] = useState([])
  const [runs, setRuns]           = useState([])
  const [loadingT, setLoadingT]   = useState(true)
  const [loadingR, setLoadingR]   = useState(true)
  const [creating, setCreating]   = useState({})
  const [showCatalog, setShowCatalog] = useState(false)
  const [selectedT, setSelectedT] = useState(null)
  const [createErr, setCreateErr] = useState('')

  const loadRuns = async () => {
    const r = await api.listRuns(tenantID, storeID)
    if (r.ok) setRuns(r.data.items || r.data || [])
    setLoadingR(false)
  }

  useEffect(() => {
    if (!tenantID) return
    api.listTemplates(tenantID).then(r => {
      if (r.ok) setTemplates(r.data.items || r.data || [])
      setLoadingT(false)
    })
    loadRuns()
  }, [tenantID, storeID])

  const runByCode = async (op) => {
    if (!storeID) return
    const tpl = templates.find(t => t.code === op.code)
    if (!tpl) {
      alert(`Template ${op.code} não encontrado. Verifique se a migration 010 foi aplicada.`)
      return
    }
    setCreating(c => ({ ...c, [op.code]: true }))
    const r = await api.createRun(tenantID, {
      store_id: storeID,
      template_id: tpl.id,
      parameters: { lookback_days: op.params.lookback_days || 14, ...op.params },
    })
    setCreating(c => { const n = { ...c }; delete n[op.code]; return n })
    if (!r.ok) {
      alert(r.data?.error || `Erro ao criar run para ${op.code}`)
      return
    }
    loadRuns()
  }

  const createRunFromTemplate = async () => {
    if (!selectedT || !storeID) return
    setCreating(c => ({ ...c, catalog: true })); setCreateErr('')
    const r = await api.createRun(tenantID, {
      store_id: storeID,
      template_id: selectedT.id,
      parameters: { lookback_days: 30 },
    })
    setCreating(c => { const n = { ...c }; delete n.catalog; return n })
    if (!r.ok) { setCreateErr(r.data?.error || 'Erro ao criar run'); return }
    loadRuns()
    setSelectedT(null)
  }

  const recentRuns = runs.slice().reverse().slice(0, 12)

  const lastRunFor = (code) => {
    const tpl = templates.find(t => t.code === code)
    if (!tpl) return null
    return recentRuns.find(r => r.template_id === tpl.id) || null
  }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Query Catalog</h2>
          <p>{templates.length} template{templates.length !== 1 ? 's' : ''} disponíve{templates.length !== 1 ? 'is' : 'l'} • {runs.length} run{runs.length !== 1 ? 's' : ''} executado{runs.length !== 1 ? 's' : ''}</p>
        </div>
      </div>

      {/* ── Operational buttons ─────────────────────────────────────── */}
      <div className="panel" style={{ marginBottom: 20 }}>
        <div className="panel-head" style={{ marginBottom: 16 }}>
          <h3>Operações ZANOM</h3>
          {!storeID && <span className="pill red" style={{ fontSize: 11 }}>Selecione uma loja</span>}
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 12 }}>
          {OPERATIONS.map(op => {
            const last = lastRunFor(op.code)
            const busy = creating[op.code]
            const hasTpl = templates.some(t => t.code === op.code)
            return (
              <div
                key={op.code}
                style={{
                  border: `1px solid var(--line)`,
                  borderLeft: `3px solid ${COLOR_BORDER[op.color] || 'var(--line)'}`,
                  borderRadius: 10,
                  padding: '14px 16px',
                  background: 'rgba(255,255,255,.02)',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 8,
                }}
              >
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
                  <span style={{ fontSize: 20, flexShrink: 0 }}>{op.icon}</span>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 700, fontSize: 13, lineHeight: 1.3, marginBottom: 4 }}>
                      {op.label}
                    </div>
                    <div style={{ color: 'var(--muted)', fontSize: 11, lineHeight: 1.4 }}>
                      {op.description}
                    </div>
                  </div>
                </div>

                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 4 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span className="pill" style={{ fontSize: 10, padding: '2px 6px' }}>{op.code}</span>
                    {last && (
                      <span
                        className={`pill ${STATUS_COLOR[last.status] || 'gold'}`}
                        style={{ fontSize: 10, padding: '2px 6px' }}
                        title={new Date(last.created_at).toLocaleString('pt-BR')}
                      >
                        {last.status.replace('_', ' ')}
                      </span>
                    )}
                  </div>
                  <button
                    className={`btn ${op.color === 'green' ? 'primary' : ''}`}
                    style={{
                      fontSize: 11,
                      padding: '5px 12px',
                      ...(op.color !== 'green' ? { borderColor: COLOR_BORDER[op.color], color: COLOR_BORDER[op.color] } : {}),
                    }}
                    disabled={busy || !storeID || loadingT}
                    onClick={() => runByCode(op)}
                  >
                    {busy ? '...' : hasTpl ? 'Executar' : 'Migration pendente'}
                  </button>
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {/* ── Runs + Catalog ─────────────────────────────────────────── */}
      <div className="grid two">
        {/* Runs history */}
        <div className="panel">
          <div className="panel-head">
            <h3>Histórico de Runs</h3>
            <span className="pill">{runs.length}</span>
          </div>
          {loadingR ? (
            <div className="empty">Carregando...</div>
          ) : runs.length === 0 ? (
            <div className="empty">Nenhum run executado. Clique em uma operação acima.</div>
          ) : (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Query</th>
                    <th>Status</th>
                    <th>Criado em</th>
                  </tr>
                </thead>
                <tbody>
                  {recentRuns.map(run => {
                    const tpl = templates.find(t => t.id === run.template_id)
                    const op  = OPERATIONS.find(o => o.code === tpl?.code)
                    return (
                      <tr key={run.id}>
                        <td style={{ fontSize: 12 }}>
                          {op?.icon && <span style={{ marginRight: 6 }}>{op.icon}</span>}
                          {tpl?.code
                            ? <span title={tpl.name}>{tpl.code}</span>
                            : <span style={{ color: 'var(--muted)' }}>{run.template_id?.substring(0, 8)}…</span>
                          }
                        </td>
                        <td>
                          <span className={`pill ${STATUS_COLOR[run.status] || 'gold'}`} style={{ fontSize: 10 }}>
                            {run.status.replace(/_/g, ' ')}
                          </span>
                        </td>
                        <td style={{ color: 'var(--muted)', fontSize: 11 }}>
                          {run.created_at ? new Date(run.created_at).toLocaleString('pt-BR') : '—'}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Full catalog (collapsed by default) */}
        <div className="panel">
          <div
            className="panel-head"
            style={{ cursor: 'pointer', userSelect: 'none' }}
            onClick={() => setShowCatalog(v => !v)}
          >
            <h3>Catálogo Completo</h3>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span className="pill blue">{templates.length}</span>
              <span style={{ color: 'var(--muted)', fontSize: 13 }}>{showCatalog ? '▲' : '▼'}</span>
            </div>
          </div>

          {!showCatalog ? (
            <div className="empty" style={{ cursor: 'pointer' }} onClick={() => setShowCatalog(true)}>
              Clique para ver todos os {templates.length} templates disponíveis
            </div>
          ) : loadingT ? (
            <div className="empty">Carregando...</div>
          ) : templates.length === 0 ? (
            <div className="empty">Nenhum template. Aplique as migrations 008 e 010.</div>
          ) : (
            <div style={{ padding: '4px 0', maxHeight: 480, overflowY: 'auto' }}>
              {templates.map(t => (
                <div
                  key={t.id}
                  style={{
                    padding: '10px 14px', cursor: 'pointer', borderBottom: '1px solid var(--line)',
                    background: selectedT?.id === t.id ? 'rgba(110,168,255,.08)' : 'transparent',
                    borderLeft: selectedT?.id === t.id ? '3px solid var(--blue)' : '3px solid transparent',
                  }}
                  onClick={() => setSelectedT(selectedT?.id === t.id ? null : t)}
                >
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <span style={{ fontWeight: 600, fontSize: 12 }}>{t.code || t.name}</span>
                    <div style={{ display: 'flex', gap: 5 }}>
                      <span className="pill blue" style={{ fontSize: 9, padding: '2px 5px' }}>{t.query_family}</span>
                    </div>
                  </div>
                  {t.description && (
                    <p style={{ color: 'var(--muted)', fontSize: 11, marginTop: 3, lineHeight: 1.4 }}>{t.description}</p>
                  )}
                  {selectedT?.id === t.id && (
                    <div style={{ marginTop: 10 }}>
                      {createErr && <div style={{ color: 'var(--red)', fontSize: 12, marginBottom: 8 }}>{createErr}</div>}
                      <button className="btn primary" style={{ fontSize: 11 }} onClick={createRunFromTemplate} disabled={creating.catalog || !storeID}>
                        {creating.catalog ? 'Criando...' : storeID ? 'Executar Run' : 'Selecione uma loja'}
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
