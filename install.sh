#!/bin/bash
# ============================================================================
# RunCat Neo カスタムメトリクス - インストールスクリプト
# ============================================================================
# スクリプトと LaunchAgent をセットアップします。
#
# 使い方:
#   ./install.sh              # 全プロバイダーをインストール
#   ./install.sh claude-code  # Claude Code のみ
#   ./install.sh kiro         # Kiro のみ
#   ./install.sh antigravity  # Antigravity のみ
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts"
INSTALL_SCRIPTS_DIR="${HOME}/.local/share/runcat-neo-metrics/scripts"
LAUNCHAGENTS_SRC="${REPO_DIR}/launchagents"
LAUNCHAGENTS_DST="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/RunCatNeoMetrics"
OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"

# カラー出力
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# --- インストール関数 ---
install_provider() {
    local provider="$1"
    local plist_name="com.runcat-neo.${provider}-usage.plist"
    local plist_src="${LAUNCHAGENTS_SRC}/${plist_name}"
    local plist_dst="${LAUNCHAGENTS_DST}/${plist_name}"

    if [[ ! -f "$plist_src" ]]; then
        error "plist が見つかりません: $plist_src"
        return 1
    fi

    # 既存の LaunchAgent をアンロード
    if launchctl list "com.runcat-neo.${provider}-usage" &>/dev/null; then
        launchctl unload "$plist_dst" 2>/dev/null || true
    fi

    # plist のパスを実際のパスに置換してインストール
    local kiro_api_key_value="${KIRO_API_KEY:-}"
    # API キーファイルから読む
    if [[ -z "$kiro_api_key_value" && -f "${HOME}/.config/kiro/api_key" ]]; then
        kiro_api_key_value=$(cat "${HOME}/.config/kiro/api_key" 2>/dev/null | tr -d '[:space:]')
    fi

    sed -e "s|SCRIPTS_DIR|${INSTALL_SCRIPTS_DIR}|g" \
        -e "s|LOG_DIR|${LOG_DIR}|g" \
        -e "s|HOME_DIR|${HOME}|g" \
        -e "s|KIRO_API_KEY_PLACEHOLDER|${kiro_api_key_value}|g" \
        "$plist_src" > "$plist_dst"

    # ロード
    launchctl load "$plist_dst"
    info "${provider} LaunchAgent インストール完了"
}

check_dependency() {
    local provider="$1"
    case "$provider" in
        claude-code)
            if [[ ! -f "${HOME}/.claude/.credentials.json" ]]; then
                local keychain_check
                keychain_check=$(security find-generic-password -s "Claude Code-credentials" 2>/dev/null || true)
                if [[ -z "$keychain_check" ]]; then
                    warn "Claude Code: 認証情報が見つかりません。'claude login' を実行してください。"
                    return 1
                fi
            fi
            ;;
        codex)
            if [[ ! -d "${CODEX_HOME:-${HOME}/.codex}/sessions" ]]; then
                warn "Codex: セッションディレクトリが見つかりません。Codex を使用してください。"
                return 1
            fi
            info "Codex: ローカルセッションログからデータを取得します (認証不要)"
            ;;
        kiro)
            if ! command -v kiro-cli &>/dev/null; then
                warn "Kiro: kiro-cli が見つかりません。"
                echo "  インストール: curl -fsSL https://cli.kiro.dev/install | bash"
                return 1
            fi
            # KIRO_API_KEY の確認 (ヘッドレスモード)
            if [[ -z "${KIRO_API_KEY:-}" ]]; then
                if [[ -f "${HOME}/.config/kiro/api_key" ]]; then
                    info "Kiro: API キー検出 (~/.config/kiro/api_key)"
                elif [[ -f "${OUTPUT_DIR}/.env" ]] && grep -q "KIRO_API_KEY" "${OUTPUT_DIR}/.env" 2>/dev/null; then
                    info "Kiro: API キー検出 (.env)"
                else
                    echo ""
                    warn "Kiro: KIRO_API_KEY が未設定です。"
                    echo "  LaunchAgent からの実行にはヘッドレスモード (API キー) が必要です。"
                    echo "  API キーは https://kiro.dev のアカウント設定から生成できます。"
                    echo ""
                    read -p "  KIRO_API_KEY を入力 (スキップは Enter): " kiro_key
                    if [[ -n "$kiro_key" ]]; then
                        mkdir -p "${HOME}/.config/kiro"
                        printf '%s' "$kiro_key" > "${HOME}/.config/kiro/api_key"
                        chmod 600 "${HOME}/.config/kiro/api_key"
                        export KIRO_API_KEY="$kiro_key"
                        info "Kiro: API キーを ~/.config/kiro/api_key に保存しました"
                    else
                        warn "Kiro: API キーなし。kiro-cli login 済みなら手動実行は可能です。"
                    fi
                fi
            else
                info "Kiro: KIRO_API_KEY 環境変数検出"
            fi
            ;;
        antigravity)
            # Antigravity は実行時にプロセスを検出するため、事前チェックは軽めに
            info "Antigravity: 実行時に Windsurf/Antigravity プロセスを検出します。"
            ;;
    esac
    return 0
}

