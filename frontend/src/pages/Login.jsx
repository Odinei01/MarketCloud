import { useState } from 'react'
import { api, setToken } from '../api/client.js'

export default function Login({ onLogin }) {
  const [email, setEmail] = useState('admin@zanom.com')
  const [password, setPassword] = useState('Zanom@123')
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)

  const submit = async (e) => {
    e.preventDefault()
    setLoading(true); setErr('')
    const r = await api.login(email, password)
    setLoading(false)
    if (!r.ok) { setErr(r.data.error || 'Login falhou'); return }
    setToken(r.data.access_token)
    onLogin(r.data)
  }

  return (
    <div style={{
      minHeight: '100vh', display: 'grid', placeItems: 'center',
      background: 'radial-gradient(circle at top left,rgba(110,168,255,.18),transparent 30%),radial-gradient(circle at 70% 20%,rgba(243,201,107,.10),transparent 35%),linear-gradient(135deg,#070b16 0%,#0b1020 45%,#111827 100%)',
    }}>
      <div style={{
        width: 380, padding: 40,
        border: '1px solid var(--line)',
        background: 'linear-gradient(180deg,rgba(255,255,255,.07),rgba(255,255,255,.032))',
        borderRadius: 24, boxShadow: 'var(--shadow)',
      }}>
        <div style={{ textAlign: 'center', marginBottom: 32 }}>
          <div style={{
            width: 56, height: 56, borderRadius: 16, margin: '0 auto 16px',
            background: 'linear-gradient(135deg,#f8d98a,#996b19)',
            display: 'grid', placeItems: 'center',
            color: '#101525', fontWeight: 950, fontSize: 24,
            boxShadow: '0 14px 35px rgba(243,201,107,.25)',
          }}>MC</div>
          <h2 style={{ fontSize: 22, letterSpacing: '-.03em', marginBottom: 6 }}>MarketCloud Engine</h2>
          <p style={{ color: 'var(--muted)', fontSize: 13 }}>Entre com sua conta para continuar</p>
        </div>

        <form onSubmit={submit} style={{ display: 'grid', gap: 14 }}>
          <div>
            <div className="label" style={{ marginBottom: 6 }}>Email</div>
            <input type="email" value={email} onChange={e => setEmail(e.target.value)} required />
          </div>
          <div>
            <div className="label" style={{ marginBottom: 6 }}>Senha</div>
            <input type="password" value={password} onChange={e => setPassword(e.target.value)} required />
          </div>

          {err && (
            <div style={{ padding: 10, background: 'rgba(255,107,107,.1)', border: '1px solid rgba(255,107,107,.3)', borderRadius: 10, color: 'var(--red)', fontSize: 13 }}>
              {err}
            </div>
          )}

          <button type="submit" className="btn primary" disabled={loading} style={{ width: '100%', marginTop: 6, padding: 14 }}>
            {loading ? 'Entrando...' : 'Entrar'}
          </button>
        </form>
      </div>
    </div>
  )
}
