#!/bin/bash
# ============================================================================
# Kiro CLI Usage → RunCat Neo Custom Metrics
# ============================================================================
# kiro-cli を使って Kiro の月次クレジット使用量を取得し、
# RunCat Neo のカスタムメトリクス JSON として書き出すスクリプト。
#
# 認証方式 (優先順):
#   1. KIRO_API_KEY 環境変数 (ヘッドレスモード — ブラウザ不要)
#      → API キーは https://kiro.dev のアカウント設定から生成
#      → LaunchAgent / CI / cron 等のヘッドレス環境に最適
#   2. kiro-cli login 済みのセッション (対話モード)
#
# 前提条件:
#   - kiro-cli がインストール済み (PATH に存在)
#   - KIRO_API_KEY が設定済み、または kiro-cli login 済み
#
# 取得情報:
#   - プラン名 (Free / Pro / etc.)
#   - 月次クレジット使用量 (X of Y)
#   - ボーナスクレジット (存在する場合)
#   - リセット日
#
# 出力: ~/.config/runcat-neo-metrics/kiro-usage.json
# ============================================================================

set -euo pipefail

# --- 設定 ---
OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
OUTPUT_FILE="${OUTPUT_DIR}/kiro-usage.json"
KIRO_CLI_TIMEOUT=20

# --- KIRO_API_KEY 読み込み ---
# 環境変数が未設定の場合、設定ファイルから読み込みを試みる
if [[ -z "${KIRO_API_KEY:-}" ]]; then
    # ~/.config/kiro/api_key に保存されている場合
    if [[ -f "${HOME}/.config/kiro/api_key" ]]; then
        KIRO_API_KEY=$(cat "${HOME}/.config/kiro/api_key" 2>/dev/null | tr -d '[:space:]')
        export KIRO_API_KEY
    # .env ファイルから読む場合
    elif [[ -f "${HOME}/.config/runcat-neo-metrics/.env" ]]; then
        KIRO_API_KEY=$(grep -E '^KIRO_API_KEY=' "${HOME}/.config/runcat-neo-metrics/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"'"'" || true)
        if [[ -n "$KIRO_API_KEY" ]]; then
            export KIRO_API_KEY
        fi
    fi
fi

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

# ANSI エスケープシーケンスを除去 + kiro-cli のプロンプト装飾を除去
strip_ansi() {
    sed $'s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g' | sed 's/^λ↯//; s/λ↯//g' | tr -d '\r'
}

# --- kiro-cli 検出 ---
find_kiro_cli() {
    local cli_path

    # PATH から探す
    cli_path=$(which kiro-cli 2>/dev/null || true)
    if [[ -n "$cli_path" ]]; then
        echo "$cli_path"
        return
    fi

    # よくあるインストール先を確認
    local candidates=(
        "/usr/local/bin/kiro-cli"
        "${HOME}/.local/bin/kiro-cli"
        "${HOME}/.kiro/bin/kiro-cli"
    )
    for path in "${candidates[@]}"; do
        if [[ -x "$path" ]]; then
            echo "$path"
            return
        fi
    done

    die "kiro-cli が見つかりません。インストールしてください: https://kiro.dev"
}

# --- 使用量取得 ---
fetch_kiro_usage() {
    local kiro_cli="$1"
    local output

    # macOS には timeout コマンドがないため、バックグラウンドプロセス + wait で代替
    run_with_timeout() {
        local timeout_sec="$1"
        shift
        "$@" &
        local pid=$!
        (sleep "$timeout_sec" && kill "$pid" 2>/dev/null) &
        local watchdog=$!
        wait "$pid" 2>/dev/null
        local status=$?
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        return $status
    }

    # kiro-cli chat --no-interactive /usage でテキスト出力を取得
    output=$("$kiro_cli" chat --no-interactive /usage 2>&1 | strip_ansi || true)

    if [[ -z "$output" ]]; then
        # フォールバック: whoami で少なくともログイン状態を確認
        local whoami_output
        whoami_output=$("$kiro_cli" whoami 2>&1 | strip_ansi || true)

        if echo "$whoami_output" | grep -qi "not logged in\|login required"; then
            die "Kiro にログインしていません。'kiro-cli login' を実行してください。"
        fi

        die "kiro-cli から使用量情報を取得できませんでした。"
    fi

    # ログイン確認
    if echo "$output" | grep -qi "not logged in\|login required\|kiro-cli login"; then
        die "Kiro にログインしていません。'kiro-cli login' を実行してください。"
    fi

    echo "$output"
}

# --- パース & JSON 変換 ---
parse_and_convert() {
    local raw_output="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    printf '%s' "$raw_output" | python3 "${script_dir}/kiro_parse.py"
}

# --- メイン ---
main() {
    mkdir -p "$OUTPUT_DIR"

    log "kiro-cli 検出中..."
    local kiro_cli
    kiro_cli=$(find_kiro_cli)
    log "使用: $kiro_cli"

    log "使用量取得中..."
    local raw_output
    raw_output=$(fetch_kiro_usage "$kiro_cli")

    log "RunCat Neo JSON 生成中..."
    local runcat_json
    runcat_json=$(parse_and_convert "$raw_output")

    if [[ -z "$runcat_json" ]]; then
        die "JSON 生成に失敗しました"
    fi

    atomic_write "$OUTPUT_FILE" "$runcat_json"
    log "完了: $OUTPUT_FILE"
}

main "$@"
