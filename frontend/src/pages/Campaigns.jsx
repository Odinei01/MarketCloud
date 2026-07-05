import { useState, useEffect } from 'react'
import { api } from '../api/client.js'

const ROLES = ['ALL', 'CONVERSION', 'ASSISTED_CONVERSION', 'DISCOVERY', 'REMARKETING', 'WASTE', 'UNKNOWN']

const ROLE_COLOR = {
  CONVERSION: 'green', DISCOVERY: 'blue', ASSISTED_CONVERSION: 'purple',
  REMARKETING: 'gold', WASTE: 'red', UNKNOWN: '',
}

// Derive campaign list from recommendations since there's no dedicated /campaigns endpoint yet
function campaignsFromRecs(recs) {
  const map = new Map()
  for (const r of recs) {
    if (!map.has(r.target_id)) {
      map.set(r.target_id, {
        id: r.target_id,
        name: r.target_name,
        role: null,
        confidence: 0,
        recs: [],
        evidence: r.impact_estimate || {},
      })
    }
    map.get(r.target_id).recs.push(r)
    if (r.confidence > map.get(r.target_id).confidence) {
      map.get(r.target_id).confidence = r.confidence
    }
  }
  // Infer role from action_type
  for (const c of map.values()) {
    const actions = c.recs.map(r => r.action_type)
    if (actions.includes('INCREASE_BUDGET')) c.role = 'CONVERSION'
    else if (actions.includes('DO_NOT_PAUSE')) c.role = c.recs[0]?.action_type === 'CREATE_AUDIENCE' ? 'REMARKETING' : 'ASSISTED_CONVERSION'
    else if (actions.includes('CREATE_AUDIENCE')) c.role = 'REMARKETING'
    else if (actions.includes('DECREASE_BID') || actions.includes('DECREASE_BUDGET')) c.role = 'WASTE'
    else c.role = 'UNKNOWN'
  }
  return [...map.values()]
}

export default function Campaigns({ ctx }) {
  const { tenantID, storeID } = ctx
  const [campaigns, setCampaigns] = useState([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState('ALL')
  const [search, setSearch] = useState('')

  useEffect(() => {
    if (!tenantID) return
    setLoading(true)
    api.listRecs(tenantID, storeID).then(r => {
      if (r.ok) setCampaigns(campaignsFromRecs(r.data.items || []))
      setLoading(false)
    })
  }, [tenantID, storeID])

  const filtered = campaigns.filter(c => {
    if (filter !== 'ALL' && c.role !== filter) return false
    if (search && !c.name.toLowerCase().includes(search.toLowerCase())) return false
    return true
  })

  const counts = {}
  ROLES.forEach(r => { counts[r] = r === 'ALL' ? campaigns.length : campaigns.filter(c => c.role === r).length })

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Campanhas</h2>
          <p>{campaigns.length} campanha{campaigns.length !== 1 ? 's' : ''} classificada{campaigns.length !== 1 ? 's' : ''} pelo modelo</p>
        </div>
        <div className="actions">
          <input
            style={{ width: 200, fontSize: 13 }}
            placeholder="Buscar campanha..."
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 20, flexWrap: 'wrap' }}>
        {ROLES.map(role => (
          <button
            key={role}
            className={`btn ${filter === role ? 'primary' : ''}`}
            onClick={() => setFilter(role)}
            style={{ fontSize: 12 }}
          >
            {role === 'ALL' ? 'Todos' : role.replace('_', ' ')} ({counts[role]})
          </button>
        ))}
      </div>

      {loading ? (
        <div className="loading"><div className="spinner" /><div>Carregando campanhas...</div></div>
      ) : filtered.length === 0 ? (
        <div className="panel" style={{ padding: 48, textAlign: 'center' }}>
          <p style={{ color: 'var(--muted)', fontSize: 15 }}>
            {campaigns.length === 0
              ? 'Nenhuma campanha classificada ainda. Execute um query run para ativar o modelo.'
              : 'Nenhuma campanha com os filtros selecionados.'}
          </p>
        </div>
      ) : (
        <div className="panel">
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Campanha</th>
                  <th>Papel</th>
                  <th>Recomendações</th>
                  <th>Confiança</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map(c => (
                  <tr key={c.id}>
                    <td style={{ fontWeight: 700 }}>{c.name}</td>
                    <td>
                      <span className={`pill ${ROLE_COLOR[c.role] || ''}`}>{c.role}</span>
                    </td>
                    <td>
                      {c.recs.map(r => (
                        <span key={r.id} className={`pill`} style={{ marginRight: 4, fontSize: 10 }}>
                          {r.action_type}
                        </span>
                      ))}
                    </td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div className="bar" style={{ flex: 1, minWidth: 80 }}>
                          <div className={`fill ${ROLE_COLOR[c.role] || 'blue'}`} style={{ width: `${c.confidence * 100}%` }} />
                        </div>
                        <span style={{ fontSize: 11, color: 'var(--muted)', minWidth: 32 }}>
                          {(c.confidence * 100).toFixed(0)}%
                        </span>
                      </div>
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
