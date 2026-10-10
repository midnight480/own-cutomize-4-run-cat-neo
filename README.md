# RunCat Neo Custom Metrics — AI Coding Tools Usage

[RunCat Neo](https://apps.apple.com/us/app/runcat-neo/id6757801838) のカスタムメトリクス機能を使って、AI コーディングツールのトークン使用量をメニューバーとダッシュボードに表示するスクリプト集。

## 対応プロバイダー

| プロバイダー | 認証方式 | 表示内容 |
|---|---|---|
| **Claude Code** | OAuth (自動取得) | 5時間/7日間のレート制限、モデル別制限、オーバーエイジ |
| **Codex** | Codex app-server (ローカル JSON-RPC、認証情報は ~/.codex を共有) | レート制限ウィンドウ、当日トークン数、プラン情報 |
| **Kiro** | KIRO_API_KEY (ヘッドレスモード) | 月次クレジット使用量、ボーナスクレジット、プラン情報 |
| **Antigravity** | `agy` CLI (ログイン済み) / ローカル Language Server | Gemini/Claude/GPT の週間・5時間クォータ |
| **Cursor** | cursor-agent / Cursor IDE のセッション (Keychain / state.vscdb、非公式API) | Cursor Models / Other Models のプラン使用率、オンデマンド使用量、プラン情報 |

## セットアップ

### 前提条件

- macOS 14+ (Sonoma 以降)
- [RunCat Neo](https://apps.apple.com/us/app/runcat-neo/id6757801838) インストール済み
- Python 3 (macOS 標準搭載)
- 各プロバイダーの CLI / アプリがセットアップ済み

### クイックインストール

```bash
git clone git@github.com:midnight480/own-cutomize-4-run-cat-neo.git
cd own-cutomize-4-run-cat-neo
chmod +x install.sh
./install.sh
```

特定のプロバイダーのみインストール:

```bash
./install.sh claude-code
./install.sh codex
./install.sh kiro
./install.sh antigravity
./install.sh cursor
```

### RunCat Neo への登録

1. RunCat Neo を開く
2. **Settings → Metrics → Custom Metrics**
3. **Add JSON Source** をクリック
4. 以下のファイルを選択:
   - `~/.config/runcat-neo-metrics/claude-code-usage.json`
   - `~/.config/runcat-neo-metrics/codex-usage.json`
   - `~/.config/runcat-neo-metrics/kiro-usage.json`
   - `~/.config/runcat-neo-metrics/antigravity-usage.json`
   - `~/.config/runcat-neo-metrics/cursor-usage.json`

## プロバイダー詳細

### Claude Code

Claude Code の OAuth 認証トークンを使い、Anthropic の使用量 API (`https://api.anthropic.com/api/oauth/usage`) を直接叩きます。

**認証情報の読み取り順:**
1. `~/.claude/.credentials.json` (Claude Code CLI が書き出すファイル)
2. macOS Keychain (`Claude Code-credentials` サービス)

**表示メトリクス:**
- Plan: プラン名 (認証情報の `subscriptionType` から自動取得)
- 5h: 5時間ウィンドウの使用率
- 7d: 7日間ウィンドウの使用率
- 7d Opus/Sonnet: モデル別の7日間制限 (プランによる)
- Overage: オーバーエイジ発生時の使用額

**動作確認済みの出力例:**
```json
{
  "title": "Claude Code",
  "symbol": "brain.head.profile",
  "metricsBarValue": "22%",
  "metrics": [
    { "title": "5h", "formattedValue": "22%", "normalizedValue": 0.22 },
    { "title": "7d", "formattedValue": "16%", "normalizedValue": 0.16 }
  ],
  "lastUpdatedDate": "2026-07-15T11:35:30Z"
}
```

**トラブルシューティング:**
```bash
# 手動実行でデバッグ
./scripts/claude-code-usage.sh

# 認証情報の確認
cat ~/.claude/.credentials.json | python3 -m json.tool

# 再認証
claude login
```

### Codex (OpenAI)

Codex CLI に内蔵された app-server (`codex app-server --listen stdio://`) を起動し、JSON-RPC の `account/read`・`account/rateLimits/read`・`account/usage/read` を呼び出してレート制限とプラン情報を取得します。

**認証方式:**

追加の認証設定は不要です。`~/.codex/auth.json` に保存済みの Codex ログイン情報を app-server がそのまま利用します (ChatGPT ログイン / API キーのいずれにも対応)。

**データソース:**
- `codex app-server` (stdio) の JSON-RPC API — Codex Desktop が内部で使っているのと同じ仕組み
- フォールバック: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` の `token_count` イベント (旧バージョン向け)

**前提条件:**
- [Codex](https://chatgpt.com/codex) CLI がインストール済み (`codex` コマンドが PATH 上にあること)
- Codex にログイン済み (`codex login`)

```bash
# Codex CLI インストール
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

**表示メトリクス:**
- Plan: プラン名 (Codex Free / Codex Pro など)
- 5h / Weekly / Monthly: レート制限ウィンドウの使用率 (プランにより異なる)
- Resets in: リセットまでの残り時間
- Credits: クレジット残高 (クレジット保有時)
- Today: 当日のトークン使用量

**動作確認済みの出力例:**
```json
{
  "title": "Codex",
  "symbol": "terminal",
  "metricsBarValue": "0%",
  "metrics": [
    { "title": "Plan", "formattedValue": "Codex Free" },
    { "title": "Monthly", "formattedValue": "0%", "normalizedValue": 0.0 },
    { "title": "Resets in", "formattedValue": "30.0d" }
  ],
  "lastUpdatedDate": "2026-10-10T01:11:28Z"
}
```

**トラブルシューティング:**
```bash
# 手動実行
./scripts/codex-usage.sh

# codex コマンドの確認
codex --version

# app-server の動作確認 (initialize に応答すれば OK)
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test","version":"0"}}}' | codex app-server --listen stdio://

# 旧バージョン向けフォールバック用セッションログの確認
find ~/.codex/sessions -name "rollout-*.jsonl" | sort | tail -5
```

### Kiro

[`kiro-cli`](https://kiro.dev) コマンドを使い、[ヘッドレスモード](https://aws.amazon.com/jp/blogs/news/kiro-introducing-headless-mode/) (KIRO_API_KEY) で使用量情報を取得します。

**認証方式:**

LaunchAgent はブラウザを開けないため、**API キーによるヘッドレスモード**を使用します。

```bash
# 1. https://kiro.dev のアカウント設定から API キーを生成
# 2. インストーラが自動で設定するか、手動で保存:
mkdir -p ~/.config/kiro
echo "YOUR_API_KEY" > ~/.config/kiro/api_key
chmod 600 ~/.config/kiro/api_key
```

`KIRO_API_KEY` 環境変数が設定されていれば、`kiro-cli` はブラウザ認証をスキップして動作します。スクリプトは以下の順で API キーを探します:
1. 環境変数 `KIRO_API_KEY`
2. `~/.config/kiro/api_key` ファイル
3. `~/.config/runcat-neo-metrics/.env` 内の `KIRO_API_KEY=...`

**前提条件:**
```bash
# kiro-cli インストール
curl -fsSL https://cli.kiro.dev/install | bash
```

**表示メトリクス:**
- Plan: プラン名 (Free / Pro / etc.)
- Credits: 月次クレジット使用量 (X.X/Y)
- Bonus: ボーナスクレジット (存在する場合)
- Resets: リセット日

**動作確認済みの出力例:**
```json
{
  "title": "Kiro",
  "symbol": "sparkles",
  "metricsBarValue": "30%",
  "metrics": [
    { "title": "Plan", "formattedValue": "Kiro Pro" },
    { "title": "Credits", "formattedValue": "301.4/1000", "normalizedValue": 0.3014 },
    { "title": "Resets", "formattedValue": "2026-08-01" }
  ],
  "lastUpdatedDate": "2026-07-15T11:35:38Z"
}
```

**トラブルシューティング:**
```bash
# 手動実行
./scripts/kiro-usage.sh

# kiro-cli の動作確認
kiro-cli whoami
kiro-cli chat --no-interactive /usage
```

### Antigravity (Windsurf / agy CLI)

[`agy` CLI](https://antigravity.google/docs/cli/overview) の `agy -p /usage --output-format json` でクォータ情報を取得します。`agy` が使えない場合は、起動中の Antigravity / Windsurf アプリの Language Server に gRPC-web で接続します。

**認証方式:**

`agy` にログイン済みであれば追加の認証は不要です。`/usage` はモデルを呼び出さないため、トークンを消費しません。`agy` を別途起動しておく必要もありません。

> **備考:** `agy` CLI 1.2.x 以降は Language Server が CSRF トークンを要求し、そのトークンを外部に公開しません。そのため `agy` の Language Server には直接接続できず、`agy -p /usage` を使います。

**前提条件:**
- `agy` CLI がインストール済みでログイン済み
- または Windsurf / Antigravity アプリが起動中

```bash
# agy CLI のインストール (まだの場合)
# https://antigravity.google/docs/cli/overview を参照

# ログイン状態の確認 (未ログインなら対話モードで /login)
agy -p /usage --output-format json
```

**表示メトリクス:**
- Gemini Weekly / Gemini 5h: Gemini モデル群の週間・5時間クォータ使用率
- Claude/GPT Weekly / Claude/GPT 5h: Claude/GPT モデル群の週間・5時間クォータ使用率

アプリの Language Server 経由で取得した場合は、Plan (プラン名) も表示されます。

**動作確認済みの出力例:**
```json
{
  "title": "Antigravity",
  "symbol": "wind",
  "metricsBarValue": "0.4%",
  "metrics": [
    { "title": "Gemini Weekly", "formattedValue": "0.1%", "normalizedValue": 0.0006 },
    { "title": "Gemini 5h", "formattedValue": "0.4%", "normalizedValue": 0.0035 },
    { "title": "Claude/GPT Weekly", "formattedValue": "0%", "normalizedValue": 0 },
    { "title": "Claude/GPT 5h", "formattedValue": "0%", "normalizedValue": 0 }
  ],
  "lastUpdatedDate": "2026-09-16T10:56:36Z"
}
```

**トラブルシューティング:**
```bash
# 手動実行
./scripts/antigravity-usage.sh

# agy CLI での取得確認
agy -p /usage --output-format json

# アプリの Language Server プロセス確認
ps aux | grep -i "language.server" | grep -i "antigravity\|windsurf\|codeium"

# ポート確認
lsof -nP -iTCP -sTCP:LISTEN | grep -i "language"
```

### Cursor

`cursor-agent` (Cursor CLI) または Cursor IDE が保存するセッション JWT を使い、Cursor ダッシュボードの使用量エンドポイント (`https://cursor.com/api/usage-summary`) から使用量を取得します。

> **注意:** 個人プランの使用量を返す公式 API は存在しないため、ダッシュボードが内部で使う**非公式エンドポイント**を利用しています。仕様変更で動かなくなる可能性があります (利用量の多い OSS ツールと同じ方式です)。

**認証情報の読み取り順:**

アクセストークン:
1. macOS Keychain (`cursor-access-token` サービス) — `agent login` が書き込む
2. Cursor IDE の `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`cursorAuth/accessToken`)

アクセストークン (JWT、約60日有効) が期限切れの場合は、`cursor-refresh-token` / `cursorAuth/refreshToken` で `https://api2.cursor.sh/oauth/token` を呼んで自動更新します (トークンの書き戻しはしません)。リフレッシュも失効していたら再ログインが必要です。

**前提条件:**

```bash
# cursor-agent のインストール (未インストールの場合)
curl https://cursor.com/install -fsS | bash

# ログイン (ブラウザが開く)
agent login
```

または Cursor IDE にログイン済みであること。

**表示メトリクス:**
- Plan: プラン名 (`membershipType` から取得: Free / Pro / Pro+ / Ultra / Enterprise)
- Cursor Models: Auto / Composer / Grok 系など Cursor 管理モデルの使用率 (`autoPercentUsed`)
- Other Models: API 経由モデルの使用率 (`apiPercentUsed`)
- Plan Usage: 上記が無い環境向けの合計使用率 (従量の場合は `$使用額/$上限`)
- On-Demand: オンデマンド (従量課金) の使用額
- Resets: 請求周期のリセット日

**トラブルシューティング:**
```bash
# 手動実行
./scripts/cursor-usage.sh

# セッションの確認 (エントリがあれば OK)
security find-generic-password -s cursor-access-token
security find-generic-password -s cursor-refresh-token

# セッション失効時は再ログイン
agent login
```

初回実行時に macOS が「security がキーチェーンの情報を使用しようとしています」と確認ダイアログを出す場合があります。「常に許可」を選んでください。

## 動作の仕組み

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────┐
│  LaunchAgent    │────▶│  Shell Script    │────▶│  JSON File   │
│  (2分間隔)      │     │  (データ取得)     │     │  (atomic mv) │
└─────────────────┘     └──────────────────┘     └──────┬───────┘
                                                         │
                                                         ▼
                                                  ┌──────────────┐
                                                  │  RunCat Neo  │
                                                  │  (FS watch)  │
                                                  └──────────────┘
```

- LaunchAgent が2分間隔でスクリプトを実行
- スクリプトは各プロバイダーから使用量を取得
- JSON ファイルにアトミック書き込み (一時ファイル → `mv`)
- RunCat Neo がファイル変更を検知して即座にダッシュボード更新

### 更新タイミングとプロバイダーの起動状態

LaunchAgent（2分間隔のスケジューラ）は **macOS にログインしている間は常に動作しています**。各スクリプト自体は数秒で実行して終了する短命プロセスです。Codex などのアプリ / プロセスを「常に起動しっぱなしにする」必要はありません。

ただし、**データの取得先がローカルプロセスに依存するプロバイダー**はアプリ起動中のみ更新されます:

| プロバイダー | データソース | アプリ未起動時の動作 |
|---|---|---|
| **Claude Code** | リモート API (`api.anthropic.com`) | OAuth トークンが有効なら**常に更新される** (アプリ起動不要) |
| **Codex** | `codex app-server` (ローカル JSON-RPC) | Codex にログイン済みなら**常に更新される** (アプリ起動不要) |
| **Kiro** | `kiro-cli` コマンド実行 | `kiro-cli` がインストール済み + API キー設定済みなら**常に更新される** |
| **Antigravity** | `agy -p /usage` (リモート) / ローカル Language Server | `agy` にログイン済みなら**常に更新される**。`agy` が使えない場合はアプリ起動中のみ更新 |
| **Cursor** | リモート API (`cursor.com`、非公式) | セッションが有効なら**常に更新される** (アプリ起動不要) |

**要するに:**

- **Claude Code / Codex / Kiro / Antigravity / Cursor** — ログイン中は常に2分ごとに最新値に更新 (Antigravity は `agy` ログイン済みの場合)

### macOS のセキュリティに関する注意

`install.sh` はスクリプトを `~/.local/share/runcat-neo-metrics/scripts/` にコピーし、LaunchAgent はそちらを参照します。これは macOS の TCC (Transparency, Consent, and Control) が `~/Documents` や `~/Desktop` 等のフォルダへのアクセスを制限するためです。

もし LaunchAgent のログに `Operation not permitted` が出る場合:

```bash
# ログ確認
cat ~/Library/Logs/RunCatNeoMetrics/claude-code-usage.log

# 再インストールで解決
./install.sh
```

`install.sh` を再実行すれば、スクリプトが保護対象外のパスにコピーされ、問題が解消します。

### ログのローテーション

各スクリプトは起動時に自分のログファイル (`~/Library/Logs/RunCatNeoMetrics/<provider>-usage.log`) を検査し、1MB を超えていたら末尾 512KB だけを残して切り詰めます。外部のログローテーション設定は不要です。

また `codex-usage.sh` は `~/.codex/logs_2.sqlite` (Codex の内部ログ DB) の空き領域回収も行います。Codex 自体が古い行を削除しますが削除済みページはファイル内に残るため、1日1回まで `PRAGMA incremental_vacuum` を実行して実サイズを縮小します。デーモン稼働中にロックが取れない場合はスキップされ、次回以降に再試行されます。

## ファイル構成

```
.
├── README.md
├── install.sh              # インストーラ
├── uninstall.sh            # アンインストーラ
├── scripts/
│   ├── claude-code-usage.sh   # Claude Code 使用量取得
│   ├── codex-usage.sh         # Codex 使用量取得
│   ├── kiro-usage.sh          # Kiro 使用量取得
│   ├── kiro_parse.py          # Kiro 出力パーサー
│   ├── antigravity-usage.sh   # Antigravity 使用量取得
│   └── cursor-usage.sh        # Cursor 使用量取得
└── launchagents/
    ├── com.runcat-neo.claude-code-usage.plist
    ├── com.runcat-neo.codex-usage.plist
    ├── com.runcat-neo.kiro-usage.plist
    ├── com.runcat-neo.antigravity-usage.plist
    └── com.runcat-neo.cursor-usage.plist
```

## カスタマイズ

### 更新間隔の変更

LaunchAgent の `StartInterval` (秒) を変更:

```bash
# 例: 5分間隔に変更
# launchagents/*.plist の StartInterval を 300 に変更後:
launchctl unload ~/Library/LaunchAgents/com.runcat-neo.claude-code-usage.plist
launchctl load ~/Library/LaunchAgents/com.runcat-neo.claude-code-usage.plist
```

### 出力先の変更

各スクリプトの `OUTPUT_DIR` / `OUTPUT_FILE` 変数を編集してください。

### JSON スキーマ

RunCat Neo のカスタムメトリクス JSON スキーマは [CustomMetricsSchema.md](https://github.com/runcat-dev/RunCatNeo/blob/main/docs/CustomMetricsSchema.md) を参照。

## アンインストール

```bash
./uninstall.sh
```

手動でアンインストール:

```bash
# LaunchAgent 停止・削除
launchctl unload ~/Library/LaunchAgents/com.runcat-neo.claude-code-usage.plist
launchctl unload ~/Library/LaunchAgents/com.runcat-neo.codex-usage.plist
launchctl unload ~/Library/LaunchAgents/com.runcat-neo.kiro-usage.plist
launchctl unload ~/Library/LaunchAgents/com.runcat-neo.antigravity-usage.plist
launchctl unload ~/Library/LaunchAgents/com.runcat-neo.cursor-usage.plist
rm -f ~/Library/LaunchAgents/com.runcat-neo.*.plist

# JSON 削除
rm -f ~/.config/runcat-neo-metrics/*-usage.json
```

## 参考

- [RunCat Neo](https://github.com/runcat-dev/RunCatNeo) — Custom Metrics 機能
- [CodexBar](https://github.com/steipete/codexbar) — AI プロバイダー使用量追跡 (プロバイダー実装の参考)
- [Claude Code OAuth API](https://docs.anthropic.com/) — Anthropic OAuth 使用量エンドポイント
- [Codex CLI](https://developers.openai.com/codex/cli/) — OpenAI Codex CLI ドキュメント
- [Codex 環境変数](https://developers.openai.com/codex/environment-variables) — CODEX_API_KEY 等
- [Kiro ヘッドレスモード](https://aws.amazon.com/jp/blogs/news/kiro-introducing-headless-mode/) — API キーによるブラウザ不要認証
- [Antigravity CLI (agy)](https://antigravity.google/docs/cli/overview) — agy CLI ドキュメント
- [Cursor CLI](https://cursor.com/docs/cli/overview) — cursor-agent ドキュメント

## License

MIT
