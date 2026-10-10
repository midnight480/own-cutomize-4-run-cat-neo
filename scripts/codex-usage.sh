#!/bin/bash
# ============================================================================
# Codex (OpenAI) Usage → RunCat Neo Custom Metrics
# ============================================================================
# Codex app-server の JSON-RPC API からアカウントのレート制限情報を取得し、
# RunCat Neo のカスタムメトリクス JSON として書き出すスクリプト。
#
# 認証: ~/.codex/auth.json に保存済みの Codex ログイン情報を app-server 経由で利用
#
# データソース (優先順):
#   1. `codex app-server --listen stdio://` に JSON-RPC で接続し、
#      account/read・account/rateLimits/read・account/usage/read を呼び出す
#      (Codex 0.160 以降のアプリ/デーモン構成で有効)
#   2. ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl の token_count イベント
#      (旧バージョン向けフォールバック)
#
# 出力: ~/.config/runcat-neo-metrics/codex-usage.json
# ============================================================================

set -euo pipefail

# --- 設定 ---
OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
OUTPUT_FILE="${OUTPUT_DIR}/codex-usage.json"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
SESSIONS_DIR="${CODEX_HOME}/sessions"
CODEX_BIN="${CODEX_BIN:-codex}"

# --- ユーティリティ ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

atomic_write() {
    local dest="$1"
    local content="$2"
    local tmp
    tmp=$(mktemp "${dest}.XXXXXX")
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$dest"
}

# --- ログローテーション ---
# LaunchAgent が追記し続けるログの肥大化を防ぐ。launchd は O_APPEND でログを
# 開いているため、inode を維持したまま内容だけ末尾側に切り詰める。
LOG_FILE="${HOME}/Library/Logs/RunCatNeoMetrics/$(basename "$0" .sh).log"
LOG_MAX_BYTES=1048576  # 1MB

trim_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
    (( size <= LOG_MAX_BYTES )) && return 0
    local tmp
    tmp=$(mktemp "${LOG_FILE}.XXXXXX")
    tail -c $((LOG_MAX_BYTES / 2)) "$LOG_FILE" > "$tmp"
    cat "$tmp" > "$LOG_FILE"
    rm -f "$tmp"
}

# --- Codex ログ DB の空き領域回収 ---
# logs_2.sqlite は Codex が古い行を自前で削除するが、削除済みページ (freelist) は
# ファイル内に残り続ける。1日1回まで incremental_vacuum で実サイズを縮小する。
# デーモン稼働中は busy_timeout でロック待ちし、失敗しても処理は継続する。
prune_codex_logs() {
    local db="${CODEX_HOME}/logs_2.sqlite"
    local stamp="${OUTPUT_DIR}/.codex-logs-vacuum-at"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    [[ -f "$db" ]] || return 0
    local now last=0
    now=$(date +%s)
    [[ -f "$stamp" ]] && last=$(cat "$stamp" 2>/dev/null || echo 0)
    (( now - last < 86400 )) && return 0
    if sqlite3 -cmd "PRAGMA busy_timeout=3000;" "$db" \
        "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum;" >/dev/null 2>&1; then
        printf '%s\n' "$now" > "$stamp"
        log "Codex ログ DB の空き領域を回収しました: $db"
    fi
}

# --- app-server JSON-RPC で取得 ---
fetch_via_app_server() {
    python3 - "$CODEX_BIN" << 'PYTHON_SCRIPT'
import json
import subprocess
import sys
import time
import select
from datetime import datetime, timezone

CODEX_BIN = sys.argv[1]
DEADLINE = 30.0  # 全体タイムアウト (秒)

PLAN_LABELS = {
    "free": "Free",
    "go": "Go",
    "plus": "Plus",
    "pro": "Pro",
    "prolite": "Pro Lite",
    "promax": "Pro Max",
    "team": "Team",
    "business": "Business",
    "enterprise": "Enterprise",
    "edu": "Edu",
    "edu_plus": "Edu Plus",
    "edu_pro": "Edu Pro",
}


def plan_label(plan_type):
    if not plan_type:
        return None
    key = str(plan_type).lower()
    label = PLAN_LABELS.get(key)
    if label is None:
        label = key.replace("_", " ").title()
    return f"Codex {label}"


def window_label(minutes):
    if minutes is None:
        return "Limit"
    table = {300: "5h", 1440: "24h", 10080: "Weekly", 43200: "Monthly"}
    if minutes in table:
        return table[minutes]
    hours = minutes // 60
    if hours >= 24:
        return f"{hours // 24}d"
    if hours >= 1:
        return f"{hours}h"
    return f"{minutes}m"


def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}K"
    return str(n)


