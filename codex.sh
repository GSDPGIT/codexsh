#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BOT_LOG="/root/bot_run.log"
PY_SCRIPT="/root/auto_run.py"
WORK_DIR="/root/codex-console"
VENV_DIR="${WORK_DIR}/venv"
VENV_PY="${VENV_DIR}/bin/python"
DAEMON_SCRIPT="/root/daemon.sh"
UPDATE_SCRIPT="/root/codex_update.sh"
ENV_FILE="/root/.codex_env"
SERVICE_FILE="/etc/systemd/system/codex-console.service"
TARGET_PORT="18080"
CLOUD_SCRIPT_URL="https://raw.githubusercontent.com/GSDPGIT/codexsh/refs/heads/main/auto_run.py"
REPO_URL="https://github.com/dou-jiang/codex-console.git"

print_header() {
  clear || true
  echo -e "${GREEN}====================================================${NC}"
  echo -e "${YELLOW} Codex Console 自动化管理面板 v6.0 (Debian/Ubuntu 首次部署修复版) ${NC}"
  echo -e "${GREEN}====================================================${NC}"
}

log() { echo -e "$1"; }
err() { echo -e "${RED}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }
info() { echo -e "${CYAN}$1${NC}"; }

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "❌ 请使用 root 运行此脚本。"
    exit 1
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_systemd() {
  if ! cmd_exists systemctl; then
    err "❌ 当前系统没有 systemctl，无法管理 systemd 服务。"
    exit 1
  fi
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

save_env() {
  local pwd="$1"
  cat > "$ENV_FILE" <<EOF_ENV
export CODEX_PASSWORD='$pwd'
export TARGET_PORT='$TARGET_PORT'
EOF_ENV
  chmod 600 "$ENV_FILE"
}

check_or_ask_password() {
  if [ ! -f "$ENV_FILE" ]; then
    echo
    info "[安全配置] 检测到首次运行或密码文件不存在。"
    read -r -p "请设置统一访问密码: " input_pwd
    echo
    if [ -z "${input_pwd}" ]; then
      err "❌ 密码不能为空。"
      exit 1
    fi
    save_env "$input_pwd"
  fi
  load_env
  if [ -z "${CODEX_PASSWORD:-}" ]; then
    err "❌ 未读取到 CODEX_PASSWORD，请重新设置。"
    exit 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip git curl cron ca-certificates
  if ! cmd_exists ufw; then
    apt-get install -y ufw || true
  fi
}

configure_firewall() {
  if cmd_exists ufw; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow "${TARGET_PORT}/tcp" >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
  else
    warn "⚠️ 未安装 ufw，已跳过防火墙配置。请手动放行 ${TARGET_PORT}/tcp。"
  fi
}

clone_or_update_repo() {
  if [ ! -d "$WORK_DIR/.git" ]; then
    rm -rf "$WORK_DIR"
    git clone "$REPO_URL" "$WORK_DIR"
  else
    git -C "$WORK_DIR" fetch --all --prune || true
    git -C "$WORK_DIR" reset --hard origin/HEAD || true
    git -C "$WORK_DIR" pull --ff-only || true
  fi
}

ensure_project_files() {
  [ -f "$WORK_DIR/requirements.txt" ] || { err "❌ 缺少 requirements.txt"; exit 1; }
  [ -f "$WORK_DIR/webui.py" ] || { err "❌ 缺少 webui.py"; exit 1; }
}

create_venv() {
  cd "$WORK_DIR"
  if [ ! -x "$VENV_PY" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  "$VENV_PY" -m pip install --upgrade pip setuptools wheel
  "$VENV_PY" -m pip install -r requirements.txt
  [ -x "$VENV_PY" ] || { err "❌ venv 创建失败"; exit 1; }
}

write_project_env() {
  cat > "$WORK_DIR/.env" <<EOF_ENV
PASSWORD="$CODEX_PASSWORD"
PORT=$TARGET_PORT
EOF_ENV
}

create_service() {
  cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Codex Console Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
EnvironmentFile=-$ENV_FILE
Environment=PASSWORD=$CODEX_PASSWORD
Environment=PORT=$TARGET_PORT
ExecStart=$VENV_PY $WORK_DIR/webui.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable codex-console >/dev/null 2>&1 || true
}

sync_passwords_now() {
  check_or_ask_password
  write_project_env
  create_service
  if [ -f "$WORK_DIR/data/database.db" ]; then
    rm -f "$WORK_DIR/data/database.db"
  fi
  systemctl restart codex-console
  sleep 2
}

write_update_script() {
  cat > "$UPDATE_SCRIPT" <<'EOF_UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
WORK_DIR="/root/codex-console"
VENV_PY="${WORK_DIR}/venv/bin/python"
if [ -d "$WORK_DIR/.git" ]; then
  git -C "$WORK_DIR" fetch --all --prune || true
  git -C "$WORK_DIR" reset --hard origin/HEAD || true
fi
if [ -x "$VENV_PY" ] && [ -f "$WORK_DIR/requirements.txt" ]; then
  "$VENV_PY" -m pip install -r "$WORK_DIR/requirements.txt" || true
fi
systemctl daemon-reload || true
systemctl restart codex-console || true
EOF_UPDATE
  chmod +x "$UPDATE_SCRIPT"
}

install_cron_job() {
  write_update_script
  systemctl enable cron >/dev/null 2>&1 || true
  systemctl start cron >/dev/null 2>&1 || true
  tmpcron="$(mktemp)"
  crontab -l 2>/dev/null | grep -Fv "$UPDATE_SCRIPT" > "$tmpcron" || true
  echo "0 5 * * * $UPDATE_SCRIPT >> /var/log/codex_update.log 2>&1" >> "$tmpcron"
  crontab "$tmpcron"
  rm -f "$tmpcron"
}

generate_daemon() {
  cat > "$DAEMON_SCRIPT" <<'EOF_DAEMON'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG_FILE="/root/bot_run.log"
PY_SCRIPT="/root/auto_run.py"
VENV_PY="/root/codex-console/venv/bin/python"
CLOUD_URL="https://raw.githubusercontent.com/GSDPGIT/codexsh/refs/heads/main/auto_run.py"
TARGET_PORT="18080"
while true; do
  touch "$LOG_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 规则 1: 清理残留进程..." >> "$LOG_FILE"
  pkill -9 -f "auto_run.py" 2>/dev/null || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 规则 2: 重启 codex-console 服务..." >> "$LOG_FILE"
  systemctl restart codex-console >> "$LOG_FILE" 2>&1 || true
  sleep 5
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ☁️ 规则 3: 同步云端脚本..." >> "$LOG_FILE"
  curl -sSfL -o /tmp/auto_run_temp.py "$CLOUD_URL" && mv -f /tmp/auto_run_temp.py "$PY_SCRIPT"
  chmod 700 "$PY_SCRIPT"
  if [ ! -x "$VENV_PY" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 缺少虚拟环境解释器: $VENV_PY" >> "$LOG_FILE"
    sleep 60
    continue
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 规则 4: 唤醒打工人 (通过 $TARGET_PORT 端口验证密码)..." >> "$LOG_FILE"
  "$VENV_PY" "$PY_SCRIPT" >> "$LOG_FILE" 2>&1 || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 规则 5: 进入 5 分钟深度休眠..." >> "$LOG_FILE"
  sleep 300
done
EOF_DAEMON
  chmod +x "$DAEMON_SCRIPT"
}

validate_runtime() {
  [ -d "$WORK_DIR" ] || { err "❌ $WORK_DIR 不存在，请先执行 1。"; exit 1; }
  [ -x "$VENV_PY" ] || { err "❌ $VENV_PY 不存在，请先执行 1。"; exit 1; }
  [ -f "$SERVICE_FILE" ] || { err "❌ $SERVICE_FILE 不存在，请先执行 1。"; exit 1; }
}

deploy_env() {
  need_root
  ensure_systemd
  check_or_ask_password
  info ">>> 开始部署 codex-console 环境..."
  install_packages
  configure_firewall
  clone_or_update_repo
  ensure_project_files
  create_venv
  sync_passwords_now
  install_cron_job
  log "${GREEN}✅ 首次部署完成。Debian / Ubuntu 均可正常启动。${NC}"
}

start_engine() {
  need_root
  ensure_systemd
  check_or_ask_password
  validate_runtime
  generate_daemon
  pkill -9 -f "daemon.sh" 2>/dev/null || true
  nohup "$DAEMON_SCRIPT" >/dev/null 2>&1 &
  log "${GREEN}✅ 永动机引擎已启动。${NC}"
}

stop_engine() {
  systemctl stop codex-console >/dev/null 2>&1 || true
  pkill -9 -f daemon.sh 2>/dev/null || true
  pkill -9 -f auto_run.py 2>/dev/null || true
  log "${GREEN}✅ 已停止相关后台任务。${NC}"
}

health_report() {
  uptime || true
  free -h || true
  systemctl --no-pager --full status codex-console || true
  ps aux | grep -E "daemon\.sh|auto_run\.py|webui\.py" | grep -v grep || true
}

monitor_log() {
  touch "$BOT_LOG"
  tail -f "$BOT_LOG"
}

reset_password() {
  rm -f "$ENV_FILE"
  check_or_ask_password
  sync_passwords_now
}

main_menu() {
  while true; do
    print_header
    echo -e " 1. 〖全能部署〗 首次安装 / 修复环境 / 创建 systemd 服务 / 同步密码"
    echo -e " 2. 〖启动引擎〗 启动监工 (自动同步 GitHub 打工人代码)"
    echo -e " 3. 〖彻底停机〗 停止服务与后台任务"
    echo -e " 4. 〖体检报告〗 查看 CPU、内存、systemd 状态与相关进程"
    echo -e " 5. 〖实时监控〗 追踪控制台输出日志"
    echo -e " 6. 〖重置密码〗 修改本地密码并立刻同步到服务"
    echo -e " 0. 退出管理面板"
    echo -e "${GREEN}====================================================${NC}"
    read -r -p "请输入指令数字 [0-6]: " choice
    case "$choice" in
      1) deploy_env; read -r -p "按回车继续..." ;;
      2) start_engine; read -r -p "按回车继续..." ;;
      3) stop_engine; read -r -p "按回车继续..." ;;
      4) health_report; read -r -p "按回车继续..." ;;
      5) monitor_log ;;
      6) reset_password; read -r -p "按回车继续..." ;;
      0) exit 0 ;;
      *) warn "无效指令"; sleep 1 ;;
    esac
  done
}

trap '' SIGINT
main_menu
