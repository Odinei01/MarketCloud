import { useState } from 'react'

export default function Settings({ ctx }) {
  const [tab, setTab] = useState('tenant')
  const [saved, setSaved] = useState(false)

  const save = () => { setSaved(true); setTimeout(() => setSaved(false), 1800) }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Configurações</h2>
          <p>Tenant, conexões e preferências da plataforma</p>
        </div>
        <div className="actions">
          <button className="btn primary" onClick={save}>{saved ? '✓ Salvo!' : 'Salvar Alterações'}</button>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 10, marginBottom: 20 }}>
        {['tenant', 'amazon', 'modeling', 'users'].map(t => (
          <button key={t} className={`btn ${tab === t ? 'primary' : ''}`} onClick={() => setTab(t)}>
            {{ tenant: 'Tenant', amazon: 'Amazon Ads', modeling: 'Modeling', users: 'Usuários' }[t]}
          </button>
        ))}
      </div>

      {tab === 'tenant' && (
        <div className="grid two">
          <div className="panel">
            <div className="panel-head"><h3>Dados do Tenant</h3></div>
            <div className="panel-body" style={{ display: 'grid', gap: 14 }}>
              <Field label="Nome do Tenant"><input defaultValue="ZANOM Marketplace" /></Field>
              <Field label="Slug"><input defaultValue="zanom" /></Field>
              <Field label="Plano">
                <select defaultValue="PROFESSIONAL">
                  <option>FREE</option>
                  <option>STARTER</option>
                  <option>PROFESSIONAL</option>
                  <option>ENTERPRISE</option>
                </select>
              </Field>
              <Field label="Status"><select defaultValue="ACTIVE"><option>ACTIVE</option><option>SUSPENDED</option></select></Field>
            </div>
          </div>
          <div className="panel">
            <div className="panel-head"><h3>Uso do Plano</h3></div>
            <div className="panel-body">
              <UsageRow label="Lojas" used={4} max={10} color="green" />
              <UsageRow label="Campanhas" used={87} max={500} color="blue" />
              <UsageRow label="AMC Query Runs / mês" used={23} max={100} color="gold" />
              <UsageRow label="Webhooks" used={3} max={20} color="purple" />
              <div style={{ marginTop: 20, padding: 14, background: 'rgba(243,201,107,.07)', borderRadius: 14, border: '1px solid rgba(243,201,107,.2)', fontSize: 13 }}>
                <div style={{ color: 'var(--gold)', fontWeight: 700, marginBottom: 4 }}>Plano PROFESSIONAL</div>
                <div style={{ color: 'var(--muted)' }}>Renovação em 26 dias</div>
              </div>
            </div>
          </div>
        </div>
      )}

      {tab === 'amazon' && (
        <div className="grid two">
          <div className="panel">
            <div className="panel-head"><h3>OAuth Amazon Ads</h3></div>
            <div className="panel-body" style={{ display: 'grid', gap: 14 }}>
              <Field label="Client ID (LWA)"><input type="password" defaultValue="amzn1.application-oa2-client.XXXX" /></Field>
              <Field label="Client Secret"><input type="password" defaultValue="••••••••••••••••" /></Field>
              <Field label="Redirect URI"><input defaultValue="https://app.marketcloud.io/oauth/amazon/callback" /></Field>
              <div style={{ padding: 14, background: 'rgba(49,211,154,.07)', borderRadius: 14, border: '1px solid rgba(49,211,154,.2)', fontSize: 13 }}>
                <div style={{ color: 'var(--green)', fontWeight: 700, marginBottom: 4 }}>✓ Brasil — Token Ativo</div>
                <div style={{ color: 'var(--muted)' }}>Expira em 3h 42min • Auto-refresh habilitado</div>
              </div>
            </div>
          </div>
          <div className="panel">
            <div className="panel-head"><h3>AMC Instance</h3></div>
            <div className="panel-body" style={{ display: 'grid', gap: 14 }}>
              <Field label="AMC Instance ID"><input defaultValue="amcXXXXXXXXXXXXXXX" /></Field>
              <Field label="AMC API URL"><input defaultValue="https://amc.amazon.com/api/v1" /></Field>
              <Field label="Marketplace ID"><input defaultValue="A2Q3Y263D00KWC" /></Field>
              <button className="btn blue">Testar Conexão AMC</button>
            </div>
          </div>
        </div>
      )}

      {tab === 'modeling' && (
        <div className="panel">
          <div className="panel-head"><h3>Parâmetros do Modeling Worker</h3></div>
          <div className="panel-body" style={{ display: 'grid', gap: 14 }}>
            <div className="grid two" style={{ gap: 14 }}>
              <Field label="Target ROAS (threshold conversão)"><input type="number" defaultValue="4.0" step="0.1" /></Field>
              <Field label="Min. Spend para classificar WASTE (R$)"><input type="number" defaultValue="50" /></Field>
              <Field label="Min. Assist Rate (ASSISTED_CONVERSION)"><input type="number" defaultValue="0.30" step="0.01" /></Field>
              <Field label="Min. Last Touch Rate (CONVERSION)"><input type="number" defaultValue="0.50" step="0.01" /></Field>
              <Field label="Min. First Touch Rate (DISCOVERY)"><input type="number" defaultValue="0.35" step="0.01" /></Field>
              <Field label="Polling interval do worker (segundos)"><input type="number" defaultValue="15" /></Field>
            </div>
            <div style={{ padding: 14, background: 'rgba(184,146,255,.07)', borderRadius: 14, border: '1px solid rgba(184,146,255,.2)', fontSize: 13 }}>
              <div style={{ color: 'var(--purple)', fontWeight: 700, marginBottom: 4 }}>Classificação Determinística v1</div>
              <div style={{ color: 'var(--muted)' }}>Nenhum modelo ML usado. Resultados são 100% reproduzíveis com os mesmos dados de entrada.</div>
            </div>
          </div>
        </div>
      )}

      {tab === 'users' && (
        <div className="panel">
          <div className="panel-head">
            <h3>Usuários do Tenant</h3>
            <button className="btn sm primary">+ Convidar</button>
          </div>
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>Nome</th><th>Email</th><th>Role</th><th>Status</th><th></th></tr>
              </thead>
              <tbody>
                {[
                  { name: 'Odinei Junior', email: 'odinei@zanom.com.br', role: 'TENANT_ADMIN', status: 'ACTIVE' },
                  { name: 'Ana Marketing', email: 'ana@zanom.com.br', role: 'ANALYST', status: 'ACTIVE' },
                  { name: 'Bot Worker', email: 'bot@zanom.com.br', role: 'API_CLIENT', status: 'ACTIVE' },
                ].map(u => (
                  <tr key={u.email}>
                    <td style={{ fontWeight: 700 }}>{u.name}</td>
                    <td style={{ color: 'var(--muted)' }}>{u.email}</td>
                    <td><span className="pill blue">{u.role}</span></td>
                    <td><span className="pill green">{u.status}</span></td>
                    <td><button className="btn sm">Editar</button></td>
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

function Field({ label, children }) {
  return (
    <div>
      <div className="label" style={{ marginBottom: 6 }}>{label}</div>
      {children}
    </div>
  )
}

function UsageRow({ label, used, max, color }) {
  const pct = (used / max) * 100
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 6 }}>
        <span>{label}</span>
        <span style={{ color: `var(--${color})` }}>{used} / {max}</span>
      </div>
      <div className="bar">
        <span style={{ width: pct + '%', background: `var(--${color})` }} />
      </div>
    </div>
  )
}
