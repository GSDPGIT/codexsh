#!/bin/bash
# ==========================================
# [升级1] 多服务器仪表盘 — 心跳上报脚本
# 每 5 分钟由 daemon 调用，上报服务器状态到中央仪表盘
# ==========================================

source /root/.codex_env 2>/dev/null || true

DASHBOARD_URL="${DASHBOARD_URL:-}"
if [ -z "$DASHBOARD_URL" ]; then
    exit 0  # 未配置仪表盘，静默退出
fi

MACHINE="${MACHINE_NAME:-未命名服务器}"
DB_FILE="/root/codex-console/data/database.db"
VENV_PY="/root/codex-console/venv/bin/python"

# 收集系统信息
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' 2>/dev/null || echo "0")
MEM_INFO=$(free -m | awk '/Mem:/ {printf "{\"total\":%d,\"used\":%d,\"pct\":%.1f}", $2, $3, $3/$2*100}')
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
UPTIME_SEC=$(cat /proc/uptime | awk '{print int($1)}')

# 收集业务数据
BIZ_DATA=$("$VENV_PY" -c "
import sqlite3, json, os
try:
    conn = sqlite3.connect('$DB_FILE')
    total = conn.execute('SELECT COUNT(*) FROM accounts').fetchone()[0]
    today_ok = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='completed' AND created_at >= date('now')\").fetchone()[0]
    today_fail = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='failed' AND created_at >= date('now')\").fetchone()[0]
    running = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='running'\").fetchone()[0]
    pending = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='pending'\").fetchone()[0]
    db_size = round(os.path.getsize('$DB_FILE') / 1048576, 1)
    conn.close()
    print(json.dumps({'total_accounts': total, 'today_success': today_ok, 'today_failed': today_fail,
                      'running': running, 'pending': pending, 'db_size_mb': db_size}))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null)

# 检查服务状态
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/login --connect-timeout 3 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    SERVICE_STATUS="healthy"
else
    SERVICE_STATUS="unhealthy"
fi

# 组装心跳数据
HEARTBEAT=$(cat <<JSON
{
  "machine": "$MACHINE",
  "ip": "$(hostname -I 2>/dev/null | awk '{print $1}')",
  "status": "$SERVICE_STATUS",
  "http_code": $HTTP_CODE,
  "cpu_pct": $CPU_USAGE,
  "mem": $MEM_INFO,
  "disk_pct": $DISK_USAGE,
  "uptime_sec": $UPTIME_SEC,
  "biz": $BIZ_DATA,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "7.0"
}
JSON
)

# 上报
curl -sS -X POST "$DASHBOARD_URL/api/heartbeat" \
    -H "Content-Type: application/json" \
    -d "$HEARTBEAT" \
    --connect-timeout 5 --max-time 10 2>/dev/null || true
