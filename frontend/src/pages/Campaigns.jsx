import { useState } from 'react'

const ROLES = ['ALL', 'CONVERSION', 'ASSISTED_CONVERSION', 'DISCOVERY', 'REMARKETING', 'WASTE', 'UNKNOWN']

const ROLE_COLOR = {
  CONVERSION: 'green',
  DISCOVERY: 'blue',
  ASSISTED_CONVERSION: 'purple',
  REMARKETING: 'gold',
  WASTE: 'red',
  UNKNOWN: '',
}

const DEMO = [
  { name: 'Exata - Tênis Nike', role: 'CONVERSION',          roas: 6.80, spend: 12400, rev: 84320, assist: 0.12, direct: 0.88, waste: 0.00, conv: 52 },
  { name: 'Broad - Esportes',   role: 'ASSISTED_CONVERSION', roas: 2.10, spend: 6800,  rev: 14280, assist: 0.71, direct: 0.21, waste: 0.08, conv: 14 },
  { name: 'Ampla - Calçados',   role: 'DISCOVERY',           roas: 1.20, spend: 8200,  rev: 9840,  assist: 0.55, direct: 0.12, waste: 0.33, conv: 6  },
  { name: 'Remarketing 30d',    role: 'REMARKETING',         roas: 3.90, spend: 3100,  rev: 12090, assist: 0.22, direct: 0.68, waste: 0.10, conv: 31 },
  { name: 'Concorrente - Adidas', role: 'WASTE',             roas: 0.40, spend: 5500,  rev: 2200,  assist: 0.08, direct: 0.04, waste: 0.88, conv: 2  },
  { name: 'SP Exact - Running', role: 'CONVERSION',          roas: 5.20, spend: 9800,  rev: 50960, assist: 0.09, direct: 0.81, waste: 0.10, conv: 38 },
  { name: 'Generic Broad',      role: 'UNKNOWN',             roas: 0.00, spend: 1200,  rev: 0,     assist: 0.00, direct: 0.00, waste: 1.00, conv: 0  },
]

function ScoreBar({ val, color }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <div className="bar" style={{ flex: 1 }}>
        <span style={{ width: (val * 100) + '%', background: `var(--${color})` }} />
      </div>
      <span style={{ fontSize: 12, color: `var(--${color})`, minWidth: 32 }}>{(val * 100).toFixed(0)}%</span>
    </div>
  )
}

export default function Campaigns({ ctx }) {
  const [roleFilter, setRoleFilter] = useState('ALL')
  const [q, setQ] = useState('')

  const rows = DEMO
    .filter(c => roleFilter === 'ALL' || c.role === roleFilter)
    .filter(c => c.name.toLowerCase().includes(q.toLowerCase()))

  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Campanhas</h2>
          <p>Classificação inteligente por papel de conversão</p>
        </div>
        <div className="actions">
          <button className="btn">Exportar CSV</button>
          <button className="btn primary">Sync Amazon</button>
        </div>
      </div>

      <div className="grid cards" style={{ marginBottom: 16 }}>
        {[
          { role: 'CONVERSION', count: DEMO.filter(c=>c.role==='CONVERSION').length, color: 'green' },
          { role: 'ASSISTED', count: DEMO.filter(c=>c.role==='ASSISTED_CONVERSION').length, color: 'purple' },
          { role: 'DISCOVERY', count: DEMO.filter(c=>c.role==='DISCOVERY').length, color: 'blue' },
          { role: 'WASTE', count: DEMO.filter(c=>c.role==='WASTE').length, color: 'red' },
        ].map(r => (
          <div className="card" key={r.role} style={{ minHeight: 'unset', padding: 16 }}>
            <div className="k">{r.role}</div>
            <div className="v" style={{ color: `var(--${r.color})`, fontSize: 26 }}>{r.count}</div>
          </div>
        ))}
      </div>

      <div className="search-row" style={{ marginBottom: 14 }}>
        <input placeholder="Buscar campanha..." value={q} onChange={e => setQ(e.target.value)} />
        <select value={roleFilter} onChange={e => setRoleFilter(e.target.value)}>
          {ROLES.map(r => <option key={r}>{r}</option>)}
        </select>
        <span className="pill" style={{ height: '100%', display: 'flex', alignItems: 'center' }}>
          {rows.length} campanhas
        </span>
      </div>

      <div className="panel">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Campanha</th>
                <th>Papel AMC</th>
                <th>ROAS</th>
                <th>Investimento</th>
                <th>Receita</th>
                <th>Conversão Direta</th>
                <th>Score Assistência</th>
                <th>Score Desperdício</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(c => (
                <tr key={c.name}>
                  <td style={{ fontWeight: 700 }}>{c.name}</td>
                  <td><span className={`pill ${ROLE_COLOR[c.role]}`}>{c.role}</span></td>
                  <td style={{ color: c.roas >= 4 ? 'var(--green)' : c.roas < 1 ? 'var(--red)' : 'var(--orange)', fontWeight: 800 }}>
                    {c.roas.toFixed(2)}×
                  </td>
                  <td>R$ {c.spend.toLocaleString('pt-BR')}</td>
                  <td>R$ {c.rev.toLocaleString('pt-BR')}</td>
                  <td className="score-cell"><ScoreBar val={c.direct} color="green" /></td>
                  <td className="score-cell"><ScoreBar val={c.assist} color="purple" /></td>
                  <td className="score-cell"><ScoreBar val={c.waste} color="red" /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
