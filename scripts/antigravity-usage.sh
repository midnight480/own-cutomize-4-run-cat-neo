#!/bin/bash
# ============================================================================
# Antigravity Usage → RunCat Neo Custom Metrics
# ============================================================================
# Antigravity (Windsurf/Codeium) のローカル Language Server に接続し、
# モデルクォータ情報を取得して RunCat Neo のカスタムメトリクス JSON に変換する。
#
# 動作原理:
#   A. agy CLI がインストール済みなら `agy -p /usage --output-format json` で取得
#      (トークン消費なし、agy を別途起動しておく必要もない)
#   B. A が使えない場合は起動中のアプリの Language Server に接続:
#   1. ps コマンドで Antigravity language_server / agy プロセスを検出
#   2. --csrf_token フラグからCSRFトークンを抽出
#   3. lsof でリスニングポートを特定
#   4. localhost の gRPC-web エンドポイントに POST して使用量取得
#      - RetrieveUserQuotaSummary (推奨、新しい形式)
#      - GetUserStatus (フォールバック)
#
# 前提条件:
#   - agy CLI がインストール済みでログイン済み
#   - または Antigravity (Windsurf) アプリが起動中
#
# 備考:
#   agy CLI 1.2.x 以降は Language Server が CSRF トークンを要求し、
#   トークンを起動引数などで公開しないため、B の方法では agy に接続できない。
#
# 出力: ~/.config/runcat-neo-metrics/antigravity-usage.json
# ============================================================================

set -euo pipefail

# --- 設定 ---
OUTPUT_DIR="${HOME}/.config/runcat-neo-metrics"
OUTPUT_FILE="${OUTPUT_DIR}/antigravity-usage.json"
REQUEST_TIMEOUT=8
AGY_TIMEOUT=30

# gRPC-web パス
QUOTA_SUMMARY_PATH="/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
USER_STATUS_PATH="/exa.language_server_pb.LanguageServerService/GetUserStatus"

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

