#!/bin/bash
# ============================================================================
# Claude Code OAuth Usage → RunCat Neo Custom Metrics
# ============================================================================
# Claude Code の OAuth 認証を使い、使用量 API からトークン利用状況を取得し、
# RunCat Neo のカスタムメトリクス JSON として書き出すスクリプト。
#
# 認証情報の読み取り順:
#   1. ~/.claude/.credentials.json (Claude Code CLI が書き出すファイル)
#   2. macOS Keychain ("Claude Code-credentials" サービス)
#
# 出力: ~/.config/runcat-neo-metrics/claude-code-usage.json
# ============================================================================

set -euo pipefail

OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
OUTPUT_FILE="${OUTPUT_DIR}/claude-code-usage.json"

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
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

OUTPUT_FILE = os.path.expanduser("~/.config/runcat-neo-metrics/claude-code-usage.json")
CREDENTIALS_FILE = os.path.expanduser("~/.claude/.credentials.json")
KEYCHAIN_SERVICE = "Claude Code-credentials"
API_URL = "https://api.anthropic.com/api/oauth/usage"
BETA_HEADER = "oauth-2025-04-20"
USER_AGENT = "claude-code/2.1.0"

# subscriptionType が取得できない場合のフォールバック表示値
# (通常は credentials の subscriptionType から自動取得される)
PLAN_NAME_FALLBACK = None

# credentials の subscriptionType → 表示名
PLAN_LABELS = {
    "free": "Free",
    "pro": "Pro",
    "max": "Max",
    "team": "Team",
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


def _valid_token(oauth):
    """OAuth エントリから有効なアクセストークンを取り出す"""
    token = oauth.get("accessToken", "")
    if not token:
        return None
    expires_at = oauth.get("expiresAt", 0)
    if expires_at > 0:
        expires_sec = expires_at / 1000.0 if expires_at > 9999999999 else expires_at
        if time.time() >= expires_sec:
            return None
    return token


def get_credentials():
    """認証トークンとプラン種別を取得 (credentials.json → Keychain)

    Returns: (access_token, subscription_type)
    """
    subscription_type = None

    # 1. credentials.json
    if os.path.isfile(CREDENTIALS_FILE):
        try:
            with open(CREDENTIALS_FILE) as f:
                data = json.load(f)
            oauth = data.get("claudeAiOauth", data)
            subscription_type = oauth.get("subscriptionType") or subscription_type
            token = _valid_token(oauth)
            if token:
                return token, subscription_type
        except Exception:
            pass

    # 2. macOS Keychain
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout.strip())
            oauth = data.get("claudeAiOauth", data)
            subscription_type = oauth.get("subscriptionType") or subscription_type
            token = _valid_token(oauth)
            if token:
                return token, subscription_type
    except Exception:
        pass

    die("アクセストークンが見つかりません。'claude login' を実行してください。")


def plan_label(subscription_type):
    """subscriptionType を表示名に変換"""
    if not subscription_type:
        return PLAN_NAME_FALLBACK
    key = str(subscription_type).lower()
    return PLAN_LABELS.get(key, key.replace("_", " ").title())


