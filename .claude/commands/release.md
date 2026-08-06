---
description: hermit-works リポジトリ自身のリリース作業（CONTRIBUTING 9章）を半自動化する。version判定・CHANGELOGドラフト・コミット・タグ・pushを段階的な確認を挟みながら進める
---

このリポジトリ（hermit-works）自身のリリース作業を進めます。あなたは mgmt-release（リリースマネージャー）として振る舞ってください。

判定基準・手順の正本は `CONTRIBUTING.md` 9章（特に9.2）です。本コマンドはその実務手順をこの
リポジトリ向けに固定した保守用ローカルコマンドであり、判定基準（発火判定→種別判定→操作的判定
テストの3ステップとその基準）は下記「手順」内で自己完結させ、ここでは再定義しません（迷ったら
9.2の記述を優先します）。

このコマンドはリポジトリローカルの保守用コマンドです（`.claude/commands/` 配下。プラグイン配布物の
`commands/` には含まれず、`hw:` 名前空間にも属しません）。

本リポジトリは `develop`（統合ライン）と `main`（リリース確定ライン）の2ブランチ運用です。
リリース準備は `develop` から分岐した `release/v<version>` ブランチ上で行って `develop` 向け PR
（リリース準備 PR）で統合し、`develop`→`main` の PR をマージすることでリリースが確定します
（main・develop への直接コミットは例外なく行わない。正本は CONTRIBUTING 9.1・9.2）。

## 手順

1. **ガード確認**（いずれか不成立なら、状況を報告してここで中断する。以降は実行しない）
   - 現在ブランチが `develop` であること（`git branch --show-current`）。
   - ワークツリーがクリーンであること（`git status --porcelain` が空。未コミット変更・未追跡ファイルが
     あれば中断する）。
   - `origin/develop` と同期していること（`git fetch origin` 後に `git rev-list --left-right --count
     origin/develop...HEAD` 等で ahead/behind を確認し、ずれがあれば中断して状況を報告する）。
     `git ls-remote --heads origin develop` が空、すなわち origin にまだ `develop` が存在しない場合
     （移行初回相当）は、この同期確認を実施できない旨と対処案（先に `develop` を push するか等）を
     報告し、利用者の確認を得てから続行の可否を判断する。利用者が続行を承認した場合は、この同期
     確認を除き手順2以降を通常どおり進める（手順7のリリース準備 PR は origin 上の `develop` を
     base とするため、その前に `develop` 自体の初回 push が必要になる旨を提示し、個別に確認を
     得てから実施する）。

2. **変更一覧の作成**: `bash .claude/scripts/git-changelog.sh` を引数省略で実行し、前回リリース以降の変更
   一覧を作る（スクリプト内部のフォールバックで直前タグ〜`HEAD`〔= develop の HEAD〕、タグが
   1つも無ければ全履歴が対象になる。`git describe` をここで別途実行して二重実装しない）。

3. **V-1 発火判定**: 直前タグを `git describe --tags --abbrev=0 2>/dev/null || true` で取得する
   （タグ無し時はエラー終了・stderr出力するため `2>/dev/null || true` で空文字列に丸める）。
   直前タグがあれば `git diff --name-only <直前タグ>..HEAD`、無ければ（初回相当）
   `git diff --name-only $(git rev-list --max-parents=0 HEAD)..HEAD` で、直前タグから
   develop の現在の HEAD までを対象に変更ファイルを取得し、CONTRIBUTING 9.2 の利用者面（`agents/`・
   `commands/`・`skills/`・`.claude-plugin/plugin.json`・`README.md`）／保守面（`.claude/`（保守用
   スクリプト `.claude/scripts/` を含む）・`.github/`・`CONTRIBUTING.md`・`DESIGN.md`・
   `DEVELOPMENT.md`・`CLAUDE.md`）の2区分に照らす。利用者面
   資材への変更が1件も無い場合は、「リリース発火なし（保守面のみのため次の利用者面リリースに同乗）」と
   対象コミット一覧つきで報告し、ここで終了する（version・CHANGELOG は更新しない。対象コミット
   自体は通常どおり develop 上に残り、次のリリース PR で main へ反映される点を明記する）。利用者面・
   保守面が混在する場合は発火する（リリース側扱い）。利用者面・保守面いずれのリストにも該当しない
   パス（`LICENSE`・`.gitignore` 等）のみの変更は、配布内容・利用条件への実質的な影響（例: LICENSE の
   ライセンス種別変更）や判定に迷う余地がないか確認したうえで発火なしと判定する（フォールバック規定。
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
   （`/release` の起動自体はドラフト作成までの明示指示として扱うが、実際の書き込み・コミット・push・
   PR作成・タグは都度の個別確認を要する。CONTRIBUTING 9.2「リリース操作は利用者の明示的な指示が
   あるときに限り実施する」）。

6. **コミット**（`release/v<version>` ブランチ上）: 手順5の内容承認とは別に、コミットしてよいか
   改めて確認を得てから、`develop` から `release/v<version>` ブランチ（例: `release/v0.6.0`）を
   作成し、`.claude-plugin/plugin.json` の `version` 更新と `CHANGELOG.md` への追記を1コミットに
   まとめる（`develop` へは直接コミットしない。`develop` には PR 必須のブランチ保護が適用されて
   おり直接 push は拒否される。CONTRIBUTING 9.1・9.2）。件名は `chore(release): vX.Y.Z`、本文に
   変更概要を1〜3行で要約し、末尾に `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` を
   付す。push は行わない。

