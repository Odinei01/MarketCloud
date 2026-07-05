import { useState, useEffect } from 'react'
import { api } from '../api/client.js'

const DEMO = {
  stores: 4,
  campaigns: 87,
  roas: '4.32',
  revenue: 'R$ 1,24M',
  insights: 23,
  recs: 11,
  runs: 8,
  topCamps: [
    { name: 'Exata - Tênis Nike', role: 'CONVERSION',   roas: 6.8, spend: 12400, rev: 84320 },
    { name: 'Ampla - Calçados',   role: 'DISCOVERY',    roas: 1.2, spend: 8200,  rev: 9840  },
    { name: 'Concorrente - Adidas', role: 'WASTE',      roas: 0.4, spend: 5500,  rev: 2200  },
    { name: 'Remarketing 30d',    role: 'REMARKETING',  roas: 3.9, spend: 3100,  rev: 12090 },
    { name: 'Broad - Esportes',   role: 'ASSISTED_CONVERSION', roas: 2.1, spend: 6800, rev: 14280 },
  ],
}

const ROLE_COLOR = {
  CONVERSION: 'green',
  DISCOVERY: 'blue',
  ASSISTED_CONVERSION: 'purple',
  REMARKETING: 'gold',
  WASTE: 'red',
  UNKNOWN: '',
}

export default function Overview({ ctx }) {
  return (
    <div>
      <div className="topbar">
        <div>
          <h2>Visão Geral</h2>
          <p>MarketCloud Intelligence • Atualizado há 4 minutos</p>
        </div>
        <div className="actions">
          <button className="btn">Exportar</button>
          <button className="btn primary">+ Nova Análise</button>
        </div>
      </div>

      <div className="grid cards">
        <div className="card">
          <div className="k">Lojas Ativas</div>
          <div className="v">{DEMO.stores}</div>
          <div className="s"><span className="up">+1</span> este mês</div>
        </div>
        <div className="card">
          <div className="k">Campanhas Monitoradas</div>
          <div className="v">{DEMO.campaigns}</div>
          <div className="s"><span className="up">+12</span> este mês</div>
        </div>
        <div className="card">
          <div className="k">ROAS Médio</div>
          <div className="v" style={{ color: 'var(--gold)' }}>{DEMO.roas}×</div>
          <div className="s"><span className="up">+0.3</span> vs mês anterior</div>
        </div>
        <div className="card">
          <div className="k">Receita Atribuída</div>
          <div className="v" style={{ color: 'var(--green)' }}>{DEMO.revenue}</div>
          <div className="s"><span className="up">+18%</span> vs mês anterior</div>
        </div>
      </div>

      <div className="gap" />

      <div className="grid two">
        <div className="panel">
          <div className="panel-head">
            <h3>Top Campanhas por Receita</h3>
            <span className="pill gold">últimos 30d</span>
          </div>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Campanha</th>
                  <th>Papel</th>
                  <th>ROAS</th>
                  <th>Investimento</th>
                  <th>Receita</th>
                </tr>
              </thead>
              <tbody>
                {DEMO.topCamps.map(c => (
                  <tr key={c.name}>
                    <td>{c.name}</td>
                    <td><span className={`pill ${ROLE_COLOR[c.role]}`}>{c.role}</span></td>
                    <td style={{ color: c.roas >= 4 ? 'var(--green)' : c.roas < 1 ? 'var(--red)' : 'var(--orange)' }}>{c.roas.toFixed(1)}×</td>
                    <td>R$ {c.spend.toLocaleString('pt-BR')}</td>
                    <td>R$ {c.rev.toLocaleString('pt-BR')}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div style={{ display: 'grid', gap: 16 }}>
          <div className="panel">
            <div className="panel-head"><h3>Status do Sistema</h3></div>
            <div className="panel-body">
              <StatusRow label="API Gateway" ok />
              <StatusRow label="Conector Amazon" ok />
              <StatusRow label="Query Orchestrator" ok />
              <StatusRow label="Modeling Worker" ok />
              <StatusRow label="AMC Queries" warn text="2 em fila" />
            </div>
          </div>
          <div className="panel">
            <div className="panel-head"><h3>Atividade Recente</h3></div>
            <div className="panel-body">
              {[
                { t: '14:32', msg: 'Query KEYWORD_ROLE concluída' },
                { t: '14:20', msg: '3 insights gerados — Loja BR' },
                { t: '13:55', msg: 'Recomendação aprovada: INCREASE_BUDGET' },
                { t: '13:10', msg: 'Nova campanha detectada: "SP Exact"' },
              ].map(a => (
                <div key={a.t} style={{ display: 'flex', gap: 12, marginBottom: 12, fontSize: 13 }}>
                  <span style={{ color: 'var(--muted)', flexShrink: 0 }}>{a.t}</span>
                  <span>{a.msg}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      <div className="gap" />

      <div className="grid three">
        <div className="card">
          <div className="k">Insights Gerados</div>
          <div className="v" style={{ color: 'var(--blue)' }}>{DEMO.insights}</div>
          <div className="s">Aguardando revisão: <span className="warn">7</span></div>
        </div>
        <div className="card">
          <div className="k">Recomendações Pendentes</div>
          <div className="v" style={{ color: 'var(--orange)' }}>{DEMO.recs}</div>
          <div className="s">Aprovadas hoje: <span className="up">4</span></div>
        </div>
        <div className="card">
          <div className="k">AMC Query Runs</div>
          <div className="v" style={{ color: 'var(--purple)' }}>{DEMO.runs}</div>
          <div className="s">Em execução: <span className="blue">2</span></div>
        </div>
      </div>
    </div>
  )
}

function StatusRow({ label, ok, warn, text }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, fontSize: 13 }}>
      <span>{label}</span>
      {ok  && <span className="pill green">● Online</span>}
      {warn && <span className="pill orange">⚠ {text}</span>}
    </div>
  )
}
