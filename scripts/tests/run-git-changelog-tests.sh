#!/usr/bin/env bash
#
# scripts/git-changelog.sh の回帰テストハーネス。
#
# 方針:
#   - scripts/tests/run-tests.sh（validate.sh用）と同じ方針を踏襲する: 外部ランタイム
#     非依存（bash + POSIX標準ツール + git のみ）、一時ディレクトリは mktemp -d で作成し
#     trap で必ず削除する。
#   - git-changelog.sh は「自分自身が置かれているディレクトリの1階層上」を対象リポジトリ
#     （REPO_ROOT）として決め打ちで扱う設計のため（scripts/validate.sh 等、本リポジトリの
#     他スクリプトと同じ規約）、フィクスチャは静的ファイルではなく「一時ディレクトリに
#     git init し、Conventional Commits 形式のコミットを積んだ使い捨てリポジトリ」を作り、
#     そのリポジトリ配下に git-changelog.sh 自体をコピーして実行する。
#
# 実行方法:
#   bash scripts/tests/run-git-changelog-tests.sh
#
# 終了コード: 全ケースPASSなら0、1件でもFAILがあれば1。
#
set -uo pipefail
# 注意: -e は使わない（run-tests.sh 同様、個々のテストケース内で非ゼロ終了を扱うため）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GIT_CHANGELOG_SH="$REPO_ROOT/scripts/git-changelog.sh"
ASSERTIONS_LIB="$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$GIT_CHANGELOG_SH" ]; then
  echo "Error: git-changelog.sh が見つかりません: $GIT_CHANGELOG_SH" >&2
  exit 1
fi
if [ ! -f "$ASSERTIONS_LIB" ]; then
  echo "Error: assertions.sh が見つかりません: $ASSERTIONS_LIB" >&2
  exit 1
fi

# アサーションヘルパー・一時ディレクトリ管理（TMP_DIRS/cleanup/trap）・テスト集計
# （PASS_COUNT/FAIL_COUNT/run_test/finish_test_run）は
# scripts/tests/run-tests.sh と共通のため lib へ切り出し済み（M16）。
source "$ASSERTIONS_LIB"

# 使い捨てのgitリポジトリを作り、グローバル変数 NEW_REPO_DIR にパスを格納する
# （run-tests.sh の new_case_dir 同様、コマンド置換のサブシェル問題を避けるため
#  標準出力ではなくグローバル変数経由で返す）。
NEW_REPO_DIR=""
new_git_repo() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  NEW_REPO_DIR="$d"
}

# 指定リポジトリに1コミットを作る（ファイル内容はコミットごとに変える）。
commit_in() {
  local d="$1" subject="$2"
  echo "$RANDOM$RANDOM$RANDOM" > "$d/file.txt"
  git -C "$d" add file.txt
  git -C "$d" commit -q -m "$subject"
}

# ---------------------------------------------------------------------------
# git-changelog.sh 実行ヘルパー
# ---------------------------------------------------------------------------

# 指定の使い捨てリポジトリ配下に git-changelog.sh をコピーしたうえで実行する。
run_changelog_in_repo() {
  local d="$1"; shift
  mkdir -p "$d/scripts"
  cp "$GIT_CHANGELOG_SH" "$d/scripts/git-changelog.sh"
  LAST_OUTPUT="$(bash "$d/scripts/git-changelog.sh" "$@" 2>&1)"
  LAST_EXIT=$?
}

# =============================================================================
# テストケース本体
# =============================================================================

test_groups_by_conventional_commit_type() {
  new_git_repo; local d="$NEW_REPO_DIR"
  commit_in "$d" "feat: 機能A追加"
  commit_in "$d" "fix: バグ修正"
  commit_in "$d" "feat(scope): スコープ付き機能"
  commit_in "$d" "docs: ドキュメント更新"
  run_changelog_in_repo "$d"
  local ok=0
  assert_exit 0 "正常系はexit 0" || ok=1
  assert_contains '### feat' "featセクションが出力される" || ok=1
  assert_contains '機能A追加' "feat内のコミットが含まれる" || ok=1
  assert_contains 'スコープ付き機能' "scope付きコミットもfeatに分類される" || ok=1
  assert_contains '### fix' "fixセクションが出力される" || ok=1
  assert_contains '### docs' "docsセクションが出力される" || ok=1
  assert_contains 'コミット数: 4' "コミット数が正しく集計される" || ok=1
  return $ok
}

