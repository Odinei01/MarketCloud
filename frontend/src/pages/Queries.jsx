import { useState } from 'react'

const TEMPLATES = [
  {
    id: 't1', name: 'ASSISTED_CONVERSIONS', category: 'attribution',
    desc: 'Atribuição multi-touch: campanhas que assistem conversões sem ser last-click.',
    status: 'SUCCEEDED', lastRun: '2025-07-04T14:32:00Z', duration: '4m 12s',
  },
  {
    id: 't2', name: 'PATH_TO_PURCHASE', category: 'journey',
    desc: 'Jornada completa do comprador: sequência de touchpoints até conversão.',
    status: 'SUCCEEDED', lastRun: '2025-07-04T13:55:00Z', duration: '6m 48s',
  },
  {
    id: 't3', name: 'FREQUENCY_ANALYSIS', category: 'reach',
    desc: 'Frequência ótima de exposição: quantas impressões convertem mais.',
    status: 'SUCCEEDED', lastRun: '2025-07-04T12:10:00Z', duration: '3m 22s',
  },
  {
    id: 't4', name: 'REMARKETING_POOL', category: 'audiences',
    desc: 'Geração de pool de audiências qualificadas para remarketing.',
    status: 'RUNNING', lastRun: '2025-07-05T14:00:00Z', duration: '—',
  },
  {
    id: 't5', name: 'KEYWORD_ROLE', category: 'campaigns',
    desc: 'Classifica keywords por papel de conversão usando dados AMC.',
    status: 'QUEUED', lastRun: null, duration: '—',
  },
  {
    id: 't6', name: 'ASIN_CROSS_SELL', category: 'products',
    desc: 'Oportunidades de cross-sell baseadas em co-compras no período.',
    status: 'CREATED', lastRun: null, duration: '—',
  },
]

const STATUS_COLOR = {
  SUCCEEDED: 'green',
  RUNNING: 'blue',
  QUEUED: 'gold',
  CREATED: '',
  FAILED: 'red',
  SUBMITTED: 'purple',
  MODELING_STARTED: 'purple',
  INSIGHTS_GENERATED: 'green',
}

const SQL_PREVIEW = `SELECT
  campaign_id,
  SUM(attributed_conversions_1d) AS direct_conversions,
  SUM(attributed_conversions_7d - attributed_conversions_1d) AS assist_conversions,
  SUM(attributed_sales_7d) AS revenue,
  COUNT(DISTINCT user_id) AS unique_users
FROM amcod.impressions_clicks
WHERE event_date BETWEEN :start_date AND :end_date
  AND marketplace_id = :marketplace_id
GROUP BY campaign_id
HAVING assist_conversions > 0
ORDER BY assist_conversions DESC`

export default function Queries({ ctx }) {
  const [sel, setSel] = useState(TEMPLATES[0])
  const [running, setRunning] = useState(null)

  const runQuery = (t) => {
    setRunning(t.id)
    setTimeout(() => setRunning(null), 2000)
  }

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Query Catalog</h2>
          <p>Templates AMC prontos — execute e agende análises de atribuição</p>
        </div>
        <div className="actions">
          <button className="btn">Ver Histórico</button>
          <button className="btn primary">+ Custom Query</button>
        </div>
      </div>

      <div className="grid two">
        <div className="panel">
          <div className="panel-head"><h3>Templates Disponíveis</h3></div>
          <div>
            {TEMPLATES.map(t => (
              <div
                key={t.id}
                onClick={() => setSel(t)}
                style={{
                  padding: '14px 20px',
                  borderBottom: '1px solid var(--line)',
                  cursor: 'pointer',
                  background: sel?.id === t.id ? 'rgba(243,201,107,.06)' : 'transparent',
                  transition: '.15s',
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
                  <span style={{ fontWeight: 700, fontSize: 13 }}>{t.name}</span>
                  <span className={`pill ${STATUS_COLOR[t.status]}`}>{t.status}</span>
                </div>
                <div style={{ color: 'var(--muted)', fontSize: 12 }}>{t.desc}</div>
                {t.lastRun && (
                  <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 5 }}>
                    Última execução: {new Date(t.lastRun).toLocaleString('pt-BR')} • {t.duration}
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>

        <div style={{ display: 'grid', gap: 16, alignContent: 'start' }}>
          {sel && (
            <>
              <div className="panel">
                <div className="panel-head">
                  <h3>{sel.name}</h3>
                  <span className={`pill ${STATUS_COLOR[sel.status]}`}>{sel.status}</span>
                </div>
                <div className="panel-body">
                  <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 16 }}>{sel.desc}</p>
                  <div style={{ display: 'flex', gap: 10 }}>
                    <button
                      className="btn primary"
                      style={{ flex: 1 }}
                      onClick={() => runQuery(sel)}
                      disabled={running === sel.id}
                    >
                      {running === sel.id ? '⟳ Enviando...' : '▶ Executar Query'}
                    </button>
                    <button className="btn">Agendar</button>
                  </div>
                </div>
              </div>

              <div className="panel">
                <div className="panel-head"><h3>SQL Preview</h3></div>
                <div className="panel-body">
                  <div className="code">{SQL_PREVIEW}</div>
                </div>
              </div>
            </>
          )}
        </div>
      </div>

      <div className="gap" />

      <div className="panel">
        <div className="panel-head"><h3>Execuções Recentes</h3></div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Query</th>
                <th>Status</th>
                <th>Iniciada</th>
                <th>Duração</th>
                <th>Insights Gerados</th>
              </tr>
            </thead>
            <tbody>
              {TEMPLATES.filter(t => t.lastRun).map(t => (
                <tr key={t.id}>
                  <td style={{ fontWeight: 700 }}>{t.name}</td>
                  <td><span className={`pill ${STATUS_COLOR[t.status]}`}>{t.status}</span></td>
                  <td style={{ color: 'var(--muted)', fontSize: 12 }}>{new Date(t.lastRun).toLocaleString('pt-BR')}</td>
                  <td>{t.duration}</td>
                  <td style={{ color: 'var(--green)' }}>{t.status === 'SUCCEEDED' ? Math.floor(Math.random() * 5 + 2) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
