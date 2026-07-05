import { useState, useEffect, useCallback } from 'react'
import { api, getToken, setToken } from './api/client.js'
import Login from './pages/Login.jsx'
import Overview from './pages/Overview.jsx'
import Stores from './pages/Stores.jsx'
import Campaigns from './pages/Campaigns.jsx'
import Journey from './pages/Journey.jsx'
import Audiences from './pages/Audiences.jsx'
import Recommendations from './pages/Recommendations.jsx'
import Queries from './pages/Queries.jsx'
import APIPage from './pages/APIPage.jsx'
import Settings from './pages/Settings.jsx'

const PAGES = [
  { key: 'overview',        label: 'Visão Geral',   icon: '◈', section: 'principal' },
  { key: 'stores',          label: 'Multi-Loja',    icon: '⊞', section: 'principal' },
  { key: 'campaigns',       label: 'Campanhas',     icon: '⟡', section: 'principal' },
  { key: 'journey',         label: 'Jornada',       icon: '⤳', section: 'principal' },
  { key: 'audiences',       label: 'Audiências',    icon: '⊛', section: 'principal' },
  { key: 'recommendations', label: 'Recomendações', icon: '⚡', section: 'principal' },
  { key: 'queries',         label: 'Query Catalog', icon: '◉', section: 'plataforma' },
  { key: 'api',             label: 'API / Webhooks',icon: '⊕', section: 'plataforma' },
  { key: 'settings',        label: 'Configurações', icon: '⚙', section: 'plataforma' },
]

const PAGE_MAP = {
  overview: Overview, stores: Stores, campaigns: Campaigns,
  journey: Journey, audiences: Audiences, recommendations: Recommendations,
  queries: Queries, api: APIPage, settings: Settings,
}

export default function App() {
  const [authed, setAuthed]   = useState(!!getToken())
  const [me, setMe]           = useState(null)
  const [page, setPage]       = useState('overview')
  const [stores, setStores]   = useState([])
  const [storeID, setStoreID] = useState('')

  // After login, load /me and stores
  const afterLogin = useCallback(async () => {
    setAuthed(true)
    const meR = await api.me()
    if (meR.ok) {
      setMe(meR.data)
      const tid = meR.data.tenant_id
      const stR = await api.listStores(tid)
      if (stR.ok && stR.data.items?.length) {
        setStores(stR.data.items)
        setStoreID(stR.data.items[0].id)
      }
    }
  }, [])

  // On mount, if already have token try to load me
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

  const principal = PAGES.filter(p => p.section === 'principal')
  const plataforma = PAGES.filter(p => p.section === 'plataforma')
  const PageComponent = PAGE_MAP[page] || Overview

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
            <div style={{ fontSize: 12, color: 'var(--muted)', padding: '6px 0' }}>Nenhuma loja cadastrada</div>
          )}
        </div>

        <div className="nav-section">Principal</div>
        <nav className="nav">
          {principal.map(p => (
            <button key={p.key} className={page === p.key ? 'active' : ''} onClick={() => setPage(p.key)}>
              <span>{p.icon}  {p.label}</span>
              <span className="dot" />
            </button>
          ))}
        </nav>

        <div className="nav-section">Plataforma</div>
        <nav className="nav">
          {plataforma.map(p => (
            <button key={p.key} className={page === p.key ? 'active' : ''} onClick={() => setPage(p.key)}>
              <span>{p.icon}  {p.label}</span>
              <span className="dot" />
            </button>
          ))}
        </nav>

        <div style={{ marginTop: 'auto', paddingTop: 20 }}>
          <button className="btn" style={{ width: '100%', fontSize: 12, padding: '9px 12px' }} onClick={logout}>
            Sair
          </button>
        </div>
      </aside>

      <main className="main">
        <PageComponent ctx={ctx} key={`${page}-${storeID}`} />
      </main>
    </div>
  )
}
