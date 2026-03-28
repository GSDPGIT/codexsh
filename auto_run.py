#!/usr/bin/env python3
"""
Codex Console 自动化打工人 v4.0
核心改进：
  - 每轮启动时先取消所有残留任务（彻底解决僵尸问题）
  - 跟踪 batch_id 精确监控本批次进度
  - 实时显示 journalctl 日志
  - TG 凭据环境变量化（不再硬编码）
  - fcntl lazy import（兼容 Windows 调试）
  - 智能任务调度器（自动降档）
  - 每日自动报告
"""
import json
import time
import urllib.request
import urllib.error
import urllib.parse
import sys
import subprocess
import os

# ─── 环境变量 ───
PASSWORD = os.environ.get("CODEX_PASSWORD")
if not PASSWORD:
    print("❌ 致命错误：未读取到密码！请通过 SH 面板启动以加载本地安全变量。")
    sys.exit(1)

HOST = "http://127.0.0.1:18080"
MACHINE_NAME = os.environ.get("MACHINE_NAME", "未命名服务器")

# TG 推送（从环境变量读取，不再硬编码）
TG_BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID", "")
TG_PROXY = os.environ.get("TG_PROXY", "https://tg.700006.xyz")  # TG API 代理
TG_API = f"{TG_PROXY}/bot{TG_BOT_TOKEN}/sendMessage?chat_id={TG_CHAT_ID}&text=" if TG_BOT_TOKEN and TG_CHAT_ID else ""

PAYLOAD = {
    "email_service_type": "tempmail",
    "auto_upload_cpa": True,
    "cpa_service_ids": [1],
    "auto_upload_sub2api": False,
    "sub2api_service_ids": [],
    "auto_upload_tm": False,
    "tm_service_ids": [],
    "count": 8000,
    "interval_min": 5,
    "interval_max": 30,
    "concurrency": 10,
    "mode": "parallel"
}

HEADERS = {"Content-Type": "application/json"}

# ─── 配置 ───
TASK_SUBMIT_TIMEOUT = 1800  # 30分钟，低配服务器创建8000任务需要很久
LOGIN_TIMEOUT = 15
API_POLL_INTERVAL = 15
MAX_IDLE_MINUTES = 30
MAX_RETRIES = 3
RETRY_BACKOFF = 5
DB_PATH = "/root/codex-console/data/database.db"
SCHEDULER_STATE = "/root/.codex_scheduler.json"

# ─── 智能调度配置 ───
MIN_COUNT = 500
MAX_COUNT = 20000
MIN_CONCURRENCY = 3
MAX_CONCURRENCY = 50
FAIL_STREAK_PAUSE = 3  # 连续失败轮数达到此值时暂停1小时


# ═══════════ 工具函数 ═══════════

def tg(msg):
    if not TG_API:
        return
    try:
        urllib.request.urlopen(TG_API + urllib.parse.quote(f"[{MACHINE_NAME}] {msg}"), timeout=5)
    except Exception:
        pass