7. **push とリリース準備 PR**（`release/v<version>` → `develop`）: コミット内容を利用者に提示し、
   `release/v<version>` を push してよいか個別に確認を得てから push する。push 後、`develop` 向け
   PR（リリース準備 PR）を作成してよいか個別に確認を得てから作成する。マージは利用者が GitHub 上で
   行い（AI は `gh pr merge` を実行しない）、マージ完了を `gh pr view` 等で確認できるまで手順8には
   進まない。確認後、`git fetch origin` に加えて `git switch develop && git merge --ff-only
   origin/develop` 等でローカルの `develop` を実際に前進させる（fetch はリモート追跡ブランチの
   更新のみでローカル `develop` は動かないため）。マージされたリモートの `release/v<version>` は
   `delete-merged-branch.yml` により自動削除される。

8. **リリース PR の作成**（`develop` → `main`）: リリース準備 PR のマージ確認後、リリース PR を作成してよいか個別に確認を
   得てから `gh pr create --base main --head develop` 等で作成する。PR 本文には手順2の変更概要（利用者
   向けの主な変更点）を記載する。また PR 本文に、**マージはマージコミット方式で行うこと・squash
   マージを行わないこと**を明記する（squash すると develop と main の履歴が乖離し、以降の
   `git-changelog.sh` の起点検出やタグ検出（手順10）が破綻するため。CONTRIBUTING 9.2 参照）。作成した
   PR 番号は手順11（CI 失敗時のフォールバック）の検証で用いるため控えておく。

9. **マージ待ち**: リリース PR のマージは利用者が GitHub 上で行う（AI は `gh pr merge` を実行しない。
   `.claude/settings.json` で deny 設定済み）。マージが完了するまで手順10以降には進まない。

10. **タグ作成確認**: 利用者からマージ完了の報告を得たら、CI
    （`.github/workflows/tag-release.yml`）による自動タグ付与を確認する（申告のみに依拠しない）。
    - `gh run list --workflow=tag-release.yml --branch main --limit 5` で当該マージに対応する
      実行の成否を確認するか、`git fetch origin --tags` 後に
      `git ls-remote --tags origin "refs/tags/v<version>"` でタグ `v<version>` が自動作成されて
      いることを確認する。
    - タグが確認できれば、手動でのタグ付与・push は行わず、手順12（完了報告）へ進む。
    - 続けて `/release-notes` でリリースノートのドラフト作成・登録に進められる（別セッションからの
      単独実行も可）。

11. **CI 失敗時のフォールバック**: CI が失敗している場合（`gh run list` 上のワークフロー実行が
    失敗、または一定時間待ってもタグが作成されない場合）のみ、実行ログから失敗原因（squash／
    rebase 検知によるマージ方式不一致、タグ衝突等）を確認し、利用者に報告して指示を仰ぐ。指示を
    得たうえで、原因を解消してから次の手動手順でフォールバックする（各ステップは個別に確認を
    得てから実行し、まとめて先取りの承認としない）。
    1. `gh pr view <PR番号> --json state,mergedAt,mergeCommit` を実行し（`<PR番号>` は手順8で
       控えたもの）、`state` が `MERGED` であることを確認し、あわせて `mergeCommit.oid`
       （マージコミットの SHA）を取得する。
    2. `git fetch origin` 後、`git log -1 --format=%P <mergeCommit.oid>`（または
       `git rev-list --parents -n 1 <mergeCommit.oid>`）で、**当該リリース PR のマージコミット
       自体**の親コミット数を確認する（`origin/main` の HEAD ではなく、取得した SHA を対象にする。
       保護未適用環境や、マージ直後に別コミットが main に入ったケースでの取り違えを避けるため）。
       親が2つ（マージコミット）であればマージコミット方式でのマージと判断する。親が1つしか
       ない場合は squash または rebase マージが行われた疑いが確定するため、対処方針を利用者と
       相談する（以降の手順は進めない）。
    3. 上記2点を確認できたら、タグ `v<version>` を付与してよいか個別に確認を得てから、手順7の
       リリース準備 PR のマージで `develop` に入った version 更新コミット（squash マージのため
       `develop` 上のマージ結果のコミット。`git log origin/develop --grep "chore(release): v<version>"
       -n 1` のようにバージョン番号を含めて一意に特定し、当該コミットの `.claude-plugin/plugin.json`
       の `version` が対象バージョンと一致することを確認する）に対して
       `git tag v<version> <コミットSHA>` を実行する（このコミットはマージコミット方式のマージに
       より main の履歴にも祖先として含まれるため、develop 側のコミットへ打刻すれば両ブランチで
       タグ検出が成立し、main への back-merge は不要）。
    4. タグ付与後、リモートへのタグ push を実行してよいか改めて個別に確認を得てから push する。

12. **完了報告**: 実施内容（発火判定の結果・確定した version と種別・コミット/push/PR/マージ確認/
    タグ作成確認（CI）の実施状況。CI 失敗時はフォールバック実施状況も含む）を簡潔に報告する。
    手順1または3で終了した場合はその旨と理由のみを報告する。

## 制約

- 各ステップの確認は個別に行い、まとめて先取りの承認を得たものとして省略しない。
- ガード不成立時・V-1 で発火なしと判定した場合は、以降の手順を実行しない。
- 判定基準の詳細な再定義はここでは行わない（CONTRIBUTING 9.2 が正本）。
