import { useState, useEffect } from 'react'
import { api } from '../api/client.js'

const ACTION_COLOR = {
  INCREASE_BUDGET: 'green', DECREASE_BUDGET: 'red', INCREASE_BID: 'green',
  DECREASE_BID: 'red', DO_NOT_PAUSE: 'purple', CREATE_AUDIENCE: 'blue', DO_NOT_BUY_QUALITY: 'orange',
}

export default function Recommendations({ ctx }) {
  const { tenantID, storeID } = ctx
  const [recs, setRecs]       = useState([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter]   = useState('PENDING')
  const [actioning, setActioning] = useState({})

  const load = async () => {
    setLoading(true)
    const r = await api.listRecs(tenantID, storeID)
    if (r.ok) setRecs(r.data.items || [])
    setLoading(false)
  }

  useEffect(() => { if (tenantID) load() }, [tenantID, storeID])

  const act = async (id, action) => {
    setActioning(a => ({ ...a, [id]: action }))
    const fn = action === 'approve' ? api.approveRec : api.rejectRec
    await fn(tenantID, id)
    setActioning(a => { const n = { ...a }; delete n[id]; return n })
    load()
  }

  const counts = { PENDING: 0, APPROVED: 0, REJECTED: 0 }
  recs.forEach(r => { if (counts[r.status] !== undefined) counts[r.status]++ })

  const displayed = filter ? recs.filter(r => r.status === filter) : recs

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Recomendações</h2>
          <p>{counts.PENDING} pendente{counts.PENDING !== 1 ? 's' : ''} • {counts.APPROVED} aprovada{counts.APPROVED !== 1 ? 's' : ''} • {counts.REJECTED} rejeitada{counts.REJECTED !== 1 ? 's' : ''}</p>
        </div>
        <div className="actions">
          {[['PENDING', 'Pendentes'], ['APPROVED', 'Aprovadas'], ['REJECTED', 'Rejeitadas'], ['', 'Todas']].map(([s, label]) => (
            <button key={label} className={`btn ${filter === s ? 'primary' : ''}`} onClick={() => setFilter(s)}>
              {label}
            </button>
          ))}
        </div>
      </div>

      {loading ? (
        <div className="loading"><div className="spinner" /><div>Carregando recomendações...</div></div>
      ) : displayed.length === 0 ? (
        <div className="panel" style={{ padding: 48, textAlign: 'center' }}>
          <p style={{ color: 'var(--muted)', fontSize: 15 }}>
            {recs.length === 0 ? 'Nenhuma recomendação gerada ainda. Execute um query run.' : `Nenhuma recomendação ${filter ? `com status "${filter}"` : ''}.`}
          </p>
        </div>
      ) : (
        <div className="panel">
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Campanha</th>
                  <th>Ação</th>
                  <th>Motivo</th>
                  <th>Confiança</th>
                  <th>Status</th>
                  <th>Ações</th>
                </tr>
              </thead>
              <tbody>
                {displayed.map(rec => (
                  <tr key={rec.id}>
                    <td style={{ fontWeight: 700 }}>{rec.target_name}</td>
                    <td>
                      <span className={`pill ${ACTION_COLOR[rec.action_type] || ''}`}>{rec.action_type}</span>
                    </td>
                    <td style={{ color: 'var(--muted)', fontSize: 12, maxWidth: 280 }}>{rec.reason}</td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div className="bar" style={{ flex: 1, minWidth: 60 }}>
                          <div className="fill green" style={{ width: `${(rec.confidence || 0) * 100}%` }} />
                        </div>
                        <span style={{ fontSize: 11, color: 'var(--muted)', minWidth: 32 }}>
                          {((rec.confidence || 0) * 100).toFixed(0)}%
                        </span>
                      </div>
                    </td>
                    <td>
                      <span className={`pill ${rec.status === 'APPROVED' ? 'green' : rec.status === 'REJECTED' ? 'red' : 'gold'}`}>
                        {rec.status}
                      </span>
                    </td>
                    <td>
                      {rec.status === 'PENDING' ? (
                        <div style={{ display: 'flex', gap: 6 }}>
                          <button
                            className="btn primary" style={{ padding: '5px 12px', fontSize: 11 }}
                            disabled={!!actioning[rec.id]}
                            onClick={() => act(rec.id, 'approve')}
                          >
                            {actioning[rec.id] === 'approve' ? '...' : 'Aprovar'}
                          </button>
                          <button
                            className="btn" style={{ padding: '5px 12px', fontSize: 11, color: 'var(--red)', borderColor: 'var(--red)' }}
                            disabled={!!actioning[rec.id]}
                            onClick={() => act(rec.id, 'reject')}
                          >
                            {actioning[rec.id] === 'reject' ? '...' : 'Rejeitar'}
                          </button>
                        </div>
                      ) : (
                        <span style={{ color: 'var(--muted)', fontSize: 12 }}>—</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  )
}
