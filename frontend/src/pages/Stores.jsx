import { useState } from 'react'

const DEMO_STORES = [
  { id: 's1', name: 'Brasil - Loja Principal', marketplace: 'AMAZON_BR', campaigns: 52, roas: 4.32, status: 'ACTIVE', connected: true },
  { id: 's2', name: 'US - Main Store', marketplace: 'AMAZON_US', campaigns: 35, roas: 3.85, status: 'ACTIVE', connected: true },
  { id: 's3', name: 'México', marketplace: 'AMAZON_MX', campaigns: 0, roas: 0, status: 'PENDING', connected: false },
]

const MARKET_COLOR = { AMAZON_BR: 'green', AMAZON_US: 'blue', AMAZON_MX: 'gold', AMAZON_CA: 'purple' }

export default function Stores({ ctx }) {
  const [modal, setModal] = useState(false)
  const [form, setForm] = useState({ name: '', marketplace: 'AMAZON_BR', external_id: '' })

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Multi-Loja</h2>
          <p>Gerencie suas lojas conectadas ao MarketCloud</p>
        </div>
        <div className="actions">
          <button className="btn primary" onClick={() => setModal(true)}>+ Nova Loja</button>
        </div>
      </div>

      <div className="grid three" style={{ marginBottom: 16 }}>
        {DEMO_STORES.map(s => (
          <div className="card" key={s.id}>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10 }}>
              <span className={`pill ${MARKET_COLOR[s.marketplace]}`}>{s.marketplace}</span>
              <span className={`pill ${s.connected ? 'green' : 'orange'}`}>{s.connected ? 'Conectado' : 'Pendente'}</span>
            </div>
            <div style={{ fontWeight: 800, fontSize: 15, marginBottom: 8 }}>{s.name}</div>
            <div style={{ color: 'var(--muted)', fontSize: 13 }}>{s.campaigns} campanhas • ROAS {s.roas > 0 ? s.roas.toFixed(2) + '×' : '—'}</div>
            <div style={{ marginTop: 12 }}>
              <div className="bar"><span style={{ width: Math.min(s.roas / 8 * 100, 100) + '%' }} /></div>
            </div>
          </div>
        ))}
      </div>

      <div className="panel">
        <div className="panel-head">
          <h3>Todas as Lojas</h3>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Nome</th>
                <th>Marketplace</th>
                <th>Campanhas</th>
                <th>ROAS</th>
                <th>Status</th>
                <th>Conexão Amazon</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {DEMO_STORES.map(s => (
                <tr key={s.id}>
                  <td style={{ fontWeight: 700 }}>{s.name}</td>
                  <td><span className={`pill ${MARKET_COLOR[s.marketplace]}`}>{s.marketplace}</span></td>
                  <td>{s.campaigns}</td>
                  <td style={{ color: s.roas >= 4 ? 'var(--green)' : s.roas > 0 ? 'var(--orange)' : 'var(--muted)' }}>
                    {s.roas > 0 ? s.roas.toFixed(2) + '×' : '—'}
                  </td>
                  <td><span className={`pill ${s.status === 'ACTIVE' ? 'green' : 'orange'}`}>{s.status}</span></td>
                  <td><span className={`pill ${s.connected ? 'green' : 'red'}`}>{s.connected ? '● Online' : '○ Offline'}</span></td>
                  <td>
                    {!s.connected && (
                      <button className="btn sm blue">Conectar OAuth</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {modal && (
        <Modal title="Nova Loja" onClose={() => setModal(false)}>
          <div style={{ display: 'grid', gap: 12 }}>
            <Field label="Nome da Loja">
              <input value={form.name} onChange={e => setForm(f => ({ ...f, name: e.target.value }))} placeholder="Ex: Brasil - Principal" />
            </Field>
            <Field label="Marketplace">
              <select value={form.marketplace} onChange={e => setForm(f => ({ ...f, marketplace: e.target.value }))}>
                <option>AMAZON_BR</option>
                <option>AMAZON_US</option>
                <option>AMAZON_MX</option>
                <option>AMAZON_CA</option>
              </select>
            </Field>
            <Field label="External ID (opcional)">
              <input value={form.external_id} onChange={e => setForm(f => ({ ...f, external_id: e.target.value }))} placeholder="ID externo da loja" />
            </Field>
            <div style={{ display: 'flex', gap: 10, marginTop: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={() => setModal(false)}>Cancelar</button>
              <button className="btn primary" onClick={() => setModal(false)}>Criar Loja</button>
            </div>
          </div>
        </Modal>
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

function Modal({ title, children, onClose }) {
  return (
    <div style={{
      position: 'fixed', inset: 0, background: 'rgba(0,0,0,.7)',
      display: 'grid', placeItems: 'center', zIndex: 100,
    }}>
      <div style={{
        background: 'var(--panel)', border: '1px solid var(--line)',
        borderRadius: 20, padding: 28, width: 420, maxWidth: '95vw',
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20, alignItems: 'center' }}>
          <h3 style={{ fontSize: 16 }}>{title}</h3>
          <button onClick={onClose} style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 18 }}>✕</button>
        </div>
        {children}
      </div>
    </div>
  )
}
