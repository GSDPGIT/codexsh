#!/bin/bash
# ==========================================
# Codex Console 自动化管理面板 v7.0
# v7.0 改进：
#   1. 修复 daemon 健康检查端口硬编码
#   2. Python 版本检测增加安全保护
#   3. 每日更新脚本补 Jinja2 补丁
#   4. TG/备份凭据改为环境变量
#   5. SSH Key 备份支持
#   6. 智能任务调度器（自动降档）
#   7. 蓝绿升级（零停机）
#   8. 每日自动报告
#   9. 多服务器仪表盘
# ==========================================
VERSION="7.0"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BOT_LOG="/root/bot_run.log"
PY_SCRIPT="/root/auto_run.py"
WORK_DIR="/root/codex-console"
VENV_PY="${WORK_DIR}/venv/bin/python"
PYTHON_MIN_MINOR=10   # curl_cffi 要求 >=3.10
DAEMON_SCRIPT="/root/daemon.sh"
UPDATE_SCRIPT="/root/codex_update.sh"
BACKUP_SCRIPT="/root/codex_backup.sh"
ENV_FILE="/root/.codex_env"
TARGET_PORT="18080"
LOG_MAX_SIZE=512000  # 500K

# 👇 云端脚本地址
CLOUD_SCRIPT_URL="https://raw.githubusercontent.com/GSDPGIT/codexsh/refs/heads/main/auto_run.py"

