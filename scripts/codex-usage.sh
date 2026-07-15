#!/bin/bash
# ============================================================================
# Codex (OpenAI) Usage → RunCat Neo Custom Metrics
# ============================================================================
# Codex のローカルセッションログ (~/.codex/sessions/) をスキャンし、
# 最新の token_count イベントからレート制限情報を抽出して
# RunCat Neo のカスタムメトリクス JSON として書き出すスクリプト。
#
# 認証: 不要 (ローカルファイル読み取りのみ)
#
# データソース:
#   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
#   各セッションの event_msg type=token_count に rate_limits と token_usage が含まれる
#
# 出力: ~/.config/runcat-neo-metrics/codex-usage.json
# ============================================================================

set -euo pipefail

# --- 設定 ---
OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
OUTPUT_FILE="${OUTPUT_DIR}/codex-usage.json"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
SESSIONS_DIR="${CODEX_HOME}/sessions"

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

# --- メイン ---
main() {
    mkdir -p "$OUTPUT_DIR"

    if [[ ! -d "$SESSIONS_DIR" ]]; then
        die "Codex セッションディレクトリが見つかりません: $SESSIONS_DIR"
    fi

    log "最新セッションログをスキャン中..."

    # 最新の JSONL ファイルを探す (直近90日分)
    local latest_files
    latest_files=$(find "$SESSIONS_DIR" -name "rollout-*.jsonl" -mtime -90 2>/dev/null | sort -r | head -20)

    if [[ -z "$latest_files" ]]; then
        die "セッションログが見つかりません。Codex を使ってください。"
    fi

    log "RunCat Neo JSON 生成中..."

    # Python でパース & JSON 生成
    local runcat_json
    runcat_json=$(python3 /dev/stdin "$latest_files" << 'PYTHON_SCRIPT'
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
)

    if [[ -z "$runcat_json" || "$runcat_json" == *'"error"'* ]]; then
        die "セッションログに token_count データが見つかりません。Codex を使用してからお試しください。"
    fi

    atomic_write "$OUTPUT_FILE" "$runcat_json"
    log "完了: $OUTPUT_FILE"
}

main "$@"
