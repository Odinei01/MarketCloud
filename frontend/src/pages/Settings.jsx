import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const MODES = [
  { value: 'advisor', label: 'Advisor', help: 'Somente recomenda. Nao aplica sozinho.' },
  { value: 'semi_auto', label: 'Semi-auto', help: 'Reservado para aprovacao assistida.' },
  { value: 'full_auto', label: 'Full-auto', help: 'Pode aplicar quando campanha tambem estiver liberada.' },
]

function fmt(n, d = 0) {
  if (n === null || n === undefined || n === '') return '-'
  return Number(n).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })
}

function fmtDateTime(value) {
  if (!value) return '-'
  return new Date(value).toLocaleString('pt-BR')
}

function statusClass(status) {
  if (status === 'ok') return 'green'
  if (status === 'error') return 'red'
  return 'orange'
}

function modeRank(mode) {
  return { advisor: 0, semi_auto: 1, full_auto: 2 }[mode] ?? 0
}

export default function Settings({ ctx }) {
  const { tenantID } = ctx
  const [tab, setTab] = useState('health')
  const [campaigns, setCampaigns] = useState([])
  const [fullControlProducts, setFullControlProducts] = useState([])
  const [fullControlGovernance, setFullControlGovernance] = useState([])
  const [fullControlMonitoring, setFullControlMonitoring] = useState({ pilots: [], actions: [] })
  const [selectedProductASIN, setSelectedProductASIN] = useState('')
  const [pilotDrafts, setPilotDrafts] = useState({})
  const [settings, setSettings] = useState(null)
  const [health, setHealth] = useState([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState('')
  const [saveNotice, setSaveNotice] = useState('')
  const [error, setError] = useState('')

  const loadAll = useCallback(async () => {
    if (!tenantID) return
    setLoading(true)
    setError('')
    const [campaignRes, settingsRes, healthRes, fullControlRes, fullControlGovRes, fullControlMonitoringRes] = await Promise.all([
      api.goldMlFullAutoCampaigns(tenantID),
      api.tenantSettings(tenantID),
      api.tenantHealth(tenantID),
      api.fullControlProducts(tenantID),
      api.fullControlGovernance(tenantID),
      api.fullControlMonitoring(tenantID),
    ])
    if (campaignRes.ok) setCampaigns(campaignRes.data.items || [])
    else setError(campaignRes.data?.error || `HTTP ${campaignRes.status}`)
    if (settingsRes.ok) setSettings(settingsRes.data)
    else setError(settingsRes.data?.error || `HTTP ${settingsRes.status}`)
    if (healthRes.ok) setHealth(healthRes.data.items || [])
    if (fullControlRes.ok) {
      const items = fullControlRes.data.items || []
      setFullControlProducts(items)
      setSelectedProductASIN(prev => prev || items[0]?.product_asin || '')
    }
    if (fullControlGovRes.ok) setFullControlGovernance(fullControlGovRes.data.items || [])
    if (fullControlMonitoringRes.ok) {
      setFullControlMonitoring({
        pilots: fullControlMonitoringRes.data.pilots || [],
        actions: fullControlMonitoringRes.data.actions || [],
      })
    }
    setLoading(false)
  }, [tenantID])

  useEffect(() => { loadAll() }, [loadAll])

  const enabledCount = campaigns.filter(c => c.automation_mode === 'full_auto' || c.full_auto_enabled).length
  const tenantMode = settings?.operational_mode || 'advisor'

  const saveSettings = async (patch = {}) => {
    const next = { ...(settings || defaultSettings()), ...patch }
    setSaving('tenant')
    setError('')
    const res = await api.setTenantSettings(tenantID, normalizeSettings(next))
    if (res.ok) setSettings(res.data)
    else setError(res.data?.error || `HTTP ${res.status}`)
    setSaving('')
    api.tenantHealth(tenantID).then(r => { if (r.ok) setHealth(r.data.items || []) })
  }

  const setCampaignMode = async (campaign, automationMode) => {
    const key = campaign.campaign_name
    setSaving(key)
    setError('')
    const res = await api.setGoldMlFullAutoCampaign(tenantID, {
      campaign_id: campaign.campaign_id || '',
      campaign_name: campaign.campaign_name,
      automation_mode: automationMode,
      enabled: automationMode === 'full_auto',
      notes: `Modo ${automationMode} definido no Config Center.`,
    })
    if (res.ok) {
      setCampaigns(prev => prev.map(it => it.campaign_name === campaign.campaign_name
        ? {
            ...it,
            automation_mode: automationMode,
            full_auto_enabled: automationMode === 'full_auto',
            can_auto_apply: automationMode === 'full_auto' && tenantMode === 'full_auto',
            flag_updated_at: new Date().toISOString(),
          }
        : it))
    } else {
      setError(res.data?.error || `HTTP ${res.status}`)
    }
    setSaving('')
    api.tenantHealth(tenantID).then(r => { if (r.ok) setHealth(r.data.items || []) })
  }

  const protectedHours = useMemo(() => new Set(settings?.protected_hours || []), [settings])
  const selectedProduct = useMemo(
    () => fullControlProducts.find(p => p.product_asin === selectedProductASIN) || null,
    [fullControlProducts, selectedProductASIN],
  )
  const toggleHour = (hour) => {
    const next = new Set(protectedHours)
    if (next.has(hour)) next.delete(hour)
    else next.add(hour)
    saveSettings({ protected_hours: [...next].sort((a, b) => a - b) })
  }

  const draftKey = (product, campaign) => `${product.product_asin}|${campaign.campaign_id}`
  const getPilotDraft = (product, campaign) => {
    const key = draftKey(product, campaign)
    return pilotDrafts[key] || {
      mode: campaign.pilot_mode === 'not_configured' ? 'monitor_only' : campaign.pilot_mode,
      status: campaign.pilot_status === 'not_configured' ? 'draft' : campaign.pilot_status,
      sale_price_brl: Number(product.sale_price_brl || 0),
      unit_cost_brl: Number(product.unit_cost_brl || 0),
      stock_available: Number(product.stock_available || 0),
      max_daily_budget_brl: 0,
      max_spend_without_order_brl: 0,
      min_roas: Number(settings?.min_roas || 4),
      max_acos: 0,
      notes: '',
    }
  }
  const updatePilotDraft = (product, campaign, patch) => {
    const key = draftKey(product, campaign)
    setPilotDrafts(prev => ({ ...prev, [key]: { ...getPilotDraft(product, campaign), ...patch } }))
  }
  const savePilot = async (product, campaign) => {
    const key = draftKey(product, campaign)
    const draft = getPilotDraft(product, campaign)
    await persistPilot(product, campaign, draft, key)
  }

  const startMonitoring = async (product, campaign) => {
    const key = `monitor|${draftKey(product, campaign)}`
    const draft = {
      ...getPilotDraft(product, campaign),
      mode: 'monitor_only',
      status: 'active',
      notes: 'Monitoria iniciada pelo Config Center.',
    }
    updatePilotDraft(product, campaign, draft)
    await persistPilot(product, campaign, draft, key)
  }

  const persistPilot = async (product, campaign, draft, key) => {
    setSaving(key)
    setError('')
    setSaveNotice('')
    const res = await api.setFullControlPilot(tenantID, {
      ...draft,
      product_asin: product.product_asin,
      seller_sku: product.seller_sku || '',
      product_title: product.product_title || product.product_asin,
      campaign_id: campaign.campaign_id,
      campaign_name: campaign.campaign_name,
    })
    if (res.ok) {
      await loadAll()
      const modeLabel = draft.mode === 'full_control' ? 'Full Control' : draft.mode === 'semi_auto' ? 'Semi-auto' : 'Monitoria'
      setSaveNotice(`${modeLabel} salvo para ${campaign.campaign_name}. Acompanhe em "Pilotos ativos" abaixo.`)
    } else {
      setError(res.data?.error || `HTTP ${res.status}`)
    }
    setSaving('')
  }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Config Center</h2>
          <p>Saude da conta, travas do seller e liberacao por campanha</p>
        </div>
        <div className="actions">
          <button className="btn" onClick={loadAll}>Atualizar</button>
        </div>
      </div>

      <div className="settings-tabs">
        {[
          ['health', 'Saude'],
          ['operation', 'Operacao'],
          ['campaigns', 'Campanhas'],
          ['full-control', 'Full Control'],
          ['alerts', 'Alertas'],
        ].map(([value, label]) => (
          <button key={value} className={`btn ${tab === value ? 'primary' : ''}`} onClick={() => setTab(value)}>
            {label}
          </button>
        ))}
      </div>

      {error && <div className="error-box">{error}</div>}
      {saveNotice && <div className="success-box">{saveNotice}</div>}
      {loading && <div className="loading"><div className="spinner" />Carregando configuracoes...</div>}

      {!loading && tab === 'health' && (
        <div className="grid two">
          <div className="panel">
            <div className="panel-head">
              <div>
                <h3>Saude operacional</h3>
                <p className="subtle">Farol de prontidao para operar um seller.</p>
              </div>
              <span className="pill blue">{health.length} checks</span>
            </div>
            <div className="panel-body health-list">
              {health.map(item => (
                <div className="health-row" key={item.key}>
                  <span className={`health-dot ${item.status}`} />
                  <div>
                    <strong>{item.label}</strong>
                    <p>{item.detail || '-'}</p>
                  </div>
                  <span className={`pill ${statusClass(item.status)}`}>{item.status}</span>
                </div>
              ))}
            </div>
          </div>

          <div className="panel">
            <div className="panel-head"><h3>Resumo de governanca</h3></div>
            <div className="panel-body metric-stack">
              <Metric label="Modo do seller" value={labelForMode(tenantMode)} />
              <Metric label="Campanhas full-auto" value={enabledCount} />
              <Metric label="ROAS minimo" value={fmt(settings?.min_roas, 2)} />
              <Metric label="Horas protegidas" value={(settings?.protected_hours || []).length} />
            </div>
          </div>
        </div>
      )}

      {!loading && tab === 'operation' && settings && (
        <div className="grid two">
          <div className="panel">
            <div className="panel-head"><h3>Travas do seller</h3></div>
            <div className="panel-body settings-form">
              <label>
                <span>Modo maximo do seller</span>
                <select value={settings.operational_mode} onChange={e => saveSettings({ operational_mode: e.target.value })}>
                  {MODES.map(mode => <option key={mode.value} value={mode.value}>{mode.label}</option>)}
                </select>
                <small>{MODES.find(m => m.value === settings.operational_mode)?.help}</small>
              </label>
              <label>
                <span>ROAS minimo para auto-apply</span>
                <input type="number" min="0" step="0.1" value={settings.min_roas}
                  onChange={e => setSettings({ ...settings, min_roas: Number(e.target.value) })}
                  onBlur={() => saveSettings()} />
              </label>
              <label>
                <span>Agressividade ML (delta maximo)</span>
                <input type="number" min="0" max="1" step="0.05" value={settings.ml_aggressiveness}
                  onChange={e => setSettings({ ...settings, ml_aggressiveness: Number(e.target.value) })}
                  onBlur={() => saveSettings()} />
                <small>1.00 permite saltos grandes; 0.20 limita ajustes bruscos.</small>
              </label>
              <label>
                <span>Orcamento de risco por dia (R$)</span>
                <input type="number" min="0" step="1" value={settings.risk_budget_brl}
                  onChange={e => setSettings({ ...settings, risk_budget_brl: Number(e.target.value) })}
                  onBlur={() => saveSettings()} />
                <small>0 desliga o teto diario.</small>
              </label>
            </div>
          </div>

          <div className="panel">
            <div className="panel-head"><h3>Horarios protegidos</h3></div>
            <div className="panel-body">
              <div className="hour-grid">
                {Array.from({ length: 24 }, (_, hour) => (
                  <button key={hour} className={`hour-btn ${protectedHours.has(hour) ? 'locked' : ''}`} onClick={() => toggleHour(hour)}>
                    {String(hour).padStart(2, '0')}
                  </button>
                ))}
              </div>
              <p className="subtle top-gap">O worker nunca aplica sugestao em hora protegida.</p>
              {saving === 'tenant' && <div className="notice top-gap">Salvando travas...</div>}
            </div>
          </div>
        </div>
      )}

      {!loading && tab === 'campaigns' && (
        <div className="panel">
          <div className="panel-head">
            <div>
              <h3>Modo por campanha</h3>
              <p className="subtle">O seller define o teto. A campanha opta dentro desse limite.</p>
            </div>
            <span className="pill green">{enabledCount} full-auto</span>
          </div>
          <div className="panel-body">
            <div className="notice">
              O modelo gera predicoes para todas as campanhas. O worker so aplica quando seller e campanha estao em full-auto, com holdout e guardrails OK.
            </div>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Campanha</th>
                    <th>Score</th>
                    <th>Recs</th>
                    <th>Modo</th>
                    <th>Auto-apply</th>
                  </tr>
                </thead>
                <tbody>
                  {campaigns.map(c => {
                    const campaignMode = c.automation_mode || (c.full_auto_enabled ? 'full_auto' : 'advisor')
                    const blockedByTenant = modeRank(campaignMode) > modeRank(tenantMode)
                    return (
                      <tr key={c.campaign_name}>
                        <td>
                          <div style={{ fontWeight: 800 }}>{c.campaign_name}</div>
                          <div className="muted">{c.campaign_id || 'sem campaign_id no lake'}</div>
                        </td>
                        <td>{fmt(c.max_priority_score, 0)}</td>
                        <td>{fmt(c.recommendation_rows)}</td>
                        <td>
                          <select value={campaignMode} disabled={saving === c.campaign_name} onChange={e => setCampaignMode(c, e.target.value)}>
                            {MODES.map(mode => <option key={mode.value} value={mode.value}>{mode.label}</option>)}
                          </select>
                        </td>
                        <td>
                          {c.can_auto_apply && !blockedByTenant ? (
                            <span className="pill green">apto</span>
                          ) : (
                            <span className="pill orange">{blockedByTenant ? 'acima do teto' : 'bloqueado'}</span>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}

      {!loading && tab === 'full-control' && (
        <>
        <div className="grid two full-control-grid">
          <div className="panel">
            <div className="panel-head">
              <div>
                <h3>Produto do piloto</h3>
                <p className="subtle">Selecione o produto. As campanhas abaixo sao derivadas pelo ASIN anunciado.</p>
              </div>
              <span className="pill blue">{fullControlProducts.length} produtos</span>
            </div>
            <div className="panel-body settings-form">
              <label>
                <span>Produto / ASIN</span>
                <select value={selectedProductASIN} onChange={e => setSelectedProductASIN(e.target.value)}>
                  {fullControlProducts.map(p => (
                    <option key={p.product_asin} value={p.product_asin}>
                      {p.product_asin} - {p.product_title || p.seller_sku || 'Produto'}
                    </option>
                  ))}
                </select>
              </label>
              {selectedProduct ? (
                <div className="product-card">
                  <strong>{selectedProduct.product_title || selectedProduct.product_asin}</strong>
                  <span>{selectedProduct.seller_sku || 'SKU ainda nao importado'} | {selectedProduct.product_asin}</span>
                  <div className="product-metrics">
                    <Metric label="Campanhas" value={fmt(selectedProduct.campaign_count)} />
                    <Metric label="Gasto 30d" value={`R$ ${fmt(selectedProduct.spend_30d, 2)}`} />
                    <Metric label="Pedidos 30d" value={fmt(selectedProduct.orders_30d)} />
                    <Metric label="ROAS 30d" value={fmt(selectedProduct.roas_30d, 2)} />
                    <Metric label="Preco" value={`R$ ${fmt(selectedProduct.sale_price_brl, 2)}`} />
                    <Metric label="Custo" value={`R$ ${fmt(selectedProduct.unit_cost_brl, 2)}`} />
                    <Metric label="Estoque" value={fmt(selectedProduct.stock_available)} />
                    <Metric label="Margem" value={selectedProduct.gross_margin_pct !== null && selectedProduct.gross_margin_pct !== undefined ? `${fmt(Number(selectedProduct.gross_margin_pct) * 100, 1)}%` : '-'} />
                  </div>
                  <div className="source-grid">
                    <div><span>Estoque local</span><strong>{fmt(selectedProduct.stock_local_available)}</strong></div>
                    <div><span>Estoque FBA/transito</span><strong>{fmt(selectedProduct.stock_fba_available)}</strong></div>
                    <div><span>Fonte estoque</span><strong>{selectedProduct.stock_source || '-'}</strong></div>
                    <div><span>Atualizado</span><strong>{fmtDateTime(selectedProduct.stock_updated_at)}</strong></div>
                    <div><span>Fonte custo</span><strong>{selectedProduct.unit_cost_source || '-'}</strong></div>
                  </div>
                  <div className="notice economics-note">
                    O produto deriva as campanhas automaticamente. O estoque vem do SWARM: saldo local + fases fisicas FBA. Se o total for zero, o Full Control fica bloqueado por NO_STOCK.
                  </div>
                </div>
              ) : (
                <div className="empty">Nenhum produto encontrado nas fontes AMS/SWARM.</div>
              )}
              <div className="governance-box">
                <h4>Governanca ativa</h4>
                {fullControlGovernance.length ? fullControlGovernance.map(item => (
                  <div className="gov-row" key={item.pilot_id}>
                    <div>
                      <strong>{item.campaign_name}</strong>
                      <span>{item.product_asin} | estoque {fmt(item.stock_available)} | gasto hoje R$ {fmt(item.spend_today, 2)} | pedidos {fmt(item.orders_today)}</span>
                      <span>{item.stock_source || '-'} | atualizado {fmtDateTime(item.stock_updated_at)}</span>
                    </div>
                    <span className={`pill ${item.can_control ? 'green' : 'orange'}`}>{item.can_control ? 'liberado' : item.gate_reason}</span>
                  </div>
                )) : <p className="subtle">Nenhum piloto salvo ainda.</p>}
              </div>
            </div>
          </div>

          <div className="panel">
            <div className="panel-head">
              <div>
                <h3>Campanhas derivadas</h3>
                <p className="subtle">Clique em Iniciar monitoria para observar, ou salve como Full Control + Active para liberar o robo dentro dos tetos.</p>
              </div>
            </div>
            <div className="panel-body full-campaign-list">
              {(selectedProduct?.campaigns || []).map(campaign => {
                const draft = getPilotDraft(selectedProduct, campaign)
                const key = draftKey(selectedProduct, campaign)
                const economicsReady = Number(draft.sale_price_brl || 0) > 0 && Number(draft.unit_cost_brl || 0) > 0 && Number(draft.stock_available || 0) > 0
                return (
                  <div className="pilot-row" key={campaign.campaign_id}>
                    <div className="pilot-main">
                      <div>
                        <strong>{campaign.campaign_name}</strong>
                        <span>{campaign.campaign_id}</span>
                      </div>
                      <div className="pilot-stats">
                        <span>Gasto R$ {fmt(campaign.spend_30d, 2)}</span>
                        <span>Pedidos {fmt(campaign.orders_30d)}</span>
                        <span>ROAS {fmt(campaign.roas_30d, 2)}</span>
                      </div>
                    </div>
                    <div className="monitor-banner">
                      <div>
                        <strong>{draft.mode === 'monitor_only' && draft.status === 'active' ? 'Campanha em monitoria' : 'Escolher esta campanha para monitoria'}</strong>
                        <span>Salva como Monitor only + Active. O robô observa por hora, mas não executa alteração.</span>
                      </div>
                      <button className="btn primary" disabled={saving === `monitor|${key}`} onClick={() => startMonitoring(selectedProduct, campaign)}>
                        {saving === `monitor|${key}` ? 'Ativando...' : 'Iniciar monitoria'}
                      </button>
                    </div>
                    <div className="pilot-form">
                      <label><span>Modo</span><select value={draft.mode} onChange={e => updatePilotDraft(selectedProduct, campaign, { mode: e.target.value })}>
                        <option value="monitor_only">Monitor only</option>
                        <option value="semi_auto">Semi-auto</option>
                        <option value="full_control">Full Control</option>
                      </select></label>
                      <label><span>Status</span><select value={draft.status} onChange={e => updatePilotDraft(selectedProduct, campaign, { status: e.target.value })}>
                        <option value="draft">Draft</option>
                        <option value="active">Active</option>
                        <option value="paused">Paused</option>
                        <option value="completed">Completed</option>
                      </select></label>
                      <label><span>Preco</span><input type="number" min="0" step="0.01" value={draft.sale_price_brl} onChange={e => updatePilotDraft(selectedProduct, campaign, { sale_price_brl: Number(e.target.value) })} /></label>
                      <label><span>Custo</span><input type="number" min="0" step="0.01" value={draft.unit_cost_brl} onChange={e => updatePilotDraft(selectedProduct, campaign, { unit_cost_brl: Number(e.target.value) })} /></label>
                      <label><span>Estoque</span><input type="number" min="0" step="1" value={draft.stock_available} onChange={e => updatePilotDraft(selectedProduct, campaign, { stock_available: Number(e.target.value) })} /></label>
                      <label><span>Budget/dia</span><input type="number" min="0" step="1" value={draft.max_daily_budget_brl} onChange={e => updatePilotDraft(selectedProduct, campaign, { max_daily_budget_brl: Number(e.target.value) })} /></label>
                      <label><span>Gasto sem pedido</span><input type="number" min="0" step="1" value={draft.max_spend_without_order_brl} onChange={e => updatePilotDraft(selectedProduct, campaign, { max_spend_without_order_brl: Number(e.target.value) })} /></label>
                      <label><span>ROAS min.</span><input type="number" min="0" step="0.1" value={draft.min_roas} onChange={e => updatePilotDraft(selectedProduct, campaign, { min_roas: Number(e.target.value) })} /></label>
                    </div>
                    <div className="pilot-actions">
                      <span className={`pill ${economicsReady ? 'green' : 'orange'}`}>{economicsReady ? 'economia pronta' : 'faltam dados economicos'}</span>
                      <button className="btn primary" disabled={saving === key} onClick={() => savePilot(selectedProduct, campaign)}>
                        {saving === key ? 'Salvando...' : 'Salvar plano'}
                      </button>
                    </div>
                  </div>
                )
              })}
              {selectedProduct && !(selectedProduct.campaigns || []).length && <div className="empty">Nenhuma campanha derivada para este produto.</div>}
            </div>
          </div>
        </div>
        <FullControlMonitoringPanel monitoring={fullControlMonitoring} />
        </>
      )}

      {!loading && tab === 'alerts' && settings && (
        <div className="panel narrow-panel">
          <div className="panel-head"><h3>Alertas</h3></div>
          <div className="panel-body settings-form">
            <label>
              <span>Telegram chat id</span>
              <input value={settings.telegram_chat_id || ''}
                onChange={e => setSettings({ ...settings, telegram_chat_id: e.target.value })}
                onBlur={() => saveSettings()} />
            </label>
            <label>
              <span>Notas internas</span>
              <input value={settings.notes || ''}
                onChange={e => setSettings({ ...settings, notes: e.target.value })}
                onBlur={() => saveSettings()} />
            </label>
          </div>
        </div>
      )}

      <style>{`
        .settings-tabs{display:flex;gap:10px;margin-bottom:20px;flex-wrap:wrap}
        .notice{padding:12px 14px;border:1px solid rgba(84,160,255,.35);background:rgba(84,160,255,.09);border-radius:8px;margin-bottom:12px;color:#b8d6ff;font-size:13px}
        .success-box{padding:10px 12px;border:1px solid rgba(44,224,139,.35);background:rgba(44,224,139,.10);border-radius:8px;margin-bottom:12px;color:#93f5c2;font-size:13px;font-weight:800}
        .error-box{padding:10px 12px;border:1px solid rgba(255,84,112,.35);background:rgba(255,84,112,.10);border-radius:8px;margin-bottom:12px;color:#ff9bad;font-size:13px}
        .muted{color:var(--muted);font-size:12px;margin-top:3px}
        .subtle{color:var(--muted);font-size:13px;margin:4px 0 0;line-height:1.45}
        .top-gap{margin-top:14px}
        .health-list{display:grid;gap:10px}
        .health-row{display:grid;grid-template-columns:14px 1fr auto;align-items:center;gap:12px;padding:13px;border:1px solid var(--line);border-radius:8px;background:rgba(255,255,255,.035)}
        .health-row p{color:var(--muted);font-size:12px;margin-top:3px}
        .health-dot{width:10px;height:10px;border-radius:999px;background:var(--orange)}
        .health-dot.ok{background:var(--green)}
        .health-dot.error{background:var(--red)}
        .metric-stack{display:grid;gap:12px}
        .metric{border:1px solid var(--line);border-radius:8px;padding:14px;background:rgba(255,255,255,.035)}
        .metric span{display:block;color:var(--muted);font-size:12px;margin-bottom:5px}
        .metric strong{font-size:24px}
        .settings-form{display:grid;gap:16px}
        .settings-form label{display:grid;gap:7px}
        .settings-form label span{font-weight:800}
        .settings-form small{color:var(--muted);font-size:12px}
        .hour-grid{display:grid;grid-template-columns:repeat(6,1fr);gap:8px}
        .hour-btn{border:1px solid var(--line);background:#0c1324;color:var(--text);border-radius:8px;padding:11px 0;font-weight:850;cursor:pointer}
        .hour-btn.locked{background:rgba(255,107,107,.16);border-color:rgba(255,107,107,.35);color:#ffb1bd}
        .narrow-panel{max-width:720px}
        .full-control-grid{grid-template-columns:minmax(320px,.8fr) minmax(0,1.2fr)}
        .product-card{border:1px solid var(--line);border-radius:8px;padding:14px;background:rgba(255,255,255,.035)}
        .product-card strong{display:block;font-size:18px}
        .product-card span{display:block;color:var(--muted);font-size:12px;margin-top:4px}
        .product-metrics{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-top:12px}
        .source-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-top:12px;border-top:1px solid var(--line);padding-top:12px}
        .source-grid div{border:1px solid var(--line);border-radius:8px;background:rgba(255,255,255,.025);padding:9px}
        .source-grid span{display:block;color:var(--muted);font-size:11px;font-weight:800;text-transform:uppercase;letter-spacing:.04em;margin:0 0 4px}
        .source-grid strong{font-size:12px;line-height:1.35;word-break:break-word}
        .economics-note{margin-top:12px;margin-bottom:0}
        .governance-box{border-top:1px solid var(--line);margin-top:14px;padding-top:14px}
        .governance-box h4{margin:0 0 10px;font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
        .gov-row{display:flex;justify-content:space-between;gap:10px;align-items:center;border:1px solid var(--line);border-radius:8px;padding:10px;background:rgba(255,255,255,.03);margin-bottom:8px}
        .gov-row strong{display:block;font-size:13px}
        .gov-row span:not(.pill){display:block;color:var(--muted);font-size:11px;margin-top:3px}
        .full-campaign-list{display:grid;gap:12px;max-height:720px;overflow:auto}
        .pilot-row{border:1px solid var(--line);border-radius:8px;background:rgba(255,255,255,.03);padding:13px}
        .pilot-main{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:12px}
        .pilot-main strong{display:block;font-size:15px}
        .pilot-main span{display:block;color:var(--muted);font-size:12px;margin-top:3px}
        .pilot-stats{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end}
        .pilot-stats span{border:1px solid var(--line);border-radius:999px;padding:5px 8px;background:rgba(255,255,255,.035)}
        .monitor-banner{display:flex;justify-content:space-between;gap:14px;align-items:center;border:1px solid rgba(44,224,139,.34);background:rgba(44,224,139,.08);border-radius:8px;padding:12px;margin-bottom:12px}
        .monitor-banner strong{display:block}
        .monitor-banner span{display:block;color:var(--muted);font-size:12px;margin-top:3px;line-height:1.35}
        .pilot-form{display:grid;grid-template-columns:repeat(4,minmax(110px,1fr));gap:10px}
        .pilot-form label{display:grid;gap:5px}
        .pilot-form label span{font-size:11px;color:var(--muted);font-weight:800;text-transform:uppercase;letter-spacing:.04em}
        .pilot-actions{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-top:12px}
        .monitor-panel{margin-top:18px}
        .mini-grid{display:grid;grid-template-columns:repeat(4,minmax(120px,1fr));gap:10px;margin-bottom:14px}
        .section-title{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:18px 0 8px}
        .pilot-monitor-list{border:1px solid var(--line);border-radius:8px;background:rgba(255,255,255,.025);padding:0 12px}
        .pilot-monitor-row{display:grid;grid-template-columns:1.3fr .7fr .8fr .8fr .9fr;gap:10px;align-items:center;border-bottom:1px solid var(--line);padding:10px 0}
        .pilot-monitor-row:last-child{border-bottom:0}
        .pilot-monitor-row strong{display:block}
        .pilot-monitor-row span:not(.pill){display:block;color:var(--muted);font-size:12px;margin-top:3px}
        .actions-table td{vertical-align:top}
        .actions-table small{display:block;color:var(--muted);font-size:11px;margin-top:3px}
        select{min-width:150px}
        @media(max-width:1100px){.full-control-grid{grid-template-columns:1fr}.pilot-form{grid-template-columns:repeat(2,minmax(110px,1fr))}.monitor-banner{align-items:stretch;flex-direction:column}.mini-grid{grid-template-columns:repeat(2,minmax(120px,1fr))}.pilot-monitor-row{grid-template-columns:1fr}}
      `}</style>
    </div>
  )
}

function defaultSettings() {
  return {
    operational_mode: 'advisor',
    min_roas: 4,
    ml_aggressiveness: 1,
    risk_budget_brl: 0,
    protected_hours: [],
    telegram_chat_id: '',
    notes: '',
  }
}

function FullControlMonitoringPanel({ monitoring }) {
  const pilots = monitoring?.pilots || []
  const actions = monitoring?.actions || []
  const activePilots = pilots.filter(p => p.status === 'active')
  const fullControl = activePilots.filter(p => p.mode === 'full_control')
  const monitorOnly = activePilots.filter(p => p.mode === 'monitor_only')
  const blocked = fullControl.filter(p => !p.can_control)

  return (
    <div className="panel monitor-panel">
      <div className="panel-head">
        <div>
          <h3>Pilotos ativos e acoes do robo</h3>
          <p className="subtle">Aqui voce monitora o piloto escolhido e qualquer campanha sinalizada como monitoria ou Full Control.</p>
        </div>
        <span className="pill blue">{pilots.length} pilotos</span>
      </div>
      <div className="panel-body">
        <div className="mini-grid">
          <Metric label="Ativos" value={activePilots.length} />
          <Metric label="Monitoria" value={monitorOnly.length} />
          <Metric label="Full Control" value={fullControl.length} />
          <Metric label="Bloqueados" value={blocked.length} />
        </div>

        <h4 className="section-title">Pilotos ativos</h4>
        {pilots.length ? (
          <div className="pilot-monitor-list">
            {pilots.map(pilot => (
              <div className="pilot-monitor-row" key={pilot.pilot_id}>
                <div>
                  <strong>{pilot.campaign_name}</strong>
                  <span>{pilot.product_asin} | {pilot.seller_sku || 'sem SKU'} | {labelFullControlMode(pilot.mode)}</span>
                </div>
                <div>
                  <strong>{pilot.status}</strong>
                  <span>atualizado {fmtDateTime(pilot.updated_at)}</span>
                </div>
                <div>
                  <strong>R$ {fmt(pilot.spend_today, 2)}</strong>
                  <span>gasto hoje</span>
                </div>
                <div>
                  <strong>{fmt(pilot.orders_today)}</strong>
                  <span>pedidos hoje</span>
                </div>
                <div>
                  <span className={`pill ${pilot.can_control ? 'green' : 'orange'}`}>
                    {pilot.can_control ? 'robo liberado' : pilot.gate_reason}
                  </span>
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="empty">Nenhum piloto salvo ainda. Use Iniciar monitoria ou Salvar plano em uma campanha derivada.</div>
        )}

        <h4 className="section-title">Ultimas acoes e medicoes</h4>
        {actions.length ? (
          <div className="table-wrap">
            <table className="actions-table">
              <thead>
                <tr>
                  <th>Campanha</th>
                  <th>Hora</th>
                  <th>Proposta</th>
                  <th>Aplicado</th>
                  <th>Resultado</th>
                  <th>Medicao</th>
                </tr>
              </thead>
              <tbody>
                {actions.map(action => (
                  <tr key={`${action.recommendation_id}-${action.event_hour}`}>
                    <td>
                      <strong>{action.campaign_name}</strong>
                      <small>{action.ad_group_name || action.campaign_id || '-'}</small>
                    </td>
                    <td>{String(action.event_hour ?? '-').padStart(2, '0')}h</td>
                    <td>
                      {action.recommended_action || '-'}
                      <small>{fmtMultiplier(action.recommended_bid_multiplier)}</small>
                    </td>
                    <td>
                      {action.execution_status || '-'}
                      <small>{fmtDateTime(action.executed_at)}</small>
                    </td>
                    <td>
                      <span className={`pill ${action.audit_result === 'WINNING' ? 'green' : action.audit_result === 'LOSING' ? 'red' : 'orange'}`}>
                        {action.audit_result || 'PENDING'}
                      </span>
                      <small>{action.model_result || 'INCONCLUSIVE'}</small>
                    </td>
                    <td>
                      1h {labelOutcome(action.outcome_label_1h, action.delta_roas_1h)}
                      <small>3h {labelOutcome(action.outcome_label_3h, action.delta_roas_3h)} | 24h {labelOutcome(action.outcome_label_24h, action.delta_roas_24h)}</small>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="empty">Ainda nao ha acao aplicada pelo robo para os pilotos atuais. Monitoria nao altera BID; Full Control so aplica se estiver Active e com gate liberado.</div>
        )}
      </div>
    </div>
  )
}

function normalizeSettings(settings) {
  return {
    operational_mode: settings.operational_mode || 'advisor',
    min_roas: Number(settings.min_roas || 0),
    ml_aggressiveness: Number(settings.ml_aggressiveness ?? 1),
    risk_budget_brl: Number(settings.risk_budget_brl || 0),
    protected_hours: (settings.protected_hours || []).map(Number).filter(n => n >= 0 && n <= 23),
    telegram_chat_id: settings.telegram_chat_id || '',
    notes: settings.notes || '',
  }
}

function labelForMode(mode) {
  return MODES.find(m => m.value === mode)?.label || mode || '-'
}

function labelFullControlMode(mode) {
  if (mode === 'full_control') return 'Full Control'
  if (mode === 'monitor_only') return 'Monitoria'
  if (mode === 'semi_auto') return 'Semi-auto'
  return mode || '-'
}

function fmtMultiplier(value) {
  if (value === null || value === undefined || value === '') return '-'
  return `${fmt(Number(value), 2)}x`
}

function labelOutcome(label, deltaRoas) {
  const roas = deltaRoas === null || deltaRoas === undefined ? '' : ` (${fmt(deltaRoas, 2)} ROAS)`
  return `${label || 'pendente'}${roas}`
}

function Metric({ label, value }) {
  return (
    <div className="metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}