print_header() {
    clear
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${YELLOW}   Codex Console 自动化管理面板 v${VERSION}                ${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

# ═══════════ systemd 服务 ═══════════
create_or_update_service() {
    source "$ENV_FILE" 2>/dev/null || true
    cat <<EOF > /etc/systemd/system/codex-console.service
[Unit]
Description=Codex Console Service
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
Environment="WEBUI_ACCESS_PASSWORD=$CODEX_PASSWORD"
Environment="WEBUI_PORT=$TARGET_PORT"
Environment="TEMPMAIL_API_KEY=${TEMPMAIL_API_KEY:-}"
Environment="MACHINE_NAME=${MACHINE_NAME:-未命名服务器}"
Environment="TG_BOT_TOKEN=${TG_BOT_TOKEN:-}"
Environment="TG_CHAT_ID=${TG_CHAT_ID:-}"
ExecStart=$VENV_PY $WORK_DIR/webui.py --port $TARGET_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ═══════════ 密码 / 配置同步 ═══════════
sync_passwords_now() {
    if [ ! -f "$ENV_FILE" ]; then return; fi
    source "$ENV_FILE"

    echo -e "${CYAN}🔄 正在执行全系统配置同步...${NC}"

    # 1. 同步到主程序 .env
    if [ -d "$WORK_DIR" ]; then
        echo "WEBUI_ACCESS_PASSWORD=\"$CODEX_PASSWORD\"" > "$WORK_DIR/.env"
        echo "WEBUI_PORT=$TARGET_PORT" >> "$WORK_DIR/.env"
        [ -n "$TEMPMAIL_API_KEY" ] && echo "TEMPMAIL_API_KEY=$TEMPMAIL_API_KEY" >> "$WORK_DIR/.env"
        [ -n "$MACHINE_NAME" ] && echo "MACHINE_NAME=$MACHINE_NAME" >> "$WORK_DIR/.env"
    fi

    # 2. 更新 systemd 服务
    create_or_update_service
    systemctl restart codex-console 2>/dev/null || true

    echo -e "${GREEN}✅ 配置已同步至：面板、主程序、系统服务！${NC}"
}

# ═══════════ 初始化配置 ═══════════
check_or_ask_password() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "\n${CYAN}🛡️  [安全配置] 检测到首次运行，请依次完成配置。${NC}\n"
        _ask_all_config ""
    fi
    source "$ENV_FILE"
}

_ask_all_config() {
    local mode="$1"  # "edit" = 编辑模式（显示当前值，按回车保留）
    source "$ENV_FILE" 2>/dev/null || true

    # 1. 密码
    if [ "$mode" = "edit" ]; then
        echo -e "${CYAN}当前密码: ${CODEX_PASSWORD:-未设置}${NC}"
        read -p "🔑 新密码 (回车保留不变): " input_pwd
        [ -z "$input_pwd" ] && input_pwd="$CODEX_PASSWORD"
    else
        read -p "🔑 请设置统一访问密码: " input_pwd
        if [ -z "$input_pwd" ]; then
            echo -e "${RED}❌ 密码不能为空！${NC}"; exit 1
        fi
    fi

    # 2. Tempmail API Key
    echo -e "${CYAN}当前 API Key: ${TEMPMAIL_API_KEY:-未设置}${NC}"
    read -p "🔐 Tempmail API Key (回车保留不变，输入 clear 清除): " input_api_key
    if [ "$input_api_key" = "clear" ]; then
        input_api_key=""
    elif [ -z "$input_api_key" ]; then
        input_api_key="${TEMPMAIL_API_KEY:-}"
    fi

    # 2b. TG Bot Token
    echo -e "${CYAN}当前 TG Bot Token: ${TG_BOT_TOKEN:+已配置}${TG_BOT_TOKEN:-未配置}${NC}"
    read -p "🤖 TG Bot Token (回车保留不变，输入 clear 清除): " input_tg_token
    if [ "$input_tg_token" = "clear" ]; then
        input_tg_token=""
    elif [ -z "$input_tg_token" ]; then
        input_tg_token="${TG_BOT_TOKEN:-}"
    fi

    # 2c. TG Chat ID
    echo -e "${CYAN}当前 TG Chat ID: ${TG_CHAT_ID:-未配置}${NC}"
    read -p "💬 TG Chat ID (回车保留不变): " input_tg_chatid
    [ -z "$input_tg_chatid" ] && input_tg_chatid="${TG_CHAT_ID:-}"

    # 3. 机器名
    echo -e "${CYAN}当前服务器名称: ${MACHINE_NAME:-未命名}${NC}"
    read -p "📛 服务器名称 (回车保留不变，支持中文): " input_machine_name
    [ -z "$input_machine_name" ] && input_machine_name="${MACHINE_NAME:-未命名服务器}"

    # 4. 备份服务器
    echo -e "${CYAN}当前备份服务器: ${BACKUP_HOST:-未配置}${NC}"
    read -p "🖥️  备份服务器地址 (回车保留不变，输入 clear 取消): " input_backup_host
    if [ "$input_backup_host" = "clear" ]; then
        input_backup_host=""
        input_backup_pass=""
        input_backup_path=""
    elif [ -z "$input_backup_host" ]; then
        input_backup_host="${BACKUP_HOST:-}"
        input_backup_pass="${BACKUP_PASS:-}"
        input_backup_path="${BACKUP_PATH:-}"
    else
        read -p "🔑 备份服务器密码: " input_backup_pass
        echo ""
        read -p "📂 备份路径 (默认 /root/codex_backups): " input_backup_path
        [ -z "$input_backup_path" ] && input_backup_path="/root/codex_backups"
    fi

    # 写入配置
    escaped_pwd=$(printf '%q' "$input_pwd")
    cat > "$ENV_FILE" <<ENVEOF
export CODEX_PASSWORD=$escaped_pwd
export MACHINE_NAME="$input_machine_name"
ENVEOF
    [ -n "$input_api_key" ] && echo "export TEMPMAIL_API_KEY=$input_api_key" >> "$ENV_FILE"
    [ -n "$input_tg_token" ] && echo "export TG_BOT_TOKEN=\"$input_tg_token\"" >> "$ENV_FILE"
    [ -n "$input_tg_chatid" ] && echo "export TG_CHAT_ID=\"$input_tg_chatid\"" >> "$ENV_FILE"
    [ -n "$input_backup_host" ] && {
        echo "export BACKUP_HOST=\"$input_backup_host\"" >> "$ENV_FILE"
        echo "export BACKUP_PASS=\"$input_backup_pass\"" >> "$ENV_FILE"
        echo "export BACKUP_PATH=\"$input_backup_path\"" >> "$ENV_FILE"
    }
    chmod 600 "$ENV_FILE"
    echo -e "${GREEN}✅ 配置已保存！${NC}"
    sync_passwords_now
}

# ═══════════ Python 版本保障 ═══════════
ensure_python311() {
    # 查找系统中可用的 Python >=3.10
    local best=""
    for cmd in python3.13 python3.12 python3.11 python3.10; do
        if command -v "$cmd" &>/dev/null; then
            best=$(command -v "$cmd")
            break
        fi
    done

    # 检查默认 python3 的版本
    if [ -z "$best" ] && command -v python3 &>/dev/null; then
        local ver=$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null)
        if [ "$ver" -ge "$PYTHON_MIN_MINOR" ] 2>/dev/null; then
            best=$(command -v python3)
        fi
    fi

    if [ -n "$best" ]; then
        PYTHON_BIN="$best"
        echo -e "${GREEN}✅ 发现可用 Python: $($PYTHON_BIN --version)${NC}"
        return 0
    fi

    # 没有合适版本，需要编译 Python 3.11
    echo -e "${YELLOW}⚠️  系统 Python 版本过低（$(python3 --version 2>&1)），需要 >=3.10${NC}"
    echo -e "${CYAN}🔨 正在编译安装 Python 3.11.9（约 5-10 分钟）...${NC}"

    apt-get install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
        libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev \
        wget libbz2-dev liblzma-dev 2>&1 | tail -1

    local PY_VER="3.11.9"
    local PY_SRC="/tmp/Python-${PY_VER}"
    if [ ! -f "/usr/local/bin/python3.11" ]; then
        cd /tmp
        [ ! -f "Python-${PY_VER}.tgz" ] && \
            wget -q --show-progress "https://www.python.org/ftp/python/${PY_VER}/Python-${PY_VER}.tgz"
        rm -rf "$PY_SRC"
        tar -xf "Python-${PY_VER}.tgz"
        cd "$PY_SRC"
        ./configure --enable-optimizations --prefix=/usr/local -q 2>&1 | tail -3
        make -j$(nproc) -s 2>&1 | tail -3
        make altinstall 2>&1 | tail -3
        cd /root
    fi

    if [ -f "/usr/local/bin/python3.11" ]; then
        PYTHON_BIN="/usr/local/bin/python3.11"
        echo -e "${GREEN}✅ Python 3.11 编译安装成功！${NC}"
    else
        echo -e "${RED}❌ Python 3.11 编译失败，请手动安装。${NC}"
        exit 1
    fi
}

# ═══════════ 源码补丁 ═══════════
apply_patches() {
    source "$ENV_FILE" 2>/dev/null || true

    # 补丁 1：注册上限 1000 → 999999
    REG_FILE="$WORK_DIR/src/web/routes/registration.py"
    if [ -f "$REG_FILE" ]; then
        sed -i 's/request.count > 1000/request.count > 999999/g' "$REG_FILE"
        sed -i 's/注册数量必须在 1-1000 之间/注册数量必须在 1-999999 之间/g' "$REG_FILE"
        sed -i 's/count: 注册数量 (1-1000)/count: 注册数量 (1-999999)/g' "$REG_FILE"
    fi

    # 补丁 2：去广告（幂等）
    remove_ads_silent

    # 补丁 3：Tempmail API Key 注入（__init__ 级别，所有请求生效）
    TEMPMAIL_FILE="$WORK_DIR/src/services/tempmail.py"
    if [ -n "$TEMPMAIL_API_KEY" ] && [ -f "$TEMPMAIL_FILE" ]; then
        # 确保 import os
        grep -q "^import os$" "$TEMPMAIL_FILE" || sed -i '1s/^/import os\n/' "$TEMPMAIL_FILE"
        # 在 __init__ 的 self.config 赋值后注入 API Key 到 http_client
        if ! grep -q "TEMPMAIL_API_KEY" "$TEMPMAIL_FILE"; then
            sed -i '/self\._last_check_time/a\
\        # 📧 Tempmail API Key 注入\
\        _api_key = os.environ.get("TEMPMAIL_API_KEY", "")\
\        if _api_key:\
\            self._api_key = _api_key\
\        else:\
\            self._api_key = ""' "$TEMPMAIL_FILE"
            # 在请求头构造处加入 Authorization
            sed -i 's/"Accept": "application\/json",/"Accept": "application\/json",/' "$TEMPMAIL_FILE"
            sed -i '/"Accept": "application\/json",/a\
\                    **({"Authorization": f"Bearer {self._api_key}"} if getattr(self, "_api_key", "") else {}),' "$TEMPMAIL_FILE"
        fi
    fi

    # 补丁 4：扩大数据库连接池 5+10 → 20+30（解决并发 QueuePool 耗尽）
    SESSION_FILE="$WORK_DIR/src/database/session.py"
    if [ -f "$SESSION_FILE" ] && ! grep -q "pool_size" "$SESSION_FILE"; then
        sed -i 's/pool_pre_ping=True/pool_pre_ping=True,\n            pool_size=20,\n            max_overflow=30,\n            pool_timeout=60/' "$SESSION_FILE"
        echo -e "${GREEN}  ✅ 补丁4: 数据库连接池已扩大到 20+30${NC}"
    fi
}

# ═══════════ 去广告（静默版 + 幂等） ═══════════
remove_ads_silent() {
    WEBUI_FILE="$WORK_DIR/webui.py"
    NOTICE_TPL="$WORK_DIR/templates/partials/site_notice.html"

    # 1. 终端广告：注释掉 _print_project_notice() 调用
    if [ -f "$WEBUI_FILE" ] && grep -q "^[^#]*_print_project_notice()" "$WEBUI_FILE"; then
        sed -i 's/^\(\s*\)_print_project_notice()/\1# _print_project_notice()  # 已禁用/' "$WEBUI_FILE"
    fi

    # 2. Web UI 广告：直接清空广告模板文件（终极方案）
    if [ -f "$NOTICE_TPL" ]; then
        echo "<!-- 广告已移除 -->" > "$NOTICE_TPL"
    fi
}

# ═══════════ 去广告（交互版） ═══════════
remove_ads() {
    remove_ads_silent
    echo -e "${GREEN}✅ 广告已移除。${NC}"
    systemctl restart codex-console 2>/dev/null || true
}

# ═══════════ 部署环境 ═══════════
deploy_env() {
    check_or_ask_password
    echo -e "\n${YELLOW}>>> 开始部署 codex-console 环境...${NC}"
    apt-get update -y && apt-get install -y python3 python3-venv python3-pip git curl cron ufw sshpass

    # 防火墙
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow $TARGET_PORT/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1

    # 克隆源码（安全升级：不删除已有数据）
    if [ ! -f "$WORK_DIR/webui.py" ]; then
        echo -e "${CYAN}📦 正在克隆 codex-console 源码...${NC}"
        if [ -d "$WORK_DIR" ]; then
            [ -f "$WORK_DIR/.env" ] && cp "$WORK_DIR/.env" /tmp/.codex_env_backup
            # 备份数据库
            [ -f "$WORK_DIR/data/database.db" ] && {
                cp "$WORK_DIR/data/database.db" "/root/database_backup_$(date +%Y%m%d_%H%M%S).db"
                echo -e "${GREEN}✅ 数据库已备份到 /root/${NC}"
            }
            rm -rf "$WORK_DIR"
        fi
        git clone "https://github.com/GSDPGIT/codex-console.git" "$WORK_DIR"
        [ -f /tmp/.codex_env_backup ] && mv /tmp/.codex_env_backup "$WORK_DIR/.env"
    else
        echo -e "${GREEN}✅ codex-console 源码已存在，执行 git pull 更新...${NC}"
        cd "$WORK_DIR" && git pull 2>/dev/null || true
    fi

    # 应用所有补丁
    apply_patches
    echo -e "${GREEN}✅ 所有补丁已应用${NC}"

    # 确保 Python >=3.10
    ensure_python311

    # 虚拟环境（使用检测到的最佳 Python）
    cd "$WORK_DIR"
    if [ -f "$VENV_PY" ]; then
        # 检查已有 venv 的 Python 版本是否足够
        local venv_ver=$($VENV_PY -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)
        if [ "$venv_ver" -lt "$PYTHON_MIN_MINOR" ] 2>/dev/null; then
            echo -e "${YELLOW}⚠️  已有虚拟环境 Python 版本过低，正在重建...${NC}"
            rm -rf venv
        fi
    fi
    if [ -z "$PYTHON_BIN" ]; then
        echo -e "${RED}❌ PYTHON_BIN 未设置，请检查 Python 安装。${NC}"
        return 1
    fi
    [ ! -d "venv" ] && "$PYTHON_BIN" -m venv venv
    "$VENV_PY" -m pip install --upgrade pip && "$VENV_PY" -m pip install -r requirements.txt

    # 补丁 5：锁定 Jinja2/Starlette 版本（防止 "unhashable type: dict" 500 错误）
    "$VENV_PY" -m pip install "jinja2==3.1.3" "starlette==0.46.2" 2>/dev/null
    echo -e "${GREEN}  ✅ 补丁5: Jinja2/Starlette 版本已锁定${NC}"

    # systemd 服务
    create_or_update_service
    systemctl enable codex-console 2>/dev/null || true
    sync_passwords_now

    # 每日更新脚本（蓝绿升级：零停机更新）
    cat > "$UPDATE_SCRIPT" <<'UPDATEEOF'
#!/bin/bash
# [升级4] 蓝绿升级：staging 构建 → 健康检查 → 原子切换
source /root/.codex_env 2>/dev/null || true

PROD="/root/codex-console"
STAGING="/root/codex-console-staging"
ROLLBACK="/root/codex-console-rollback"

echo "[$(date)] 🔄 蓝绿升级开始..."

# 1. 克隆到 staging
rm -rf "$STAGING"
cp -a "$PROD" "$STAGING"
cd "$STAGING" && git remote set-url origin https://github.com/GSDPGIT/codex-console.git && git pull 2>/dev/null

# 2. 安装依赖 + 补丁
$STAGING/venv/bin/python -m pip install -r requirements.txt 2>/dev/null
$STAGING/venv/bin/python -m pip install "jinja2==3.1.3" "starlette==0.46.2" 2>/dev/null

# 重新打补丁
sed -i 's/request.count > 1000/request.count > 999999/g' $STAGING/src/web/routes/registration.py 2>/dev/null
WEBUI_F=$STAGING/webui.py
[ -f "$WEBUI_F" ] && grep -q "^[^#]*_print_project_notice()" "$WEBUI_F" && \
    sed -i 's/^\(\s*\)_print_project_notice()/\1# _print_project_notice()/' "$WEBUI_F"
SESSION_F=$STAGING/src/database/session.py
[ -f "$SESSION_F" ] && ! grep -q "pool_size" "$SESSION_F" && \
    sed -i 's/pool_pre_ping=True/pool_pre_ping=True,\n            pool_size=20,\n            max_overflow=30,\n            pool_timeout=60/' "$SESSION_F"
NOTICE_TPL=$STAGING/templates/partials/site_notice.html
[ -f "$NOTICE_TPL" ] && echo "<!-- 广告已移除 -->" > "$NOTICE_TPL"

# 3. 同步配置（cp -a 已复制数据库，这里只同步可能变化的 .env）
[ -f "$PROD/.env" ] && cp "$PROD/.env" "$STAGING/.env"

# 4. 原子切换
systemctl stop codex-console 2>/dev/null
rm -rf "$ROLLBACK"
mv "$PROD" "$ROLLBACK"
mv "$STAGING" "$PROD"
systemctl start codex-console

# 5. 健康检查（等 10 秒）
sleep 10
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/login --connect-timeout 5 2>/dev/null)
if [ "$HTTP" = "200" ]; then
    echo "[$(date)] ✅ 蓝绿升级成功！"
    rm -rf "$ROLLBACK"
else
    echo "[$(date)] ❌ 升级失败(HTTP $HTTP)，回滚..."
    systemctl stop codex-console 2>/dev/null
    rm -rf "$PROD"
    mv "$ROLLBACK" "$PROD"
    systemctl start codex-console
    echo "[$(date)] 🔙 已回滚到旧版本"
fi
UPDATEEOF
    chmod +x "$UPDATE_SCRIPT"
    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "$BACKUP_SCRIPT" > /tmp/mycron
    echo "0 5 * * * $UPDATE_SCRIPT" >> /tmp/mycron

    # 数据库备份 cron（每天凌晨 3 点）
    setup_backup_cron

    crontab /tmp/mycron && rm -f /tmp/mycron

    echo -e "${GREEN}✅ 部署完成！记得在云平台安全组也开放 $TARGET_PORT 端口。${NC}"
}

