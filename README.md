# RunCat Neo Custom Metrics — AI Coding Tools Usage

[RunCat Neo](https://apps.apple.com/us/app/runcat-neo/id6757801838) のカスタムメトリクス機能を使って、AI コーディングツールのトークン使用量をメニューバーとダッシュボードに表示するスクリプト集。

## 対応プロバイダー

| プロバイダー | 認証方式 | 表示内容 |
|---|---|---|
| **Claude Code** | OAuth (自動取得) | 5時間/7日間のレート制限、モデル別制限、オーバーエイジ |
| **Codex** | ローカルログスキャン (認証不要) | 週間レート制限、セッショントークン数、プラン情報 |
| **Kiro** | KIRO_API_KEY (ヘッドレスモード) | 月次クレジット使用量、ボーナスクレジット、プラン情報 |
| **Antigravity** | `agy` CLI (ログイン済み) / ローカル Language Server | Gemini/Claude/GPT の週間・5時間クォータ |

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

## プロバイダー詳細

### Claude Code

Claude Code の OAuth 認証トークンを使い、Anthropic の使用量 API (`https://api.anthropic.com/api/oauth/usage`) を直接叩きます。

**認証情報の読み取り順:**
1. `~/.claude/.credentials.json` (Claude Code CLI が書き出すファイル)
2. macOS Keychain (`Claude Code-credentials` サービス)

**表示メトリクス:**
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

Codex のローカルセッションログ (`~/.codex/sessions/`) をスキャンし、最新の `token_count` イベントからレート制限情報を抽出します。

**認証方式:**

認証不要です。Codex Desktop / CLI がセッションログを `~/.codex/sessions/` に自動的に書き出すため、ローカルファイルの読み取りのみで動作します。

**データソース:**
- `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
- 各セッション内の `event_msg` type=`token_count` イベントに `rate_limits` と `token_usage` が含まれる

**前提条件:**
- [Codex](https://chatgpt.com/codex) Desktop アプリまたは CLI がインストール済み
- 少なくとも1回 Codex を使用済み (セッションログが存在すること)

```bash
# Codex CLI インストール
curl -fsSL https://chatgpt.com/codex/install.sh | sh

# ヘッドレス実行 (CI/自動化) には CODEX_API_KEY を使用
# https://developers.openai.com/codex/environment-variables
```

**表示メトリクス:**
- Plan: プラン名 (Codex Free / Codex Pro)
- Weekly: 週間レート制限の使用率
- 5h: 5時間レート制限 (存在する場合)
- Resets in: リセットまでの残り時間
- Credits: クレジット残高 (Pro プラン)
- Session: 最新セッションのトークン使用量

**動作確認済みの出力例:**
```json
{
  "title": "Codex",
  "symbol": "terminal",
  "metricsBarValue": "44%",
  "metrics": [
    { "title": "Plan", "formattedValue": "Codex Free" },
    { "title": "Weekly", "formattedValue": "44.0%", "normalizedValue": 0.44 },
    { "title": "Session", "formattedValue": "38.5K tokens" }
  ],
  "lastUpdatedDate": "2026-07-15T12:03:35Z"
}
```

**トラブルシューティング:**
```bash
# 手動実行
./scripts/codex-usage.sh

# セッションログ確認
find ~/.codex/sessions -name "rollout-*.jsonl" | sort | tail -5

# 最新の token_count イベント確認
grep "token_count" ~/.codex/sessions/2026/*/*/*.jsonl | tail -1 | python3 -m json.tool
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
| **Codex** | ローカルセッションログ (`~/.codex/sessions/`) | 既存ログを読むので**常に更新される** (アプリ起動不要だがデータは最後の使用時点のまま) |
| **Kiro** | `kiro-cli` コマンド実行 | `kiro-cli` がインストール済み + API キー設定済みなら**常に更新される** |
| **Antigravity** | `agy -p /usage` (リモート) / ローカル Language Server | `agy` にログイン済みなら**常に更新される**。`agy` が使えない場合はアプリ起動中のみ更新 |

**要するに:**

- **Claude Code / Kiro / Antigravity** — ログイン中は常に2分ごとに最新値に更新 (Antigravity は `agy` ログイン済みの場合)
- **Codex** — ログイン中は常に2分ごとに実行されるが、表示値は最後に Codex を使ったセッションの情報

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
│   └── antigravity-usage.sh   # Antigravity 使用量取得
└── launchagents/
    ├── com.runcat-neo.claude-code-usage.plist
    ├── com.runcat-neo.codex-usage.plist
    ├── com.runcat-neo.kiro-usage.plist
    └── com.runcat-neo.antigravity-usage.plist
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

## License

MIT
