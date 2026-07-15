const BASE = '/api/v1'

let _token = localStorage.getItem('mc_token') || ''

export function setToken(t) {
  _token = t
  localStorage.setItem('mc_token', t)
}

export function getToken() { return _token }

async function req(method, path, body, tenantID, storeID) {
  const headers = { 'Content-Type': 'application/json' }
  if (_token) headers['Authorization'] = `Bearer ${_token}`
  if (tenantID) headers['X-Tenant-ID'] = tenantID
  if (storeID) headers['X-Store-ID'] = storeID

  const res = await fetch(BASE + path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  })

  if (res.status === 401) {
    _token = ''
    localStorage.removeItem('mc_token')
    window.location.hash = '#login'
  }

  const text = await res.text()
  try { return { ok: res.ok, status: res.status, data: JSON.parse(text) } }
  catch { return { ok: res.ok, status: res.status, data: { error: text } } }
}

export const api = {
  // Auth
  login: (email, password) => req('POST', '/auth/login', { email, password }),
  register: (tenant_id, email, password, name) => req('POST', '/auth/register', { tenant_id, email, password, name }),
  me: () => req('GET', '/auth/me'),
  refresh: (refresh_token) => req('POST', '/auth/refresh', { refresh_token }),

  // Tenants
  createTenant: (name, slug, plan) => req('POST', '/tenants', { name, slug, plan }),
  getTenant: (id) => req('GET', `/tenants/${id}`),

  // Organizations
  listOrgs: (tid) => req('GET', '/organizations', null, tid),
  createOrg: (tid, body) => req('POST', '/organizations', body, tid),

  // Stores
  listStores: (tid) => req('GET', '/stores', null, tid),
  createStore: (tid, body) => req('POST', '/stores', body, tid),
  getStore: (tid, id) => req('GET', `/stores/${id}`, null, tid),

  // Amazon profiles
  listProfiles: (tid, storeID) => req('GET', `/stores/${storeID}/amazon-profiles`, null, tid),
  registerProfile: (tid, storeID, body) => req('POST', `/stores/${storeID}/amazon-profiles`, body, tid),

  // AMC instances
  listAMC: (tid, storeID) => req('GET', `/stores/${storeID}/amc/instances`, null, tid),
  registerAMC: (tid, storeID, body) => req('POST', `/stores/${storeID}/amc/instances`, body, tid),

  // Amazon OAuth
  oauthStart: (tid, store_id) => req('POST', '/connections/amazon/oauth/start', { store_id }, tid),
  connectionStatus: (tid, store_id) => req('GET', `/connections/amazon/status?store_id=${store_id}`, null, tid),

  // Query templates
  listTemplates: (tid) => req('GET', '/query-templates', null, tid),
  getTemplate: (tid, id) => req('GET', `/query-templates/${id}`, null, tid),

  // Query runs
  createRun: (tid, body) => req('POST', '/query-runs', body, tid),
  listRuns: (tid, storeID, status) => {
    const p = new URLSearchParams()
    if (storeID) p.set('store_id', storeID)
    if (status) p.set('status', status)
    return req('GET', `/query-runs?${p}`, null, tid)
  },
  getRun: (tid, id) => req('GET', `/query-runs/${id}`, null, tid),

  // Insights
  listInsights: (tid, storeID, filters = {}) => {
    const p = new URLSearchParams()
    if (storeID) p.set('store_id', storeID)
    Object.entries(filters).forEach(([k, v]) => v && p.set(k, v))
    return req('GET', `/insights?${p}`, null, tid)
  },

  // Recommendations
  listRecs: (tid, storeID, status) => {
    const p = new URLSearchParams()
    if (storeID) p.set('store_id', storeID)
    if (status) p.set('status', status)
    return req('GET', `/recommendations?${p}`, null, tid)
  },
  approveRec: (tid, id) => req('POST', `/recommendations/${id}/approve`, {}, tid),
  rejectRec: (tid, id) => req('POST', `/recommendations/${id}/reject`, {}, tid),

  // External
  externalActions: (tid, storeID) => req('GET', `/external/recommendations/actions?store_id=${storeID}`, null, tid),

  // API clients
  listAPIClients: (tid) => req('GET', '/api-clients', null, tid),
  createAPIClient: (tid, body) => req('POST', '/api-clients', body, tid),

  // Usage
  usage: (tid) => req('GET', '/usage', null, tid),

  // Gold Layer V2 cockpit + feedback loop
  goldReviewQueue: (tid, filters = {}) => {
    const p = new URLSearchParams()
    Object.entries(filters).forEach(([k, v]) => v && p.set(k, v))
    return req('GET', `/gold/review-queue?${p}`, null, tid)
  },
  goldActionSummary: (tid) => req('GET', '/gold/action-summary', null, tid),
  amcAlerts: (tid) => req('GET', '/gold/amc-alerts', null, tid),
  robotToday: (tid) => req('GET', '/gold/robot-today', null, tid),
  goldHourlyReal: (tid, filters = {}) => {
    const p = new URLSearchParams()
    Object.entries(filters).forEach(([k, v]) => v && p.set(k, v))
    return req('GET', `/gold/hourly-real?${p}`, null, tid)
  },
  goldKeywordHourlyReal: (tid, filters = {}) => {
    const p = new URLSearchParams()
    Object.entries(filters).forEach(([k, v]) => v && p.set(k, v))
    return req('GET', `/gold/keyword-hourly-real?${p}`, null, tid)
  },
  goldMlAmsStatus: (tid) => req('GET', '/gold/ml-ams-status', null, tid),
  goldMlFullAutoCampaigns: (tid) => req('GET', '/gold/ml-full-auto-campaigns', null, tid),
  setGoldMlFullAutoCampaign: (tid, body) => req('PUT', '/gold/ml-full-auto-campaigns', body, tid),
  goldPartnerCampaignMonitor: (tid) => req('GET', '/gold/partner-campaign-monitor', null, tid),
  goldCampaignPlans: (tid) => req('GET', '/gold/campaign-plans', null, tid),
  goldDecide: (tid, id, body) => req('POST', `/gold/review-queue/${id}/decision`, body, tid),
}
