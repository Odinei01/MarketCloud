import { useState } from 'react'

const ENDPOINTS = [
  { method: 'POST', path: '/api/v1/auth/login', desc: 'Autenticação (JWT)' },
  { method: 'GET',  path: '/api/v1/stores', desc: 'Listar lojas do tenant' },
  { method: 'POST', path: '/api/v1/query-runs', desc: 'Submeter query AMC' },
  { method: 'GET',  path: '/api/v1/insights', desc: 'Listar insights gerados' },
  { method: 'GET',  path: '/api/v1/recommendations', desc: 'Listar recomendações' },
  { method: 'POST', path: '/api/v1/recommendations/{id}/approve', desc: 'Aprovar recomendação' },
  { method: 'GET',  path: '/api/v1/external/recommendations/actions', desc: 'Ações para sistemas externos' },
]

const WEBHOOKS = [
  { event: 'query.succeeded', desc: 'Query AMC concluída com sucesso' },
  { event: 'insights.generated', desc: 'Novos insights disponíveis' },
  { event: 'recommendation.created', desc: 'Nova recomendação gerada' },
  { event: 'recommendation.approved', desc: 'Recomendação aprovada pelo usuário' },
]

const METHOD_COLOR = { GET: 'green', POST: 'blue', PUT: 'gold', DELETE: 'red' }

const EXAMPLE_PAYLOAD = `{
  "store_id": "store-br-001",
  "template_id": "tpl-keyword-role-v1",
  "parameters": {
    "start_date": "2025-06-01",
    "end_date": "2025-06-30",
    "marketplace_id": "A2Q3Y263D00KWC"
  }
}`

export default function APIPage({ ctx }) {
  const [apiKey, setApiKey] = useState('')
  const [copied, setCopied] = useState(false)
  const [tab, setTab] = useState('endpoints')

  const generate = () => {
    const k = 'mc_' + Array.from(crypto.getRandomValues(new Uint8Array(24)))
      .map(b => b.toString(16).padStart(2, '0')).join('')
    setApiKey(k)
  }

  const copy = () => {
    navigator.clipboard.writeText(apiKey)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>API & Webhooks</h2>
          <p>Integração programática com o MarketCloud Engine</p>
        </div>
        <div className="actions">
          <button className="btn primary" onClick={generate}>Gerar API Key</button>
        </div>
      </div>

      {apiKey && (
        <div style={{
          marginBottom: 20, padding: 16,
          background: 'rgba(49,211,154,.07)', border: '1px solid rgba(49,211,154,.25)',
          borderRadius: 16, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12,
        }}>
          <div>
            <div style={{ color: 'var(--green)', fontWeight: 700, fontSize: 12, marginBottom: 6 }}>Nova API Key gerada — salve agora, não será exibida novamente</div>
            <code style={{ fontSize: 13, color: 'var(--text)', letterSpacing: '.05em' }}>{apiKey}</code>
          </div>
          <button className="btn sm" onClick={copy}>{copied ? '✓ Copiado' : 'Copiar'}</button>
        </div>
      )}

      <div style={{ display: 'flex', gap: 10, marginBottom: 20 }}>
        {['endpoints', 'webhooks', 'exemplo'].map(t => (
          <button key={t} className={`btn ${tab === t ? 'primary' : ''}`} onClick={() => setTab(t)}>
            {t === 'endpoints' ? 'Endpoints' : t === 'webhooks' ? 'Webhooks' : 'Exemplo de Uso'}
          </button>
        ))}
      </div>

      {tab === 'endpoints' && (
        <div className="panel">
          <div className="panel-head"><h3>Endpoints REST</h3><span className="pill">Base: https://api.marketcloud.io/api/v1</span></div>
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>Método</th><th>Endpoint</th><th>Descrição</th></tr>
              </thead>
              <tbody>
                {ENDPOINTS.map(e => (
                  <tr key={e.path}>
                    <td><span className={`pill ${METHOD_COLOR[e.method]}`}>{e.method}</span></td>
                    <td><code style={{ fontSize: 12 }}>{e.path}</code></td>
                    <td style={{ color: 'var(--muted)' }}>{e.desc}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === 'webhooks' && (
        <div className="panel">
          <div className="panel-head">
            <h3>Eventos de Webhook</h3>
            <button className="btn sm primary">+ Cadastrar URL</button>
          </div>
          <div className="panel-body">
            <div style={{ display: 'grid', gap: 12 }}>
              {WEBHOOKS.map(w => (
                <div key={w.event} style={{
                  padding: 14, border: '1px solid var(--line)',
                  borderRadius: 14, display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                }}>
                  <div>
                    <div style={{ fontWeight: 700, marginBottom: 4 }}><code>{w.event}</code></div>
                    <div style={{ color: 'var(--muted)', fontSize: 13 }}>{w.desc}</div>
                  </div>
                  <button className="btn sm">Testar</button>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {tab === 'exemplo' && (
        <div className="grid two">
          <div className="panel">
            <div className="panel-head"><h3>Submeter Query AMC</h3></div>
            <div className="panel-body">
              <div className="label" style={{ marginBottom: 8 }}>POST /api/v1/query-runs</div>
              <div className="code">{EXAMPLE_PAYLOAD}</div>
              <div style={{ marginTop: 16 }}>
                <div className="label" style={{ marginBottom: 8 }}>Headers obrigatórios</div>
                <div className="code">{`Authorization: Bearer mc_<seu_token>
X-Tenant-ID: tenant-zanom
Content-Type: application/json`}</div>
              </div>
            </div>
          </div>
          <div className="panel">
            <div className="panel-head"><h3>Resposta</h3><span className="pill green">200 OK</span></div>
            <div className="panel-body">
              <div className="code">{`{
  "run_id": "qr-abc123",
  "status": "QUEUED",
  "idempotency_key": "sha256:...",
  "created_at": "2025-07-05T14:32:00Z",
  "estimated_completion": "2025-07-05T14:50:00Z"
}`}</div>
              <div style={{ marginTop: 16, padding: 14, background: 'rgba(110,168,255,.07)', borderRadius: 14, border: '1px solid rgba(110,168,255,.2)', fontSize: 13 }}>
                <div style={{ color: 'var(--blue)', fontWeight: 700, marginBottom: 6 }}>Polling de status</div>
                <div style={{ color: 'var(--muted)' }}>
                  Use <code>GET /api/v1/query-runs/{'{run_id}'}</code> para acompanhar o estado.
                  O webhook <code>query.succeeded</code> dispara automaticamente ao concluir.
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
