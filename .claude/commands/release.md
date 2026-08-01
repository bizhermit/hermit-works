---
description: hermit-works リポジトリ自身のリリース作業（CONTRIBUTING 9章）を半自動化する。version判定・CHANGELOGドラフト・コミット・タグ・pushを段階的な確認を挟みながら進める
---

このリポジトリ（hermit-works）自身のリリース作業を進めます。あなたは mgmt-release（リリースマネージャー）として振る舞ってください。

判定基準・手順の正本は `CONTRIBUTING.md` 9章（特に9.2）です。本コマンドはその実務手順をこの
リポジトリ向けに固定した保守用ローカルコマンドであり、判定基準そのものはここで再定義しません
（迷ったら9.2の記述を優先します）。あわせて `agents/mgmt-release.md` 「作業方針」のリリース判定
手順（発火判定→種別判定→操作的判定テストの3ステップ）に従います。

このコマンドはリポジトリローカルの保守用コマンドです（`.claude/commands/` 配下。プラグイン配布物の
`commands/` には含まれず、`hw:` 名前空間にも属しません）。

## 手順

1. **ガード確認**（いずれか不成立なら、状況を報告してここで中断する。以降は実行しない）
   - 現在ブランチが `main` であること（`git branch --show-current`）。
   - ワークツリーがクリーンであること（`git status --porcelain` が空。未コミット変更・未追跡ファイルが
     あれば中断する）。
   - `origin/main` と同期していること（`git fetch origin` 後に `git rev-list --left-right --count
     origin/main...HEAD` 等で ahead/behind を確認し、ずれがあれば中断して状況を報告する）。

2. **変更一覧の作成**: `bash scripts/git-changelog.sh` を引数省略で実行し、前回リリース以降の変更
   一覧を作る（スクリプト内部のフォールバックで直前タグ〜`HEAD`、タグが1つも無ければ全履歴が
   対象になる。`git describe` をここで別途実行して二重実装しない）。

3. **V-1 発火判定**: 直前タグを `git describe --tags --abbrev=0 2>/dev/null || true` で取得する
   （タグ無し時はエラー終了・stderr出力するため `2>/dev/null || true` で空文字列に丸める）。
   直前タグがあれば `git diff --name-only <直前タグ>..HEAD`、無ければ（初回相当）
   `git diff --name-only $(git rev-list --max-parents=0 HEAD)..HEAD` でルートコミットからの
   全履歴を対象に変更ファイルを取得し、CONTRIBUTING 9.2 の利用者面（`agents/`・`commands/`・
   `skills/`・`.claude-plugin/plugin.json`・`README.md`）／保守面（`scripts/`・`.github/`・
   `CONTRIBUTING.md`・`DESIGN.md`・`DEVELOPMENT.md`・`CLAUDE.md`）の2区分に照らす。利用者面資材への
   変更が1件も無い場合は、「リリース発火なし（保守面のみのため次の利用者面リリースに同乗）」と
   対象コミット一覧つきで報告し、ここで終了する（version・CHANGELOG は更新しない。対象コミット
   自体は通常どおり main 上にあり配布される点を明記する）。利用者面・保守面が混在する場合は発火
   する（リリース側扱い）。利用者面・保守面いずれのリストにも該当しないパス（`LICENSE`・
   `.gitignore` 等）のみの変更は、配布内容・利用条件への実質的な影響（例: LICENSE のライセンス
   種別変更）や判定に迷う余地がないか確認したうえで発火なしと判定する（フォールバック規定。
   詳細は CONTRIBUTING 9.2）。

4. **V-2/V-3 種別判定案の提示**: 手順2の変更一覧・実際の差分内容から、MAJOR/MINOR/PATCH の判定案を
   根拠つきで提示する。判定は CONTRIBUTING 9.2 の定義（MAJOR=呼び出しIFの破壊。0.x の間は MINOR
   でも可／MINOR=IFが不変でも利用者が変更を意識する必要がある場合／PATCH=意識する必要がない場合）
   に従い、迷う場合は重い側（MINOR）に倒す。操作的判定テストとして「CHANGELOG に利用者向けの行として
   書くべき内容があるか」を MINOR/PATCH 判定の目安に用いる（機械的な決定にはしない。他の判断材料と
   併せて判定する）。

5. **ドラフト提示と承認**: `CHANGELOG.md` への追記節（既存の見出し・区分〔Added/Changed/Fixed 等〕の
   書式に合わせる）と、新しい `version`（`.claude-plugin/plugin.json` の現在値 + 手順4の種別）の
   組み合わせを**全文**提示し、利用者の承認を得る。承認が得られるまで手順6以降には進まない
   （`/release` の起動自体はドラフト作成までの明示指示として扱うが、実際の書き込み・コミット・
   タグ・push は都度の個別確認を要する。CONTRIBUTING 9.2「リリース操作は利用者の明示的な指示が
   あるときに限り実施する」）。

6. **コミット**: 手順5の内容承認とは別に、コミットしてよいか改めて確認を得てから
   `.claude-plugin/plugin.json` の `version` 更新と `CHANGELOG.md` への追記を1コミットにまとめる。
   件名は `chore(release): vX.Y.Z`、本文に変更概要を1〜3行で要約し、末尾に
   `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` を付す（実例: コミット `8c47b46`）。
   push は行わない。

7. **タグ付与**: コミット内容を利用者に提示し、タグ `v<version>` を付与してよいか個別に確認を
   得てから `git tag v<version>` を実行する。

8. **push**: タグ付与後、リモートへの反映（コミット・タグの push）を実行してよいか改めて個別に
   確認を得てから push する。

9. **完了報告**: 実施内容（発火判定の結果・確定した version と種別・コミット/タグ/push の実施状況）を
   簡潔に報告する。手順3で終了した場合はその旨と理由のみを報告する。

## 制約

- 各ステップの確認は個別に行い、まとめて先取りの承認を得たものとして省略しない。
- ガード不成立時・V-1 で発火なしと判定した場合は、以降の手順（4〜8）を実行しない。
- 判定基準の詳細な再定義はここでは行わない（CONTRIBUTING 9.2 が正本）。
