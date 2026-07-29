# DEVELOPMENT（保守ガイド）

本ドキュメントは**このリポジトリを保守・開発する方**向けです。プラグインの利用方法は
[README.md](README.md)、エージェント/コマンド/スキルの追加・変更手順は
[CONTRIBUTING.md](CONTRIBUTING.md)、設計思想と主要な設計判断の背景は
[DESIGN.md](DESIGN.md) を参照してください。

## ディレクトリ構成

```
hermit-works/
├── .claude/settings.json        # プロジェクトスコープ設定（マーケットプレイス登録＋プラグイン有効化）
├── .claude-plugin/
│   ├── plugin.json              # プラグインマニフェスト
│   └── marketplace.json         # 配布元マニフェスト（自己参照）
├── .devcontainer/               # 開発環境（VSCode Dev Container）
├── agents/                      # 専門家エージェント定義（51体、グループ別プレフィックス）
├── commands/                    # スラッシュコマンド（/hw: 名前空間で呼び出し）
├── skills/                      # 作業手順書スキル（hw: 名前空間）
├── scripts/                     # 静的検証スクリプトと回帰テスト
├── CLAUDE.md                    # 保守作業向けコンテキスト（一次受けの振り分け・検証必須の定め）
├── README.md                    # 利用者向けドキュメント
├── DEVELOPMENT.md               # 本ドキュメント（保守者向け）
├── CONTRIBUTING.md              # 追加・変更手順と規約
└── DESIGN.md                    # 設計思想と主要な設計判断の記録
```

## 開発環境

VSCode Dev Container（`.devcontainer/`）で開発します。コンテナには Claude Code CLI・gh 等が
セットアップされ、`~/.claude`（認証情報・プラグイン設定）は Docker ボリューム `claude-config` に
永続化されます。起動時チェック（git safe.directory 登録・gh/claude の認証状態確認）は
`postStart.sh` が行います。

## プラグインの読み込みの仕組み（自己参照マーケットプレイス）

本リポジトリは `.claude-plugin/marketplace.json` を持つ**自己参照マーケットプレイス**です。
リポジトリ自身を配布元 `hermit-works` として登録し、その中のプラグイン `hw` を有効化しています。

コミット済みの `.claude/settings.json`（プロジェクトスコープ）が登録本体です。

```json
{
  "extraKnownMarketplaces": {
    "hermit-works": { "source": { "source": "directory", "path": "." } }
  },
  "enabledPlugins": { "hw@hermit-works": true }
}
```

これにより、リポジトリのルートでセッションを開始すれば CLI・VSCode 拡張のどちらでも起動時に
自動で有効になります。仕組み上の注意点は以下のとおりです（いずれも動作検証済み）。

- **`path` は `"."` を維持すること。** セッション開始時にカレントディレクトリ基準で絶対パスに
  解決されるため、クローン先のパスに依存せず、ホスト・devcontainer のどちらでも動作します。
  `claude plugin marketplace add` を実行し直すと CLI が**絶対パスに正規化して書き込む**ため、
  実行後は `"."` に手で戻してください。
- 環境変数展開（`${CLAUDE_PROJECT_DIR}` 等）はサポートされていません（展開されずそのまま
  パスとして扱われます）。
- プロジェクトスコープ設定は**リポジトリのルートでセッションを開始した場合のみ**読み込まれます。
  サブディレクトリで起動すると有効になりません（絶対パスで記録しても同じ）。
- 設定を書き換えた直後の 1 セッションは配布元の同期のみが走り、プラグインが有効になるのは
  **次のセッションから**です。
- 解決結果は `~/.claude/plugins/known_marketplaces.json` にキャッシュされます。このファイルが
  消えても（Docker ボリュームの作り直し等）、settings から自動で再登録されるため復旧操作は不要です。

## 開発ループ

```bash
# 定義を編集したら、セッション内で再読み込み
/reload-plugins

# 一時的に別リポジトリのセッションへ読み込んで試す場合（CLI 限定・VSCode 拡張では不可）
claude --plugin-dir <このリポジトリのパス>

# プラグイン全体の状態・トークンコストの確認
claude plugin list
claude plugin details hw
```

## 検証（変更後は必須）

検証手順の正本は [CONTRIBUTING.md](CONTRIBUTING.md) 5章です。以下はその項目1・2を掲載の便宜のため
再掲したものであり、両方実行してエラー・警告を解消してから完了とします（項目3の `/reload-plugins`
は本ドキュメントの「開発ループ」節にすでに記載しているため、ここでは繰り返しません）。

```bash
# 1. プラグイン定義のバリデーション（マニフェスト・frontmatter の検証）
claude plugin validate .

# 2. 静的検証スクリプト（frontmatter必須項目・命名規則・重複・README整合性）
bash scripts/validate.sh

# scripts/validate.sh 自体を変更した場合は回帰テストも実行（合格基準: 全ケース PASS）
bash scripts/tests/run-tests.sh
```
