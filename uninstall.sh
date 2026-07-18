#!/bin/bash
# ============================================================================
# RunCat Neo カスタムメトリクス - アンインストールスクリプト
# ============================================================================

set -euo pipefail

LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/RunCatNeoMetrics"
OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
INSTALL_SCRIPTS_DIR="${HOME}/.local/share/runcat-neo-metrics/scripts"

providers=("claude-code" "codex" "kiro" "antigravity")

echo "RunCat Neo カスタムメトリクス アンインストール"
echo ""

for provider in "${providers[@]}"; do
    local_label="com.runcat-neo.${provider}-usage"
    plist="${LAUNCHAGENTS_DIR}/${local_label}.plist"

    if [[ -f "$plist" ]]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "✓ ${provider} LaunchAgent 削除"
    fi
done

# JSON ファイル削除
for provider in "${providers[@]}"; do
    rm -f "${OUTPUT_DIR}/${provider}-usage.json"
done
echo "✓ JSON ファイル削除"

# インストール済みスクリプト削除
if [[ -d "$INSTALL_SCRIPTS_DIR" ]]; then
    rm -rf "$INSTALL_SCRIPTS_DIR"
    echo "✓ インストール済みスクリプト削除"
fi

# ログ削除 (確認)
if [[ -d "$LOG_DIR" ]]; then
    read -p "ログディレクトリを削除しますか? (${LOG_DIR}) [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        echo "✓ ログ削除"
    fi
fi

echo ""
echo "アンインストール完了"
echo "RunCat Neo の Custom Metrics 設定から手動でソースを削除してください。"
