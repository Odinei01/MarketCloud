import { useState } from 'react'

const DEMO = [
  {
    id: 'r1', action: 'INCREASE_BUDGET', campaign: 'Exata - Tênis Nike',
    title: 'Aumentar budget em 30%',
    body: 'Campanha com ROAS 6.8× está limitada por orçamento. Elevar budget de R$ 12.400 para R$ 16.120 capturaria estimadas 14 conversões adicionais.',
    impact: 'high', status: 'PENDING', confidence: 0.91,
  },
  {
    id: 'r2', action: 'DO_NOT_PAUSE', campaign: 'Broad - Esportes',
    title: 'NÃO pausar esta campanha',
    body: 'Campanha ASSISTED_CONVERSION com score 71% de assistência. Pausar eliminaria suporte a conversões do funil, reduzindo ROAS geral em até 18%.',
    impact: 'critical', status: 'PENDING', confidence: 0.96,
  },
  {
    id: 'r3', action: 'DECREASE_BID', campaign: 'Concorrente - Adidas',
    title: 'Reduzir lance em 60%',
    body: 'WASTE score 88%. Zero conversões diretas ou assistidas em R$ 5.500 de investimento. Reduzir bid evita desperdício sem eliminar presença.',
    impact: 'high', status: 'PENDING', confidence: 0.88,
  },
  {
    id: 'r4', action: 'CREATE_AUDIENCE', campaign: 'Remarketing 30d',
    title: 'Criar audiência de compradores 60d',
    body: 'Pool de recompra com 1.200 usuários altamente qualificados. Expandir janela para 60 dias aumentaria pool para ~3.800 usuários.',
    impact: 'medium', status: 'PENDING', confidence: 0.79,
  },
  {
    id: 'r5', action: 'DECREASE_BUDGET', campaign: 'Ampla - Calçados',
    title: 'Reduzir orçamento em 25%',
    body: 'ROAS 1.2× abaixo do target. Campanha DISCOVERY com assist_rate 55% ainda tem valor, mas budget pode ser reduzido sem impacto material na jornada.',
    impact: 'medium', status: 'APPROVED', confidence: 0.72,
  },
]

const IMPACT_COLOR = { high: 'red', critical: 'purple', medium: 'orange', low: 'blue' }
const ACTION_COLOR = {
  INCREASE_BUDGET: 'green',
  DO_NOT_PAUSE: 'purple',
  DECREASE_BID: 'orange',
  CREATE_AUDIENCE: 'blue',
  DECREASE_BUDGET: 'red',
}

export default function Recommendations({ ctx }) {
  const [recs, setRecs] = useState(DEMO)
  const [filter, setFilter] = useState('ALL')

  const approve = (id) => setRecs(r => r.map(x => x.id === id ? { ...x, status: 'APPROVED' } : x))
  const reject  = (id) => setRecs(r => r.map(x => x.id === id ? { ...x, status: 'REJECTED' } : x))

  const rows = filter === 'ALL' ? recs : recs.filter(r => r.status === filter)

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Recomendações</h2>
          <p>Ações inteligentes geradas pelo Modeling Worker</p>
        </div>
        <div className="actions">
          <select value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 160 }}>
            <option value="ALL">Todas</option>
            <option value="PENDING">Pendentes</option>
            <option value="APPROVED">Aprovadas</option>
            <option value="REJECTED">Rejeitadas</option>
          </select>
        </div>
      </div>

      <div className="grid three" style={{ marginBottom: 16 }}>
        <div className="card">
          <div className="k">Pendentes</div>
          <div className="v warn">{recs.filter(r => r.status === 'PENDING').length}</div>
        </div>
        <div className="card">
          <div className="k">Aprovadas</div>
          <div className="v up">{recs.filter(r => r.status === 'APPROVED').length}</div>
        </div>
        <div className="card">
          <div className="k">Rejeitadas</div>
          <div className="v down">{recs.filter(r => r.status === 'REJECTED').length}</div>
        </div>
      </div>

      <div className="insight-list">
        {rows.map(r => (
          <div className="insight" key={r.id} style={{
            borderColor: r.status === 'APPROVED' ? 'rgba(49,211,154,.3)' : r.status === 'REJECTED' ? 'rgba(255,107,107,.2)' : 'var(--line)'
          }}>
            <div className="meta">
              <span className={`pill ${ACTION_COLOR[r.action]}`}>{r.action}</span>
              <span className={`pill ${IMPACT_COLOR[r.impact]}`}>Impacto {r.impact}</span>
              <span className="pill">Confiança {(r.confidence * 100).toFixed(0)}%</span>
              {r.status !== 'PENDING' && (
                <span className={`pill ${r.status === 'APPROVED' ? 'green' : 'red'}`}>{r.status}</span>
              )}
            </div>
            <h4>{r.title}</h4>
            <div style={{ fontSize: 12, color: 'var(--muted)' }}>Campanha: {r.campaign}</div>
            <p>{r.body}</p>
            {r.status === 'PENDING' && (
              <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
                <button className="btn sm primary" onClick={() => approve(r.id)}>✓ Aprovar</button>
                <button className="btn sm" style={{ borderColor: 'rgba(255,107,107,.3)', color: 'var(--red)' }} onClick={() => reject(r.id)}>✕ Rejeitar</button>
              </div>
            )}
          </div>
        ))}
        {rows.length === 0 && <div className="empty">Nenhuma recomendação neste filtro.</div>}
      </div>
    </div>
  )
}
