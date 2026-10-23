"""Embedded local web dashboard for AgentPulse Windows."""
import os
import json
import urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import threading
import webbrowser
from datetime import datetime, timezone
from typing import Optional
from .models import AgentSource, SessionStats
from .tools import ToolScanner, ToolRegistry
from .discovery import SessionDiscovery, SessionRef, Readers, Monitor
from .usage import TokenUsageScanner, UsageAggregation, UsageRange
from .format import Fmt

scanner = TokenUsageScanner()

class DashboardHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        # Only answer requests addressed to our own loopback origin (blocks DNS-rebinding pages).
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost"):
            self.send_error(403)
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/":
            self._serve_html()
        elif path == "/api/status":
            self._serve_status()
        elif path == "/api/tools":
            self._serve_tools()
        elif path == "/api/sessions":
            tool_id = query.get("tool", ["codex"])[0]
            self._serve_sessions(tool_id)
        elif path == "/api/session-detail":
            sess_path = query.get("path", [""])[0]
            tool_id = query.get("tool", [""])[0]
            self._serve_session_detail(sess_path, tool_id)
        elif path == "/api/usage":
            range_val = query.get("range", ["month"])[0]
            tool_val = query.get("tool", [None])[0]
            self._serve_usage(range_val, tool_val)
        else:
            self.send_error(404)

    def _serve_json(self, data: dict):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_status(self):
        latest = Monitor.latest_session()
        active = Monitor.active_sessions()

        def serialize_stats(s):
            if not s: return None
            now = datetime.now(timezone.utc)
            waiting_elapsed = 0
            if s.waiting_since:
                b = s.waiting_since if s.waiting_since.tzinfo else s.waiting_since.replace(tzinfo=timezone.utc)
                waiting_elapsed = max(0, int((now - b).total_seconds()))
            return {
                "source": s.source.id,
                "displayName": s.source.display_name,
                "projectName": s.project_name,
                "path": s.path,
                "model": s.model,
                "turns": s.turns,
                "steps": s.steps,
                "recentTPS": s.recent_tps,
                "lastTPS": s.last_tps,
                "sessionTPS": s.session_tps,
                "credits": s.credits,
                "recentCreditRate": s.recent_credit_rate,
                "displayRecentSpeed": s.display_recent_speed,
                "speedUnit": s.speed_unit,
                "speedTitle": s.speed_title,
                "usesCredits": s.uses_credits,
                "totalTokens": s.total_tokens,
                "outputTokens": s.output_tokens,
                "uncachedInput": s.uncached_input,
                "cacheRead": s.cache_read,
                "cacheWrite": s.cache_write,
                "contextTokens": s.context_tokens,
                "contextWindow": s.context_window,
                "contextFraction": s.context_fraction,
                "avgTTFT": s.avg_ttft,
                "isWaiting": s.waiting_since is not None,
                "waitingElapsed": waiting_elapsed,
            }

        self._serve_json({
            "latest": serialize_stats(latest),
            "activeCount": len(active),
            "activeSessions": [serialize_stats(s) for s in active]
        })

    def _serve_tools(self):
        tools = ToolScanner.scan()
        data = []
        for t in tools:
            count = len(SessionDiscovery.sessions_for(t.spec, limit=1000)) if t.supported else 0
            data.append({
                "id": t.spec.id,
                "name": t.spec.name,
                "supported": t.supported,
                "hasApp": t.has_app,
                "hasCLI": t.has_cli,
                "hasData": t.has_data,
                "installKinds": t.install_kinds,
                "note": t.spec.note,
                "sessionCount": count
            })
        self._serve_json({"tools": data})

    def _serve_sessions(self, tool_id: str):
        spec = ToolRegistry.spec(tool_id)
        if not spec or not spec.format:
            self._serve_json({"sessions": []})
            return
        refs = SessionDiscovery.sessions_for(spec, limit=100)
        data = []
        for r in refs:
            base = os.path.basename(r.path)
            data.append({
                "path": r.path,
                "filename": base,
                "modified": r.modified.isoformat(),
                "relative": Fmt.relative(r.modified),
                "isSubagent": r.is_subagent
            })
        self._serve_json({"sessions": data})

    def _serve_session_detail(self, path: str, tool_id: str):
        spec = ToolRegistry.spec(tool_id)
        # Only parse files inside the tool's own session roots; never arbitrary paths.
        if not spec or not spec.format or not SessionDiscovery.is_under_session_roots(spec, path):
            self.send_error(404)
            return
        ref = SessionRef(path=path, source=AgentSource(id=spec.id), modified=datetime.now(timezone.utc))
        stats, requests = Readers.read_session(ref)
        steps_data = []
        for ss in stats.display_step_speeds:
            steps_data.append({
                "step": ss.step,
                "tokens": ss.output_tokens,
                "duration": round(ss.duration, 2),
                "tps": round(ss.tps, 1),
                "rate": round(ss.rate, 2),
                "credits": ss.credits,
                "time": ss.completed_at.strftime("%H:%M:%S")
            })

        self._serve_json({
            "source": stats.source.id,
            "displayName": stats.source.display_name,
            "projectName": stats.project_name,
            "model": stats.model,
            "turns": stats.turns,
            "steps": stats.steps,
            "displayRecentSpeed": round(stats.display_recent_speed, 1) if stats.display_recent_speed else None,
            "displayLastSpeed": round(stats.display_last_speed, 1) if stats.display_last_speed else None,
            "displaySessionSpeed": round(stats.display_session_speed, 1) if stats.display_session_speed else None,
            "speedUnit": stats.speed_unit,
            "speedTitle": stats.speed_title,
            "credits": stats.credits,
            "totalTokens": stats.total_tokens,
            "outputTokens": stats.output_tokens,
            "uncachedInput": stats.uncached_input,
            "cacheRead": stats.cache_read,
            "cacheWrite": stats.cache_write,
            "cacheHitRate": round((stats.cache_hit_rate or 0) * 100, 1),
            "contextTokens": stats.context_tokens,
            "contextWindow": stats.context_window,
            "contextFraction": round((stats.context_fraction or 0) * 100, 1),
            "avgTTFT": round(stats.avg_ttft, 2) if stats.avg_ttft else None,
            "modelTime": round(stats.model_time, 1),
            "toolTime": round(stats.tool_time, 1),
            "stepSpeeds": steps_data,
            "speedNote": stats.speed_note
        })

    def _serve_usage(self, range_val: str, tool_id: Optional[str]):
        since = UsageRange.start_date(range_val)
        events = scanner.scan(since=since, source_id=tool_id)
        summary = UsageAggregation.summary(events, range_val, tool_id=tool_id)

        buckets_data = []
        for b in summary.buckets:
            buckets_data.append({
                "date": b.tooltip_title,
                "label": b.axis_label,
                "total": b.totals.total,
                "output": b.totals.output,
                "uncached": b.totals.uncached_input,
                "cacheRead": b.totals.cache_read,
                "cacheWrite": b.totals.cache_write,
                "requests": b.totals.requests,
                "credits": b.totals.credits
            })

        tools_data = []
        for t in summary.tools:
            tools_data.append({
                "id": t.source.id,
                "name": t.source.display_name,
                "total": t.totals.total,
                "output": t.totals.output,
                "uncached": t.totals.uncached_input,
                "cacheRead": t.totals.cache_read,
                "cacheWrite": t.totals.cache_write,
                "requests": t.totals.requests,
                "sessions": t.session_count,
                "credits": t.totals.credits,
                "costUsd": round(t.cost.usd, 2)
            })

        models_data = []
        for m in summary.models:
            models_data.append({
                "model": m.model,
                "displayName": m.display_name,
                "total": m.totals.total,
                "requests": m.totals.requests,
                "costUsd": round(m.cost.usd, 2),
                "unpriced": m.cost.unpriced_tokens > 0
            })

        self._serve_json({
            "totalTokens": summary.totals.total,
            "outputTokens": summary.totals.output,
            "inputTokens": summary.totals.input,
            "cacheRead": summary.totals.cache_read,
            "cacheWrite": summary.totals.cache_write,
            "cacheHitRate": round((summary.totals.cache_hit_rate or 0) * 100, 1),
            "totalCostUsd": round(summary.cost.usd, 2),
            "pricedTokens": summary.cost.priced_tokens,
            "unpricedTokens": summary.cost.unpriced_tokens,
            "sessionCount": summary.session_count,
            "requests": summary.totals.requests,
            "credits": summary.totals.credits,
            "buckets": buckets_data,
            "tools": tools_data,
            "models": models_data
        })

    def _serve_html(self):
        html = DASHBOARD_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AgentPulse · Agent 速度表 (Windows)</title>
