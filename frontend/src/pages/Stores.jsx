import { useState, useEffect } from 'react'
import { api } from '../api/client.js'

const MP_ICON = { AMAZON_BR: '🇧🇷', AMAZON_US: '🇺🇸', AMAZON_MX: '🇲🇽', AMAZON_CA: '🇨🇦' }
const MP_LABEL = { AMAZON_BR: 'Amazon BR', AMAZON_US: 'Amazon US', AMAZON_MX: 'Amazon MX', AMAZON_CA: 'Amazon CA' }

export default function Stores({ ctx }) {
  const { tenantID } = ctx
  const [stores, setStores] = useState([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [form, setForm] = useState({ name: '', marketplace: 'AMAZON_BR', seller_id: '' })
  const [creating, setCreating] = useState(false)
  const [err, setErr] = useState('')

  const load = async () => {
    setLoading(true)
    const r = await api.listStores(tenantID)
    if (r.ok) setStores(r.data.items || [])
    setLoading(false)
  }

  useEffect(() => { if (tenantID) load() }, [tenantID])

  const create = async () => {
    setCreating(true); setErr('')
    const r = await api.createStore(tenantID, form)
    setCreating(false)
    if (!r.ok) { setErr(r.data.error || 'Erro ao criar loja'); return }
    setShowCreate(false)
    setForm({ name: '', marketplace: 'AMAZON_BR', seller_id: '' })
    load()
  }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Multi-Loja</h2>
          <p>{stores.length} loja{stores.length !== 1 ? 's' : ''} cadastrada{stores.length !== 1 ? 's' : ''}</p>
        </div>
        <div className="actions">
          <button className="btn primary" onClick={() => setShowCreate(true)}>+ Nova Loja</button>
        </div>
      </div>

      {loading ? (
        <div className="loading"><div className="spinner" /><div>Carregando lojas...</div></div>
      ) : stores.length === 0 ? (
        <div className="panel" style={{ padding: 40, textAlign: 'center' }}>
          <p style={{ color: 'var(--muted)', fontSize: 15 }}>Nenhuma loja cadastrada ainda.</p>
          <button className="btn primary" style={{ marginTop: 16 }} onClick={() => setShowCreate(true)}>Cadastrar primeira loja</button>
        </div>
      ) : (
        <>
          <div className="grid cards">
            {stores.map(s => (
              <div className="card" key={s.id}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
                  <span style={{ fontSize: 24 }}>{MP_ICON[s.marketplace] || '🌐'}</span>
                  <div>
                    <div style={{ fontWeight: 700, fontSize: 15 }}>{s.name}</div>
                    <div style={{ color: 'var(--muted)', fontSize: 12 }}>{MP_LABEL[s.marketplace] || s.marketplace}</div>
                  </div>
                </div>
                <div className="s" style={{ fontSize: 12, marginBottom: 8 }}>
                  <span className="label">Seller ID:</span> <span style={{ color: 'var(--text)' }}>{s.seller_id || '—'}</span>
                </div>
                <span className={`pill ${s.status === 'ACTIVE' ? 'green' : 'red'}`}>{s.status || 'ACTIVE'}</span>
              </div>
            ))}
          </div>

          <div className="gap" />

          <div className="panel">
            <div className="panel-head"><h3>Todas as Lojas</h3></div>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Nome</th>
                    <th>Marketplace</th>
                    <th>Seller ID</th>
                    <th>Status</th>
                    <th>Criada em</th>
                  </tr>
                </thead>
                <tbody>
                  {stores.map(s => (
                    <tr key={s.id}>
                      <td style={{ fontWeight: 700 }}>{s.name}</td>
                      <td>{MP_LABEL[s.marketplace] || s.marketplace}</td>
                      <td style={{ color: 'var(--muted)', fontSize: 12 }}>{s.seller_id || '—'}</td>
                      <td><span className={`pill ${s.status === 'ACTIVE' ? 'green' : 'red'}`}>{s.status || 'ACTIVE'}</span></td>
                      <td style={{ color: 'var(--muted)', fontSize: 12 }}>{s.created_at ? new Date(s.created_at).toLocaleDateString('pt-BR') : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}

      {showCreate && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,.7)', display: 'grid', placeItems: 'center', zIndex: 100
        }}>
          <div style={{ width: 420, padding: 32, background: 'var(--panel)', border: '1px solid var(--line)', borderRadius: 20 }}>
            <h3 style={{ marginBottom: 20 }}>Nova Loja</h3>
            <div style={{ display: 'grid', gap: 14 }}>
              <div>
                <div className="label" style={{ marginBottom: 6 }}>Nome da Loja</div>
                <input value={form.name} onChange={e => setForm(f => ({ ...f, name: e.target.value }))} placeholder="Ex: Minha Loja BR" />
              </div>
              <div>
                <div className="label" style={{ marginBottom: 6 }}>Marketplace</div>
                <select value={form.marketplace} onChange={e => setForm(f => ({ ...f, marketplace: e.target.value }))}>
                  <option value="AMAZON_BR">Amazon Brasil</option>
                  <option value="AMAZON_US">Amazon USA</option>
                  <option value="AMAZON_MX">Amazon México</option>
                  <option value="AMAZON_CA">Amazon Canadá</option>
                </select>
              </div>
              <div>
                <div className="label" style={{ marginBottom: 6 }}>Seller ID</div>
                <input value={form.seller_id} onChange={e => setForm(f => ({ ...f, seller_id: e.target.value }))} placeholder="AXXXXXXXXXXXXXXX" />
              </div>
            </div>
            {err && <div style={{ marginTop: 12, color: 'var(--red)', fontSize: 13 }}>{err}</div>}
            <div style={{ display: 'flex', gap: 10, marginTop: 20 }}>
              <button className="btn primary" onClick={create} disabled={creating || !form.name}>
                {creating ? 'Criando...' : 'Criar Loja'}
              </button>
              <button className="btn" onClick={() => { setShowCreate(false); setErr('') }}>Cancelar</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
