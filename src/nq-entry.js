import app, { MetricsBroadcaster as BaseMetricsBroadcaster } from './index.js'

// Wrangler 需要在 Worker 入口文件中直接看到 Durable Object class。
export class MetricsBroadcaster extends BaseMetricsBroadcaster {}

let nqSchemaReady = false

const NQ_RUNTIME_SCRIPT = `<script data-cfsm-nq-runtime>
(() => {
  const BUTTON_CLASS = 'cfsm-nq-button'
  const ROW_CLASS = 'cfsm-nq-row'
  let nqServers = []
  let renderQueued = false

  function text(value) {
    return String(value ?? '').trim()
  }

  function findServerForCard(card) {
    const headerText = text(card.firstElementChild?.textContent || card.textContent)
    return nqServers.find(server => headerText.includes(text(server.name))) || null
  }

  function makeButton(server) {
    const link = document.createElement('a')
    link.className = BUTTON_CLASS
    link.href = server.nq_url
    link.target = '_blank'
    link.rel = 'noopener noreferrer'
    link.title = server.nq_updated_at
      ? 'NodeQuality · ' + new Date(Number(server.nq_updated_at)).toLocaleString()
      : 'NodeQuality'
    link.style.cssText = [
      'display:inline-flex',
      'align-items:center',
      'gap:4px',
      'height:22px',
      'padding:0 7px',
      'border:1px solid rgba(16,185,129,.38)',
      'border-radius:4px',
      'background:rgba(16,185,129,.06)',
      'color:inherit',
      'font-size:11px',
      'line-height:1',
      'font-weight:600',
      'text-decoration:none',
      'cursor:pointer'
    ].join(';')

    const icon = document.createElement('span')
    icon.textContent = 'N'
    icon.style.cssText = 'font-weight:800;color:#10b981;font-size:12px'

    const label = document.createElement('span')
    label.textContent = 'NQ'

    link.append(icon, label)
    link.addEventListener('click', event => event.stopPropagation())
    link.addEventListener('mousedown', event => event.stopPropagation())
    return link
  }

  function renderButtons() {
    for (const card of document.querySelectorAll('.node-card')) {
      const server = findServerForCard(card)
      const oldRow = card.querySelector('.' + ROW_CLASS)

      if (!server) {
        oldRow?.remove()
        continue
      }

      let row = oldRow
      if (!row) {
        row = document.createElement('div')
        row.className = ROW_CLASS
        row.style.cssText = 'display:flex;align-items:center;justify-content:flex-start;margin-top:8px;min-height:22px'

        // Emerald 的 CardX：第 1 个子元素是 header，第 2 个子元素是 content。
        // 放进 content 尾部，可以稳定显示在延迟/丢包色带下方。
        const content = card.children[1] || card
        content.appendChild(row)
      }

      let button = row.querySelector('.' + BUTTON_CLASS)
      if (!button) {
        button = makeButton(server)
        row.appendChild(button)
      } else {
        button.href = server.nq_url
        button.title = server.nq_updated_at
          ? 'NodeQuality · ' + new Date(Number(server.nq_updated_at)).toLocaleString()
          : 'NodeQuality'
      }
    }
  }

  function queueRender() {
    if (renderQueued) return
    renderQueued = true
    requestAnimationFrame(() => {
      renderQueued = false
      renderButtons()
    })
  }

  async function refreshReports() {
    try {
      const response = await fetch('/api/servers', {
        cache: 'no-store',
        headers: { Accept: 'application/json' }
      })
      if (!response.ok) return
      const data = await response.json()
      nqServers = (Array.isArray(data?.servers) ? data.servers : [])
        .filter(server => server && server.nq_url && server.name)
        .sort((a, b) => text(b.name).length - text(a.name).length)
      queueRender()
    } catch (_) {
      // 页面本身仍可正常使用；下一轮会自动重试。
    }
  }

  function start() {
    const observer = new MutationObserver(queueRender)
    observer.observe(document.documentElement, { childList: true, subtree: true })
    refreshReports()
    setInterval(refreshReports, 60_000)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true })
  } else {
    start()
  }
})()
</script>`

async function injectNodeQualityRuntime(response, pathname) {
  if (!response || !response.ok) return response
  if (pathname === '/admin' || pathname.startsWith('/admin/')) return response

  const contentType = response.headers.get('Content-Type') || ''
  if (!contentType.includes('text/html')) return response

  let html
  try {
    html = await response.text()
  } catch (_) {
    return response
  }

  if (html.includes('data-cfsm-nq-runtime')) {
    return new Response(html, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers
    })
  }

  const injected = html.includes('</body>')
    ? html.replace('</body>', `${NQ_RUNTIME_SCRIPT}</body>`)
    : `${html}${NQ_RUNTIME_SCRIPT}`

  const headers = new Headers(response.headers)
  headers.delete('Content-Length')
  headers.set('Cache-Control', 'no-cache')

  return new Response(injected, {
    status: response.status,
    statusText: response.statusText,
    headers
  })
}

async function ensureNodeQualitySchema(db) {
  if (nqSchemaReady) return

  await db.prepare(`
    CREATE TABLE IF NOT EXISTS nodequality_reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      server_id TEXT NOT NULL,
      report_url TEXT NOT NULL,
      tested_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  `).run()

  await db.prepare(`
    CREATE INDEX IF NOT EXISTS idx_nodequality_reports_server_time
    ON nodequality_reports(server_id, tested_at DESC, id DESC)
  `).run()

  nqSchemaReady = true
}

