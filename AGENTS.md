# AGENTS.md

AI コーディングエージェント向けのリポジトリガイド。利用者向けの詳細は `README.md` を参照。

## 概要

[RunCat Neo](https://github.com/runcat-dev/RunCatNeo) のカスタムメトリクス機能向けに、AI コーディングツール (Claude Code / Codex / Kiro / Antigravity) の使用量を JSON に書き出す macOS 用スクリプト集。LaunchAgent が 2 分間隔でスクリプトを実行し、RunCat Neo が JSON ファイルの変更を検知して表示する。

ビルド工程・パッケージマネージャ・テストフレームワークはない。外部依存は macOS 標準の `bash` と `python3` (標準ライブラリのみ) に限る。

## ファイル構成

- `scripts/<provider>-usage.sh` — プロバイダーごとの取得スクリプト。多くは bash から heredoc で Python を実行する
- `scripts/kiro_parse.py` — `kiro-cli` の出力パーサー
- `launchagents/com.runcat-neo.<provider>-usage.plist` — LaunchAgent テンプレート
- `install.sh` / `uninstall.sh` — インストーラとアンインストーラ
- `.kiro/` — Kiro 用の AI-DLC ステアリングルール (このプロジェクトのコードではない)

`<provider>` は `claude-code`、`codex`、`kiro`、`antigravity` のいずれか。この名前はスクリプト名、plist 名、ラベル、出力 JSON 名、`install.sh` / `uninstall.sh` のプロバイダー一覧で共通なので、一致させること。

## 実行時のパス

| 用途 | パス |
|---|---|
| インストール先スクリプト | `~/.local/share/runcat-neo-metrics/scripts/` |
| 出力 JSON | `~/.config/runcat-neo-metrics/<provider>-usage.json` |
| ログ | `~/Library/Logs/RunCatNeoMetrics/<provider>-usage.log` |
| LaunchAgent | `~/Library/LaunchAgents/com.runcat-neo.<provider>-usage.plist` |

LaunchAgent はリポジトリ内ではなくインストール先のコピーを実行する (macOS TCC が `~/Documents` へのアクセスを制限するため)。`scripts/` を変更した場合は `./install.sh <provider>` を再実行しないと LaunchAgent に反映されない。

## コーディング規約

- シェルスクリプトは `#!/bin/bash` と `set -euo pipefail` で始め、冒頭のヘッダーコメントに目的・データソース・出力先を書く
- コメント、ログ、インストーラのメッセージは日本語で書く
- 出力 JSON は必ずアトミックに書き込む (同じディレクトリに一時ファイルを作り、`mv -f` または `os.replace` で置き換える)。RunCat Neo が書き込み途中のファイルを読まないようにするため
- 失敗時は stderr にタイムスタンプ付きでログを出し、非ゼロで終了する。既存の JSON は上書きしない (前回の値を残す)
- 出力は [RunCat Neo Custom Metrics スキーマ](https://github.com/runcat-dev/RunCatNeo/blob/main/docs/CustomMetricsSchema.md) に従う (`title`、`symbol`、`metricsBarValue`、`metrics[]` の `title` / `formattedValue` / `normalizedValue`、`lastUpdatedDate`)。`normalizedValue` は 0〜1
- Python は標準ライブラリだけを使う (`pip install` を前提にしない)
- plist テンプレートのプレースホルダー (`SCRIPTS_DIR`、`LOG_DIR`、`HOME_DIR`、`KIRO_API_KEY_PLACEHOLDER`) は `install.sh` が `sed` で置換する。新しく追加する場合は `install.sh` も更新する

## プロバイダーを追加するとき

1. `scripts/<provider>-usage.sh` を作成する
2. `launchagents/com.runcat-neo.<provider>-usage.plist` を既存のものから複製して作成する
3. `install.sh` の `providers` 配列と `check_dependency`、`uninstall.sh` の `providers` 配列に追加する
4. `README.md` の対応プロバイダー表、プロバイダー詳細、ファイル構成を更新する

## 動作確認

テストスイートはないため、手動で実行して確認する。

```bash
bash -n scripts/<provider>-usage.sh           # 構文チェック
./scripts/<provider>-usage.sh                 # 手動実行
python3 -m json.tool ~/.config/runcat-neo-metrics/<provider>-usage.json
cat ~/Library/Logs/RunCatNeoMetrics/<provider>-usage.log
```

`shellcheck` がインストールされていれば併用する。

## 注意事項

- 認証情報 (OAuth トークン、`KIRO_API_KEY` など) をログ、出力 JSON、コミットに含めない
- 生成物 (`*-usage.json`、`*.log`、`__pycache__/`) と `ref/` は `.gitignore` 済み。コミットしない
- `install.sh` と `uninstall.sh` は `launchctl` を操作し、ユーザーのホームディレクトリにファイルを書き込む。エージェントは確認なしに実行しない
