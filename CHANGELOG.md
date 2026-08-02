# Changelog

このリポジトリの notable な変更を記録する。バージョニング方針は [DESIGN.md](DESIGN.md) 2.10・2.31 に
準拠する（Semantic Versioning ベースで、MAJOR は呼び出しインターフェースの破壊、MINOR/PATCH は
利用者が変更を意識する必要があるかで定義。詳細は [CONTRIBUTING.md](CONTRIBUTING.md) 9.2 が正本）。
リリースは利用者面資材（`agents/`・`commands/`・`skills/`・`.claude-plugin/plugin.json`・
`README.md`）に変更が及ぶ場合のみ発火する。

## [0.6.0] - 2026-08-03

### Added
- リリース PR のマージを契機にタグ `v<version>` を自動付与する CI ワークフロー
  （`.github/workflows/tag-release.yml`）を新設（マージコミット方式であることの検証込み。
  squash/rebase マージ検知時はタグを付与せず失敗させる）
- リリースノートのドラフト作成・GitHub Release へのドラフト登録を行う保守用ローカル
  `/release-notes` コマンド（`.claude/commands/release-notes.md`）を新設（`/release` 手順10からの
  続き、または単独実行に対応）

### Changed
- 「記録先の使い分け」条項を拡充: 利用者から指摘・訂正・裁定を受けて記録する際は、個人メモリへ
  書き込む前に共有要否を判断し、共有すべき内容のうち規約・手順の誤り・不足に起因するものは
  当該資材の修正を第一候補とする（`/hw:init` 手順5の提案条項文・`/hw:audit-assets` の ai-prompt
  点検観点を拡充。DESIGN 2.22。保守用 CLAUDE.md にも自己適用版を追加）
- 保守運用の都合（保守用の定期実行との連携等）を理由に配布対象の資材を変更しない原則を規約化
  （CONTRIBUTING 1.10 正本・DESIGN・保守用 CLAUDE.md）

## [0.5.0] - 2026-08-02

### Added
- 計画ファイルの冒頭に案件ヘッダー「背景（Why）・案件の完了条件」（各2行以内）を、変更を伴う案件には
  「スコープ外」欄（2行以内）を導入（`mgmt-coordinator`・`/hw:plan`・`/hw:request`）。成果統合時に
  スコープ外の変更の混入がないかを確認する手順も追加
- `/hw:report` に「コスト効率」観点（エージェント別キャッシュヒット率の計測・著しく低いエージェントの
  検知）を新設し、`scripts/aggregate-agent-token-usage.sh` に cache_hit_rate 列を追加。あわせて
  エージェントの effort ティアリングを導入し、保守的に4体（ana-data/docs-l10n/docs-user/mgmt-pm）へ
  適用（CONTRIBUTING 2.3/2.5 に正典化）
- `/hw:init` に時点レポート（`.hw/reports/standup*`・`report-*`）の `.gitignore` 除外提案を追加
  （パターンごとの個別選択・コミット済みの場合の `git rm --cached` 提案込み。承認なしに追記しない）
- `mgmt-release` にバージョン更新・リリース要否の判定手順（発火判定 → 種別判定 → 操作的判定テストの
  3ステップ。利用者側方針が無い場合はリリース手順の構築を最初のタスクとして提案）を追加
- develop マージ済み作業ブランチをリモート自動削除する CI ワークフロー
  （`.github/workflows/delete-merged-branch.yml`）を新設
- リポジトリ保守用のローカル `/release` コマンド（`.claude/commands/release.md`）と、Claude Code
  permissions のチーム共有設定（`.claude/settings.json`。承認境界・リリース保護・破壊的操作の
  deny/ask）を新設

### Changed
- `/hw:standup` の出力を課題台帳型テンプレートへ全面改訂。課題表（No./起票日/優先度/状態/課題/詳細）は
  優先度の降順（高→中→低）・同一優先度内は起票日の昇順で並べ、No. は表示順の通し番号に変更（実行を
  またいだ固定番号・欠番許容は廃止。実行をまたぐ引き継ぎキーは課題タイトル）。保存先を実行ごとの
  新規ファイル `standup_<YYYYMMDD-hhmmss>.md` に変更（同日追記を廃止。旧 `standup-*.md` からの
  引き継ぎ手順あり）
