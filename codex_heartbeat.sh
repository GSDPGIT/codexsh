#!/bin/bash
# ==========================================
# [升级1] 多服务器仪表盘 — 心跳上报脚本 v1.1
# 修复：JSON 安全（空值保护）、端口变量化
# ==========================================

source /root/.codex_env 2>/dev/null || true

DASHBOARD_URL="${DASHBOARD_URL:-}"
if [ -z "$DASHBOARD_URL" ]; then
    exit 0  # 未配置仪表盘，静默退出
fi

MACHINE="${MACHINE_NAME:-未命名服务器}"
DB_FILE="/root/codex-console/data/database.db"
VENV_PY="/root/codex-console/venv/bin/python"
PORT="${TARGET_PORT:-18080}"

# 收集系统信息（带默认值防 JSON 损坏）
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f", 100 - $8}' 2>/dev/null || echo "0.0")
MEM_INFO=$(free -m | awk '/Mem:/ {printf "{\"total\":%d,\"used\":%d,\"pct\":%.1f}", $2, $3, $3/$2*100}' 2>/dev/null || echo '{"total":0,"used":0,"pct":0}')
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%' 2>/dev/null || echo "0")
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")

# 收集业务数据
BIZ_DATA=$("$VENV_PY" -c "
import sqlite3, json, os
try:
    conn = sqlite3.connect('$DB_FILE')
    total = conn.execute('SELECT COUNT(*) FROM accounts').fetchone()[0]
    today_ok = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='completed' AND created_at >= date('now','localtime')\").fetchone()[0]
    today_fail = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='failed' AND created_at >= date('now','localtime')\").fetchone()[0]
    running = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='running'\").fetchone()[0]
    pending = conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE status='pending'\").fetchone()[0]
    db_size = round(os.path.getsize('$DB_FILE') / 1048576, 1)
    conn.close()
    print(json.dumps({'total_accounts': total, 'today_success': today_ok, 'today_failed': today_fail,
                      'running': running, 'pending': pending, 'db_size_mb': db_size}))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" 2>/dev/null || echo '{"error":"python_failed"}')

# 检查服务状态
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/login" --connect-timeout 3 2>/dev/null || echo "0")
if [ "$HTTP_CODE" = "200" ]; then
    SERVICE_STATUS="healthy"
else
    SERVICE_STATUS="unhealthy"
fi

# 组装心跳数据（所有数值都有默认值，保证 JSON 合法）
HEARTBEAT=$(cat <<JSON
{
  "machine": "$MACHINE",
  "ip": "$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')",
  "status": "$SERVICE_STATUS",
  "http_code": ${HTTP_CODE:-0},
  "cpu_pct": ${CPU_USAGE:-0},
  "mem": ${MEM_INFO:-{}},
  "disk_pct": ${DISK_USAGE:-0},
  "uptime_sec": ${UPTIME_SEC:-0},
  "biz": ${BIZ_DATA:-{}},
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
