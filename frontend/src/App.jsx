import { useState, useEffect, useCallback } from 'react'
import { api, getToken, setToken } from './api/client.js'
import Login from './pages/Login.jsx'
import Queries from './pages/Queries.jsx'
import Settings from './pages/Settings.jsx'
import ReviewQueue from './pages/ReviewQueue.jsx'
import HorariosReais from './pages/HorariosReais.jsx'
import AmcAlerts from './pages/AmcAlerts.jsx'
import MeuRoboHoje from './pages/MeuRoboHoje.jsx'
import KeywordHorarios from './pages/KeywordHorarios.jsx'
import DaypartingCalibration from './pages/DaypartingCalibration.jsx'
import MetricasDayparting from './pages/MetricasDayparting.jsx'
import StatusAmsMl from './pages/StatusAmsMl.jsx'
import PartnerCampaignMonitor from './pages/PartnerCampaignMonitor.jsx'

export default function App() {
  const [authed, setAuthed]   = useState(!!getToken())
  const [me, setMe]           = useState(null)
  const [page, setPage]       = useState('robo-hoje')
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
            {me?.name || '...'}
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
          <button className={page === 'robo-hoje' ? 'active' : ''} onClick={() => setPage('robo-hoje')}>
            <span>RB Meu Robo Hoje</span><span className="dot" />
          </button>
          <button className={page === 'cockpit' ? 'active' : ''} onClick={() => setPage('cockpit')}>
            <span>CP Cockpit</span><span className="dot" />
          </button>
          <button className={page === 'horarios' ? 'active' : ''} onClick={() => setPage('horarios')}>
            <span>HR Horarios reais</span><span className="dot" />
          </button>
          <button className={page === 'keyword-horarios' ? 'active' : ''} onClick={() => setPage('keyword-horarios')}>
            <span>KW  Keywords x hora</span><span className="dot" />
          </button>
          <button className={page === 'dayparting-calib' ? 'active' : ''} onClick={() => setPage('dayparting-calib')}>
            <span>DP  Calibracao horaria</span><span className="dot" />
          </button>
          <button className={page === 'dayparting-metrics' ? 'active' : ''} onClick={() => setPage('dayparting-metrics')}>
            <span>MT  Medicao resultado</span><span className="dot" />
          </button>
          <button className={page === 'partner-monitor' ? 'active' : ''} onClick={() => setPage('partner-monitor')}>
            <span>M19 Monitor parceiro</span><span className="dot" />
          </button>
          <button className={page === 'status-ams-ml' ? 'active' : ''} onClick={() => setPage('status-ams-ml')}>
            <span>ST  Status AMS + ML</span><span className="dot" />
          </button>
          <button className={page === 'amc-alerts' ? 'active' : ''} onClick={() => setPage('amc-alerts')}>
            <span>AL Alertas AMC</span><span className="dot" />
          </button>
          <button className={page === 'queries' ? 'active' : ''} onClick={() => setPage('queries')}>
            <span>AM AMC Queries</span><span className="dot" />
          </button>
          <button className={page === 'settings' ? 'active' : ''} onClick={() => setPage('settings')}>
            <span>CF Config Center</span><span className="dot" />
          </button>
        </nav>

        <div style={{ marginTop: 'auto', paddingTop: 20 }}>
          <button className="btn" style={{ width: '100%', fontSize: 12, padding: '9px 12px' }} onClick={logout}>
            Sair
          </button>
        </div>
      </aside>

      <main className="main">
        {page === 'robo-hoje' && <MeuRoboHoje ctx={ctx} key={`robo-hoje-${storeID}`} />}
        {page === 'cockpit'  && <ReviewQueue ctx={ctx} key={`cockpit-${storeID}`} />}
        {page === 'horarios' && <HorariosReais ctx={ctx} key={`horarios-${storeID}`} />}
        {page === 'keyword-horarios' && <KeywordHorarios ctx={ctx} key={`keyword-horarios-${storeID}`} />}
        {page === 'dayparting-calib' && <DaypartingCalibration ctx={ctx} key={`dayparting-calib-${storeID}`} />}
        {page === 'dayparting-metrics' && <MetricasDayparting ctx={ctx} key={`dayparting-metrics-${storeID}`} />}
        {page === 'partner-monitor' && <PartnerCampaignMonitor ctx={ctx} key={`partner-monitor-${storeID}`} />}
        {page === 'status-ams-ml' && <StatusAmsMl ctx={ctx} key={`status-ams-ml-${storeID}`} />}
        {page === 'amc-alerts' && <AmcAlerts ctx={ctx} key={`amc-alerts-${storeID}`} />}
        {page === 'queries'  && <Queries  ctx={ctx} key={`queries-${storeID}`} />}
        {page === 'settings' && <Settings ctx={ctx} key={`settings-${storeID}`} />}
      </main>
    </div>
  )
}