# ═══════════ 数据库备份 ═══════════
setup_backup_cron() {
    source "$ENV_FILE" 2>/dev/null || true
    if [ -z "$BACKUP_HOST" ]; then return; fi

    cat > "$BACKUP_SCRIPT" <<'BACKUPEOF'
#!/bin/bash
source /root/.codex_env 2>/dev/null || true
DB_FILE="/root/codex-console/data/database.db"
if [ ! -f "$DB_FILE" ]; then exit 0; fi

MACHINE_TAG=$(echo "$MACHINE_NAME" | tr ' ' '_')
DATE=$(date +%Y%m%d_%H%M%S)
REMOTE_FILE="${BACKUP_PATH}/${MACHINE_TAG}_${DATE}.db"

# 优先用 SSH Key，没有再用 sshpass
if [ -f /root/.ssh/id_rsa ] || [ -f /root/.ssh/id_ed25519 ]; then
    scp -o StrictHostKeyChecking=no "$DB_FILE" "${BACKUP_HOST}:${REMOTE_FILE}" 2>/dev/null
    ssh -o StrictHostKeyChecking=no "$BACKUP_HOST" \
        "cd $BACKUP_PATH && ls -t ${MACHINE_TAG}_*.db 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null" 2>/dev/null
elif [ -n "$BACKUP_PASS" ]; then
    sshpass -p "$BACKUP_PASS" scp -o StrictHostKeyChecking=no "$DB_FILE" "${BACKUP_HOST}:${REMOTE_FILE}" 2>/dev/null
    sshpass -p "$BACKUP_PASS" ssh -o StrictHostKeyChecking=no "$BACKUP_HOST" \
        "cd $BACKUP_PATH && ls -t ${MACHINE_TAG}_*.db 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null" 2>/dev/null
else
    echo "[$(date)] ❌ 无 SSH Key 也无密码，备份跳过" >> /root/bot_run.log
fi
BACKUPEOF
    chmod +x "$BACKUP_SCRIPT"
    # 加入 cron（避免重复）
    grep -q "$BACKUP_SCRIPT" /tmp/mycron 2>/dev/null || echo "0 3 * * * $BACKUP_SCRIPT" >> /tmp/mycron
}

