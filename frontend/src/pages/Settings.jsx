import { useCallback, useEffect, useState } from 'react'
import { api } from '../api/client.js'

function fmt(n, d = 0) {
  if (n === null || n === undefined || n === '') return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })
}

export default function Settings({ ctx }) {
  const { tenantID } = ctx
  const [tab, setTab] = useState('modeling')
  const [campaigns, setCampaigns] = useState([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState('')
  const [error, setError] = useState('')

  const loadFullAuto = useCallback(async () => {
    if (!tenantID) return
    setLoading(true)
    setError('')
    const res = await api.goldMlFullAutoCampaigns(tenantID)
    if (res.ok) {
      setCampaigns(res.data.items || [])
    } else {
      setError(res.data?.error || `HTTP ${res.status}`)
    }
    setLoading(false)
  }, [tenantID])

  useEffect(() => { loadFullAuto() }, [loadFullAuto])

  const toggleFullAuto = async (campaign, enabled) => {
    const key = campaign.campaign_name
    setSaving(key)
    setError('')
    const res = await api.setGoldMlFullAutoCampaign(tenantID, {
      campaign_id: campaign.campaign_id || '',
      campaign_name: campaign.campaign_name,
      enabled,
      notes: enabled ? 'Liberada para ML full-auto 360 pela tela Settings > Modeling.' : 'Full-auto 360 desligado pela tela.',
    })
    if (res.ok) {
      setCampaigns(prev => prev.map(it => it.campaign_name === campaign.campaign_name
        ? { ...it, full_auto_enabled: enabled, flag_updated_at: new Date().toISOString() }
        : it))
    } else {
      setError(res.data?.error || `HTTP ${res.status}`)
    }
    setSaving('')
  }

  const enabledCount = campaigns.filter(c => c.full_auto_enabled).length

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Configuracoes</h2>
          <p>Controles operacionais do MarketCloud</p>
        </div>
        <div className="actions">
          <button className="btn" onClick={loadFullAuto}>Atualizar</button>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 10, marginBottom: 20 }}>
        {['modeling', 'tenant', 'amazon', 'users'].map(t => (
          <button key={t} className={`btn ${tab === t ? 'primary' : ''}`} onClick={() => setTab(t)}>
            {{ modeling: 'Modeling', tenant: 'Tenant', amazon: 'Amazon Ads', users: 'Usuarios' }[t]}
          </button>
        ))}
      </div>

      {tab === 'modeling' && (
        <div className="grid two">
          <div className="panel">
            <div className="panel-head">
              <div>
                <h3>ML full-auto 360 por campanha</h3>
                <p style={{ margin: '4px 0 0', color: 'var(--muted)', fontSize: 13 }}>
                  Recomenda, aplica na Agenda de BIDs, monitora AMS e aprende com o resultado.
                </p>
              </div>
              <span className="pill green">{enabledCount} ligadas</span>
            </div>
            <div className="panel-body">
              <div className="notice">
                O modelo continua gerando predicoes para todas as campanhas. O bot so aplica automaticamente nas campanhas com a chave ligada abaixo.
              </div>
              {error && <div className="error-box">{error}</div>}
              {loading ? (
                <div className="empty">Carregando campanhas...</div>
              ) : (
                <div className="table-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th>Campanha</th>
                        <th>Score</th>
                        <th>Recs</th>
                        <th>Full auto</th>
                      </tr>
                    </thead>
                    <tbody>
                      {campaigns.map(c => (
                        <tr key={c.campaign_name}>
                          <td>
                            <div style={{ fontWeight: 800 }}>{c.campaign_name}</div>
                            <div className="muted">{c.campaign_id || 'sem campaign_id no lake'}</div>
                          </td>
                          <td>{fmt(c.max_priority_score, 0)}</td>
                          <td>{fmt(c.recommendation_rows)}</td>
                          <td>
                            <button
                              className={`toggle-btn ${c.full_auto_enabled ? 'on' : ''}`}
                              disabled={saving === c.campaign_name}
                              onClick={() => toggleFullAuto(c, !c.full_auto_enabled)}
                            >
                              {saving === c.campaign_name ? 'Salvando...' : c.full_auto_enabled ? 'Ligado' : 'Desligado'}
                            </button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          </div>

          <div className="panel">
            <div className="panel-head"><h3>Como ler as predicoes</h3></div>
            <div className="panel-body" style={{ display: 'grid', gap: 12 }}>
              <Info title="Predicao nao e alteracao">
                Uma predicao e uma linha avaliada pelo modelo. Exemplo: 50 campanhas x 24 horas = 1200 predicoes.
              </Info>
              <Info title="O que vira acao">
                Depois da predicao entram filtros: confianca, ML concorda, regra pendente, bid sugerido maior que o atual e campanha liberada no full-auto.
              </Info>
              <Info title="O que o 360 mede">
                A decisao aplicada e comparada com AMS depois de 1h, 3h e 24h para rotular se melhorou, piorou ou ficou neutro.
              </Info>
            </div>
          </div>
        </div>
      )}

      {tab !== 'modeling' && (
        <div className="panel">
          <div className="panel-head"><h3>{tab}</h3></div>
          <div className="panel-body">
            <div className="empty">Configuracao operacional ainda nao editavel nesta aba.</div>
          </div>
        </div>
      )}

      <style>{`
        .notice{padding:12px 14px;border:1px solid rgba(84,160,255,.35);background:rgba(84,160,255,.09);border-radius:8px;margin-bottom:12px;color:#b8d6ff;font-size:13px}
        .error-box{padding:10px 12px;border:1px solid rgba(255,84,112,.35);background:rgba(255,84,112,.10);border-radius:8px;margin-bottom:12px;color:#ff9bad;font-size:13px}
        .muted{color:var(--muted);font-size:12px;margin-top:3px}
        .empty{padding:24px;text-align:center;color:var(--muted)}
        .toggle-btn{min-width:92px;border:1px solid var(--border);background:#202838;color:#d8e5ff;border-radius:8px;padding:8px 10px;font-weight:800;cursor:pointer}
        .toggle-btn.on{background:#0b6b48;border-color:#159c70;color:#dfffee}
        .toggle-btn:disabled{opacity:.65;cursor:wait}
        .info-box{border:1px solid var(--border);background:rgba(255,255,255,.03);border-radius:8px;padding:12px}
        .info-title{font-weight:800;margin-bottom:4px}
        .info-body{color:var(--muted);font-size:13px;line-height:1.45}
      `}</style>
    </div>
  )
}

function Info({ title, children }) {
  return (
    <div className="info-box">
      <div className="info-title">{title}</div>
      <div className="info-body">{children}</div>
    </div>
  )
}