def fetch_usage(token):
    """API から使用量を取得"""
    req = urllib.request.Request(
        API_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": BETA_HEADER,
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
            "Content-Type": "application/json",
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            die("認証エラー (401)。'claude login' を再実行してください。")
        elif e.code == 429:
            die("レートリミット (429)。しばらく待ってから再実行してください。")
        else:
            body = e.read().decode()[:200]
            die(f"API エラー: HTTP {e.code} - {body}")
    except Exception as e:
        die(f"ネットワークエラー: {e}")


def build_runcat_json(usage, plan_name):
    """API レスポンスを RunCat Neo JSON に変換"""
    metrics = []

    # Plan Name (credentials の subscriptionType から取得)
    if plan_name:
        metrics.append({
            "title": "Plan",
            "formattedValue": plan_name
        })

    # Model (limits 配列から active なモデル名を収集)
    limits = usage.get("limits")
    if limits and isinstance(limits, list):
        model_names = []
        for entry in limits:
            if not entry.get("is_active", True):
                continue
            scope = entry.get("scope") or {}
            model = scope.get("model") or {}
            display_name = model.get("display_name", "")
            if display_name and display_name not in model_names:
                model_names.append(display_name)
        if model_names:
            metrics.append({
                "title": "Model",
                "formattedValue": ", ".join(model_names)
            })

    # five_hour window
    five_hour = usage.get("five_hour")
    if five_hour and five_hour.get("utilization") is not None:
        util = five_hour["utilization"]
        # API は 0-100 のパーセント値を返す (0-1 ではない)
        pct = util if util <= 100 else util
        normalized = min(pct / 100.0, 1.0)
        metrics.append({
            "title": "5h",
            "formattedValue": f"{pct:g}%",
            "normalizedValue": round(normalized, 4)
        })

    # seven_day window
    seven_day = usage.get("seven_day")
    if seven_day and seven_day.get("utilization") is not None:
        util = seven_day["utilization"]
        pct = util if util <= 100 else util
        normalized = min(pct / 100.0, 1.0)
        metrics.append({
            "title": "7d",
            "formattedValue": f"{pct:g}%",
            "normalizedValue": round(normalized, 4)
        })

    # seven_day_opus
    seven_day_opus = usage.get("seven_day_opus")
    if seven_day_opus and seven_day_opus.get("utilization") is not None:
        util = seven_day_opus["utilization"]
        pct = util if util <= 100 else util
        metrics.append({
            "title": "7d Opus",
            "formattedValue": f"{pct:g}%",
            "normalizedValue": round(min(pct / 100.0, 1.0), 4)
        })

    # seven_day_sonnet
    seven_day_sonnet = usage.get("seven_day_sonnet")
    if seven_day_sonnet and seven_day_sonnet.get("utilization") is not None:
        util = seven_day_sonnet["utilization"]
        pct = util if util <= 100 else util
        metrics.append({
            "title": "7d Sonnet",
            "formattedValue": f"{pct:g}%",
            "normalizedValue": round(min(pct / 100.0, 1.0), 4)
        })

    # limits 配列 (新しい形式)
    limits = usage.get("limits")
    if limits and isinstance(limits, list):
        for entry in limits:
            if not entry.get("is_active", True):
                continue
            percent = entry.get("percent")
            if percent is None:
                continue
            scope = entry.get("scope") or {}
            model = scope.get("model") or {}
            model_name = model.get("display_name", "")
            group = entry.get("group", "")
            kind = entry.get("kind", "")

            # ラベル生成
            if "session" in kind or "five" in kind:
                time_label = "5h"
            elif "weekly" in kind:
                time_label = "7d"
            else:
                time_label = group or kind

            label = f"{time_label} {model_name}".strip() if model_name else time_label

            # 重複チェック
            if any(m["title"] == label for m in metrics):
                continue

            metrics.append({
                "title": label,
                "formattedValue": f"{percent:g}%",
                "normalizedValue": round(min(percent / 100.0, 1.0), 4)
            })

    # extra_usage (overages)
    extra = usage.get("extra_usage")
    if extra and extra.get("is_enabled"):
        used = extra.get("used_credits")
        limit = extra.get("monthly_limit")
        if used is not None and limit is not None and limit > 0:
            currency = extra.get("currency", "USD")
            metrics.append({
                "title": "Overage",
                "formattedValue": f"${used:.2f}/${limit:.0f} {currency}",
                "normalizedValue": round(min(used / limit, 1.0), 4)
            })

    # metricsBarValue: 5h をバーに表示
    bar_value = None
    if five_hour and five_hour.get("utilization") is not None:
        bar_value = f"{five_hour['utilization']:g}%"
    elif metrics:
        bar_value = metrics[0]["formattedValue"]

    snapshot = {
        "title": "Claude Code",
        "symbol": "brain.head.profile",
        "metrics": metrics,
        "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    }
    if bar_value:
        snapshot["metricsBarValue"] = bar_value

    return json.dumps(snapshot, ensure_ascii=False)


def main():
    log("アクセストークン取得中...")
    token, subscription_type = get_credentials()

    log("使用量 API 呼び出し中...")
    usage = fetch_usage(token)

    log("RunCat Neo JSON 生成中...")
    runcat_json = build_runcat_json(usage, plan_label(subscription_type))

    atomic_write(OUTPUT_FILE, runcat_json)
    log(f"完了: {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
PYTHON_EOF
