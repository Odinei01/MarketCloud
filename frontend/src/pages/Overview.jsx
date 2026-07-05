import { useState, useEffect } from 'react'
import { api } from '../api/client.js'

const ROLE_COLOR = {
  CONVERSION: 'green', DISCOVERY: 'blue',
  ASSISTED_CONVERSION: 'purple', REMARKETING: 'gold',
  WASTE: 'red', UNKNOWN: '',
}

function useData(fn, deps) {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    let cancelled = false
    setLoading(true)
    fn().then(r => { if (!cancelled && r.ok) setData(r.data); setLoading(false) })
    return () => { cancelled = true }
  }, deps)
  return [data, loading]
}

export default function Overview({ ctx }) {
  const { tenantID, storeID } = ctx
  const [stores, storesLoading]   = useData(() => api.listStores(tenantID), [tenantID])
  const [insights, insLoading]    = useData(() => api.listInsights(tenantID, storeID), [tenantID, storeID])
  const [recs, recsLoading]       = useData(() => api.listRecs(tenantID, storeID), [tenantID, storeID])
  const [runs, runsLoading]       = useData(() => api.listRuns(tenantID, storeID), [tenantID, storeID])
  const [camps, campsLoading]     = useData(
    () => fetch(`/api/v1/campaigns?store_id=${storeID}`, {
      headers: { Authorization: `Bearer ${localStorage.getItem('mc_token')}`, 'X-Tenant-ID': tenantID }
    }).then(r => r.json().then(d => ({ ok: r.ok, data: d }))),
    [tenantID, storeID]
  )

  const totalStores    = stores?.items?.length ?? stores?.total ?? 0
  const totalInsights  = insights?.items?.length ?? 0
  const pendingRecs    = recs?.items?.filter(r => r.status === 'PENDING').length ?? 0
  const totalRuns      = runs?.items?.length ?? 0
  const campaigns      = camps?.items ?? []

  // Compute top campaigns with metrics from insights
  const topCamps = campaigns.slice(0, 5)

  const loading = storesLoading || insLoading || recsLoading || runsLoading

  if (loading && !stores) {
    return <div className="loading"><div className="spinner" /><div>Carregando dados reais...</div></div>
  }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Visão Geral</h2>
          <p>MarketCloud Intelligence • dados reais do banco</p>
        </div>
        <div className="actions">
          <button className="btn">Exportar</button>
        </div>
      </div>

      <div className="grid cards">
        <div className="card">
          <div className="k">Lojas Cadastradas</div>
          <div className="v">{totalStores}</div>
          <div className="s" style={{ color: 'var(--muted)' }}>no tenant</div>
        </div>
        <div className="card">
          <div className="k">Campanhas</div>
          <div className="v">{campaigns.length || '—'}</div>
          <div className="s" style={{ color: 'var(--muted)' }}>nesta loja</div>
        </div>
        <div className="card">
          <div className="k">Insights Gerados</div>
          <div className="v" style={{ color: 'var(--blue)' }}>{totalInsights}</div>
          <div className="s"><span className="warn">{pendingRecs} recs pendentes</span></div>
        </div>
        <div className="card">
          <div className="k">AMC Query Runs</div>
          <div className="v" style={{ color: 'var(--purple)' }}>{totalRuns}</div>
          <div className="s" style={{ color: 'var(--muted)' }}>total na loja</div>
        </div>
      </div>

      <div className="gap" />

      <div className="grid two">
        <div className="panel">
          <div className="panel-head">
            <h3>Insights Recentes</h3>
            <span className="pill gold">{totalInsights} total</span>
          </div>
          {insights?.items?.length ? (
            <div className="insight-list" style={{ padding: 16 }}>
              {insights.items.slice(0, 5).map(ins => (
                <div className="insight" key={ins.id}>
                  <div className="meta">
                    <span className={`pill ${ins.severity === 'CRITICAL' ? 'red' : ins.severity === 'HIGH' ? 'orange' : ins.severity === 'INFO' ? 'green' : 'blue'}`}>
                      {ins.severity}
                    </span>
                    <span className="pill">{ins.insight_type}</span>
                  </div>
                  <h4>{ins.title}</h4>
                  <p>{ins.summary}</p>
                </div>
              ))}
            </div>
          ) : (
            <div className="empty">
              {insLoading ? 'Carregando...' : 'Nenhum insight gerado ainda. Crie um query run para gerar.'}
            </div>
          )}
        </div>

        <div style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
          <div className="panel">
            <div className="panel-head"><h3>Query Runs</h3></div>
            {runs?.items?.length ? (
              <div className="table-wrap">
                <table>
                  <thead><tr><th>Status</th><th>Criado</th></tr></thead>
                  <tbody>
                    {runs.items.slice(0, 5).map(r => (
                      <tr key={r.id}>
                        <td>
                          <span className={`pill ${r.status === 'INSIGHTS_GENERATED' ? 'green' : r.status === 'FAILED' ? 'red' : r.status === 'SUCCEEDED' ? 'blue' : 'gold'}`}>
                            {r.status}
                          </span>
                        </td>
                        <td style={{ color: 'var(--muted)', fontSize: 12 }}>
                          {new Date(r.created_at).toLocaleString('pt-BR')}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="empty">{runsLoading ? 'Carregando...' : 'Nenhum run ainda'}</div>
            )}
          </div>

          <div className="panel">
            <div className="panel-head"><h3>Recomendações Pendentes</h3></div>
            {recs?.items?.filter(r => r.status === 'PENDING').length ? (
              <div style={{ padding: '8px 16px' }}>
                {recs.items.filter(r => r.status === 'PENDING').slice(0, 4).map(r => (
                  <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '10px 0', borderBottom: '1px solid var(--line)', fontSize: 13 }}>
                    <span style={{ fontWeight: 700 }}>{r.target_name}</span>
                    <span className={`pill ${r.action_type === 'DO_NOT_PAUSE' ? 'purple' : r.action_type === 'CREATE_AUDIENCE' ? 'blue' : r.action_type.includes('DECREASE') ? 'red' : 'green'}`}>
                      {r.action_type}
                    </span>
                  </div>
                ))}
              </div>
            ) : (
              <div className="empty">{recsLoading ? 'Carregando...' : 'Nenhuma recomendação pendente'}</div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