- バージョニング方針を改訂: 利用者面資材（`agents/`・`commands/`・`skills/`・
  `.claude-plugin/plugin.json`・`README.md`）に変更が及ぶ場合のみリリース発火とし、MINOR/PATCH を
  「利用者が変更を意識する必要があるか」で判定する V-1〜V-3 を導入（CONTRIBUTING 9.2・DESIGN 2.31）。
  面リスト非該当パスのフォールバック規定（既定は発火なし・配布内容への実質影響時は発火側）も追加
- ブランチ運用・リリース手順を develop（統合ライン）/ main（リリース確定ライン）の2ブランチ方式へ
  見直し（CONTRIBUTING 9章）。`scripts/git-cleanup-branch.sh` の既定起点を develop 化し、削除前
  マージ済み確認の起点も develop に変更。VSCode タスク（ブランチ掃除）を新設
- CI の Claude Code CLI インストールを、固定バージョンの直接取得＋SHA256 照合方式へ切替（B9）

### Fixed
- 計画ファイルの「本案件のガードレール」欄の適用条件を「変更を伴う案件では」に統一し、
  `mgmt-coordinator` と `/hw:request`・`/hw:plan` 間の記述齟齬を解消

## [0.4.0] - 2026-08-01

### Added
- 共通ガードレール層（常時層6短文・判断手順1行／トリガー行＋詳細スキル層／機械層）の配置基準
  （判定順: 機械層 → トリガー行＋スキル層を標準の既定先 → 常時層は審査ゲート経由）とトリガー行
  新設の3要件（実機検証・`scripts/validate.sh` への逐語検証追加・対象エージェント限定）を
  CONTRIBUTING 1.4 に新設
- 共通ガードレール層の棚卸し運用（CONTRIBUTING 1.9）を新設。審査ゲート発生時・定期振り返り相乗り
  の2条件で発動し、実効性点検・降格候補判定・記録様式（行頭一致の定型1行）を規定
- 共通ガードレール文言の正典を集約した `scripts/lib/guidelines.sh` を新設（正典＝lib／検証＝
  `scripts/validate.sh`／伝播＝新設の `scripts/sync-guidelines.sh` の3分掌）。正典変更時の反映を
  「lib編集→sync実行→validate確認」に短縮し、51ファイル手編集の運用を廃止
- `scripts/validate.sh` セクション9(h) を新設し、`agents/sec-audit.md`・`agents/sec-appsec.md`・
  `agents/infra-devops.md` の permissions トリガー行（3ファイル間）の逐語一致を機械検証
- `scripts/sync-guidelines.sh` の回帰テストハーネス `scripts/tests/run-sync-guidelines-tests.sh` を
  新設し、CI（`.github/workflows/validate.yml`）・`CLAUDE.md`・`DEVELOPMENT.md` の検証手順一覧に反映
- 「秩序より改善を優先する原則（成長原則）」（DESIGN 1.4・2.28）を明文化。採用すべき改善が既存方針・
  過去裁定と衝突する場合、抵触のみを理由に棄却せず、実害範囲・検知手段・他層代替可否のメリット審査
  で可否を判断する運用を導入し、統括（`mgmt-coordinator`）の作業方針に衝突時の対応（メリット審査・
  縮小案と規約側改訂案の併記・利用者裁定を仰ぐ）を追加

### Changed
- CONTRIBUTING 1.8「別枠の共通行追加は原則打ち止め」を「審査ゲート」として再定義し、既存方針への
  抵触を単独の棄却理由にしない運用へ変更（1.4 原則6と同等の審査を必須化）
- CONTRIBUTING 2.4: permissions トリガー行の同期範囲の記述を、`scripts/validate.sh` 逐語検証追加
  （目視確認のみ→機械検証併用）に合わせて更新
- `scripts/validate.sh`: 逐語検証用の正典定数群の定義を撤去し、`scripts/lib/guidelines.sh` を
  source する構成へリファクタリング（値の実体を lib に一元化。検証結果は移設前後で不変）
- `scripts/sync-guidelines.sh`・`scripts/validate.sh` が個別実装していたリーダー判定関数を
  `scripts/lib/guidelines.sh` の共通関数 `is_leader_agent_name` へ集約し、重複実装を解消

## [0.3.0] - 2026-08-01

### Added
- 利用者向け出力・成果物文書（統括・docs系エージェント: docs-l10n/docs-lead/docs-tech/docs-user/
  mgmt-coordinator）に URL 区切り規約を導入。裸 URL は前後を空白・改行で区切り直後に文字を続けない、
  可能な限り markdown リンクを用いるよう統一し、出力の URL がリンクとして正しく認識されない事態を防ぐ
