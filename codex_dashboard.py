#!/usr/bin/env python3
"""
Codex 多服务器群控主控面板 v1.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
功能：
  - 接收所有子服务器的心跳上报
  - Web 仪表盘实时展示所有服务器状态
  - 一键查看每台服务器的 CPU/内存/账号/成功率
  - 超 10 分钟无心跳自动标记为离线

部署：
  python3 codex_dashboard.py              # 默认端口 8888
  python3 codex_dashboard.py --port 9999  # 自定义端口

子服务器配置：
  在 .codex_env 中添加：
  export DASHBOARD_URL="http://主控IP:8888"
"""

import json
import os
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone

# ─── 配置 ───
DEFAULT_PORT = 8888
DATA_FILE = "/root/codex_dashboard_data.json"
OFFLINE_THRESHOLD = 600  # 10 分钟无心跳 → 离线

# 内存数据
servers = {}


def load_data():
    global servers
    try:
        if os.path.exists(DATA_FILE):
            with open(DATA_FILE, "r") as f:
                servers = json.load(f)
    except Exception:
        servers = {}


def save_data():
    try:
        with open(DATA_FILE, "w") as f:
            json.dump(servers, f, indent=2, ensure_ascii=False)
    except Exception:
        pass


# ─── HTML 模板 ───
DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Codex 群控面板</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, 'Segoe UI', Roboto, sans-serif;
    background: linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%);
    min-height: 100vh; color: #e0e0e0; padding: 20px;
  }
  .header {
    text-align: center; padding: 30px 0 20px;
    background: rgba(255,255,255,0.03); border-radius: 16px;
    margin-bottom: 24px; backdrop-filter: blur(10px);
    border: 1px solid rgba(255,255,255,0.05);
  }
  .header h1 {
    font-size: 28px; font-weight: 700;
    background: linear-gradient(90deg, #00d2ff, #3a7bd5);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
  }
  .header .stats {
    margin-top: 10px; font-size: 14px; color: #888;
  }
  .header .stats span { color: #00d2ff; font-weight: 600; }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
    gap: 16px;
  }
  .card {
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 14px; padding: 20px;
    backdrop-filter: blur(10px);
    transition: all 0.3s ease;
    position: relative; overflow: hidden;
  }
  .card:hover {
    transform: translateY(-3px);
    border-color: rgba(0,210,255,0.3);
    box-shadow: 0 8px 32px rgba(0,210,255,0.1);
  }
  .card.offline { opacity: 0.5; border-color: rgba(255,60,60,0.3); }
  .card-header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 14px;
  }
  .card-title {
    font-size: 18px; font-weight: 600; color: #fff;
    display: flex; align-items: center; gap: 8px;
  }
  .status-dot {
    width: 10px; height: 10px; border-radius: 50%;
    display: inline-block;
  }
  .status-dot.online { background: #00e676; box-shadow: 0 0 8px #00e676; animation: pulse 2s infinite; }
  .status-dot.offline { background: #ff5252; }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }
  .card-ip { font-size: 12px; color: #666; font-family: monospace; }
  .metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .metric {
    background: rgba(255,255,255,0.03); border-radius: 8px;
    padding: 10px 12px;
  }
  .metric-label { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
  .metric-value { font-size: 20px; font-weight: 700; margin-top: 2px; }
  .metric-value.green { color: #00e676; }
  .metric-value.blue { color: #00d2ff; }
  .metric-value.yellow { color: #ffd600; }
  .metric-value.red { color: #ff5252; }
  .metric-value.purple { color: #bb86fc; }
  .progress-bar {
    height: 4px; background: rgba(255,255,255,0.1);
    border-radius: 2px; margin-top: 6px; overflow: hidden;
  }
  .progress-fill {
    height: 100%; border-radius: 2px;
    transition: width 0.5s ease;
  }
  .card-footer {
    margin-top: 12px; padding-top: 10px;
    border-top: 1px solid rgba(255,255,255,0.06);
    display: flex; justify-content: space-between;
    font-size: 11px; color: #555;
  }
  .empty-state {
    text-align: center; padding: 80px 20px;
    color: #555; font-size: 16px;
  }
  .empty-state .icon { font-size: 48px; margin-bottom: 16px; }
  .auto-refresh { color: #444; font-size: 12px; text-align: center; margin-top: 16px; }
</style>
</head>
<body>
<div class="header">
  <h1>🖥️ Codex 群控面板</h1>
  <div class="stats">
    在线 <span id="online-count">0</span> 台 ·
    总账号 <span id="total-accounts">0</span> ·
    今日注册 <span id="today-total">0</span>
  </div>
</div>
<div class="grid" id="server-grid"></div>
<div class="auto-refresh">每 15 秒自动刷新</div>

<script>
function formatUptime(sec) {
  if (!sec || sec <= 0) return 'N/A';
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d > 0) return d + '天' + h + '时';
  if (h > 0) return h + '时' + m + '分';
  return m + '分';
}

function getColor(pct) {
  if (pct < 50) return 'green';
  if (pct < 80) return 'yellow';
  return 'red';
}

function rateColor(rate) {
  if (rate >= 80) return 'green';
  if (rate >= 50) return 'yellow';
  return 'red';
}

function progressColor(pct) {
  if (pct < 50) return '#00e676';
  if (pct < 80) return '#ffd600';
  return '#ff5252';
}

function timeSince(ts) {
  if (!ts) return '未知';
  const now = new Date();
  const then = new Date(ts);
  const diff = Math.floor((now - then) / 1000);
  if (diff < 60) return diff + '秒前';
  if (diff < 3600) return Math.floor(diff / 60) + '分钟前';
  if (diff < 86400) return Math.floor(diff / 3600) + '小时前';
  return Math.floor(diff / 86400) + '天前';
}

function renderServers(data) {
  const grid = document.getElementById('server-grid');
  const servers = Object.values(data);

  if (servers.length === 0) {
    grid.innerHTML = '<div class="empty-state"><div class="icon">📡</div>暂无服务器上报<br>请在子服务器 .codex_env 中配置 DASHBOARD_URL</div>';
    return;
  }

  let online = 0, totalAccounts = 0, todayTotal = 0;
  let html = '';

  servers.sort((a, b) => (a.machine || '').localeCompare(b.machine || ''));

  servers.forEach(s => {
    const isOnline = s._online !== false;
    if (isOnline) online++;
    const biz = s.biz || {};
    const mem = s.mem || {};
    totalAccounts += biz.total_accounts || 0;
    const todayOk = biz.today_success || 0;
    const todayFail = biz.today_failed || 0;
    todayTotal += todayOk;
    const rate = (todayOk + todayFail) > 0 ? Math.round(todayOk / (todayOk + todayFail) * 100) : 0;
    const cpuPct = Math.round(s.cpu_pct || 0);
    const memPct = Math.round(mem.pct || 0);
    const diskPct = s.disk_pct || 0;

    html += '<div class="card ' + (isOnline ? '' : 'offline') + '">' +
      '<div class="card-header">' +
        '<div class="card-title"><span class="status-dot ' + (isOnline ? 'online' : 'offline') + '"></span>' + (s.machine || '未命名') + '</div>' +
        '<div class="card-ip">' + (s.ip || '') + '</div>' +
      '</div>' +
      '<div class="metrics">' +
        '<div class="metric"><div class="metric-label">今日注册</div><div class="metric-value green">' + todayOk.toLocaleString() + '</div></div>' +
        '<div class="metric"><div class="metric-label">成功率</div><div class="metric-value ' + rateColor(rate) + '">' + rate + '%</div></div>' +
        '<div class="metric"><div class="metric-label">总账号</div><div class="metric-value blue">' + (biz.total_accounts || 0).toLocaleString() + '</div></div>' +
        '<div class="metric"><div class="metric-label">活跃任务</div><div class="metric-value purple">' + ((biz.running || 0) + (biz.pending || 0)) + '</div></div>' +
      '</div>' +
      '<div class="metrics" style="margin-top:8px">' +
        '<div class="metric"><div class="metric-label">CPU</div><div class="metric-value ' + getColor(cpuPct) + '">' + cpuPct + '%</div>' +
          '<div class="progress-bar"><div class="progress-fill" style="width:' + cpuPct + '%;background:' + progressColor(cpuPct) + '"></div></div></div>' +
        '<div class="metric"><div class="metric-label">内存</div><div class="metric-value ' + getColor(memPct) + '">' + memPct + '%</div>' +
          '<div class="progress-bar"><div class="progress-fill" style="width:' + memPct + '%;background:' + progressColor(memPct) + '"></div></div></div>' +
      '</div>' +
      '<div class="card-footer">' +
        '<span>v' + (s.version || '?') + ' · 磁盘 ' + diskPct + '% · 运行 ' + formatUptime(s.uptime_sec) + '</span>' +
        '<span>' + timeSince(s.timestamp) + '</span>' +
      '</div>' +
    '</div>';
  });

  grid.innerHTML = html;
  document.getElementById('online-count').textContent = online;
  document.getElementById('total-accounts').textContent = totalAccounts.toLocaleString();
  document.getElementById('today-total').textContent = todayTotal.toLocaleString();
}

function refresh() {
  fetch('/api/servers')
    .then(r => r.json())
    .then(d => renderServers(d))
    .catch(() => {});
}

refresh();
setInterval(refresh, 15000);
</script>
</body>
</html>"""


class DashboardHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # 静默日志
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html, status=200):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self._send_html(DASHBOARD_HTML)
        elif self.path == "/api/servers":
            # 标记离线服务器
            now = time.time()
            result = {}
            for key, srv in servers.items():
                srv_copy = dict(srv)
                ts = srv_copy.get("_received_at", 0)
                srv_copy["_online"] = (now - ts) < OFFLINE_THRESHOLD
                result[key] = srv_copy
            self._send_json(result)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/heartbeat":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length)
                data = json.loads(body.decode("utf-8", errors="ignore"))
                machine = data.get("machine", "unknown")
                ip = data.get("ip", "unknown")
                key = f"{machine}_{ip}"
                data["_received_at"] = time.time()
                servers[key] = data
                save_data()
                self._send_json({"status": "ok", "machine": machine})
                print(f"💚 心跳: {machine} ({ip})")
            except Exception as e:
                self._send_json({"error": str(e)}, 400)
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


def main():
    port = DEFAULT_PORT
    if "--port" in sys.argv:
        idx = sys.argv.index("--port")
        if idx + 1 < len(sys.argv):
            port = int(sys.argv[idx + 1])

    load_data()
    server = HTTPServer(("0.0.0.0", port), DashboardHandler)
    print(f"""
╔══════════════════════════════════════════════╗
║   🖥️  Codex 群控主控面板 v1.0                ║
║   端口: {port}                                ║
║   地址: http://0.0.0.0:{port}                 ║
╠══════════════════════════════════════════════╣
║   子服务器配置：                              ║
║   export DASHBOARD_URL="http://主控IP:{port}" ║
║   添加到 /root/.codex_env 即可               ║
╚══════════════════════════════════════════════╝
""")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n👋 主控面板已关闭")
        server.server_close()


if __name__ == "__main__":
    main()
