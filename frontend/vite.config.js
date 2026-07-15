import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Alvo do proxy /api configuravel por env: no container aponta para o
// service "api" (http://api:8090); fora do Docker (npm run dev direto) usa
// localhost:8090 por padrao.
const apiProxyTarget = process.env.VITE_API_PROXY_TARGET || 'http://localhost:8090'

export default defineConfig({
  plugins: [react()],
  server: {
    host: true,
    port: 3001,
    proxy: {
      '/api': { target: apiProxyTarget, changeOrigin: true }
    }
  }
})
