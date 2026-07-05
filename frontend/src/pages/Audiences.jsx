import { useState } from 'react'

const DEMO = [
  { name: 'Compradores 30d - Tênis', size: 8420,  type: 'REMARKETING_POOL', status: 'READY',    score: 0.92, source: 'AMC' },
  { name: 'Visitantes sem compra 7d', size: 22100, type: 'REMARKETING_POOL', status: 'READY',    score: 0.74, source: 'AMC' },
  { name: 'Lookalike - Converters',  size: 45000, type: 'LOOKALIKE',        status: 'READY',    score: 0.88, source: 'AMC' },
  { name: 'Cross-sell - Meias',      size: 3200,  type: 'CROSS_SELL',       status: 'BUILDING', score: 0.61, source: 'AMC' },
  { name: 'Top 10% LTV',            size: 1100,  type: 'HIGH_VALUE',       status: 'READY',    score: 0.95, source: 'AMC' },
]

const TYPE_COLOR = {
  REMARKETING_POOL: 'gold',
  LOOKALIKE: 'blue',
  CROSS_SELL: 'purple',
  HIGH_VALUE: 'green',
}

export default function Audiences({ ctx }) {
  const [sel, setSel] = useState(null)

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Audiências AMC</h2>
          <p>Pools de remarketing e lookalike gerados via Amazon Marketing Cloud</p>
        </div>
        <div className="actions">
          <button className="btn primary">Gerar Nova Audiência</button>
        </div>
      </div>

      <div className="grid three" style={{ marginBottom: 16 }}>
        <div className="card">
          <div className="k">Total de Audiências</div>
          <div className="v">{DEMO.length}</div>
          <div className="s"><span className="up">+2</span> este mês</div>
        </div>
        <div className="card">
          <div className="k">Usuários Totais Mapeados</div>
          <div className="v" style={{ color: 'var(--blue)' }}>{(DEMO.reduce((a, b) => a + b.size, 0) / 1000).toFixed(0)}k</div>
          <div className="s">via AMC query pools</div>
        </div>
        <div className="card">
          <div className="k">Audiências Prontas</div>
          <div className="v" style={{ color: 'var(--green)' }}>{DEMO.filter(a => a.status === 'READY').length}</div>
          <div className="s">Disponíveis para ativação</div>
        </div>
      </div>

      <div className="grid two">
        <div className="panel">
          <div className="panel-head">
            <h3>Audiências Disponíveis</h3>
            <span className="pill gold">via AMC</span>
          </div>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Nome</th>
                  <th>Tipo</th>
                  <th>Tamanho</th>
                  <th>Score</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {DEMO.map(a => (
                  <tr key={a.name} style={{ cursor: 'pointer' }} onClick={() => setSel(a)}>
                    <td style={{ fontWeight: 700 }}>{a.name}</td>
                    <td><span className={`pill ${TYPE_COLOR[a.type]}`}>{a.type}</span></td>
                    <td>{a.size.toLocaleString('pt-BR')}</td>
                    <td>
                      <div className="bar" style={{ width: 80 }}>
                        <span style={{ width: (a.score * 100) + '%', background: a.score > 0.85 ? 'var(--green)' : a.score > 0.65 ? 'var(--gold)' : 'var(--red)' }} />
                      </div>
                    </td>
                    <td>
                      <span className={`pill ${a.status === 'READY' ? 'green' : 'orange'}`}>{a.status}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="panel">
          <div className="panel-head"><h3>Detalhes da Audiência</h3></div>
          {sel ? (
            <div className="panel-body">
              <div style={{ marginBottom: 14 }}>
                <span className={`pill ${TYPE_COLOR[sel.type]}`}>{sel.type}</span>
                <span className={`pill ${sel.status === 'READY' ? 'green' : 'orange'}`} style={{ marginLeft: 8 }}>{sel.status}</span>
              </div>
              <h3 style={{ fontSize: 18, marginBottom: 12 }}>{sel.name}</h3>
              <Row k="Tamanho" v={sel.size.toLocaleString('pt-BR') + ' usuários'} />
              <Row k="Fonte" v={sel.source} />
              <Row k="Priority Score" v={(sel.score * 100).toFixed(0) + '%'} />
              <div style={{ marginTop: 20 }}>
                <button className="btn primary" style={{ width: '100%' }}>Ativar em Campanha</button>
              </div>
            </div>
          ) : (
            <div className="empty">Selecione uma audiência para ver detalhes</div>
          )}
        </div>
      </div>
    </div>
  )
}

function Row({ k, v }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', borderBottom: '1px solid var(--line)', padding: '10px 0', fontSize: 13 }}>
      <span style={{ color: 'var(--muted)' }}>{k}</span>
      <span style={{ fontWeight: 700 }}>{v}</span>
    </div>
  )
}