# --- メイン ---
main() {
    local providers=("claude-code" "codex" "kiro" "antigravity")

    # 引数で特定プロバイダーのみ指定可能
    if [[ $# -gt 0 ]]; then
        providers=("$@")
    fi

    echo "============================================"
    echo " RunCat Neo カスタムメトリクス インストーラ"
    echo "============================================"
    echo ""

    # ディレクトリ作成
    mkdir -p "$LAUNCHAGENTS_DST" "$LOG_DIR" "$OUTPUT_DIR" "$INSTALL_SCRIPTS_DIR"
    info "ディレクトリ作成完了"

    # スクリプトをインストール先にコピー (Documents 外で LaunchAgent が実行可能に)
    cp "${SCRIPTS_DIR}/"*.sh "$INSTALL_SCRIPTS_DIR/"
    cp "${SCRIPTS_DIR}/"*.py "$INSTALL_SCRIPTS_DIR/" 2>/dev/null || true
    chmod +x "${INSTALL_SCRIPTS_DIR}/"*.sh
    info "スクリプトを ${INSTALL_SCRIPTS_DIR} にインストール完了"

    # 元のスクリプトにも実行権限付与 (手動実行用)
    chmod +x "${SCRIPTS_DIR}/"*.sh
    info "スクリプト実行権限設定完了"

    echo ""

    # 各プロバイダーをインストール
    for provider in "${providers[@]}"; do
        echo "--- ${provider} ---"
        if check_dependency "$provider"; then
            install_provider "$provider"
        else
            warn "${provider}: 依存関係の問題がありますが、LaunchAgent はインストールします。"
            install_provider "$provider" || true
        fi

        # 初回実行テスト
        echo "  初回実行テスト..."
        if bash "${SCRIPTS_DIR}/${provider}-usage.sh" 2>/dev/null; then
            info "${provider}: 初回実行成功"
        else
            warn "${provider}: 初回実行失敗 (後で再試行されます)"
        fi
        echo ""
    done

    echo "============================================"
    echo " セットアップ完了"
    echo "============================================"
    echo ""
    echo "RunCat Neo の設定:"
    echo "  1. RunCat Neo を開く"
    echo "  2. Settings → Metrics → Custom Metrics"
    echo "  3. 'Add JSON Source' をクリック"
    echo "  4. 以下のファイルを追加:"
    for provider in "${providers[@]}"; do
        echo "     - ~/.config/runcat-neo-metrics/${provider}-usage.json"
    done
    echo ""
    echo "ログ: ${LOG_DIR}/"
    echo "更新間隔: 2分ごと (LaunchAgent)"
    echo ""
    echo "手動実行:"
    for provider in "${providers[@]}"; do
        echo "  ${SCRIPTS_DIR}/${provider}-usage.sh"
    done
}

main "$@"