<style>
:root {
  --bg: #0f1115;
  --card-bg: #16181f;
  --card-border: #262a34;
  --text: #f0f3f8;
  --text-muted: #8b94a5;
  --accent: #3b82f6;
  --accent-green: #22c55e;
  --accent-amber: #f59e0b;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}
header {
  background: #13151b;
  border-bottom: 1px solid var(--card-border);
  padding: 14px 24px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 18px; }
.brand span { color: var(--accent); }
.nav-tabs { display: flex; gap: 8px; }
.nav-tab {
  padding: 7px 16px;
  border-radius: 8px;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  border: 1px solid transparent;
  font-size: 14px;
  font-weight: 500;
  transition: all 0.2s;
}
.nav-tab:hover { color: var(--text); background: rgba(255,255,255,0.04); }
.nav-tab.active { color: #fff; background: var(--accent); }

main { flex: 1; padding: 24px; max-width: 1400px; width: 100%; margin: 0 auto; }
.tab-pane { display: none; }
.tab-pane.active { display: block; }

.card {
  background: var(--card-bg);
  border: 1px solid var(--card-border);
  border-radius: 12px;
  padding: 20px;
  margin-bottom: 20px;
}
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 16px;
}
.card-title { font-size: 16px; font-weight: 600; color: var(--text); }

.grid-3 { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 20px; }
.metric-box {
  background: rgba(255,255,255,0.02);
  border: 1px solid var(--card-border);
  border-radius: 10px;
  padding: 16px;
}
.metric-label { font-size: 13px; color: var(--text-muted); margin-bottom: 6px; }
.metric-val { font-size: 26px; font-weight: 700; color: #fff; }
.metric-val.green { color: var(--accent-green); }
.metric-val.blue { color: var(--accent); }
.metric-val.amber { color: var(--accent-amber); }

.browser-layout { display: grid; grid-template-columns: 260px 320px 1fr; gap: 16px; height: 680px; }
.col-card {
  background: var(--card-bg);
  border: 1px solid var(--card-border);
  border-radius: 12px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.col-header { padding: 14px; background: rgba(255,255,255,0.02); border-bottom: 1px solid var(--card-border); font-weight: 600; font-size: 14px; }
.col-body { flex: 1; overflow-y: auto; padding: 8px; }
.item-row {
  padding: 10px 12px;
  border-radius: 8px;
  cursor: pointer;
  margin-bottom: 4px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 13px;
  transition: background 0.15s;
}
.item-row:hover { background: rgba(255,255,255,0.05); }
.item-row.active { background: rgba(59, 130, 246, 0.2); border: 1px solid var(--accent); }

table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--card-border); }
th { color: var(--text-muted); font-weight: 500; }
tr:hover td { background: rgba(255,255,255,0.02); }

.badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 500; }
.badge.blue { background: rgba(59,130,246,0.2); color: #60a5fa; }
.badge.green { background: rgba(34,197,94,0.2); color: #4ade80; }
</style>
</head>
<body>
<header>
  <div class="brand">
    <span>✦</span> AgentPulse · Windows
  </div>
  <div class="nav-tabs">
    <button class="nav-tab active" onclick="switchTab('monitor')">实时仪表盘</button>
    <button class="nav-tab" onclick="switchTab('browser')">会话浏览</button>
    <button class="nav-tab" onclick="switchTab('usage')">Token 消耗与费用</button>
  </div>
</header>

<main>
  <!-- 1. LIVE MONITOR -->
  <section id="pane-monitor" class="tab-pane active">
    <div class="grid-3">
      <div class="metric-box">
        <div class="metric-label">当前模型输出速度</div>
        <div id="live-speed" class="metric-val green">— tok/s</div>
        <div id="live-speed-desc" style="font-size:12px;color:var(--text-muted);margin-top:4px;">等待会话输出…</div>
      </div>
      <div class="metric-box">
        <div class="metric-label">当前活跃模型 / 工具</div>
        <div id="live-model" class="metric-val blue">—</div>
        <div id="live-tool" style="font-size:12px;color:var(--text-muted);margin-top:4px;">未检测到正在生成的会话</div>
      </div>
      <div class="metric-box">
        <div class="metric-label">上下文占用</div>
        <div id="live-context" class="metric-val amber">—%</div>
        <div id="live-context-desc" style="font-size:12px;color:var(--text-muted);margin-top:4px;">— / —</div>
      </div>
    </div>

    <div class="card">
      <div class="card-header">
        <div class="card-title">当前活跃会话</div>
        <button class="nav-tab" style="padding:4px 10px;" onclick="refreshStatus()">刷新</button>
      </div>
      <div id="active-sessions-list">
        <div style="color:var(--text-muted);padding:10px;">暂无运行中的会话（最近 10 分钟内无模型交互）</div>
      </div>
    </div>
  </section>

  <!-- 2. SESSION BROWSER -->
  <section id="pane-browser" class="tab-pane">
    <div class="browser-layout">
      <div class="col-card">
        <div class="col-header">已识别工具</div>
        <div class="col-body" id="browser-tools"></div>
      </div>
      <div class="col-card">
        <div class="col-header">历史会话</div>
        <div class="col-body" id="browser-sessions"></div>
      </div>
      <div class="col-card">
        <div class="col-header">会话详情 & 每步速度图表</div>
        <div class="col-body" id="browser-detail">
          <div style="color:var(--text-muted);padding:20px;text-align:center;">请选择左侧工具与会话</div>
        </div>
      </div>
    </div>
  </section>

  <!-- 3. TOKEN USAGE -->
  <section id="pane-usage" class="tab-pane">
    <div class="card">
      <div class="card-header">
        <div class="card-title">Token 消耗统计与费用估算</div>
        <div style="display:flex;gap:6px;">
          <button class="nav-tab active" onclick="loadUsage('week', this)">近 7 天</button>
          <button class="nav-tab" onclick="loadUsage('month', this)">近 30 天</button>
          <button class="nav-tab" onclick="loadUsage('quarter', this)">近 90 天</button>
          <button class="nav-tab" onclick="loadUsage('all', this)">全部</button>
        </div>
      </div>
      <div class="grid-3">
        <div class="metric-box">
          <div class="metric-label">消耗总 Token</div>
          <div id="usage-total-tok" class="metric-val blue">0 tok</div>
          <div id="usage-breakdown" style="font-size:12px;color:var(--text-muted);margin-top:4px;">缓存命中率: —%</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">官方标价估算费用</div>
          <div id="usage-cost" class="metric-val green">$0.00</div>
          <div style="font-size:12px;color:var(--text-muted);margin-top:4px;">未折算套餐与折扣</div>
        </div>
        <div class="metric-box">
          <div class="metric-label">会话与请求数</div>
          <div id="usage-reqs" class="metric-val">0</div>
          <div id="usage-sess-count" style="font-size:12px;color:var(--text-muted);margin-top:4px;">0 个会话</div>
        </div>
      </div>

      <div class="card" style="margin-top:16px;">
        <div class="card-title" style="margin-bottom:12px;">模型费用明细</div>
        <table>
          <thead>
            <tr>
              <th>模型</th>
              <th>总 Token</th>
              <th>请求次数</th>
              <th>估算费用</th>
            </tr>
          </thead>
          <tbody id="usage-models-tbody"></tbody>
        </table>
      </div>
    </div>
  </section>
</main>

<script>
function esc(v) { return String(v == null ? '' : v).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function switchTab(name) {
  document.querySelectorAll('.nav-tab').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
  event.target.classList.add('active');
  document.getElementById('pane-' + name).classList.add('active');
  if (name === 'browser') loadBrowserTools();
  if (name === 'usage') loadUsage('month');
}

async function refreshStatus() {
  try {
    const res = await fetch('/api/status');
    const data = await res.json();
    if (data.latest) {
      const s = data.latest;
      document.getElementById('live-speed').innerText = (s.displayRecentSpeed ? s.displayRecentSpeed.toFixed(1) : '—') + ' ' + s.speedUnit;
      document.getElementById('live-speed-desc').innerText = s.speedTitle + (s.isWaiting ? ' (生成中 ' + s.waitingElapsed + 's)' : '');
      document.getElementById('live-model').innerText = s.model || s.displayName;
      document.getElementById('live-tool').innerText = s.displayName + ' · ' + s.projectName;
      const frac = s.contextFraction ? (s.contextFraction * 100).toFixed(0) + '%' : '—%';
      document.getElementById('live-context').innerText = frac;
      document.getElementById('live-context-desc').innerText = (s.contextTokens ? s.contextTokens.toLocaleString() : '0') + ' / ' + (s.contextWindow ? s.contextWindow.toLocaleString() : '?') + ' tok';
    }
  } catch (e) {}
}
setInterval(refreshStatus, 1500);
refreshStatus();

async function loadBrowserTools() {
  const res = await fetch('/api/tools');
  const data = await res.json();
  const c = document.getElementById('browser-tools');
  c.innerHTML = data.tools.map(t => '<div class="item-row" onclick="selectTool(\\'' + t.id + '\\', this)"><div><div style="font-weight:600;">' + esc(t.name) + '</div><div style="font-size:11px;color:var(--text-muted);">' + t.installKinds + '</div></div><span class="badge ' + (t.supported ? 'green' : 'blue') + '">' + (t.supported ? t.sessionCount + ' 会话' : '已识别') + '</span></div>').join('');
  if (data.tools.length > 0) {
    const firstSupported = data.tools.find(t => t.supported) || data.tools[0];
    const el = c.children[0];
    if (el) selectTool(firstSupported.id, el);
  }
}

let currentToolId = '';
async function selectTool(toolId, el) {
  document.querySelectorAll('#browser-tools .item-row').forEach(r => r.classList.remove('active'));
  if (el) el.classList.add('active');
  currentToolId = toolId;
  const res = await fetch('/api/sessions?tool=' + toolId);
  const data = await res.json();
  const c = document.getElementById('browser-sessions');
  if (data.sessions.length === 0) {
    c.innerHTML = '<div style="color:var(--text-muted);padding:10px;">暂无历史会话</div>';
    document.getElementById('browser-detail').innerHTML = '<div style="color:var(--text-muted);padding:20px;text-align:center;">暂无数据</div>';
    return;
  }
  c.innerHTML = data.sessions.map(s => '<div class="item-row" onclick="selectSession(\\'' + encodeURIComponent(s.path) + '\\', this)"><div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:200px;"><div style="font-weight:500;">' + esc(s.filename) + '</div><div style="font-size:11px;color:var(--text-muted);">' + s.relative + '</div></div></div>').join('');
  if (c.children[0]) selectSession(encodeURIComponent(data.sessions[0].path), c.children[0]);
}

async function selectSession(encPath, el) {
  document.querySelectorAll('#browser-sessions .item-row').forEach(r => r.classList.remove('active'));
  if (el) el.classList.add('active');
  const res = await fetch('/api/session-detail?path=' + encPath + '&tool=' + currentToolId);
  const s = await res.json();
  const d = document.getElementById('browser-detail');
  const bars = (s.stepSpeeds || []).map(st => {
    const h = Math.min(100, Math.max(5, (st.rate / 200) * 100));
    return '<div title="第 ' + st.step + ' 步: ' + st.rate + ' ' + s.speedUnit + ' (' + st.tokens + ' tok, ' + st.duration + 's, ' + st.time + ')" style="flex:1;background:var(--accent-green);border-radius:3px;height:' + h + '%;cursor:pointer;"></div>';
  }).join('');
  d.innerHTML = '<div style="padding:16px;"><div style="font-size:18px;font-weight:700;margin-bottom:6px;">' + esc(s.projectName) + '</div><div style="color:var(--text-muted);font-size:13px;margin-bottom:16px;">' + esc(s.displayName) + ' · 模型: ' + esc(s.model || '未知') + ' · ' + s.turns + ' 轮 ' + s.steps + ' 步</div><div class="grid-3" style="margin-bottom:16px;"><div class="metric-box"><div class="metric-label">' + s.speedTitle + ' (近5步)</div><div class="metric-val green">' + (s.displayRecentSpeed || '—') + ' <span style="font-size:14px;">' + s.speedUnit + '</span></div></div><div class="metric-box"><div class="metric-label">总消耗 Token</div><div class="metric-val blue">' + s.totalTokens.toLocaleString() + '</div></div><div class="metric-box"><div class="metric-label">缓存命中率</div><div class="metric-val amber">' + s.cacheHitRate + '%</div></div></div><div class="card" style="margin-top:16px;"><div class="card-title">每步输出速度趋势 (最近40步)</div><div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;">包含步号、速度、耗时与 Token 数 (鼠标悬停查看每步)</div><div style="display:flex;gap:4px;align-items:flex-end;height:120px;background:rgba(0,0,0,0.2);border-radius:8px;padding:8px;">' + bars + '</div></div></div>';
}

async function loadUsage(range, btn) {
  if (btn) {
    btn.parentElement.querySelectorAll('button').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
  }
  const res = await fetch('/api/usage?range=' + range);
  const u = await res.json();
  document.getElementById('usage-total-tok').innerText = u.totalTokens.toLocaleString() + ' tok';
  document.getElementById('usage-breakdown').innerText = '缓存命中率: ' + u.cacheHitRate + '% · 输出: ' + u.outputTokens.toLocaleString();
  document.getElementById('usage-cost').innerText = '$' + u.totalCostUsd.toFixed(2);
  document.getElementById('usage-reqs').innerText = u.requests.toLocaleString() + ' 次请求';
  document.getElementById('usage-sess-count').innerText = u.sessionCount + ' 个会话';

  const tbody = document.getElementById('usage-models-tbody');
  tbody.innerHTML = u.models.map(m => '<tr><td style="font-weight:500;">' + esc(m.displayName) + ' <span style="font-size:11px;color:var(--text-muted);">(' + esc(m.model) + ')</span></td><td>' + m.total.toLocaleString() + ' tok</td><td>' + m.requests + '</td><td style="color:' + (m.unpriced ? 'var(--text-muted)' : 'var(--accent-green)') + ';font-weight:600;">' + (m.unpriced ? '价格未知' : '$' + m.costUsd.toFixed(2)) + '</td></tr>').join('');
}
</script>
</body>
</html>
"""

def start_server(port: int = 18989, open_browser: bool = False):
    server = None
    for candidate in range(port, port + 20):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", candidate), DashboardHandler)
            break
        except OSError:
            continue
    if server is None:
        raise OSError(f"端口 {port}-{port + 19} 均被占用")
    url = f"http://127.0.0.1:{server.server_address[1]}"
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    if open_browser:
        webbrowser.open(url)
    return url
