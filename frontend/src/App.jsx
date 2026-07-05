import { useState, useCallback } from 'react'
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
  { key: 'overview',     label: 'Visão Geral',     icon: '◈' },
  { key: 'stores',       label: 'Multi-Loja',       icon: '⊞' },
  { key: 'campaigns',    label: 'Campanhas',         icon: '⟡' },
  { key: 'journey',      label: 'Jornada',           icon: '⤳' },
  { key: 'audiences',    label: 'Audiências',        icon: '⊛' },
  { key: 'recommendations', label: 'Recomendações',  icon: '⚡' },
  { key: 'queries',      label: 'Query Catalog',     icon: '◉' },
  { key: 'api',          label: 'API / Webhooks',    icon: '⊕' },
  { key: 'settings',     label: 'Configurações',     icon: '⚙' },
]

const PAGE_MAP = {
  overview: Overview,
  stores: Stores,
  campaigns: Campaigns,
  journey: Journey,
  audiences: Audiences,
  recommendations: Recommendations,
  queries: Queries,
  api: APIPage,
  settings: Settings,
}

const MOCK_TENANTS = [
  { id: 'tenant-zanom', name: 'ZANOM Marketplace' },
  { id: 'tenant-demo', name: 'Demo Corp' },
]

const MOCK_STORES = [
  { id: 'store-br-001', name: 'Brasil - Loja Principal' },
  { id: 'store-us-001', name: 'US - Main Store' },
]

export default function App() {
  const [page, setPage] = useState('overview')
  const [tenantID, setTenantID] = useState(MOCK_TENANTS[0].id)
  const [storeID, setStoreID] = useState(MOCK_STORES[0].id)

  const go = useCallback((k) => setPage(k), [])

  const PageComponent = PAGE_MAP[page] || Overview
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
          <select value={tenantID} onChange={e => setTenantID(e.target.value)}>
            {MOCK_TENANTS.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
          <div style={{ height: 10 }} />
          <div className="label">Loja Ativa</div>
          <select value={storeID} onChange={e => setStoreID(e.target.value)}>
            {MOCK_STORES.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </div>

        <div className="nav-section">Principal</div>
        <nav className="nav">
          {PAGES.slice(0, 6).map(p => (
            <button
              key={p.key}
              className={page === p.key ? 'active' : ''}
              onClick={() => go(p.key)}
            >
              <span>{p.icon}  {p.label}</span>
              <span className="dot" />
            </button>
          ))}
        </nav>

        <div className="nav-section">Plataforma</div>
        <nav className="nav">
          {PAGES.slice(6).map(p => (
            <button
              key={p.key}
              className={page === p.key ? 'active' : ''}
              onClick={() => go(p.key)}
            >
              <span>{p.icon}  {p.label}</span>
              <span className="dot" />
            </button>
          ))}
        </nav>
      </aside>

      <main className="main">
        <PageComponent ctx={ctx} />
      </main>
    </div>
  )
}