function jsonResponse(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      ...headers
    }
  })
}

function normalizeReportUrl(value) {
  const url = String(value || '').trim()
  if (!/^https:\/\/(?:www\.)?nodequality\.com\/r\/[A-Za-z0-9_-]+\/?$/i.test(url)) {
    return ''
  }
  return url.replace(/\/$/, '')
}

function normalizeTestedAt(value) {
  const number = Number(value)
  if (!Number.isFinite(number) || number <= 0) return Date.now()
  return number < 10_000_000_000 ? Math.trunc(number * 1000) : Math.trunc(number)
}

async function handleNodeQualityReport(request, env) {
  let body
  try {
    body = await request.json()
  } catch (_) {
    return jsonResponse({ error: 'Invalid JSON', code: 400 }, 400)
  }

  const serverId = String(body?.id || '').trim()
  const secret = String(body?.secret || '')
  const reportUrl = normalizeReportUrl(body?.report_url || body?.url)
  const testedAt = normalizeTestedAt(body?.tested_at)

  if (!serverId) {
    return jsonResponse({ error: 'Missing server id', code: 400 }, 400)
  }
  if (!env.API_SECRET || secret !== env.API_SECRET) {
    return jsonResponse({ error: 'Invalid secret', code: 401 }, 401)
  }
  if (!reportUrl) {
    return jsonResponse({ error: 'Invalid NodeQuality report URL', code: 400 }, 400)
  }

  await ensureNodeQualitySchema(env.DB)

  const server = await env.DB.prepare(
    'SELECT id, name FROM servers WHERE id = ? LIMIT 1'
  ).bind(serverId).first()

  if (!server) {
    return jsonResponse({ error: 'Server not found', code: 404 }, 404)
  }

  const now = Date.now()
  await env.DB.prepare(`
    INSERT INTO nodequality_reports (server_id, report_url, tested_at, created_at)
    VALUES (?, ?, ?, ?)
  `).bind(serverId, reportUrl, testedAt, now).run()

  // 每台服务器最多保留最近 24 份（按每月两次约等于一年历史）。
  await env.DB.prepare(`
    DELETE FROM nodequality_reports
    WHERE server_id = ?
      AND id NOT IN (
        SELECT id FROM nodequality_reports
        WHERE server_id = ?
        ORDER BY tested_at DESC, id DESC
        LIMIT 24
      )
  `).bind(serverId, serverId).run()

  return jsonResponse({
    success: true,
    id: serverId,
    name: server.name || '',
    report_url: reportUrl,
    tested_at: testedAt
  })
}

async function getLatestReports(db) {
  await ensureNodeQualitySchema(db)

  const { results = [] } = await db.prepare(`
    SELECT server_id, report_url, tested_at
    FROM (
      SELECT
        server_id,
        report_url,
        tested_at,
        ROW_NUMBER() OVER (
          PARTITION BY server_id
          ORDER BY tested_at DESC, id DESC
        ) AS rn
      FROM nodequality_reports
    )
    WHERE rn = 1
  `).all()

  return new Map(results.map(row => [String(row.server_id), {
    nq_url: row.report_url,
    nq_updated_at: Number(row.tested_at) || 0
  }]))
}

function attachLatestReport(server, reports) {
  if (!server || typeof server !== 'object') return server
  const report = reports.get(String(server.id))
  if (!report) return server
  server.nq_url = report.nq_url
  server.nq_updated_at = report.nq_updated_at
  return server
}

async function enrichDashboardResponse(response, env, path) {
  if (!response || !response.ok) return response
  const contentType = response.headers.get('Content-Type') || ''
  if (!contentType.includes('application/json')) return response

  let data
  try {
    data = await response.clone().json()
  } catch (_) {
    return response
  }

  const reports = await getLatestReports(env.DB)

  if (path === '/api/servers' && Array.isArray(data?.servers)) {
    data.servers.forEach(server => attachLatestReport(server, reports))
  } else if (path === '/api/server' && data && typeof data === 'object') {
    attachLatestReport(data, reports)
  } else {
    return response
  }

  const headers = new Headers(response.headers)
  headers.set('Content-Type', 'application/json; charset=utf-8')
  headers.set('Cache-Control', 'no-store')
  headers.delete('Content-Length')

  return new Response(JSON.stringify(data), {
    status: response.status,
    statusText: response.statusText,
    headers
  })
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)

    if (request.method === 'POST' && url.pathname === '/api/nq-report') {
      return handleNodeQualityReport(request, env)
    }

    let response = await app.fetch(request, env, ctx)

    if (
      request.method === 'GET' &&
      (url.pathname === '/api/servers' || url.pathname === '/api/server')
    ) {
      try {
        return await enrichDashboardResponse(response, env, url.pathname)
      } catch (error) {
        console.warn('[NodeQuality] failed to enrich dashboard response:', error?.message || error)
      }
    }

    if (request.method === 'GET') {
      try {
        response = await injectNodeQualityRuntime(response, url.pathname)
      } catch (error) {
        console.warn('[NodeQuality] failed to inject theme runtime:', error?.message || error)
      }
    }

    return response
  },

  async scheduled(event, env, ctx) {
    return app.scheduled(event, env, ctx)
  }
}
