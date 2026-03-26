#!/bin/bash

# ==========================================
# 🎯 Codex Console 自动化管理面板 v5.1 (暴力同步版)
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BOT_LOG="/root/bot_run.log"
PY_SCRIPT="/root/auto_run.py"
WORK_DIR="/root/codex-console"
VENV_PY="${WORK_DIR}/venv/bin/python"
DAEMON_SCRIPT="/root/daemon.sh"
UPDATE_SCRIPT="/root/codex_update.sh"
ENV_FILE="/root/.codex_env"
TARGET_PORT="18080"
# 👇 您的云端脚本地址
CLOUD_SCRIPT_URL="https://raw.githubusercontent.com/GSDPGIT/codexsh/refs/heads/main/auto_run.py"

print_header() {
    clear
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${YELLOW}   Codex Console 自动化管理面板 v5.1 (暴力同步版)    ${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

# 🔐 暴力对齐：确保本地保险箱、主程序配置文件、系统服务三位一体
sync_passwords_now() {
    if [ ! -f "$ENV_FILE" ]; then return; fi
    source "$ENV_FILE"
    
    echo -e "${CYAN}🔄 正在执行全系统密码暴力同步...${NC}"
    
    # 1. 同步到主程序目录下的 .env
    echo "PASSWORD=\"$CODEX_PASSWORD\"" > "$WORK_DIR/.env"
    echo "PORT=$TARGET_PORT" >> "$WORK_DIR/.env"
    
    # 2. 同步到系统服务文件
    if [ -f /etc/systemd/system/codex-console.service ]; then
        cat << EOF > /etc/systemd/system/codex-console.service
[Unit]
Description=Codex Console Service
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
Environment="PASSWORD=$CODEX_PASSWORD"
Environment="PORT=$TARGET_PORT"
ExecStart=$VENV_PY $WORK_DIR/webui.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl restart codex-console
    fi

    # 3. 物理级重置数据库密码（删除数据库让主程序重新读 .env 写入新密码）
    if [ -f "$WORK_DIR/data/database.db" ]; then
        echo -e "${YELLOW}⚠️  检测到旧数据库，正在物理重置以对齐密码...${NC}"
        rm -f "$WORK_DIR/data/database.db"
        systemctl restart codex-console
        sleep 3
    fi
    echo -e "${GREEN}✅ 密码已强行同步至：面板、主程序、系统服务、数据库！${NC}"
}

check_or_ask_password() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "\n${CYAN}🛡️  [安全配置] 检测到这是您首次运行或密码丢失。${NC}"
        # 明文显示方便 Lee 核对密码是否包含点号等
        read -p "🔑 请设置您的统一访问密码 (主程序和打工人将共用此密码): " input_pwd
        echo "" 
        if [ -z "$input_pwd" ]; then
            echo -e "${RED}❌ 密码不能为空！${NC}"
            exit 1
        fi
        echo "export CODEX_PASSWORD='$input_pwd'" > "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        sync_passwords_now
    fi
    source "$ENV_FILE"
}

generate_daemon() {
    cat > "$DAEMON_SCRIPT" <<EOF
#!/bin/bash
LOG_FILE="$BOT_LOG"
PY_SCRIPT="$PY_SCRIPT"
WORK_DIR="$WORK_DIR"
VENV_PY="$VENV_PY"
CLOUD_URL="$CLOUD_SCRIPT_URL"

while true; do
    if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; fi
    echo "==================================================" >> "\$LOG_FILE"
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🧹 规则 1: 清理残留进程..." >> "\$LOG_FILE"
    pkill -9 -f "webui.py" 2>/dev/null
    pkill -9 -f "auto_run.py" 2>/dev/null

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🔄 规则 2: 重启 codex-console 服务..." >> "\$LOG_FILE"
    systemctl restart codex-console >> "\$LOG_FILE" 2>&1
    sleep 5

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ☁️ 规则 3: 同步云端脚本..." >> "\$LOG_FILE"
    curl -sSfL -o /tmp/auto_run_temp.py "\$CLOUD_URL" && mv -f /tmp/auto_run_temp.py "\$PY_SCRIPT"

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🚀 规则 4: 唤醒打工人 (正在通过 18080 端口验证密码)..." >> "\$LOG_FILE"
    # 使用虚拟环境运行
    $VENV_PY "\$PY_SCRIPT" >> "\$LOG_FILE" 2>&1
    
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 💤 规则 5: 进入 5 分钟深度休眠..." >> "\$LOG_FILE"
    sleep 300
done
EOF
    chmod +x "$DAEMON_SCRIPT"
}

deploy_env() {
    check_or_ask_password
    echo -e "\n${YELLOW}>>> 开始部署 codex-console 环境...${NC}"
    apt-get update -y && apt-get install -y python3 python3-venv python3-pip git curl cron ufw

    # 🔥 防火墙配置：放行 18080 端口方便外网导出账号
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow $TARGET_PORT/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1

    if [ ! -d "$WORK_DIR" ]; then
        git clone "https://github.com/dou-jiang/codex-console.git" "$WORK_DIR"
    fi

    cd "$WORK_DIR" && python3 -m venv venv
    "$VENV_PY" -m pip install --upgrade pip && "$VENV_PY" -m pip install -r requirements.txt
    
    sync_passwords_now
    
    # 配置每日凌晨 5 点更新
    cat > "$UPDATE_SCRIPT" <<EOF
#!/bin/bash
cd "$WORK_DIR" && git pull && "$VENV_PY" -m pip install -r requirements.txt && systemctl restart codex-console
EOF
    chmod +x "$UPDATE_SCRIPT"
    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > /tmp/mycron
    echo "0 5 * * * $UPDATE_SCRIPT" >> /tmp/mycron
    crontab /tmp/mycron && rm -f /tmp/mycron

    echo -e "${GREEN}✅ 部署完成！华为云安全组记得也开放 18080 端口。${NC}"
}

start_engine() {
    check_or_ask_password
    generate_daemon
    pkill -9 -f "daemon.sh" 2>/dev/null
    nohup "$DAEMON_SCRIPT" > /dev/null 2>&1 &
    echo -e "${GREEN}✅ 永动机引擎已启动！${NC}"
}

main_menu() {
    while true; do
        print_header
        echo -e "  1. 🛠️  【全能部署】 重新安装环境、解封端口、物理重置并同步密码"
        echo -e "  2. 🚀  【启动引擎】 启动监工 (会自动同步 GitHub 打工人代码)"
        echo -e "  3. 🛑  【彻底停机】 暴力停止所有相关后台与任务"
        echo -e "  4. 📊  【体检报告】 查看 CPU、内存及相关进程状态"
        echo -e "  5. 👀  【实时监控】 追踪控制台输出日志 (看打工人是否成功登录)"
        echo -e "  6. 🔑  【重置密码】 修改本地保险箱密码并立即暴力同步全服"
        echo -e "  0. 退出管理面板"
        echo -e "${GREEN}====================================================${NC}"

        read -p "请输入指令数字 [0-6]: " choice
        case "$choice" in
            1) deploy_env; read -p "按回车继续..." ;;
            2) start_engine; read -p "按回车继续..." ;;
            3) systemctl stop codex-console; pkill -9 -f daemon.sh; pkill -9 -f auto_run.py; echo "已物理超度"; read -p "按回车继续..." ;;
            4) uptime; free -h; ps aux | grep -E "daemon|auto_run|webui" | grep -v grep; read -p "按回车继续..." ;;
            5) tail -f "$BOT_LOG" ;;
            6) rm -f "$ENV_FILE"; check_or_ask_password; read -p "按回车继续..." ;;
            0) exit 0 ;;
        esac
    done
}

trap '' SIGINT
main_menu
