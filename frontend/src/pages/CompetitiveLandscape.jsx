import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client.js'

const pct = (v, d = 1) => (v == null ? '—' : `${(Number(v) * 100).toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d })}%`)
const num = (v) => (v == null ? '—' : Number(v).toLocaleString('pt-BR'))

export default function CompetitiveLandscape({ ctx }) {
  const [competitors, setCompetitors] = useState([])
  const [shared, setShared] = useState([])
  const [sel, setSel] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    setLoading(true); setError('')
    api.goldCompetitorOverlap(ctx.tenantID)
      .then(res => {
        if (!res.ok) throw new Error(res.data?.error || 'falha')
        setCompetitors(res.data.competitors || [])
        setShared(res.data.shared_queries || [])
      })
      .catch(e => setError(e?.message || 'falha ao carregar'))
      .finally(() => setLoading(false))
  }, [ctx.tenantID])

  const drill = useMemo(() => shared.filter(s => s.competitor_asin === sel), [shared, sel])
  const muted = { color: 'var(--muted,#94a3b8)' }

  return (
    <section style={{ maxWidth: 1100, color: 'var(--fg,#e6edf7)' }}>
      <h2 style={{ margin: '0 0 4px' }}>Concorrentes Reais (§46-48)</h2>
      <p style={{ ...muted, fontSize: 12.5, marginTop: 0 }}>
        Quem realmente disputa as mesmas buscas da ZANOM — por comportamento de busca (Search Terms),
        não por categoria. Ranqueado por buscas compartilhadas + overlap ponderado.
      </p>
      {loading && <div style={muted}>Carregando…</div>}
      {error && <div style={{ color: '#fca5a5' }}>{error}</div>}
      {!loading && !competitors.length && <div style={muted}>Sem overlap de concorrentes ainda (a marca precisa aparecer em buscas do mercado).</div>}

      {competitors.length > 0 && (
        <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 16, marginTop: 12 }}>
          <div style={{ border: '1px solid var(--border,#2a3550)', borderRadius: 12, overflow: 'hidden' }}>
            <div style={{ padding: '10px 14px', fontWeight: 700 }}>Concorrentes por buscas compartilhadas</div>
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                <thead><tr style={{ ...muted, textAlign: 'left' }}>
                  <th style={{ padding: '4px 10px' }}>ASIN concorrente</th><th>Buscas</th><th>Top1</th><th>Top3</th>
                  <th>Click sh méd</th><th>Overlap</th>
                </tr></thead>
                <tbody>
                  {competitors.map((c, i) => (
                    <tr key={i} onClick={() => setSel(c.competitor_asin)}
                      style={{ borderTop: '1px solid var(--border,#22304a)', cursor: 'pointer',
                        background: sel === c.competitor_asin ? 'var(--panel-3,#16233c)' : 'transparent' }}>
                      <td style={{ padding: '4px 10px', fontFamily: 'monospace' }}>
                        <a href={`https://www.amazon.com.br/dp/${c.competitor_asin}`} target="_blank" rel="noreferrer"
                          onClick={e => e.stopPropagation()} style={{ color: 'var(--gold,#d4a531)' }}>{c.competitor_asin}</a>
                      </td>
                      <td style={{ fontWeight: 700 }}>{num(c.queries_shared_with_zanom)}</td>
                      <td>{num(c.queries_where_top1)}</td>
                      <td>{num(c.queries_where_top3)}</td>
                      <td>{pct(c.avg_click_share)}</td>
                      <td>{Number(c.weighted_overlap ?? 0).toFixed(2)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div style={{ border: '1px solid var(--border,#2a3550)', borderRadius: 12, overflow: 'hidden' }}>
            <div style={{ padding: '10px 14px', fontWeight: 700 }}>
              {sel ? `Buscas de ${sel}` : 'Clique num concorrente pra ver as buscas'}
            </div>
            {sel && (
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                  <thead><tr style={{ ...muted, textAlign: 'left' }}>
                    <th style={{ padding: '4px 10px' }}>Busca</th><th>Rank</th><th>Click sh</th><th>Conv sh</th>
                  </tr></thead>
                  <tbody>
                    {drill.map((s, i) => (
                      <tr key={i} style={{ borderTop: '1px solid var(--border,#22304a)' }}>
                        <td style={{ padding: '4px 10px' }} title={s.search_query}>{s.search_query}</td>
                        <td style={{ fontWeight: 700, color: s.competitor_rank === 1 ? '#f87171' : 'inherit' }}>#{s.competitor_rank}</td>
                        <td>{pct(s.competitor_click_share)}</td>
                        <td>{pct(s.competitor_conversion_share)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      )}
    </section>
  )
}