test_breaking_change_marker_still_classified() {
  new_git_repo; local d="$NEW_REPO_DIR"
  commit_in "$d" "feat!: 破壊的変更"
  run_changelog_in_repo "$d"
  local ok=0
  assert_exit 0 "正常系はexit 0" || ok=1
  assert_contains '### feat' "feat!:もfeatに分類される" || ok=1
  assert_contains '破壊的変更' "コミット内容が含まれる" || ok=1
  return $ok
}

test_non_conventional_commit_goes_to_other() {
  new_git_repo; local d="$NEW_REPO_DIR"
  commit_in "$d" "Conventional Commits形式でないコミット"
  run_changelog_in_repo "$d"
  local ok=0
  assert_exit 0 "正常系はexit 0" || ok=1
  assert_contains '### その他' "その他セクションに分類される" || ok=1
  assert_not_contains '### feat' "featセクションは出ない" || ok=1
  return $ok
}

test_empty_range_reports_no_commits() {
  new_git_repo; local d="$NEW_REPO_DIR"
  commit_in "$d" "feat: 何か"
  run_changelog_in_repo "$d" HEAD HEAD
  local ok=0
  assert_exit 0 "変更なし範囲でもexit 0" || ok=1
  assert_contains '対象範囲に変更コミットはありません' "変更なしメッセージが出る" || ok=1
  return $ok
}

test_from_to_range_option() {
  new_git_repo; local d="$NEW_REPO_DIR"
  commit_in "$d" "feat: 最初のコミット"
  git -C "$d" tag v1.0.0
  commit_in "$d" "fix: リリース後の修正"
  run_changelog_in_repo "$d" v1.0.0 HEAD
  local ok=0
  assert_exit 0 "正常系はexit 0" || ok=1
  assert_contains 'コミット数: 1' "タグ以降の1件のみが対象になる" || ok=1
  assert_contains 'リリース後の修正' "タグ以降のコミットが含まれる" || ok=1
  assert_not_contains '最初のコミット' "タグ以前のコミットは含まれない" || ok=1
  return $ok
}

test_path_filter_option() {
  new_git_repo; local d="$NEW_REPO_DIR"
  mkdir -p "$d/services/a" "$d/services/b"
  echo x > "$d/services/a/file.txt"
  git -C "$d" add services/a/file.txt
  git -C "$d" commit -q -m "feat: サービスAの変更"
  echo y > "$d/services/b/file.txt"
  git -C "$d" add services/b/file.txt
  git -C "$d" commit -q -m "feat: サービスBの変更"
  run_changelog_in_repo "$d" -- services/a
  local ok=0
  assert_exit 0 "正常系はexit 0" || ok=1
  assert_contains 'サービスAの変更' "対象パス配下のコミットが含まれる" || ok=1
  assert_not_contains 'サービスBの変更' "対象パス外のコミットは含まれない" || ok=1
  return $ok
}

test_invalid_from_ref_errors() {
  new_git_repo; local d="$NEW_REPO_DIR"
  commit_in "$d" "feat: 何か"
  run_changelog_in_repo "$d" nonexistent-tag HEAD
  local ok=0
  assert_exit 1 "存在しないref指定はexit 1" || ok=1
  assert_contains 'git log の実行に失敗しました' "エラーメッセージが出る" || ok=1
  assert_contains 'nonexistent-tag' "範囲指定の内容がエラーメッセージに含まれる" || ok=1
  return $ok
}

test_non_git_directory_errors() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  run_changelog_in_repo "$d"
  local ok=0
  assert_exit 1 "gitリポジトリでない場合はexit 1" || ok=1
  assert_contains 'は git リポジトリではありません' "エラーメッセージが出る" || ok=1
  return $ok
}

# =============================================================================
# 実行
# =============================================================================

run_test test_groups_by_conventional_commit_type
run_test test_breaking_change_marker_still_classified
run_test test_non_conventional_commit_goes_to_other
run_test test_empty_range_reports_no_commits
run_test test_from_to_range_option
run_test test_path_filter_option
run_test test_invalid_from_ref_errors
run_test test_non_git_directory_errors

finish_test_run
