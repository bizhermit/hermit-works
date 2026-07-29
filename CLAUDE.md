# CLAUDE.md（このリポジトリの保守作業向け）

このリポジトリは Claude Code プラグイン「Hermit Works」（`hw`）本体です。
利用者向けの説明は [README.md](README.md)、保守環境は [DEVELOPMENT.md](DEVELOPMENT.md)、
資材の追加・変更の規約と検証手順の正本は [CONTRIBUTING.md](CONTRIBUTING.md)、設計思想と主要な設計判断の背景は
[DESIGN.md](DESIGN.md) を参照してください。
なお、プラグインルートの CLAUDE.md は利用側リポジトリには読み込まれません（本ファイルは保守作業専用です）。

## hermit-works への振り分け（一次受け）

コマンド・スキル・エージェントの指定がないプロンプトは、内容を見て次のように扱う。
本リポジトリはコードではなく資材（プロンプト・文書）のみで構成されるため、README の文言例にある「コード変更」は「資材の変更」と読み替え、さらに README の「軽微な1ファイル修正」の項目（直接対応してよいとする例外枠）はここでは設けていない。

- 資材（エージェント・コマンド・スキル・スクリプト・ドキュメント）の変更を伴う依頼 → 規模によらず（1ファイルの軽微な修正を含む）`/hw:request` のフローに準じて対応する。エージェント・コマンド・スキル・プロンプト類は振る舞いを定義する文書として品質ゲート判定で常にレベル2以上（qa-review 必須）に該当するため（README 等の読み物はフロー内の判定でレベル1相当となる）
- 質問・相談・軽い調査 → 直接対応してよい。ただし専門的な分析を要する調査は `/hw:request` に流す
- 迷う場合は、どちらで進めるかを一言添えてから着手する

## 変更後の検証（必須）

資材を変更したら、完了前に以下を実行してエラー・警告を解消する（詳細は DEVELOPMENT.md「検証」）。

```bash
claude plugin validate .
bash scripts/validate.sh
# scripts/validate.sh 自体を変更した場合のみ（合格基準: 全ケース PASS。正本は CONTRIBUTING.md 5章）
bash scripts/tests/run-tests.sh
```
