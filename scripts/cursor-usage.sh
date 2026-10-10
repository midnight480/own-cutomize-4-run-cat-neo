#!/bin/bash
# ============================================================================
# Cursor Usage → RunCat Neo Custom Metrics
# ============================================================================
# cursor-agent (Cursor CLI) / Cursor IDE が保存するセッション JWT を使い、
# Cursor ダッシュボードの使用量エンドポイント (非公式) からプラン使用量を取得し、
# RunCat Neo のカスタムメトリクス JSON として書き出すスクリプト。
#
# 認証情報の読み取り順:
#   1. macOS Keychain ("cursor-access-token" / "cursor-refresh-token")
#      - `agent login` (cursor-agent) が書き込む
#   2. Cursor IDE の state.vscdb (cursorAuth/accessToken / cursorAuth/refreshToken)
#
# アクセストークン (JWT) が期限切れの場合はリフレッシュトークンで
# https://api2.cursor.sh/oauth/token を呼んで更新する (Keychain / vscdb への
# 書き戻しは行わない)。リフレッシュにも失敗したら `agent login` の
# 再実行が必要。
#
# 注意: このエンドポイントは公式 API ではないため、仕様変更で動かなくなる
# 可能性がある。
#
# 出力: ~/.config/runcat-neo-metrics/cursor-usage.json
# ============================================================================

set -euo pipefail

OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
OUTPUT_FILE="${OUTPUT_DIR}/cursor-usage.json"

mkdir -p "$OUTPUT_DIR"

# --- ログローテーション ---
# LaunchAgent が追記し続けるログの肥大化を防ぐ。launchd は O_APPEND でログを
# 開いているため、inode を維持したまま内容だけ末尾側に切り詰める。
LOG_FILE="${HOME}/Library/Logs/RunCatNeoMetrics/$(basename "$0" .sh).log"
LOG_MAX_BYTES=1048576  # 1MB

if [[ -f "$LOG_FILE" ]]; then
    size=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
        tmp=$(mktemp "${LOG_FILE}.XXXXXX")
        tail -c $((LOG_MAX_BYTES / 2)) "$LOG_FILE" > "$tmp"
        cat "$tmp" > "$LOG_FILE"
        rm -f "$tmp"
    fi
fi

exec python3 << 'PYTHON_EOF'
import base64
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

OUTPUT_FILE = os.path.expanduser("~/.config/runcat-neo-metrics/cursor-usage.json")
VSCDB_PATH = os.path.expanduser(
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
KEYCHAIN_ACCESS_SERVICE = "cursor-access-token"
KEYCHAIN_REFRESH_SERVICE = "cursor-refresh-token"
REFRESH_URL = "https://api2.cursor.sh/oauth/token"
USAGE_URL = "https://cursor.com/api/usage-summary"
USER_AGENT = "cursor-agent/2025.09.12"

# JWT の有効期限チェックに設ける余裕 (秒)。期限ギリギリのトークンは
# リフレッシュ対象にする
EXP_MARGIN_SEC = 120

# membershipType → 表示名
PLAN_LABELS = {
    "free": "Free",
    "pro": "Pro",
    "pro_plus": "Pro+",
    "ultra": "Ultra",
    "business": "Business",
    "enterprise": "Enterprise",
}


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr)


def die(msg):
    log(f"ERROR: {msg}")
    sys.exit(1)


def atomic_write(path, content):
    dirpath = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".runcat-", dir=dirpath)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)


