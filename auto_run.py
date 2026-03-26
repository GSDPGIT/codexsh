import json
import time
import urllib.request
import urllib.error
import urllib.parse
import sys
import subprocess
import fcntl
import os

# 🔐 核心安全升级：动态读取服务器本地密码，不再硬编码！
PASSWORD = os.environ.get("CODEX_PASSWORD")
if not PASSWORD:
    print("❌ 致命错误：未读取到密码！请通过 SH 面板启动以加载本地安全变量。")
    sys.exit(1)

HOST = "http://127.0.0.1:18080"

# TG 推送 API
TG_API = "https://tg.700006.xyz/bot8223153416:AAGizqXN7b4Au4Qa5JWKT6SX-bmDe95pJeI/sendMessage?chat_id=837293210&text="

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
JOURNAL_VACUUM_SIZE = "10M"
IDLE_TIMEOUT_SECONDS = 1800
POLL_INTERVAL_SECONDS = 0.5


def send_tg_msg(msg: str) -> None:
    if not TG_API:
        return
    try:
        urllib.request.urlopen(TG_API + urllib.parse.quote(msg), timeout=5)
    except Exception:
        pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def cleanup_journal() -> None:
    try:
        subprocess.run(
            ["journalctl", f"--vacuum-size={JOURNAL_VACUUM_SIZE}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        pass


def steal_cookie_and_login() -> bool:
    print(f"🔄 [Python打工人] 正在向 {HOST} 出示动态密码...")
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(
        f"{HOST}/login",
        data=urllib.parse.urlencode({"next": "/", "password": PASSWORD}).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        opener.open(req, timeout=5)
    except urllib.error.HTTPError as e:
        if e.code in [302, 303] and e.headers.get("Set-Cookie"):
            HEADERS["Cookie"] = e.headers.get("Set-Cookie").split(";")[0]
            print("✅ 登录成功！取得 Cookie。")
            return True
    except Exception as e:
        print(f"❌ 连接失败: {e}")
    print("❌ 登录失败，退出交由 SH 处置。")
    return False


def fire_batch_task() -> bool:
    print(f"🚀 开始下发任务 ({PAYLOAD['count']}个 / {PAYLOAD['concurrency']}并发)...")
    req = urllib.request.Request(
        f"{HOST}/api/registration/batch",
        data=json.dumps(PAYLOAD).encode("utf-8"),
        headers=HEADERS,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body_bytes = resp.read()
    except urllib.error.HTTPError as e:
        body_bytes = e.read() if hasattr(e, "read") else b""
        print(f"❌ 任务下发 HTTP 异常: {e.code}")
        return False
    except Exception as e:
        print(f"❌ 任务下发异常: {e}")
        return False

    body_text = body_bytes.decode("utf-8", errors="ignore").strip()
    if not body_text:
        return True

    try:
        data = json.loads(body_text)
        if isinstance(data, dict):
            for key in ("success", "ok"):
                if key in data:
                    if bool(data[key]):
                        print("✅ 任务下发成功。")
                        return True
                    return False
            if "code" in data and str(data["code"]) not in {"0", "200", "success", "ok"}:
                return False
        return True
    except Exception:
        if any(word in body_text.lower() for word in ["error", "failed", "exception"]):
            return False
        return True


def terminate_process(proc) -> None:
    if not proc:
        return
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
    except Exception:
        pass


def monitor() -> int:
    print(f"🤖 [智能监工] 开始盯盘！目标: {PAYLOAD['count']} 个。")
    send_tg_msg(f"✅ 新一轮跑号任务已启动！目标：{PAYLOAD['count']}个。")
    process = subprocess.Popen(
        ["journalctl", "-u", "codex-console", "-f", "-n", "0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=os.setsid,
    )
    fd = process.stdout.fileno()
    fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)

    success_count, fail_count = 0, 0
    last_activity_time = time.time()
    target = PAYLOAD["count"]

    try:
        while True:
            if process.poll() is not None:
                return 1
            try:
                raw = process.stdout.readline()
                line = raw.decode("utf-8", errors="ignore") if raw else ""
            except Exception:
                line = ""

            current_time = time.time()
            if not line:
                if current_time - last_activity_time > IDLE_TIMEOUT_SECONDS:
                    return 1
                time.sleep(POLL_INTERVAL_SECONDS)
                continue

            last_activity_time = current_time

            if "注册任务完成" in line:
                success_count += 1
            elif any(k in line for k in ["放弃注册", "注册失败", "获取不到验证码"]):
                fail_count += 1

            if success_count + fail_count >= target:
                print(f"\n🎉 本轮达成！成功 {success_count}，失败 {fail_count}。")
                send_tg_msg(
                    f"🎉 本轮 {target} 个任务结束！\n成功: {success_count}\n失败: {fail_count}\n即将进入休眠。"
                )
                return 0
    finally:
        terminate_process(process)
        cleanup_journal()


if __name__ == "__main__":
    if not steal_cookie_and_login():
        cleanup_journal()
        sys.exit(1)
    if not fire_batch_task():
        cleanup_journal()
        sys.exit(1)
    sys.exit(monitor())