# --- agy CLI から取得 ---
fetch_via_agy_cli() {
    # LaunchAgent の PATH には ~/.local/bin (agy のインストール先) が含まれないことがある
    local agy_bin
    agy_bin=$(command -v agy 2>/dev/null || true)
    if [[ -z "$agy_bin" && -x "${HOME}/.local/bin/agy" ]]; then
        agy_bin="${HOME}/.local/bin/agy"
    fi
    [[ -n "$agy_bin" ]] || return 1

    local response
    # agy がハングしても LaunchAgent を止めないよう alarm で打ち切る
    response=$(/usr/bin/perl -e "alarm ${AGY_TIMEOUT}; exec @ARGV" \
        "$agy_bin" -p /usage --output-format json --print-timeout "$((AGY_TIMEOUT - 5))s" 2>/dev/null) || return 1

    printf '%s' "$response" | python3 -c '
import json
import sys
from datetime import datetime, timezone

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if data.get("status") != "SUCCESS":
    sys.exit(1)

groups = (data.get("command") or {}).get("data", {}).get("groups", [])

metrics = []
max_used = None

for group in groups:
    group_lower = group.get("name", "").lower()
    if "gemini" in group_lower:
        group_label = "Gemini"
    elif "claude" in group_lower or "gpt" in group_lower:
        group_label = "Claude/GPT"
    else:
        group_label = group.get("name", "Unknown")

    for bucket in group.get("buckets", []):
        remaining = bucket.get("remaining_fraction")
        if remaining is None:
            continue

        window = bucket.get("window", "")
        if window == "5h":
            time_label = "5h"
        elif window == "weekly":
            time_label = "Weekly"
        else:
            time_label = bucket.get("name") or window

        used = min(max(1 - remaining, 0.0), 1.0)
        used_pct = round(used * 100, 1)
        metrics.append({
            "title": f"{group_label} {time_label}",
            "formattedValue": f"{used_pct}%",
            "normalizedValue": round(used, 4)
        })

        # 最も使用率の高いものをバーに表示
        if max_used is None or used_pct > max_used:
            max_used = used_pct

if not metrics:
    sys.exit(1)

snapshot = {
    "title": "Antigravity",
    "symbol": "wind",
    "metricsBarValue": f"{max_used}%",
    "metrics": metrics,
    "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
print(json.dumps(snapshot, ensure_ascii=False))
'
}

# --- プロセス検出 ---
detect_antigravity_process() {
    local ps_output
    ps_output=$(ps -ax -o pid=,command= 2>/dev/null)

    # language_server プロセスを探す (Antigravity app / IDE / CLI)
    echo "$ps_output" | python3 -c "
import re, sys, json

ps_output = sys.stdin.read()
results = []
cli_without_token = False

for line in ps_output.strip().split('\n'):
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    try:
        pid = int(parts[0])
    except ValueError:
        continue
    command = parts[1]
    cmd_lower = command.lower()

    # language_server 検出
    ls_pattern = r'(^|[/\\\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|\$)'
    is_ls = bool(re.search(ls_pattern, cmd_lower))

    # Antigravity / Windsurf / Codeium 判定
    is_ag = False
    if '--app_data_dir' in cmd_lower and ('antigravity' in cmd_lower or 'windsurf' in cmd_lower or 'codeium' in cmd_lower):
        is_ag = True
    if any(x in cmd_lower for x in ['antigravity.app/', 'windsurf.app/', '/antigravity/', '/windsurf/', '/codeium/']):
        is_ag = True

    # CLI 判定
    cli_pattern = r'(^|[/\\\\])(antigravity-cli|antigravity_cli|agy|windsurf-cli)(\s|\$)'
    is_cli = bool(re.search(cli_pattern, cmd_lower))

    kind = None
    if is_ls and is_ag:
        ide_markers = ['antigravity ide.app/', 'windsurf ide.app/',
                       '--app_data_dir antigravity-ide', '--app_data_dir=antigravity-ide',
                       '/extensions/antigravity/bin/language_server',
                       '/extensions/windsurf/bin/language_server']
        if any(m in cmd_lower for m in ide_markers):
            kind = 'ide'
        else:
            kind = 'app'
    elif is_cli:
        kind = 'cli'

    if kind is None:
        continue

    # CSRF トークン抽出
    csrf_match = re.search(r'--csrf_token[=\s]+([^\s]+)', command, re.IGNORECASE)
    csrf_token = csrf_match.group(1) if csrf_match else None
    if csrf_token is None:
        # agy CLI はトークンを公開しないため API を呼べない
        if kind == 'cli':
            cli_without_token = True
        continue

    # Extension server port
    ext_port_match = re.search(r'--extension_server_port[=\s]+(\d+)', command, re.IGNORECASE)
    ext_port = int(ext_port_match.group(1)) if ext_port_match else None

    ext_csrf_match = re.search(r'--extension_server_csrf_token[=\s]+([^\s]+)', command, re.IGNORECASE)
    ext_csrf = ext_csrf_match.group(1) if ext_csrf_match else None

    results.append({
        'pid': pid,
        'csrf_token': csrf_token,
        'extension_port': ext_port,
        'ext_csrf_token': ext_csrf,
        'kind': kind
    })

if not results:
    print('CLI_ONLY' if cli_without_token else 'NOT_FOUND')
else:
    print(json.dumps(results[0]))
"
}

# --- ポート検出 ---
detect_ports() {
    local pid="$1"
    local ports

    ports=$(/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null \
        | grep -oE ':\d+' \
        | sed 's/://' \
        | sort -un \
        || true)

    if [[ -z "$ports" ]]; then
        die "Antigravity のリスニングポートが検出できません (PID: $pid)"
    fi

    echo "$ports"
}

# --- API リクエスト ---
make_request() {
    local scheme="$1"
    local port="$2"
    local path="$3"
    local csrf_token="$4"
    local body="$5"
    local requires_csrf="${6:-true}"

    local url="${scheme}://127.0.0.1:${port}${path}"
    local curl_args=(
        -s
        --max-time "$REQUEST_TIMEOUT"
        -X POST
        -H "Content-Type: application/json"
        -H "Connect-Protocol-Version: 1"
        -d "$body"
    )

    if [[ "$requires_csrf" == "true" && -n "$csrf_token" ]]; then
        curl_args+=(-H "X-Codeium-Csrf-Token: ${csrf_token}")
    fi

    # HTTPS の場合は証明書検証をスキップ (localhost)
    if [[ "$scheme" == "https" ]]; then
        curl_args+=(-k)
    fi

    local response http_code
    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url" 2>/dev/null || echo -e "\n000")
    http_code=$(echo "$response" | tail -1)
    local body_response
    body_response=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        echo "$body_response"
        return 0
    fi

    return 1
}

# --- エンドポイント試行 ---
try_endpoints() {
    local ports="$1"
    local csrf_token="$2"
    local extension_port="$3"
    local ext_csrf_token="$4"
    local kind="$5"
    local path="$6"
    local body="$7"

    local requires_csrf="true"

    # Extension server を先に試す
    if [[ -n "$extension_port" && "$extension_port" != "null" ]]; then
        local ext_token="${ext_csrf_token:-$csrf_token}"
        local result
        result=$(make_request "http" "$extension_port" "$path" "$ext_token" "$body" "$requires_csrf" 2>/dev/null) && {
            echo "$result"
            return 0
        }
    fi

    # 検出されたポートを試す
    local port
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        # HTTPS → HTTP の順で試行
        for scheme in https http; do
            local result
            result=$(make_request "$scheme" "$port" "$path" "$csrf_token" "$body" "$requires_csrf" 2>/dev/null) && {
                echo "$result"
                return 0
            }
        done
    done <<< "$ports"

    return 1
}

# --- レスポンスパース & JSON 変換 ---
parse_quota_summary() {
    local response="$1"

    python3 << PYTHON_SCRIPT
import json
import sys
from datetime import datetime, timezone

try:
    data = json.loads('''${response}''')
except json.JSONDecodeError:
    print("PARSE_ERROR", file=sys.stderr)
    sys.exit(1)

# エラーコード確認
code = data.get("code")
if code and str(code) not in ("0", "OK", ""):
    print(f"API_ERROR:{code}", file=sys.stderr)
    sys.exit(1)

metrics = []
bar_value = None

# QuotaSummary 形式: groups 配列内に buckets
groups = data.get("groups", [])
if groups:
    for group in groups:
        group_name = group.get("displayName", "Unknown")
        # グループ名整形
        group_lower = group_name.lower()
        if "gemini" in group_lower:
            group_label = "Gemini"
        elif "claude" in group_lower or "gpt" in group_lower:
            group_label = "Claude/GPT"
        else:
            group_label = group_name

        buckets = group.get("buckets", [])
        for bucket in buckets:
            if bucket.get("disabled", False):
                continue
            remaining = bucket.get("remainingFraction")
            if remaining is None:
                continue

            bucket_name = bucket.get("displayName", "")
            bucket_id = bucket.get("bucketId", "").lower()

            # バケット種別判定
            if "5h" in bucket_id or "5-hour" in bucket_id or "five hour" in bucket_id:
                time_label = "5h"
            elif "weekly" in bucket_id:
                time_label = "Weekly"
            else:
                time_label = bucket_name or bucket_id

            used_pct = round((1 - remaining) * 100, 1)
            label = f"{group_label} {time_label}"

            metrics.append({
                "title": label,
                "formattedValue": f"{used_pct}%",
                "normalizedValue": round(min(1 - remaining, 1.0), 4)
            })

            # 最も使用率の高いものをバーに表示
            if bar_value is None or used_pct > float(bar_value.replace('%', '')):
                bar_value = f"{used_pct}%"
else:
    print("NO_GROUPS", file=sys.stderr)
    sys.exit(1)

if not metrics:
    print("NO_METRICS", file=sys.stderr)
    sys.exit(1)

snapshot = {
    "title": "Antigravity",
    "symbol": "wind",
    "metrics": metrics,
    "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
if bar_value:
    snapshot["metricsBarValue"] = bar_value

print(json.dumps(snapshot, ensure_ascii=False))
PYTHON_SCRIPT
}

parse_user_status() {
    local response="$1"

    python3 << PYTHON_SCRIPT
import json
import sys
from datetime import datetime, timezone

try:
    data = json.loads('''${response}''')
except json.JSONDecodeError:
    print("PARSE_ERROR", file=sys.stderr)
    sys.exit(1)

# エラーコード確認
code = data.get("code")
if code and str(code) not in ("0", "OK", ""):
    print(f"API_ERROR:{code}", file=sys.stderr)
    sys.exit(1)

user_status = data.get("userStatus")
if not user_status:
    print("NO_USER_STATUS", file=sys.stderr)
    sys.exit(1)

metrics = []
bar_value = None

# アカウント情報
email = user_status.get("email")
plan_status = user_status.get("planStatus", {})
plan_info = plan_status.get("planInfo", {})
user_tier = user_status.get("userTier", {})

plan_name = (user_tier.get("name") or user_tier.get("displayName")
             or plan_info.get("planDisplayName") or plan_info.get("planName")
             or plan_info.get("displayName") or "Unknown")

metrics.append({
    "title": "Plan",
    "formattedValue": plan_name
})

# モデルクォータ
model_configs = (user_status.get("cascadeModelConfigData", {})
                 .get("clientModelConfigs", []))

# モデルをファミリーごとに分類して代表を選択
gemini_quotas = []
claude_gpt_quotas = []
other_quotas = []

for config in model_configs:
    quota_info = config.get("quotaInfo")
    if not quota_info:
        continue
    remaining = quota_info.get("remainingFraction")
    if remaining is None:
        continue

    model_id = config.get("modelOrAlias", {}).get("model", "")
    label = config.get("label", model_id)
    model_lower = model_id.lower() + " " + label.lower()

    # 軽量モデル・オートコンプリートはスキップ
    if any(x in model_lower for x in ["lite", "autocomplete", "tab_", "image"]):
        continue

    entry = {
        "label": label,
        "model_id": model_id,
        "remaining": remaining,
        "reset_time": quota_info.get("resetTime")
    }

    if "gemini" in model_lower:
        gemini_quotas.append(entry)
    elif "claude" in model_lower or "gpt" in model_lower or "openai" in model_lower:
        claude_gpt_quotas.append(entry)
    else:
        other_quotas.append(entry)

def add_representative(quotas, group_name):
    """最も使用率が高い代表モデルを追加"""
    if not quotas:
        return
    # 残量が最小 = 使用率が最大
    rep = min(quotas, key=lambda q: q["remaining"])
    used_pct = round((1 - rep["remaining"]) * 100, 1)
    metrics.append({
        "title": group_name,
        "formattedValue": f"{used_pct}%",
        "normalizedValue": round(min(1 - rep["remaining"], 1.0), 4)
    })
    return used_pct

max_pct = 0
for quotas, name in [(gemini_quotas, "Gemini"), (claude_gpt_quotas, "Claude/GPT"), (other_quotas, "Other")]:
    pct = add_representative(quotas, name)
    if pct and pct > max_pct:
        max_pct = pct
        bar_value = f"{pct}%"

if not metrics or len(metrics) <= 1:
    # クォータ情報が無い場合
    if not model_configs:
        print("NO_QUOTAS", file=sys.stderr)
        sys.exit(1)

snapshot = {
    "title": "Antigravity",
    "symbol": "wind",
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

    log "agy CLI から取得中..."
    local agy_json
    if agy_json=$(fetch_via_agy_cli) && [[ -n "$agy_json" ]]; then
        atomic_write "$OUTPUT_FILE" "$agy_json"
        log "完了 (agy CLI): $OUTPUT_FILE"
        return 0
    fi
    log "agy CLI から取得できませんでした。Language Server に接続します..."

    log "Antigravity プロセス検出中..."
    local process_info
    process_info=$(detect_antigravity_process)

    if [[ "$process_info" == "CLI_ONLY" ]]; then
        die "agy CLI のみ起動中ですが、agy -p /usage で取得できず、Language Server にも接続できません (CSRF トークン非公開)。agy にログインし直すか、Antigravity アプリを起動してください。"
    fi

    if [[ "$process_info" == "NOT_FOUND" || -z "$process_info" ]]; then
        die "Antigravity が起動していません。Windsurf/Antigravity を起動してください。"
    fi

    # プロセス情報をパース
    local pid csrf_token extension_port ext_csrf_token kind
    pid=$(echo "$process_info" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['pid'])")
    csrf_token=$(echo "$process_info" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['csrf_token'])")
    extension_port=$(echo "$process_info" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('extension_port') or '')")
    ext_csrf_token=$(echo "$process_info" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('ext_csrf_token') or '')")
    kind=$(echo "$process_info" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['kind'])")

    log "検出: PID=$pid, kind=$kind"

    log "リスニングポート検出中..."
    local ports
    ports=$(detect_ports "$pid")
    log "ポート: $(echo $ports | tr '\n' ' ')"

    # まず QuotaSummary を試す (新しい形式、より詳細)
    log "QuotaSummary 取得中..."
    local quota_response
    local quota_body='{"forceRefresh":true}'
    quota_response=$(try_endpoints "$ports" "$csrf_token" "$extension_port" "$ext_csrf_token" "$kind" "$QUOTA_SUMMARY_PATH" "$quota_body" 2>/dev/null || true)

    if [[ -n "$quota_response" ]]; then
        local runcat_json
        runcat_json=$(parse_quota_summary "$quota_response" 2>/dev/null || true)
        if [[ -n "$runcat_json" && "$runcat_json" != "PARSE_ERROR" ]]; then
            atomic_write "$OUTPUT_FILE" "$runcat_json"
            log "完了 (QuotaSummary): $OUTPUT_FILE"
            return 0
        fi
    fi

    # フォールバック: GetUserStatus
    log "GetUserStatus にフォールバック..."
    local status_body
    status_body=$(cat << 'EOF'
{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}
EOF
)
    local status_response
    status_response=$(try_endpoints "$ports" "$csrf_token" "$extension_port" "$ext_csrf_token" "$kind" "$USER_STATUS_PATH" "$status_body" 2>/dev/null || true)

    if [[ -z "$status_response" ]]; then
        die "Antigravity API に接続できません。Antigravity を再起動してください。"
    fi

    local runcat_json
    runcat_json=$(parse_user_status "$status_response" 2>/dev/null || true)

    if [[ -z "$runcat_json" ]]; then
        die "使用量情報のパースに失敗しました。"
    fi

    atomic_write "$OUTPUT_FILE" "$runcat_json"
    log "完了 (UserStatus): $OUTPUT_FILE"
}

main "$@"
