#!/bin/bash

# ==========================================
# 🎯 Codex Console 终极上帝监工面板 v4.0
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
TARGET_PORT="18080"  # ⬅️ 统一管理的全局端口

print_header() {
    clear
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${YELLOW}       Codex Console 规则级自动化管理面板 v4.0      ${NC}"
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
consecutive_failures=0

wait_service_ready() {
    local max_wait=120
    local waited=0
    while [ \$waited -lt \$max_wait ]; do
        if systemctl is-active --quiet codex-console; then
            if command -v curl >/dev/null 2>&1; then
                # ⬅️ 端口已变量化
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

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🚀 规则 4: 唤醒 Python 打工人..." >> "\$LOG_FILE"
    RUNNER_PY=\$(choose_python)
    \$RUNNER_PY "\$PY_SCRIPT" >> "\$LOG_FILE" 2>&1
    rc=\$?

    if [ \$rc -eq 0 ]; then
        consecutive_failures=0
    else
        consecutive_failures=\$((consecutive_failures + 1))
        if [ \$consecutive_failures -ge \$MAX_CONSECUTIVE_FAILURES ]; then exit 1; fi
    fi

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 💤 规则 5: 进入 5 分钟深度休眠..." >> "\$LOG_FILE"
    sleep 300
done
EOF
    chmod +x "$DAEMON_SCRIPT"
}

setup_auto_update() {
    # 写入独立的更新脚本
    cat > "$UPDATE_SCRIPT" <<EOF
#!/bin/bash
echo "[$(date)] 开始自动更新 codex-console..." >> /root/update.log
cd "$WORK_DIR" && git pull >> /root/update.log 2>&1
"$VENV_PY" -m pip install -r requirements.txt >> /root/update.log 2>&1
systemctl restart codex-console >> /root/update.log 2>&1
echo "[$(date)] 更新完成并已重启服务。" >> /root/update.log
EOF
    chmod +x "$UPDATE_SCRIPT"

    # 注入到 crontab (每天凌晨 5:00 执行)
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

    # 核心：强行替换源码中的 8000 端口为 18080
    echo "🔧 正在将主程序默认端口 (8000) 统一修改为 ${TARGET_PORT}..."
    find "$WORK_DIR" -type f \( -name "*.py" -o -name "*.sh" -o -name "*.env" -o -name "*.yaml" \) -exec sed -i "s/8000/${TARGET_PORT}/g" {} + 2>/dev/null

    cd "$WORK_DIR" || return 1
    python3 -m venv venv
    "$VENV_PY" -m pip install --upgrade pip
    "$VENV_PY" -m pip install -r requirements.txt

    # 配置自动更新
    setup_auto_update

    echo -e "${GREEN}✅ 部署/更新已全部完成！(端口已绑定至 ${TARGET_PORT})${NC}"
}

start_engine() {
    echo -e "\n${YELLOW}>>> 正在启动上帝监工...${NC}"
    if [ ! -f "$PY_SCRIPT" ]; then
        echo -e "${RED}❌ 致命错误：未找到打工人脚本 ($PY_SCRIPT)！请先上传！${NC}"
        return
    fi
    generate_daemon
    pkill -9 -f "daemon.sh" 2>/dev/null
    touch "$BOT_LOG"
    nohup "$DAEMON_SCRIPT" > /dev/null 2>&1 &
    echo -e "${GREEN}✅ 永动机引擎已挂载！${NC}"
}

stop_all() {
    echo -e "\n${RED}>>> 收到最高指令！正在执行物理超度...${NC}"
    systemctl stop codex-console 2>/dev/null
    pkill -9 -f "daemon.sh" 2>/dev/null
    pkill -9 -f "auto_run.py" 2>/dev/null
    pkill -9 -f "webui.py" 2>/dev/null
    echo -e "${GREEN}✅ 所有任务和后台已彻底清理。${NC}"
}

main_menu() {
    while true; do
        print_header
        echo -e "  1. 🛠️  【环境部署】 安装环境、统一端口(18080)并配置自动更新(凌晨5点)"
        echo -e "  2. 🚀  【启动引擎】 (将严格循环: 清洗->重启->等待就绪->跑号->休眠)"
        echo -e "  3. 🛑  【全服停机】 一键暴力清除所有相关后台、任务及进程"
        echo -e "  4. 📊  【体检报告】 查看当前服务器负载、内存、硬盘及相关进程"
        echo -e "  5. 👀  【实时监控】 追踪控制台输出日志 (按 Ctrl+C 返回菜单)"
        echo -e "  0. 退出管理面板"
        echo -e "${GREEN}====================================================${NC}"

        read -p "请输入指令数字 [0-5]: " choice
        case "$choice" in
            1) deploy_env; read -p "按回车键返回主菜单..." ;;
            2) start_engine; read -p "按回车键返回主菜单..." ;;
            3) stop_all; read -p "按回车键返回主菜单..." ;;
            4) show_status; read -p "按回车键返回主菜单..." ;;
            5) tail -f "$BOT_LOG" ;;
            0) exit 0 ;;
            *) echo -e "${RED}❌ 无效指令！${NC}"; sleep 1 ;;
        esac
    done
}

trap '' SIGINT
main_menu