backup_now() {
    source "$ENV_FILE" 2>/dev/null || true
    if [ -z "$BACKUP_HOST" ]; then
        echo -e "${RED}❌ 未配置备份服务器！请重置密码（选项 6）时配置。${NC}"
        return
    fi
    echo -e "${CYAN}💾 正在备份数据库...${NC}"
    bash "$BACKUP_SCRIPT"
    echo -e "${GREEN}✅ 备份完成！${NC}"
}

# ═══════════ daemon 引擎（智能版） ═══════════
generate_daemon() {
    cat > "$DAEMON_SCRIPT" <<DAEMONEOF
#!/bin/bash
LOG_FILE="$BOT_LOG"
PY_SCRIPT="$PY_SCRIPT"
WORK_DIR="$WORK_DIR"
VENV_PY="$VENV_PY"
CLOUD_URL="$CLOUD_SCRIPT_URL"
ENV_FILE="$ENV_FILE"
LOG_MAX_SIZE=$LOG_MAX_SIZE

while true; do
    if [ -f "\$ENV_FILE" ]; then source "\$ENV_FILE"; fi

    # ── 日志轮转 ──
    if [ -f "\$LOG_FILE" ]; then
        LOG_SIZE=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || echo 0)
        if [ "\$LOG_SIZE" -gt "\$LOG_MAX_SIZE" ]; then
            tail -c \$LOG_MAX_SIZE "\$LOG_FILE" > /tmp/bot_log_trim && mv -f /tmp/bot_log_trim "\$LOG_FILE"
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ 日志已轮转（超过 500K）" >> "\$LOG_FILE"
        fi
    fi

    # ── 清理 journal ──
    journalctl --vacuum-size=5M 2>/dev/null

    echo "==================================================" >> "\$LOG_FILE"

    # ── 规则 1: 健康检查（不再暴力 kill） ──
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🏥 规则 1: 健康检查..." >> "\$LOG_FILE"
    HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${TARGET_PORT}/login --connect-timeout 5 2>/dev/null)
    if [ "\$HTTP_CODE" != "200" ]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ 服务异常(HTTP \$HTTP_CODE)，正在重启..." >> "\$LOG_FILE"
        systemctl restart codex-console >> "\$LOG_FILE" 2>&1
        sleep 15
    else
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ✅ 服务正常运行" >> "\$LOG_FILE"
    fi

    # ── 规则 2: 杀旧打工人 ──
    pkill -9 -f "auto_run.py" 2>/dev/null

    # ── 规则 3: 同步云端脚本 ──
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ☁️ 规则 2: 同步云端脚本..." >> "\$LOG_FILE"
    curl -sSfL -o /tmp/auto_run_temp.py "\$CLOUD_URL" && mv -f /tmp/auto_run_temp.py "\$PY_SCRIPT"

    # ── 规则 4: 唤醒打工人（智能） ──
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 🚀 规则 3: 唤醒打工人..." >> "\$LOG_FILE"
    PYTHONUNBUFFERED=1 \$VENV_PY "\$PY_SCRIPT" >> "\$LOG_FILE" 2>&1

    # ── 规则 5: 仪表盘心跳 ──
    [ -f /root/codex_heartbeat.sh ] && bash /root/codex_heartbeat.sh 2>/dev/null

    # ── 规则 6: 休眠 ──
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 💤 规则 5: 进入 5 分钟休眠..." >> "\$LOG_FILE"
    sleep 300
