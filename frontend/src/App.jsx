import { useState, useEffect, useCallback } from 'react'
import { api, getToken, setToken } from './api/client.js'
import Login from './pages/Login.jsx'
import Queries from './pages/Queries.jsx'
import Settings from './pages/Settings.jsx'

export default function App() {
  const [authed, setAuthed]   = useState(!!getToken())
  const [me, setMe]           = useState(null)
  const [page, setPage]       = useState('queries')
  const [stores, setStores]   = useState([])
  const [storeID, setStoreID] = useState('')

  const afterLogin = useCallback(async () => {
    setAuthed(true)
    const meR = await api.me()
    if (!meR.ok) {
      setToken('')
      setAuthed(false)
      return
    }
    setMe(meR.data)
    const tid = meR.data.tenant_id
    const stR = await api.listStores(tid)
    if (stR.ok && stR.data.items?.length) {
      setStores(stR.data.items)
      setStoreID(stR.data.items[0].id)
    }
  }, [])

  useEffect(() => {
    if (getToken()) afterLogin()
  }, [afterLogin])

  const logout = () => {
    setToken('')
    setAuthed(false)
    setMe(null)
    setStores([])
    setStoreID('')
  }

  if (!authed) return <Login onLogin={afterLogin} />

  const tenantID = me?.tenant_id || ''
  const ctx = { tenantID, storeID }

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <div className="logo">MC</div>
          <div>
            <h1>MarketCloud</h1>
            <span>Engine v1.0</span>
          </div>
        </div>

        <div className="tenant-box">
          <div className="label">Tenant</div>
          <div style={{ fontSize: 13, padding: '6px 0', fontWeight: 700, color: 'var(--gold)' }}>
            {me?.name || '…'}
          </div>
          <div className="label" style={{ marginTop: 8 }}>Loja Ativa</div>
          {stores.length > 0 ? (
            <select value={storeID} onChange={e => setStoreID(e.target.value)}>
              {stores.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          ) : (
            <div style={{ fontSize: 12, color: 'var(--muted)', padding: '6px 0' }}>Nenhuma loja</div>
          )}
        </div>

        <nav className="nav" style={{ marginTop: 24 }}>
          <button className={page === 'queries' ? 'active' : ''} onClick={() => setPage('queries')}>
            <span>◉  AMC Queries</span><span className="dot" />
          </button>
          <button className={page === 'settings' ? 'active' : ''} onClick={() => setPage('settings')}>
            <span>⚙  Configurações</span><span className="dot" />
          </button>
        </nav>

        <div style={{ marginTop: 'auto', paddingTop: 20 }}>
          <button className="btn" style={{ width: '100%', fontSize: 12, padding: '9px 12px' }} onClick={logout}>
            Sair
          </button>
        </div>
      </aside>

      <main className="main">
        {page === 'queries'  && <Queries  ctx={ctx} key={`queries-${storeID}`} />}
        {page === 'settings' && <Settings ctx={ctx} key={`settings-${storeID}`} />}
      </main>
    </div>
  )
}
