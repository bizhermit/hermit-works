# 保守用のコマンドとスキル

本リポジトリの保守で使うスキルとコマンドの一覧である。ブランチ運用の規則は[CLAUDE.md](../CLAUDE.md)にある。

## スキル

| スキル | 用途 |
| :- | :- |
| `/release` | リリースを次の一作業だけ進める。`plugin.json`の`version`、タグ、開いているPRから状態を取り、バージョンを上げる、リリースPRを作成する、タグとリリースノートを作成する、のいずれかを行う。バージョンの規則もこのスキルにある。定義は[.claude/skills/release/SKILL.md](../.claude/skills/release/SKILL.md) |

## コマンド

| コマンド | 用途 |
| :- | :- |
| `claude plugin validate .` | マーケットプレイス定義（`.claude-plugin/marketplace.json`）を検証する |
| `claude plugin validate ./plugin` | プラグインマニフェスト（`plugin/.claude-plugin/plugin.json`）を検証する |
| `/reload-plugins` | セッション内で`plugin/`の変更を読み直す。本リポジトリの`.claude/settings.json`は、本リポジトリにあるプラグインを有効にしている |
| `bash scripts/git-cleanup-branch.sh [切り替え先]` | リモートで削除された作業ブランチを、ローカルからも削除する。切り替え先を省くと`develop`になる。VSCodeのタスク「Git: 作業ブランチを整理する (git-cleanup-branch)」からも実行できる |
