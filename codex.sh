#!/bin/bash

# ==========================================
# 🎯 Codex Console 终极上帝监工面板 v4.1 (云端热同步版)
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

BOT_LOG="/root/bot_run.log"
PY_SCRIPT="/root/auto_run.py"
WORK_DIR="/root/codex-console"
VENV_PY="${WORK_DIR}/venv/bin/python"
DAEMON_SCRIPT="/root/daemon.sh"
UPDATE_SCRIPT="/root/codex_update.sh"
MAX_CONSECUTIVE_FAILURES=5
TARGET_PORT="18080"
# 👇 你的云端脚本地址
CLOUD_SCRIPT_URL="https://raw.githubusercontent.com/GSDPGIT/codexsh/refs/heads/main/auto_run.py"

print_header() {
    clear
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${YELLOW}   Codex Console 规则级自动化管理面板 v4.1 (云端同步) ${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

generate_daemon() {
    cat > "$DAEMON_SCRIPT" <<EOF
#!/bin/bash
LOG_FILE="$BOT_LOG"
PY_SCRIPT="$PY_SCRIPT"
WORK_DIR="$WORK_DIR"
VENV_PY="$VENV_PY"
MAX_CONSECUTIVE_FAILURES=$MAX_CONSECUTIVE_FAILURES
CLOUD_URL="$CLOUD_SCRIPT_URL"
consecutive_failures=0

wait_service_ready() {
    local max_wait=120
    local waited=0
    while [ \$waited -lt \$max_wait ]; do
        if systemctl is-active --quiet codex-console; then
            if command -v curl >/dev/null 2>&1; then
                if curl -fsS --retry 1 --max-time 3 http://127.0.0.1:${TARGET_PORT}/login >/dev/null 2>&1; then
                    return 0
                fi
            else
                return 0
            fi
        fi
        sleep 2
        waited=\$((waited + 2))
    done
    return 1
}

choose_python() {
    if [ -x "\$VENV_PY" ]; then echo "\$VENV_PY"; else echo "python3"; fi
}

while true; do
    echo "==================================================" >> "\$LOG_FILE"
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🧹 规则 1: 清理残留幽灵进程..." >> "\$LOG_FILE"
    pkill -9 -f "webui.py" 2>/dev/null
    pkill -9 -f "auto_run.py" 2>/dev/null

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🔄 规则 2: 重启 codex-console 服务..." >> "\$LOG_FILE"
    if ! systemctl restart codex-console >> "\$LOG_FILE" 2>&1; then
        consecutive_failures=\$((consecutive_failures + 1))
        if [ \$consecutive_failures -ge \$MAX_CONSECUTIVE_FAILURES ]; then exit 1; fi
        sleep 300; continue
    fi

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ⏳ 规则 3: 等待服务在端口 ${TARGET_PORT} 就绪..." >> "\$LOG_FILE"
    if ! wait_service_ready; then
        consecutive_failures=\$((consecutive_failures + 1))
        if [ \$consecutive_failures -ge \$MAX_CONSECUTIVE_FAILURES ]; then exit 1; fi
        sleep 300; continue
    fi

    # ☁️ 新增：云端热同步逻辑
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ☁️ 规则 4: 正在从云端拉取最新打工人脚本..." >> "\$LOG_FILE"
    if curl -sSfL -o /tmp/auto_run_temp.py "\$CLOUD_URL"; then
        mv -f /tmp/auto_run_temp.py "\$PY_SCRIPT"
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ✅ 云端脚本同步成功！" >> "\$LOG_FILE"
    else
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ 云端拉取失败，将继续使用本地旧版本运行。" >> "\$LOG_FILE"
    fi

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🚀 规则 5: 唤醒 Python 打工人..." >> "\$LOG_FILE"
    RUNNER_PY=\$(choose_python)
    \$RUNNER_PY "\$PY_SCRIPT" >> "\$LOG_FILE" 2>&1
    rc=\$?

    if [ \$rc -eq 0 ]; then
        consecutive_failures=0
    else
        consecutive_failures=\$((consecutive_failures + 1))
        if [ \$consecutive_failures -ge \$MAX_CONSECUTIVE_FAILURES ]; then exit 1; fi
    fi

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 💤 规则 6: 进入 5 分钟深度休眠..." >> "\$LOG_FILE"
    sleep 300
done
EOF
    chmod +x "$DAEMON_SCRIPT"
}

setup_auto_update() {
    cat > "$UPDATE_SCRIPT" <<EOF
#!/bin/bash
echo "[$(date)] 开始自动更新 codex-console..." >> /root/update.log
cd "$WORK_DIR" && git pull >> /root/update.log 2>&1
"$VENV_PY" -m pip install -r requirements.txt >> /root/update.log 2>&1
systemctl restart codex-console >> /root/update.log 2>&1
echo "[$(date)] 更新完成并已重启服务。" >> /root/update.log
EOF
    chmod +x "$UPDATE_SCRIPT"

    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > /tmp/mycron
    echo "0 5 * * * $UPDATE_SCRIPT" >> /tmp/mycron
    crontab /tmp/mycron
    rm -f /tmp/mycron
    echo -e "${GREEN}✅ 每日凌晨 5 点自动更新任务已配置完成！${NC}"
}

deploy_env() {
    echo -e "\n${YELLOW}>>> 开始部署 codex-console 环境...${NC}"
    apt-get update -y
    apt-get install -y python3 python3-venv python3-pip git curl cron

    if [ ! -d "$WORK_DIR" ]; then
        git clone "https://github.com/dou-jiang/codex-console.git" "$WORK_DIR"
    else
        cd "$WORK_DIR" && git pull
    fi

    echo "🔧 正在将主程序默认端口 (8000) 统一修改为 ${TARGET_PORT}..."
    find "$WORK_DIR" -type f \( -name "*.py" -o -name "*.sh" -o -name "*.env" -o -name "*.yaml" \) -exec sed -i "s/8000/${TARGET_PORT}/g" {} + 2>/dev/null

    cd "$WORK_DIR" || return 1
    python3 -m venv venv
    "$VENV_PY" -m pip install --upgrade pip
    "$VENV_PY" -m pip install -r requirements.txt

    setup_auto_update
    
    # 自动拉取首次脚本
    echo "☁️ 正在初始化云端打工人脚本..."
    curl -sSfL -o "$PY_SCRIPT" "$CLOUD_SCRIPT_URL"

    echo -e "${GREEN}✅ 部署/更新已全部完成！(端口已绑定至 ${TARGET_PORT})${NC}"
}

start_engine() {
    echo -e "\n${YELLOW}>>> 正在启动上帝监工...${NC}"
    # 如果没找到脚本，尝试拉取一下
    if [ ! -f "$PY_SCRIPT" ]; then
        echo "☁️ 未找到本地脚本，正在从云端拉取..."
        if ! curl -sSfL -o "$PY_SCRIPT" "$CLOUD_SCRIPT_URL"; then
            echo -e "${RED}❌ 致命错误：从云端拉取脚本失败，请检查网络或 GitHub 链接！${NC}"
            return
        fi
    fi
    
    generate_daemon
    pkill -9 -f "daemon.sh" 2>/dev/null
    touch "$BOT_LOG"
    nohup "$DAEMON_SCRIPT" > /dev/null 2>&1 &
    echo -e "${GREEN}✅ 永动机引擎已挂载！将自动保持与云端脚本同步。${NC}"
}

stop_all() {
    echo -e "\n${RED}>>> 收到最高指令！正在执行物理超度...${NC}"
    systemctl stop codex-console 2>/dev/null
    pkill -9 -f "daemon.sh" 2>/dev/null
    pkill -9 -f "auto_run.py" 2>/dev/null
    pkill -9 -f "webui.py" 2>/dev/null
    echo -e "${GREEN}✅ 所有任务和后台已彻底清理。${NC}"
}

show_status() {
    echo -e "\n${YELLOW}>>> 服务器实时体检报告${NC}"
    echo "------------------------------------------------"
    uptime
    echo "------------------------------------------------"
    free -h | grep -E "Mem|total"
    echo "------------------------------------------------"
    df -h / | tail -n 1
    echo "------------------------------------------------"
    ps aux | grep -E "daemon.sh|auto_run.py|webui.py" | grep -v grep || echo "  (无相关进程存活)"
    echo "------------------------------------------------"
}

main_menu() {
    while true; do
        print_header
        echo -e "  1. 🛠️  【环境部署】 安装环境、绑定端口(18080)、初始化云端打工人"
        echo -e "  2. 🚀  【启动