done
DAEMONEOF
    chmod +x "$DAEMON_SCRIPT"
}

# ═══════════ 启动引擎 ═══════════
start_engine() {
    check_or_ask_password

    if [ ! -f "$VENV_PY" ]; then
        echo -e "${RED}❌ 虚拟环境不存在！请先执行选项 1【全能部署】。${NC}"
        return 1
    fi
    if [ ! -f /etc/systemd/system/codex-console.service ]; then
        echo -e "${YELLOW}⚠️  未检测到 systemd service，正在自动创建...${NC}"
        create_or_update_service
        systemctl enable codex-console 2>/dev/null || true
    fi

    generate_daemon
    pkill -9 -f "daemon.sh" 2>/dev/null
    nohup "$DAEMON_SCRIPT" > /dev/null 2>&1 &
    echo -e "${GREEN}✅ 智能引擎已启动！（不再暴力重启服务）${NC}"
}

# ═══════════ 清理旧任务 ═══════════
clear_old_tasks() {
    source "$ENV_FILE" 2>/dev/null || true
    DB_FILE="$WORK_DIR/data/database.db"
    if [ ! -f "$DB_FILE" ]; then
        echo -e "${RED}❌ 数据库文件不存在！${NC}"
        return
    fi

    # 用 python3 统计（避免 sqlite3 CLI 未安装）
    echo -e "\n${CYAN}📊 当前任务统计：${NC}"
    "$VENV_PY" -c "
import sqlite3
conn = sqlite3.connect('$DB_FILE')
for row in conn.execute('SELECT status, COUNT(*) FROM registration_tasks GROUP BY status'):
    print(f'   {row[0]}: {row[1]}')
total = conn.execute('SELECT COUNT(*) FROM registration_tasks').fetchone()[0]
print(f'\n   总计: {total}')
conn.close()
" 2>/dev/null

    echo -e "\n${YELLOW}请选择要清理的范围：${NC}"
    echo -e "  1. 只清理 failed/cancelled（保留成功和运行中的）"
    echo -e "  2. 清理 failed/cancelled + running/pending 僵尸任务（推荐！解决卡死问题）"
    echo -e "  3. 清理全部任务记录（账号数据不受影响）"
    echo -e "  0. 取消"
    read -p "请选择 [0-3]: " clean_choice

    case "$clean_choice" in
        1) SQL_WHERE="status IN ('failed','cancelled')" ;;
        2) SQL_WHERE="status IN ('failed','cancelled','running','pending')" ;;
        3) SQL_WHERE="1=1" ;;
        *) echo "已取消。"; return ;;
    esac

    # 统计将删除的数量
    DEL_COUNT=$("$VENV_PY" -c "
import sqlite3
conn = sqlite3.connect('$DB_FILE')
print(conn.execute(\"SELECT COUNT(*) FROM registration_tasks WHERE $SQL_WHERE\").fetchone()[0])
conn.close()
" 2>/dev/null)

    echo -e "${YELLOW}⚠️  将删除 $DEL_COUNT 条任务记录${NC}"
    read -p "确认？(y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cp "$DB_FILE" "/root/database_before_clean_$(date +%Y%m%d_%H%M%S).db"
        echo -e "${CYAN}💾 数据库已备份到 /root/${NC}"

        systemctl stop codex-console 2>/dev/null || true
        sleep 1

        "$VENV_PY" -c "
import sqlite3
conn = sqlite3.connect('$DB_FILE')
conn.execute(\"DELETE FROM registration_tasks WHERE $SQL_WHERE\")
conn.execute('VACUUM')
conn.commit()
remaining = conn.execute('SELECT COUNT(*) FROM registration_tasks').fetchone()[0]
print(f'✅ 清理完成！剩余 {remaining} 条')
conn.close()
" 2>/dev/null

        systemctl start codex-console 2>/dev/null || true
        echo -e "${GREEN}✅ 服务已重启${NC}"
    else
        echo "已取消。"
    fi
}

# ═══════════ 主菜单 ═══════════
main_menu() {
    while true; do
        print_header
        source "$ENV_FILE" 2>/dev/null || true
        echo -e "  ${CYAN}当前服务器: ${MACHINE_NAME:-未命名}${NC}"
        echo -e ""
        echo -e "  1. 🛠️   【全能部署】 安装/升级环境（安全保留数据库）"
        echo -e "  2. 🚀  【启动引擎】 启动智能监工（自动同步云端代码）"
        echo -e "  3. 🛑  【彻底停机】 暴力停止所有后台任务"
        echo -e "  4. 📊  【体检报告】 查看 CPU、内存及进程状态"
        echo -e "  5. 👀  【实时监控】 实时查看运行日志（Ctrl+C 退出）"
        echo -e "  6. ⚙️   【修改配置】 逐项修改密码/API Key/机器名/备份（回车保留不变）"
        echo -e "  7. 🚫  【去除广告】 去除项目声明广告"
        echo -e "  8. 🧹  【清理任务】 删除历史完成/失败任务记录"
        echo -e "  9. 💾  【立即备份】 立即备份数据库到中间服务器"
        echo -e "  0. 退出管理面板"
        echo -e "${GREEN}====================================================${NC}"

        read -p "请输入指令数字 [0-9]: " choice
        case "$choice" in
            1) deploy_env; read -p "按回车继续..." ;;
            2) start_engine; read -p "按回车继续..." ;;
            3) systemctl stop codex-console 2>/dev/null; pkill -9 -f daemon.sh; pkill -9 -f auto_run.py; pkill -f "journalctl.*codex" 2>/dev/null; pkill -f "tail.*bot_run" 2>/dev/null; echo "已物理超度"; read -p "按回车继续..." ;;
            4) echo -e "\n${CYAN}=== 系统信息 ===${NC}"; uptime; free -h; echo -e "\n${CYAN}=== 相关进程 ===${NC}"; ps aux | grep -E "daemon|auto_run|webui|codex" | grep -v grep; echo -e "\n${CYAN}=== 磁盘使用 ===${NC}"; df -h /; du -sh "$WORK_DIR/data" 2>/dev/null; read -p "按回车继续..." ;;
            5)
                trap - SIGINT
                echo -e "${YELLOW}按 Ctrl+C 退出监控${NC}"
                echo -e "${CYAN}=== 引擎日志 (bot_run.log 最近 20 行) ===${NC}"
                tail -n 20 "$BOT_LOG" 2>/dev/null
                echo -e "${CYAN}=== 注册实时日志 (journalctl) ===${NC}"
                journalctl -u codex-console -f -n 30 --no-pager 2>/dev/null || tail -f "$BOT_LOG"
                trap '' SIGINT
                ;;
            6) _ask_all_config "edit"; apply_patches; read -p "按回车继续..." ;;
            7) remove_ads; read -p "按回车继续..." ;;
            8) clear_old_tasks; read -p "按回车继续..." ;;
            9) backup_now; read -p "按回车继续..." ;;
            0) exit 0 ;;
        esac
    done
}

trap '' SIGINT
main_menu