def cleanup_journal():
    try:
        subprocess.run(["journalctl", "--vacuum-size=5M"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        pass


def load_scheduler_state():
    """[升级2] 加载调度器状态"""
    try:
        if os.path.exists(SCHEDULER_STATE):
            with open(SCHEDULER_STATE, "r") as f:
                return json.load(f)
    except Exception:
        pass
    return {"last_success_rate": -1, "fail_streak": 0, "last_count": PAYLOAD["count"],
            "last_concurrency": PAYLOAD["concurrency"], "total_success": 0, "total_failed": 0,
            "rounds": 0}


def save_scheduler_state(state):
    """[升级2] 保存调度器状态"""
    try:
        with open(SCHEDULER_STATE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception:
        pass


def auto_tune_payload():
    """[升级2] 智能任务调度器：根据上轮成功率自动调整参数"""
    state = load_scheduler_state()
    rate = state.get("last_success_rate", -1)
    streak = state.get("fail_streak", 0)

    if rate < 0:
        # 首次运行，使用默认值
        print("📡 [智能调度] 首次运行，使用默认参数")
        return False

    # 连续失败太多，暂停
    if streak >= FAIL_STREAK_PAUSE:
        print(f"⚠️  [智能调度] 连续 {streak} 轮成功率低于30%，暂停1小时")
        tg(f"⚠️ 连续{streak}轮低成功率，自动暂停1小时")
        state["fail_streak"] = 0
        save_scheduler_state(state)
        time.sleep(3600)
        return False

    old_count = PAYLOAD["count"]
    old_conc = PAYLOAD["concurrency"]

    if rate > 90:
        # 成功率高，加码 20%
        PAYLOAD["count"] = min(int(old_count * 1.2), MAX_COUNT)
        PAYLOAD["concurrency"] = min(old_conc + 2, MAX_CONCURRENCY)
        action = "⬆️ 加码"
    elif rate > 70:
        # 稳定，保持
        action = "➖ 保持"
    elif rate > 50:
        # 偏低，小幅降档
        PAYLOAD["count"] = max(int(old_count * 0.8), MIN_COUNT)
        action = "⬇️ 小幅降档"
    else:
        # 低成功率，大幅降档
        PAYLOAD["count"] = max(int(old_count * 0.5), MIN_COUNT)
        PAYLOAD["concurrency"] = max(old_conc - 2, MIN_CONCURRENCY)
        action = "⚠️ 大幅降档"

    print(f"📡 [智能调度] 上轮成功率:{rate}% | {action} | count:{old_count}→{PAYLOAD['count']} conc:{old_conc}→{PAYLOAD['concurrency']}")
    return True


def send_daily_report():
    """[升级5] 每日自动报告"""
    if not TG_API:
        return
    try:
        import sqlite3
        conn = sqlite3.connect(DB_PATH)

        total_accounts = conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]
        today_tasks = conn.execute(
            "SELECT COUNT(*) FROM registration_tasks WHERE created_at >= date('now','localtime')"
        ).fetchone()[0]
        today_success = conn.execute(
            "SELECT COUNT(*) FROM registration_tasks WHERE status='completed' AND created_at >= date('now','localtime')"
        ).fetchone()[0]
        today_failed = conn.execute(
            "SELECT COUNT(*) FROM registration_tasks WHERE status='failed' AND created_at >= date('now','localtime')"
        ).fetchone()[0]
        conn.close()

        db_size = os.path.getsize(DB_PATH) / (1024 * 1024)  # MB
        rate = round(today_success / max(today_tasks, 1) * 100, 1)

        # 系统信息
        try:
            uptime_out = subprocess.check_output(["uptime", "-p"], text=True).strip()
        except Exception:
            uptime_out = "N/A"

        report = (
            f"📋 每日报告 \u2014 {MACHINE_NAME}\n"
            f"\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\n"
            f"\u2705 今日注册: {today_success}/{today_tasks} (成功率 {rate}%)\n"
            f"\u274c 今日失败: {today_failed}\n"
            f"\ud83d\udcca 总账号数: {total_accounts:,}\n"
            f"\ud83d\udcbe 数据库: {db_size:.1f}MB\n"
            f"\u23f1\ufe0f 运行时长: {uptime_out}"
        )
        tg(report)
        print(f"📋 每日报告已推送")
    except Exception as e:
        print(f"  ⚠️ 每日报告失败: {e}")


def api_get(path, timeout=10):
    try:
        req = urllib.request.Request(f"{HOST}{path}", headers=HEADERS)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", errors="ignore"))
    except Exception:
        return None


def api_post(path, data=None, timeout=10):
    try:
        body = json.dumps(data).encode("utf-8") if data else None
        req = urllib.request.Request(f"{HOST}{path}", data=body, headers=HEADERS, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", errors="ignore"))
    except urllib.error.HTTPError as e:
        try:
            err_body = json.loads(e.read().decode("utf-8", errors="ignore"))
        except Exception:
            err_body = None
        return e.code, err_body
    except Exception as e:
        print(f"  ⚠️ API 请求失败: {e}")
        return 0, None


# ═══════════ 核心逻辑 ═══════════

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def login_with_retry():
    for attempt in range(1, MAX_RETRIES + 1):
        print(f"🔄 [{MACHINE_NAME}] 登录尝试 {attempt}/{MAX_RETRIES}...")
        opener = urllib.request.build_opener(NoRedirect)
        req = urllib.request.Request(
            f"{HOST}/login",
            data=urllib.parse.urlencode({"next": "/", "password": PASSWORD}).encode("utf-8"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            opener.open(req, timeout=LOGIN_TIMEOUT)
        except urllib.error.HTTPError as e:
            cookie = e.headers.get("Set-Cookie")
            if e.code in [302, 303] and cookie:
                HEADERS["Cookie"] = cookie.split(";")[0]
                print("✅ 登录成功！")
                return True
        except Exception as e:
            print(f"  ❌ 连接失败: {e}")

        if attempt < MAX_RETRIES:
            time.sleep(RETRY_BACKOFF * attempt)

    print("❌ 登录彻底失败。")
    tg("❌ 登录失败！请检查服务状态。")
    return False


def cancel_all_stale_tasks():
    """取消数据库中所有 running/pending 状态的残留任务（核心修复）"""
    print("🧹 取消所有残留任务...")
    try:
        import sqlite3
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.execute(
            "SELECT COUNT(*) FROM registration_tasks WHERE status IN ('running','pending')"
        )
        stale_count = cursor.fetchone()[0]

        if stale_count > 0:
            conn.execute(
                "UPDATE registration_tasks SET status='cancelled' WHERE status IN ('running','pending')"
            )
            conn.commit()
            print(f"  🧹 已取消 {stale_count} 个残留任务")
        else:
            print("  ✅ 无残留任务")

        conn.close()
    except Exception as e:
        print(f"  ⚠️ 清理失败（不影响后续操作）: {e}")


def fire_batch_task():
    """提交批量注册任务。返回 batch_id 或 None"""

    # 先测试 API 连通性（用小请求）
    print("🔗 测试 API 连通性...")
    test = api_get("/api/registration/stats")
    if test is None:
        print("  ⚠️ API 无响应，等待 30 秒后重试...")
        time.sleep(30)
        test = api_get("/api/registration/stats")
        if test is None:
            print("  ❌ API 仍然无响应，跳过本轮。")
            return None
    print(f"  ✅ API 正常 (今日成功: {test.get('today_success', '?')})")

    for attempt in range(1, MAX_RETRIES + 1):
        print(f"🚀 下发任务 {attempt}/{MAX_RETRIES} ({PAYLOAD['count']}个/{PAYLOAD['concurrency']}并发)...")
        print(f"  ⏳ 超时设置: {TASK_SUBMIT_TIMEOUT}秒，请耐心等待...")

        try:
            body = json.dumps(PAYLOAD).encode("utf-8")
            req = urllib.request.Request(
                f"{HOST}/api/registration/batch",
                data=body,
                headers=HEADERS,
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=TASK_SUBMIT_TIMEOUT) as resp:
                result = json.loads(resp.read().decode("utf-8", errors="ignore"))
                batch_id = result.get("batch_id", "")
                print(f"  ✅ 下发成功！批次: {batch_id}")
                return batch_id

        except urllib.error.HTTPError as e:
            try:
                err_body = e.read().decode("utf-8", errors="ignore")
            except Exception:
                err_body = ""
            print(f"  ❌ HTTP {e.code}: {err_body[:500]}")
            if e.code == 400:
                return None  # 参数错误不重试

        except urllib.error.URLError as e:
            print(f"  ❌ URL 错误 ({type(e.reason).__name__}): {e.reason}")

        except Exception as e:
            print(f"  ❌ 异常 ({type(e).__name__}): {e}")

        if attempt < MAX_RETRIES:
            wait = RETRY_BACKOFF * attempt
            print(f"  ⏳ {wait}秒后重试...")
            time.sleep(wait)

    print("❌ 任务下发失败。")
    tg("❌ 任务下发失败！")
    return None


def monitor(batch_id=None):
    """监控任务进度"""
    target = PAYLOAD["count"]
    print(f"🤖 [{MACHINE_NAME}] 监工开始！目标: {target}")
    tg(f"✅ 新一轮启动！目标：{target}个")

    # 启动 journalctl
    jproc = None
    try:
        jproc = subprocess.Popen(
            ["journalctl", "-u", "codex-console", "-f", "-n", "0", "--no-pager"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            preexec_fn=os.setsid,
        )
        fd = jproc.stdout.fileno()
        try:
            import fcntl
            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        except ImportError:
            pass  # Windows 下无 fcntl，跳过
    except Exception as e:
        print(f"  ⚠️ journalctl: {e}")

    last_poll = 0
    last_activity = time.time()
    idle_timeout = MAX_IDLE_MINUTES * 60
    prev_done = -1

    keywords = ["注册", "验证码", "完成", "失败", "成功", "放弃", "错误",
                "error", "Error", "邮箱", "OTP", "task", "代理",
                "register", "密码", "token", "OAuth", "Account"]

    try:
        while True:
            now = time.time()

            # 1. 实时 journalctl 日志
            if jproc and jproc.poll() is None:
                try:
                    while True:
                        raw = jproc.stdout.readline()
                        if not raw:
                            break
                        line = raw.decode("utf-8", errors="ignore").strip()
                        if line and any(kw in line for kw in keywords):
                            parts = line.split("]: ", 1)
                            display = parts[1] if len(parts) > 1 else line
                            print(f"  📋 {display[:200]}")
                            last_activity = now
                except Exception:
                    pass

            # 2. API 轮询
            if now - last_poll >= API_POLL_INTERVAL:
                last_poll = now

                if batch_id:
                    batch = api_get(f"/api/registration/batch/{batch_id}")
                    if batch:
                        total = batch.get("total", target)
                        completed = batch.get("completed", 0)
                        success = batch.get("success", 0)
                        failed = batch.get("failed", 0)
                        finished = batch.get("finished", False)
                        rate = round(success / max(total, 1) * 100, 1)

                        if completed != prev_done:
                            print(f"  📊 {completed}/{total} | 成功 {success} | 失败 {failed} | {rate}%")
                            prev_done = completed
                            last_activity = now

                        if finished or (total > 0 and completed >= total):
                            print(f"\n🎉 完成！成功 {success}，失败 {failed}，{rate}%")
                            tg(f"🎉 {total}个任务完成！成功:{success} 失败:{failed} 成功率:{rate}%")
                            return 0
                    else:
                        # batch API 不存在，用 running/pending 兜底
                        running = api_get("/api/registration/tasks?status=running&page=1&page_size=1")
                        pending = api_get("/api/registration/tasks?status=pending&page=1&page_size=1")
                        r = running.get("total", 0) if running else 0
                        p = pending.get("total", 0) if pending else 0
                        if r + p == 0:
                            print("\n✅ 所有任务完成。")
                            return 0
                        elif r + p != prev_done:
                            print(f"  📊 活跃: running={r}, pending={p}")
                            prev_done = r + p
                            last_activity = now
                else:
                    # 无 batch_id 时查活跃任务
                    running = api_get("/api/registration/tasks?status=running&page=1&page_size=1")
                    pending = api_get("/api/registration/tasks?status=pending&page=1&page_size=1")
                    r = running.get("total", 0) if running else 0
                    p = pending.get("total", 0) if pending else 0
                    if r + p == 0:
                        print("\n✅ 所有任务完成。")
                        return 0
                    elif r + p != prev_done:
                        print(f"  📊 活跃: running={r}, pending={p}")
                        prev_done = r + p
                        last_activity = now

            # 3. 超时
            if now - last_activity > idle_timeout:
                print(f"\n⏰ {MAX_IDLE_MINUTES}分钟无活动，退出。")
                tg(f"⏰ 监控超时退出（{MAX_IDLE_MINUTES}分钟无活动）")
                return 1

            time.sleep(0.5)

    finally:
        if jproc:
            try:
                jproc.terminate()
                jproc.wait(timeout=3)
            except Exception:
                try:
                    jproc.kill()
                except Exception:
                    pass
        cleanup_journal()


# ═══════════ 主入口 ═══════════

if __name__ == "__main__":
    print(f"\n{'='*50}")
    print(f"🏷️  机器: {MACHINE_NAME} | v4.0")
    print(f"{'='*50}")

    cleanup_journal()

    # [升级5] 每日报告（在登录前尝试，不影响主流程）
    try:
        import datetime
        now = datetime.datetime.now()
        report_flag = f"/tmp/codex_report_{now.strftime('%Y%m%d')}.done"
        if now.hour >= 6 and not os.path.exists(report_flag):
            send_daily_report()
            with open(report_flag, "w") as f:
                f.write("done")
    except Exception:
        pass

    if not login_with_retry():
        sys.exit(1)

    # [升级2] 智能调度: 根据上轮表现自动调整参数
    auto_tune_payload()

    # 记录本轮开始前的统计（用于计算本轮差值）
    pre_stats = api_get("/api/registration/stats")
    pre_success = pre_stats.get("today_success", 0) if pre_stats else 0
    pre_failed = pre_stats.get("today_failed", 0) if pre_stats else 0

    # 核心改变：每轮先取消所有残留 → 再提交新任务
    cancel_all_stale_tasks()

    batch_id = fire_batch_task()
    if batch_id is None:
        sys.exit(1)

    exit_code = monitor(batch_id)

    # [升级2] 更新调度器状态（用差值计算本轮成功率，而非累计）
    state = load_scheduler_state()
    stats = api_get("/api/registration/stats")
    if stats:
        round_success = stats.get("today_success", 0) - pre_success
        round_failed = stats.get("today_failed", 0) - pre_failed
        round_total = round_success + round_failed
        rate = round(round_success / max(round_total, 1) * 100, 1)
        state["last_success_rate"] = rate
        state["rounds"] = state.get("rounds", 0) + 1
        state["total_success"] = state.get("total_success", 0) + round_success
        state["total_failed"] = state.get("total_failed", 0) + round_failed
        if rate < 30:
            state["fail_streak"] = state.get("fail_streak", 0) + 1
        else:
            state["fail_streak"] = 0
        state["last_count"] = PAYLOAD["count"]
        state["last_concurrency"] = PAYLOAD["concurrency"]
        save_scheduler_state(state)
        print(f"📈 本轮成功率: {rate}% (成功{round_success}/失败{round_failed}) | 已保存调度状态")

    sys.exit(exit_code)
