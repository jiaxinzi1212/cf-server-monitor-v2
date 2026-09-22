import app, { MetricsBroadcaster as BaseMetricsBroadcaster } from './index.js'

// Wrangler 需要在 Worker 入口文件中直接看到 Durable Object class。
export class MetricsBroadcaster extends BaseMetricsBroadcaster {}

let nqSchemaReady = false

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

    const response = await app.fetch(request, env, ctx)

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

    return response
  },

  async scheduled(event, env, ctx) {
    return app.scheduled(event, env, ctx)
  }
}
