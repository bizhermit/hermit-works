# CLAUDE.md（このリポジトリの保守作業向け）

このリポジトリは Claude Code プラグイン「Hermit Works」（`hw`）本体です。
利用者向けの説明は [README.md](README.md)、保守環境は [DEVELOPMENT.md](DEVELOPMENT.md)、
資材の追加・変更の規約と検証手順の正本は [CONTRIBUTING.md](CONTRIBUTING.md)、設計思想と主要な設計判断の背景は
[DESIGN.md](DESIGN.md) を参照してください。
なお、プラグインルートの CLAUDE.md は利用側リポジトリには読み込まれません（本ファイルは保守作業専用です）。
資材・スクリプトの索引として [.hw/conventions.md](.hw/conventions.md) があれば参照してください（索引であり正本ではありません。CONTRIBUTING.md 5章の「正本と再掲」の定め参照）。
CONTRIBUTING.md・DESIGN.md は全文を読まず、冒頭目次で該当する章・節を特定して部分読み込みしてください（文書横断の整合確認等スコープ上必要な場合を除く。正本は CONTRIBUTING.md 1章）。

## hermit-works への振り分け（一次受け）

コマンド・スキル・エージェントの指定がないプロンプトは、内容を見て次のように扱う。
本リポジトリは資材（プロンプト・文書）中心で構成され、保守用スクリプト（`scripts/`）と CI 定義（`.github/workflows/`）を除き実行コードを持たないため、README の文言例にある「コード変更」は「資材の変更」と読み替え、さらに README の「軽微な1ファイル修正」の項目（直接対応してよいとする例外枠）はここでは設けていない。

- 資材（エージェント・コマンド・スキル・スクリプト・CI 定義・ドキュメント）の変更を伴う依頼 → 規模によらず（1ファイルの軽微な修正を含む）`/hw:request` のフローに準じて対応する。エージェント・コマンド・スキル・スクリプト・CLAUDE.md 等、振る舞いや設定を定義する文書は品質ゲート判定で常にレベル2以上（qa-review 必須）に、CI 定義（`.github/workflows/`）はレベル3（qa-review + sec-audit）に該当するため（README 等の読み物はフロー内の判定でレベル1相当となる。レベル定義の正本は `agents/mgmt-coordinator.md`「品質ゲートの適用判定」節）
- 質問・相談・軽い調査 → 直接対応してよい。ただし専門的な分析を要する調査、複数工程にまたがる依頼は `/hw:request` に流す（README条件「複数プロジェクトにまたがる依頼」は、本リポジトリが単一プロジェクトのため該当しない）
- 迷う場合は、どちらで進めるかを一言添えてから着手する

依頼は受付時に「プラグインのメンテナンス（配布資材＝1.10 列挙対象への変更）」か「リポジトリの環境整備（保守作業専用文書・`.claude/`・`.hw/`等の整備）」のどちらかに分類し、許容範囲の違いは CONTRIBUTING.md 1.11 を正本として参照する（迷う場合は1.11 の判定基準に従う）。
なお、本リポジトリ自身を保守するための運用上の都合（保守用の定期実行との連携等）を理由に配布対象の資材を変更してはならない。保守運用の仕組みは資材の外（routines・`.hw/`・issue 等）で完結させる（正本は CONTRIBUTING.md 1.10）。

## 記録先の使い分け

チーム共有すべき事実（決定・規約・運用ルール・案件の背景）は個人メモリ（Claude Code の自動メモリ）でなく、保守用文書の正本（CONTRIBUTING.md・DESIGN.md 等）または `.hw/` 配下（`decisions.md` 等）へ記録する。個人メモリは本人固有の好み・作業スタイル（個人のローカルな主観）に限る。
特に利用者から指摘・訂正・裁定を受けて記録するときは、個人メモリへ書き込む前に「チーム共有すべき内容か」を判断する。共有すべき内容のうち、既存の規約・手順の誤り・不足に起因するものは当該資材・文書の修正を第一候補とし（修正は上記の一次受けの振り分けに従う）、資材・文書に紐づかない決定・事実は `.hw/decisions.md` 等へ記録する。迷う場合は共有側に倒すか、利用者に確認する。既存の個人メモリに共有すべき内容を見つけたときも同様に判断して反映する（利用側向けの同趣旨の条項は `commands/init.md` 手順5が正本。経緯は DESIGN.md 2.22）。

## 変更後の検証（必須）

資材の変更は `develop` から分岐した作業ブランチ（`feature/<topic>` 等）で行い、PR は `develop` 向けとし、main・develop への直接コミットはしない
（例外なし。リリース準備コミットも `release/v<version>` ブランチ＋`develop` 向け PR で行う。正本は CONTRIBUTING.md 9章）。
資材を変更したら、完了前に以下を実行してエラー・警告を解消する（詳細は CONTRIBUTING.md 5章（正本）。保守環境まわりは DEVELOPMENT.md「検証（変更後は必須）」）。

```bash
claude plugin validate .
bash scripts/validate.sh
# scripts/validate.sh 自体を変更した場合のみ（合格基準: 全ケース PASS。正本は CONTRIBUTING.md 5章）
bash scripts/tests/run-tests.sh
# scripts/git-changelog.sh 変更時のみ
bash scripts/tests/run-git-changelog-tests.sh
# scripts/aggregate-agent-token-usage.sh 変更時のみ
bash scripts/tests/run-aggregate-agent-token-usage-tests.sh
# scripts/sync-guidelines.sh 変更時のみ
bash scripts/tests/run-sync-guidelines-tests.sh
# scripts/tests/lib/ 配下（全ハーネス共通ライブラリ）変更時は上記の全ハーネスを実行
# （詳細・合格基準・現行の一覧は正本 CONTRIBUTING.md 5章）
```
