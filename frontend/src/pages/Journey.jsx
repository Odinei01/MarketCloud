const STEPS = [
  {
    phase: 'Descoberta',
    color: 'var(--blue)',
    icon: '🔍',
    campaigns: ['Ampla - Calçados', 'Generic Broad'],
    users: '84.2k',
    rate: null,
    desc: 'Usuários expostos pela primeira vez à marca via campanhas de descoberta.',
  },
  {
    phase: 'Consideração',
    color: 'var(--purple)',
    icon: '⚡',
    campaigns: ['Broad - Esportes', 'SP Exact - Running'],
    users: '31.5k',
    rate: '37%',
    desc: 'Usuários que interagiram com campanhas assistidas após a descoberta.',
  },
  {
    phase: 'Conversão',
    color: 'var(--gold)',
    icon: '🎯',
    campaigns: ['Exata - Tênis Nike', 'SP Exact - Running'],
    users: '4.8k',
    rate: '15%',
    desc: 'Usuários que converteram por campanhas de conversão direta.',
  },
  {
    phase: 'Recompra',
    color: 'var(--green)',
    icon: '♻️',
    campaigns: ['Remarketing 30d'],
    users: '1.2k',
    rate: '25%',
    desc: 'Clientes reativados por audiências de remarketing pós-compra.',
  },
]

const PATH_DATA = [
  { path: 'Descoberta → Conversão', pct: 23, users: 19300 },
  { path: 'Descoberta → Consideração → Conversão', pct: 41, users: 34500 },
  { path: 'Direto → Conversão', pct: 18, users: 15100 },
  { path: 'Consideração → Conversão', pct: 12, users: 10100 },
  { path: 'Outros', pct: 6, users: 5000 },
]

export default function Journey({ ctx }) {
  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Jornada do Comprador</h2>
          <p>Análise multi-touch via AMC — path-to-purchase</p>
        </div>
        <div className="actions">
          <span className="pill gold">AMC: SUCCEEDED</span>
          <button className="btn primary">Rodar Query</button>
        </div>
      </div>

      <div className="journey" style={{ marginBottom: 16 }}>
        {STEPS.map((s, i) => (
          <div className="step" key={s.phase} style={{ borderColor: s.color + '44' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ fontSize: 22 }}>{s.icon}</span>
              {s.rate && <span className="pill green">{s.rate} conv.</span>}
            </div>
            <strong style={{ color: s.color, fontSize: 14 }}>Fase {i + 1}: {s.phase}</strong>
            <div style={{ fontSize: 24, fontWeight: 900, margin: '6px 0' }}>{s.users}</div>
            <small>{s.desc}</small>
            <div style={{ marginTop: 10 }}>
              {s.campaigns.map(c => (
                <span key={c} className="pill" style={{ marginRight: 4, marginTop: 4 }}>{c}</span>
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className="grid two">
        <div className="panel">
          <div className="panel-head"><h3>Principais Caminhos de Conversão</h3></div>
          <div className="panel-body">
            {PATH_DATA.map(p => (
              <div key={p.path} style={{ marginBottom: 16 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 6 }}>
                  <span>{p.path}</span>
                  <span style={{ color: 'var(--gold)', fontWeight: 800 }}>{p.pct}%</span>
                </div>
                <div className="bar">
                  <span style={{ width: p.pct + '%' }} />
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>{p.users.toLocaleString('pt-BR')} usuários</div>
              </div>
            ))}
          </div>
        </div>

        <div className="panel">
          <div className="panel-head"><h3>Frequência de Exposição</h3></div>
          <div className="panel-body">
            {[1, 2, 3, 4, 5].map(f => {
              const pct = [38, 27, 18, 10, 7][f - 1]
              return (
                <div key={f} style={{ marginBottom: 14 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, marginBottom: 5 }}>
                    <span>{f}× impressão</span>
                    <span style={{ color: 'var(--blue)' }}>{pct}%</span>
                  </div>
                  <div className="bar">
                    <span style={{ width: pct + '%', background: 'var(--blue)' }} />
                  </div>
                </div>
              )
            })}
            <div style={{ marginTop: 16, padding: 14, background: 'rgba(49,211,154,.07)', borderRadius: 14, border: '1px solid rgba(49,211,154,.2)', fontSize: 13 }}>
              <div style={{ color: 'var(--green)', fontWeight: 700, marginBottom: 6 }}>Frequência Ótima Detectada</div>
              <div style={{ color: 'var(--muted)' }}>Usuários expostos 2–3 vezes convertem 2.4× mais que expostos 1×</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