def main():
    proc = subprocess.Popen(
        [CODEX_BIN, "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    responses = {}
    try:
        def send(obj):
            proc.stdin.write(json.dumps(obj) + "\n")
            proc.stdin.flush()

        send({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "runcat-neo-metrics", "version": "1.0.0"}},
        })

        deadline = time.time() + DEADLINE
        sent_requests = False
        while time.time() < deadline and len(responses) < 3:
            remaining = deadline - time.time()
            ready, _, _ = select.select([proc.stdout], [], [], min(2.0, remaining))
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            line = proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            if msg.get("id") == 1:
                if "error" in msg:
                    print(json.dumps({"error": "initialize_failed"}), file=sys.stderr)
                    return
                send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
                send({"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}})
                send({"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read",
                      "params": {"excludeResetCreditDetails": True}})
                send({"jsonrpc": "2.0", "id": 4, "method": "account/usage/read", "params": {}})
                sent_requests = True
            elif msg.get("id") in (2, 3, 4):
                responses[msg["id"]] = msg

        if not sent_requests or 3 not in responses or "error" in responses.get(3, {}):
            print(json.dumps({"error": "no_data"}), file=sys.stderr)
            return
    finally:
        try:
            proc.kill()
        except Exception:
            pass

    rate_limits_resp = responses[3].get("result", {})
    account_resp = responses.get(2, {}).get("result", {})
    usage_resp = responses.get(4, {}).get("result", {})

    metrics = []

    # --- プラン ---
    plan_type = None
    account = account_resp.get("account") or {}
    if account.get("planType"):
        plan_type = account["planType"]
    if not plan_type:
        plan_type = (rate_limits_resp.get("rateLimits") or {}).get("planType")
    label = plan_label(plan_type)
    if label:
        metrics.append({"title": "Plan", "formattedValue": label})

    # --- レート制限ウィンドウ ---
    snapshots = []
    by_limit = rate_limits_resp.get("rateLimitsByLimitId")
    if isinstance(by_limit, dict) and by_limit:
        snapshots = [v for v in by_limit.values() if isinstance(v, dict)]
    elif rate_limits_resp.get("rateLimits"):
        snapshots = [rate_limits_resp["rateLimits"]]

    multi = len(snapshots) > 1
    bar_value = None

    for snap in snapshots:
        prefix = ""
        if multi:
            prefix = (snap.get("limitName") or snap.get("limitId") or "").strip()
            if prefix:
                prefix += " "

        for key in ("primary", "secondary"):
            window = snap.get(key)
            if not isinstance(window, dict):
                continue
            used = window.get("usedPercent")
            if used is None:
                continue
            label_w = prefix + window_label(window.get("windowDurationMins"))
            metrics.append({
                "title": label_w,
                "formattedValue": f"{used:g}%",
                "normalizedValue": round(min(used / 100.0, 1.0), 4),
            })
            if bar_value is None:
                bar_value = f"{used:g}%"

            resets_at = window.get("resetsAt")
            if resets_at:
                try:
                    remaining_h = (resets_at - time.time()) / 3600
                    if remaining_h > 0:
                        if remaining_h >= 24:
                            reset_str = f"{remaining_h / 24:.1f}d"
                        else:
                            reset_str = f"{remaining_h:.0f}h"
                        metrics.append({
                            "title": "Resets in",
                            "formattedValue": reset_str,
                        })
                except (ValueError, OSError):
                    pass

        # --- クレジット ---
        credits = snap.get("credits")
        if isinstance(credits, dict) and credits.get("hasCredits"):
            balance = credits.get("balance")
            if balance is not None:
                try:
                    bal_str = f"${float(balance):.2f}"
                except (TypeError, ValueError):
                    bal_str = str(balance)
                metrics.append({"title": "Credits", "formattedValue": bal_str})

    # --- 当日のトークン使用量 ---
    buckets = usage_resp.get("dailyUsageBuckets")
    if isinstance(buckets, list) and buckets:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        today_tokens = sum(
            int(b.get("tokens", 0))
            for b in buckets
            if isinstance(b, dict) and b.get("startDate") == today
        )
        if today_tokens > 0:
            metrics.append({
                "title": "Today",
                "formattedValue": f"{fmt_tokens(today_tokens)} tokens",
            })

    if not metrics:
        print(json.dumps({"error": "no_data"}), file=sys.stderr)
        return

    snapshot = {
        "title": "Codex",
        "symbol": "terminal",
        "metrics": metrics,
        "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if bar_value:
        snapshot["metricsBarValue"] = bar_value

    print(json.dumps(snapshot, ensure_ascii=False))


main()
PYTHON_SCRIPT
}

# --- 旧形式フォールバック: セッションログをスキャン ---
fetch_via_session_logs() {
    local latest_files
    latest_files=$(find "$SESSIONS_DIR" -name "rollout-*.jsonl" -mtime -90 2>/dev/null | sort -r | head -20)

    if [[ -z "$latest_files" ]]; then
        return 1
    fi

    python3 /dev/stdin "$latest_files" << 'PYTHON_SCRIPT'
import json
import sys
import os
from datetime import datetime, timezone

# 引数からファイルリストを取得
file_list = sys.argv[1].strip().split('\n')

# 最新の token_count イベントを探す
latest_token_count = None
latest_timestamp = None

for filepath in file_list:
    filepath = filepath.strip()
    if not filepath or not os.path.exists(filepath):
        continue
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if '"token_count"' not in line:
                    continue
                try:
                    event = json.loads(line)
                    if event.get('type') != 'event_msg':
                        continue
                    payload = event.get('payload', {})
                    if payload.get('type') != 'token_count':
                        continue
                    ts = event.get('timestamp', '')
                    # rate_limits.primary があるものだけ採用
                    rate_limits = payload.get('rate_limits', {})
                    if not rate_limits:
                        continue
                    primary = rate_limits.get('primary')
                    if not primary or primary.get('used_percent') is None:
                        continue
                    if latest_timestamp is None or ts > latest_timestamp:
                        latest_timestamp = ts
                        latest_token_count = payload
                except json.JSONDecodeError:
                    continue
    except (IOError, OSError):
        continue

if latest_token_count is None:
    print('{"error": "no_data"}', file=sys.stderr)
    sys.exit(1)

# データ抽出
rate_limits = latest_token_count.get('rate_limits', {})
info = latest_token_count.get('info', {})
total_usage = info.get('total_token_usage', {}) if info else {}

primary = rate_limits.get('primary', {})
secondary = rate_limits.get('secondary', {})
credits = rate_limits.get('credits', {})
plan_type = rate_limits.get('plan_type', 'unknown')
limit_id = rate_limits.get('limit_id', '')

metrics = []

# プラン
plan_display = plan_type.capitalize() if plan_type else "Unknown"
if limit_id:
    plan_display = f"Codex {plan_display}"
metrics.append({
    "title": "Plan",
    "formattedValue": plan_display
})

# Primary rate limit (通常は Weekly)
bar_value = None
if primary and primary.get('used_percent') is not None:
    used_pct = primary['used_percent']
    window_min = primary.get('window_minutes')
    resets_at = primary.get('resets_at')

    # ウィンドウラベル
    if window_min == 10080:
        window_label = "Weekly"
    elif window_min == 300:
        window_label = "5h"
    elif window_min:
        hours = window_min // 60
        if hours >= 24:
            window_label = f"{hours // 24}d"
        else:
            window_label = f"{hours}h"
    else:
        window_label = "Limit"

    metric = {
        "title": window_label,
        "formattedValue": f"{used_pct:.1f}%",
        "normalizedValue": round(min(used_pct / 100.0, 1.0), 4)
    }
    metrics.append(metric)
    bar_value = f"{used_pct:.0f}%"

    # リセット時刻
    if resets_at:
        try:
            reset_dt = datetime.fromtimestamp(resets_at, tz=timezone.utc)
            now = datetime.now(timezone.utc)
            remaining = reset_dt - now
            hours_left = remaining.total_seconds() / 3600
            if hours_left > 0:
                if hours_left > 24:
                    reset_str = f"{hours_left / 24:.1f}d"
                else:
                    reset_str = f"{hours_left:.0f}h"
                metrics.append({
                    "title": "Resets in",
                    "formattedValue": reset_str
                })
        except (ValueError, OSError):
            pass

# Secondary rate limit (存在する場合)
if secondary and isinstance(secondary, dict) and secondary.get('used_percent') is not None:
    sec_pct = secondary['used_percent']
    sec_window = secondary.get('window_minutes')
    if sec_window == 300:
        sec_label = "5h"
    elif sec_window == 10080:
        sec_label = "Weekly"
    elif sec_window:
        sec_label = f"{sec_window // 60}h"
    else:
        sec_label = "Secondary"
    metrics.append({
        "title": sec_label,
        "formattedValue": f"{sec_pct:.1f}%",
        "normalizedValue": round(min(sec_pct / 100.0, 1.0), 4)
    })

# Credits (Pro プランの場合)
if credits and isinstance(credits, dict) and credits.get('has_credits'):
    balance = credits.get('balance')
    if balance is not None:
        metrics.append({
            "title": "Credits",
            "formattedValue": f"${balance:.2f}"
        })

# トークン使用量 (セッション合計)
if total_usage:
    total_tokens = total_usage.get('total_tokens', 0)
    if total_tokens > 0:
        if total_tokens >= 1000000:
            token_str = f"{total_tokens / 1000000:.1f}M"
        elif total_tokens >= 1000:
            token_str = f"{total_tokens / 1000:.1f}K"
        else:
            token_str = str(total_tokens)
        metrics.append({
            "title": "Session",
            "formattedValue": f"{token_str} tokens"
        })

# 出力
snapshot = {
    "title": "Codex",
    "symbol": "terminal",
    "metrics": metrics,
    "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
if bar_value:
    snapshot["metricsBarValue"] = bar_value

print(json.dumps(snapshot, ensure_ascii=False))
PYTHON_SCRIPT
}

# --- メイン ---
main() {
    mkdir -p "$OUTPUT_DIR"
    trim_log
    prune_codex_logs

    local runcat_json=""

    # 1. app-server 経由 (Codex 0.160 以降)
    if command -v "$CODEX_BIN" >/dev/null 2>&1; then
        log "app-server からレート制限を取得中..."
        if runcat_json=$(fetch_via_app_server) && [[ -n "$runcat_json" && "$runcat_json" != *'"error"'* ]]; then
            log "RunCat Neo JSON 生成中..."
            atomic_write "$OUTPUT_FILE" "$runcat_json"
            log "完了: $OUTPUT_FILE"
            return 0
        fi
        log "app-server からの取得に失敗。セッションログにフォールバック..."
    else
        log "codex コマンドが見つかりません。セッションログをスキャンします。"
    fi

    # 2. フォールバック: セッションログ (旧バージョン)
    log "最新セッションログをスキャン中..."
    if runcat_json=$(fetch_via_session_logs) && [[ -n "$runcat_json" && "$runcat_json" != *'"error"'* ]]; then
        log "RunCat Neo JSON 生成中..."
        atomic_write "$OUTPUT_FILE" "$runcat_json"
        log "完了: $OUTPUT_FILE"
        return 0
    fi

    die "レート制限データを取得できません。Codex を使用してからお試しください。"
}

main "$@"
