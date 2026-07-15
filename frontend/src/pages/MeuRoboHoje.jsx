import { useState, useEffect, useCallback } from 'react'
import { api } from '../api/client'

const brl = (v) => v == null ? '—' : `R$ ${Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 0 })}`

const VERDICT = {
  ESCALAR: { bg: '#12331c', border: '#27ae60' },
  MATAR:   { bg: '#3a1414', border: '#c0392b' },
}
const FAROL = {
  alta:       { bg: '#12331c', border: '#27ae60' },
  media:      { bg: '#33300f', border: '#e0b000' },
  aprendendo: { bg: '#33300f', border: '#e0b000' },
  baixa:      { bg: '#3a1414', border: '#c0392b' },
}

function Card({ children, style }) {
  return <div style={{ background: '#1a1e26', border: '1px solid #2a2f3a', borderRadius: 12, padding: 18, ...style }}>{children}</div>
}

export default function MeuRoboHoje({ ctx }) {
  const { tenantID } = ctx
  const [d, setD] = useState(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    setLoading(true); setErr('')
    try {
      const r = await api.robotToday(tenantID)
      if (r.ok) setD(r.data)
      else setErr(r.data?.error || `Falha ao carregar (${r.status})`)
    }
    catch (e) { setErr(String(e)) }
    setLoading(false)
  }, [tenantID])
  useEffect(() => { load() }, [load])

  if (loading) return <div style={{ padding: 24 }}>Carregando…</div>
  if (err) return <div style={{ padding: 24, color: '#e74c3c' }}>Erro: {err}</div>
  if (!d) return null

  const r = d.resumo || {}
  const conf = d.confianca || {}
  const varUp = (r.variacao_venda_pct || 0) >= 0

  return (
    <div style={{ padding: 24, maxWidth: 1000 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 12 }}>
        <h1 style={{ margin: 0 }}>Meu Robô Hoje</h1>
        <button className="btn" style={{ fontSize: 12 }} onClick={load}>Atualizar</button>
        <span style={{ opacity: 0.5, fontSize: 12 }}>últimos 30 dias</span>
      </div>

      {/* DINHEIRO */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 12, marginTop: 16 }}>
        <Card>
          <div style={{ opacity: 0.6, fontSize: 13 }}>Vendi com anúncio</div>
          <div style={{ fontSize: 30, fontWeight: 700 }}>{brl(r.vendi)}</div>
          <div style={{ fontSize: 13, color: varUp ? '#27ae60' : '#e74c3c' }}>
            {varUp ? '▲' : '▼'} {Math.abs(r.variacao_venda_pct || 0).toFixed(0)}% vs mês anterior
          </div>
        </Card>
        <Card>
          <div style={{ opacity: 0.6, fontSize: 13 }}>Gastei em anúncio</div>
          <div style={{ fontSize: 30, fontWeight: 700 }}>{brl(r.gastei)}</div>
          <div style={{ fontSize: 13, opacity: 0.6 }}>{Math.round(r.pedidos || 0)} pedidos</div>
        </Card>
        <Card>
          <div style={{ opacity: 0.6, fontSize: 13 }}>Retorno (cada R$1 virou)</div>
          <div style={{ fontSize: 30, fontWeight: 700 }}>R$ {(r.retorno || 0).toFixed(1)}</div>
          <div style={{ fontSize: 13, opacity: 0.6 }}>{(r.retorno || 0) >= 3 ? 'saudável' : 'atenção'}</div>
        </Card>
      </div>

      {/* CONFIANÇA */}
      <Card style={{ marginTop: 12, background: (FAROL[conf.nivel] || FAROL.aprendendo).bg, border: `1px solid ${(FAROL[conf.nivel] || FAROL.aprendendo).border}` }}>
        <div style={{ fontSize: 13, opacity: 0.6 }}>Dá pra confiar no robô?</div>
        <div style={{ fontSize: 16, fontWeight: 600, marginTop: 4 }}>{conf.texto}</div>
      </Card>

      {/* PRECISA DE VOCÊ */}
      <h2 style={{ marginTop: 24, marginBottom: 8 }}>Precisa de você</h2>
      {(!d.precisa_voce || d.precisa_voce.length === 0) && <p style={{ opacity: 0.5 }}>Nada urgente agora. 👍</p>}
      <div style={{ display: 'grid', gap: 10 }}>
        {(d.precisa_voce || []).map((a, i) => {
          const s = VERDICT[a.verdict] || VERDICT.ESCALAR
          return <div key={i} style={{ background: s.bg, border: `1px solid ${s.border}`, borderRadius: 10, padding: '13px 16px', fontWeight: 600 }}>{a.texto}</div>
        })}
      </div>

      {/* O ROBÔ FEZ */}
      <h2 style={{ marginTop: 24, marginBottom: 8 }}>O que o robô está fazendo</h2>
      {(!d.robo_fez || d.robo_fez.length === 0) && <p style={{ opacity: 0.5 }}>Sem ajustes no momento — deixando rodar.</p>}
      <div style={{ display: 'grid', gap: 8 }}>
        {(d.robo_fez || []).map((a, i) => (
          <div key={i} style={{ display: 'flex', gap: 10, alignItems: 'center', background: '#1a1e26', border: '1px solid #2a2f3a', borderRadius: 10, padding: '11px 14px' }}>
            <span style={{ fontSize: 18 }}>{a.icon}</span>
            <span>{a.texto}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