- permissions（権限設定）パターン提案時の注意をスキル `hw:permission-rules` として新設。導入先で
  `deny "Bash(git push --force*)"` が前方一致により `--force-with-lease` を巻き込み正当な操作まで
  停止した実事故を受け、公式仕様の裏取りに基づく注意事項を sec-audit/sec-appsec/infra-devops へ導入した
  うえで、重複保守を避けるためスキル化・トリガー行方式に集約。`audit-assets`/`optimize-assets` にも
  一致範囲確認・新旧差分明示を必須とする一文を追加

## [0.2.0] - 2026-07-31

### Added
- 外部進捗管理ツール連携（Jira/Backlog/GitHub/Trello 等）の設定基盤 `.hw/tracker.md` と関連スキル
  `hw:tracker-setup` / `hw:tracker-sync`
- コマンド・スキル一覧を表示する `/hw:help`
- 利用者リポジトリの開発文書を生成・補完する `/hw:draft-docs`
- AI資産を他リポジトリへ横展開するスキル `hw:export-assets` / `hw:import-assets`（拒否時の観測性・
  フェイルセーフ注記込み）
- 検証一式（`claude plugin validate` / `scripts/validate.sh`）を自動実行する CI ワークフロー
- 判断に迷った場合の3段階手順（文書化された定め → 類似例・デファクトスタンダード調査 → 呼び出し元へ
  確認）を全エージェント共通で導入
- 手順資産の成長ループ（参照 → 蒸留 → 昇格）とスキル・手順資産の粒度基準。昇格前は `.hw/scripts/`
  限定で承認不要とする分岐を追加
- 新規導入提案（スキル・ツール連携等）の評価ゲート（go/no-go）をルーティングに導入
- ブランチ運用・リリース手順（CONTRIBUTING 9章）と、大型文書の部分読み込み規約・冒頭目次
- 管理番号（例: T6/B5）を対応表とセットで使う運用の標準化
- 初出パターン時の進め方確認（AI提案・カスタム・二人三脚・おまかせ）を導入
- 関係者マップへの本人申告欄（本人記入のみ）を追加
- チーム共有事実が個人メモリへ流出することへの対策（`hw:init` の条項提案・`hw:audit-assets` の
  点検観点）
- サブエージェント完了報告の規約強化とトークン使用量集計スクリプトの新設
- `validate.sh` へのチェック追加（数量表記整合・commands/skills の注入耐性文言・ファイルモード検証）
- CONTRIBUTING 8章（スクリプト・CI 定義の追加・変更手順）の新設

### Changed
- README を再構成（全体像をインストール手順より前に配置、文体・表記を統一、インストール手順を
  マーケットプレイス方式に一本化）
- モノレポ限定の表現を中立化し、単一プロジェクト構成でも前提が成立するよう統一
- `/hw:help` の README 読み込み範囲を使い方・スキル表に限定（読み込み量を約84%削減）
- スキル昇格に必要な再利用実績の目安を「2回以上」から「5回以上」に変更
- エージェント `description` のスリム化とリーダーからの委任範囲の限定
- qa-review のレビュー観点にシェルスクリプト観点（quoting・エラー処理・値検証等）を明文化
  （shellcheck の導入は見送り）
- `hw:init` の次の一歩案内に `hw:draft-docs` / `hw:optimize-assets` / `hw:audit-assets` を追加
- show-org の組織構成表の三重再掲を解消
- 改善調査フォローアップによる構成表・チェックリスト・連携節の整合是正（複数件）
- ドキュメント間の正本・再掲関係の整備（DESIGN 2.9 再掲方式基準の追記を含む）

### Fixed
- 資材監査で検出したスクリプトの不具合の是正と回帰テストの強化

### Removed
- `/hw:release` コマンドおよび `release-flow` スキルを撤去し、業務特性に依存するリリース手順は
  同梱しない方針へ変更（0.1.0 時点で未リリースの機能のため破壊的変更には該当しない）

### Security
- CI の `actions/checkout` をコミット SHA 固定にし、Dependabot を導入（`actions/checkout` を
  4.4.0 → 7.0.1 へ更新）
- sec-audit 診断で検出したプラグイン資材のセキュリティ指摘4件を是正
- CI ワークフローの防御強化（`timeout-minutes` / `persist-credentials`）

## [0.1.0] - 2026-07-29
- Hermit Works プラグイン初版（10グループ・51名の専門家エージェント組織、コマンド・スキル一式）