def decode_jwt(token):
    """JWT のペイロードをデコード。失敗時は None"""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        payload = parts[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None


def valid_token(token):
    """有効期限内のアクセストークンなら JWT クレームを返す"""
    if not token:
        return None
    claims = decode_jwt(token)
    if not claims:
        return None
    exp = claims.get("exp", 0)
    if exp and time.time() >= exp - EXP_MARGIN_SEC:
        return None
    return claims


def keychain_get(service):
    """macOS Keychain からジェネリックパスワードを取得"""
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return None


def vscdb_get(key):
    """Cursor IDE の state.vscdb (SQLite) から値を取得"""
    if not os.path.isfile(VSCDB_PATH):
        return None
    try:
        conn = sqlite3.connect(f"file:{VSCDB_PATH}?mode=ro", uri=True, timeout=5)
        try:
            row = conn.execute(
                "SELECT value FROM ItemTable WHERE key = ?", (key,)
            ).fetchone()
            if row and row[0]:
                return str(row[0])
        finally:
            conn.close()
    except Exception:
        pass
    return None


def get_access_token():
    """有効なアクセストークンを返す。期限切れならリフレッシュを試みる"""
    # 1. 保存済みアクセストークン (Keychain → state.vscdb)
    for token in (keychain_get(KEYCHAIN_ACCESS_SERVICE),
                  vscdb_get("cursorAuth/accessToken")):
        if valid_token(token):
            return token

    # 2. リフレッシュトークンで更新 (Keychain → state.vscdb)
    refresh = keychain_get(KEYCHAIN_REFRESH_SERVICE) \
        or vscdb_get("cursorAuth/refreshToken")
    if not refresh:
        die("セッション情報が見つかりません。"
            "'agent login' (cursor-agent) または Cursor IDE で"
            "ログインしてください。")

    log("アクセストークン期限切れ。リフレッシュ中...")
    req = urllib.request.Request(
        REFRESH_URL,
        data=json.dumps({
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        }).encode(),
        headers={"Content-Type": "application/json",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        die(f"トークンリフレッシュ失敗: HTTP {e.code}。"
            "'agent login' を再実行してください。")
    except Exception as e:
        die(f"トークンリフレッシュ失敗: {e}")

    if data.get("shouldLogout"):
        die("セッションが失効しています (shouldLogout)。"
            "'agent login' を再実行してください。")

    token = data.get("access_token") or ""
    if not valid_token(token):
        die("リフレッシュ後のアクセストークンが無効です。"
            "'agent login' を再実行してください。")
    return token


def session_cookie(token):
    """JWT から WorkosCursorSessionToken クッキー値を組み立てる

    形式は `<userID>%3A%3A<jwt>`。userID は JWT の sub クレームの
    最後の `|` 以降 (例: `google-oauth2|12345` → `12345`)。
    """
    claims = decode_jwt(token) or {}
    sub = str(claims.get("sub") or "")
    uid = sub.rsplit("|")[-1] if sub else ""
    if not uid:
        return None, sub
    return f"WorkosCursorSessionToken={uid}%3A%3A{token}", sub


def fetch_usage(token):
    """usage-summary API を呼び出す"""
    cookie, sub = session_cookie(token)
    candidates = []
    if cookie:
        candidates.append(cookie)
    # userID の形式が異なる環境向けに sub 全体・生 JWT も試す
    if sub:
        candidates.append(f"WorkosCursorSessionToken={sub}%3A%3A{token}")
    candidates.append(f"WorkosCursorSessionToken={token}")

    last_error = None
    for cookie_value in candidates:
        req = urllib.request.Request(
            USAGE_URL,
            headers={
                "Cookie": cookie_value,
                "User-Agent": USER_AGENT,
                "Accept": "application/json",
            }
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                last_error = e
                continue
            body = e.read().decode()[:200]
            die(f"API エラー: HTTP {e.code} - {body}")
        except Exception as e:
            die(f"ネットワークエラー: {e}")

    if last_error is not None:
        die("認証エラー (401/403)。'agent login' を再実行してください。")
    die("セッションクッキーを組み立てられませんでした。")


def num(value):
    """数値として読める値だけを返す"""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    return None


def pct_metric(title, pct):
    return {
        "title": title,
        "formattedValue": f"{pct:g}%",
        "normalizedValue": round(min(max(pct, 0) / 100.0, 1.0), 4),
    }


def cents_metric(title, bucket):
    """{used, limit, remaining} (セント) のバケットをメトリクスに変換"""
    if bucket.get("enabled") is False:
        return None
    used = num(bucket.get("used"))
    limit = num(bucket.get("limit"))
    remaining = num(bucket.get("remaining"))
    if used is None and remaining is not None and limit:
        used = max(0, limit - remaining)
    if used is None:
        return None
    used_usd = used / 100.0
    if limit and limit > 0:
        limit_usd = limit / 100.0
        return {
            "title": title,
            "formattedValue": f"${used_usd:.2f}/${limit_usd:.2f}",
            "normalizedValue": round(min(used / limit, 1.0), 4),
        }
    return {"title": title, "formattedValue": f"${used_usd:.2f}"}


def build_runcat_json(summary):
    """usage-summary レスポンスを RunCat Neo JSON に変換"""
    metrics = []
    bar_pct = None

    # Plan (membershipType)
    mtype = str(summary.get("membershipType") or "").lower()
    plan_label = PLAN_LABELS.get(mtype)
    if plan_label is None and mtype:
        plan_label = mtype.replace("_", " ").title()
    if plan_label:
        metrics.append({"title": "Plan", "formattedValue": plan_label})

    individual = summary.get("individualUsage") or {}
    plan = individual.get("plan") if isinstance(individual.get("plan"), dict) else None
    overall = individual.get("overall") if isinstance(individual.get("overall"), dict) else None
    on_demand = individual.get("onDemand") if isinstance(individual.get("onDemand"), dict) else None

    # プラン使用量。Pro/Pro+/Ultra は Cursor Models (auto) と
    # Other Models (api) の2レール、古い/Enterprise 形状は overall (セント)
    if plan and plan.get("enabled") is not False:
        auto = num(plan.get("autoPercentUsed"))
        api = num(plan.get("apiPercentUsed"))
        total = num(plan.get("totalPercentUsed"))
        if auto is not None:
            metrics.append(pct_metric("Cursor Models", auto))
            bar_pct = auto if bar_pct is None else max(bar_pct, auto)
        if api is not None:
            metrics.append(pct_metric("Other Models", api))
            bar_pct = api if bar_pct is None else max(bar_pct, api)
        if auto is None and api is None:
            if total is not None:
                metrics.append(pct_metric("Plan Usage", total))
                bar_pct = total if bar_pct is None else max(bar_pct, total)
            else:
                m = cents_metric("Plan Usage", plan)
                if m:
                    metrics.append(m)
                    if "normalizedValue" in m:
                        bar_pct = m["normalizedValue"] * 100
    elif overall:
        m = cents_metric("Plan Usage", overall)
        if m:
            metrics.append(m)
            if "normalizedValue" in m:
                bar_pct = m["normalizedValue"] * 100

    # オンデマンド (従量課金)
    if on_demand:
        m = cents_metric("On-Demand", on_demand)
        if m:
            metrics.append(m)

    # 請求周期のリセット日
    end = summary.get("billingCycleEnd") or summary.get("endOfMonth")
    reset_label = None
    if isinstance(end, str):
        try:
            dt = datetime.fromisoformat(end.replace("Z", "+00:00"))
            reset_label = dt.astimezone().strftime("%Y-%m-%d")
        except ValueError:
            pass
    elif isinstance(end, (int, float)) and end > 0:
        ts = end / 1000.0 if end > 9999999999 else end
        reset_label = datetime.fromtimestamp(ts).strftime("%Y-%m-%d")
    if reset_label:
        metrics.append({"title": "Resets", "formattedValue": reset_label})

    if not metrics:
        die("usage-summary から表示可能なメトリクスを取得できませんでした。")

    snapshot = {
        "title": "Cursor",
        "symbol": "cursorarrow.rays",
        "metrics": metrics,
        "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if bar_pct is not None:
        snapshot["metricsBarValue"] = f"{bar_pct:g}%"
    elif metrics:
        snapshot["metricsBarValue"] = metrics[0]["formattedValue"]

    return json.dumps(snapshot, ensure_ascii=False)


def main():
    log("セッショントークン取得中...")
    token = get_access_token()

    log("使用量 API 呼び出し中...")
    usage = fetch_usage(token)

    log("RunCat Neo JSON 生成中...")
    runcat_json = build_runcat_json(usage)

    atomic_write(OUTPUT_FILE, runcat_json)
    log(f"完了: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
PYTHON_EOF
