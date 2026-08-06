#!/usr/bin/env bash
#
# .claude/scripts/sync-guidelines.sh の回帰テストハーネス。
#
# 方針:
#   - 外部ランタイム非依存（bash + POSIX標準ツール + git のみ）。.claude/scripts/tests/run-tests.sh・
#     .claude/scripts/tests/run-git-changelog-tests.sh と同じ方針を踏襲する。
#   - アサーション・一時ディレクトリ管理・テスト集計は .claude/scripts/tests/lib/assertions.sh を
#     source して使う（ハーネスごとの再実装をしない。CONTRIBUTING 8.4）。
#   - .claude/scripts/sync-guidelines.sh は「正典(lib)の git HEAD時点の値」と「作業ツリーの現在値」の
#     差分を対象ファイルへ伝播する設計のため、フィクスチャは静的ファイルではなく「一時
#     ディレクトリに .claude/scripts/tests/fixtures/base/ を複製したうえで git init し、1コミットを
#     積んだ使い捨てリポジトリ」を作る（run-git-changelog-tests.sh の new_git_repo と同種の
#     アプローチ）。
#   - 「正典(lib)の現在値」は、sync-guidelines.sh が自身の SCRIPT_DIR から相対的に
#     .claude/scripts/lib/guidelines.sh を source する設計（B-1。フィクスチャ独立）のため、必ず
#     本リポジトリの実物の現在値になる。フィクスチャ側は「HEAD時点でコミットされている
#     旧い値」だけを用意すればよい。本ハーネスは実物の現在値（GUIDELINE_DECISION_PROCEDURE_LINE）
#     を実行時に読み取り、末尾にテスト用マーカーを付与した文字列を「旧文言」としてフィクスチャの
#     lib・対象ファイルへ埋め込むことで、本文の値そのものをハーネスにハードコピーせず
#     （将来の文言変更に追従できる形で）差分を再現する。
#
# 実行方法:
#   bash .claude/scripts/tests/run-sync-guidelines-tests.sh
#
# 終了コード: 全ケースPASSなら0、1件でもFAILがあれば1。
#
set -uo pipefail
# 注意: -e は使わない（他ハーネス同様、個々のテストケース内で非ゼロ終了を扱うため）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC_SH="$REPO_ROOT/.claude/scripts/sync-guidelines.sh"
REAL_LIB_FILE="$REPO_ROOT/.claude/scripts/lib/guidelines.sh"
FIXTURE_BASE="$SCRIPT_DIR/fixtures/base"
ASSERTIONS_LIB="$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$SYNC_SH" ]; then
  echo "Error: sync-guidelines.sh が見つかりません: $SYNC_SH" >&2
  exit 1
fi
if [ ! -f "$REAL_LIB_FILE" ]; then
  echo "Error: 正典libが見つかりません: $REAL_LIB_FILE" >&2
  exit 1
fi
if [ ! -d "$FIXTURE_BASE" ]; then
  echo "Error: フィクスチャが見つかりません: $FIXTURE_BASE" >&2
  exit 1
fi
if [ ! -f "$ASSERTIONS_LIB" ]; then
  echo "Error: assertions.sh が見つかりません: $ASSERTIONS_LIB" >&2
  exit 1
fi

# アサーションヘルパー・一時ディレクトリ管理（TMP_DIRS/cleanup/trap）・テスト集計
# （PASS_COUNT/FAIL_COUNT/run_test/finish_test_run）は run-tests.sh 等と共通のため
# lib へ切り出し済み（M16）。
source "$ASSERTIONS_LIB"

# 実物の正典(lib)から「現在値」を読み取る（.claude/scripts/tests/fixtures/base/ の agents/*.md は
# この現在値を既に含んでいる前提。.claude/scripts/tests/run-tests.sh の正常系ケースが前提としている
# ことと同じ）。
source "$REAL_LIB_FILE"
NEW_VAL="$GUIDELINE_DECISION_PROCEDURE_LINE"
OLD_VAL="${NEW_VAL} [SYNC-TEST-OLD-MARKER]"

# ---------------------------------------------------------------------------
# フィクスチャ・ヘルパー
# ---------------------------------------------------------------------------

# ファイル内容中の $2(旧) を $3(新) へ、末尾改行を保持したままリテラル置換する。
replace_in_file() {
  local f="$1" old="$2" new="$3"
  local content
  content="$(cat "$f"; printf 'x')"
  content="${content%x}"
  printf '%s' "${content//"$old"/"$new"}" > "$f"
}

# フィクスチャ一式を新しい一時ディレクトリへコピーし、グローバル変数 NEW_CASE_DIR に
# パスを格納する（run-tests.sh の new_case_dir と同種。コマンド置換のサブシェル問題を
# 避けるため標準出力ではなくグローバル変数経由で返す）。
NEW_CASE_DIR=""
new_case_dir() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  cp -r "$FIXTURE_BASE"/. "$d"/
  NEW_CASE_DIR="$d"
}

# 一時ディレクトリを git リポジトリ化し、現状を1コミットとして積む。
# .claude/scripts/lib/guidelines.sh が存在する場合は 100755 を index へ明示する（validate.sh
# セクション11のファイルモード検査対応。core.fileMode=false環境ではchmodのみでは
# git index上のモードが反映されないため、git update-index --chmod=+x を併用する）。
git_commit_all() {
  local d="$1"
  git -C "$d" init -q
  if [ -f "$d/.claude/scripts/lib/guidelines.sh" ]; then
    chmod 755 "$d/.claude/scripts/lib/guidelines.sh"
  fi
  git -C "$d" -c user.email='sync-test@example.com' -c user.name='sync-test' add -A
  if git -C "$d" ls-files --error-unmatch .claude/scripts/lib/guidelines.sh >/dev/null 2>&1; then
    git -C "$d" update-index --chmod=+x -- .claude/scripts/lib/guidelines.sh
  fi
  git -C "$d" -c user.email='sync-test@example.com' -c user.name='sync-test' commit -q -m init >/dev/null
}

# 「HEAD時点で旧文言（OLD_VAL）がコミットされている」フィクスチャを作る:
#   - .claude/scripts/lib/guidelines.sh は実物の現在の lib と同一の構成だが、
#     GUIDELINE_DECISION_PROCEDURE_LINE の値だけ OLD_VAL に置き換えたもの
#   - agents/eng-backend.md・agents/qa-test.md は、実物の現在値(NEW_VAL)が既に
#     埋め込まれているフィクスチャを OLD_VAL に置き換えたもの（＝「まだ同期前の状態」）
# 呼び出し後、NEW_CASE_DIR にケースのディレクトリパスが入る。
new_perturbed_git_case_dir() {
  new_case_dir
  local d="$NEW_CASE_DIR"
  mkdir -p "$d/.claude/scripts/lib"

  local real_lib_content
  real_lib_content="$(cat "$REAL_LIB_FILE")"
  printf '%s' "${real_lib_content//"$NEW_VAL"/"$OLD_VAL"}" > "$d/.claude/scripts/lib/guidelines.sh"

  replace_in_file "$d/agents/eng-backend.md" "$NEW_VAL" "$OLD_VAL"
  replace_in_file "$d/agents/qa-test.md" "$NEW_VAL" "$OLD_VAL"

  git_commit_all "$d"
  NEW_CASE_DIR="$d"
}

# 「HEAD時点で旧文言(OLD_VAL)がコミットされている」が、対象ファイルのうち一部は
# 既に新文言(NEW_VAL)へ手動更新済み・他は未更新（旧文言のまま）という混在状態を作る
# （qa M-1/M-2是正の回帰: 新文言化済みファイルはERRORにせずスキップし、他方は通常どおり
# 更新されることを検証する）。
# 呼び出し後、NEW_CASE_DIR にケースのディレクトリパスが入る。
new_mixed_already_migrated_case_dir() {
  new_case_dir
  local d="$NEW_CASE_DIR"
  mkdir -p "$d/.claude/scripts/lib"

  local real_lib_content
  real_lib_content="$(cat "$REAL_LIB_FILE")"
  printf '%s' "${real_lib_content//"$NEW_VAL"/"$OLD_VAL"}" > "$d/.claude/scripts/lib/guidelines.sh"

  # agents/eng-backend.md は旧文言のまま（＝通常どおり更新される）。
  replace_in_file "$d/agents/eng-backend.md" "$NEW_VAL" "$OLD_VAL"
  # agents/qa-test.md は既に新文言(NEW_VAL)へ更新済み（フィクスチャ本来の値のまま。
  # ＝置換不要でスキップされるべき対象）。

  git_commit_all "$d"
  NEW_CASE_DIR="$d"
}

# 「HEAD時点で実物の現在値のままコミットされている」フィクスチャを作る（lib未変更=no-op系）。
new_clean_git_case_dir() {
  new_case_dir
  local d="$NEW_CASE_DIR"
  mkdir -p "$d/.claude/scripts/lib"
  cp "$REAL_LIB_FILE" "$d/.claude/scripts/lib/guidelines.sh"
  git_commit_all "$d"
  NEW_CASE_DIR="$d"
}

# 指定ファイル中の文字列を無関係な文字列で上書きする（「旧文言が見つからない」ケース用）。
corrupt_file_text() {
  local f="$1" needle="$2"
  replace_in_file "$f" "$needle" '（テスト用に無関係な文字列へ書き換え済み）'
}

file_contains() {
  local f="$1" needle="$2"
  case "$(cat "$f")" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# sync-guidelines.sh 実行ヘルパー
# ---------------------------------------------------------------------------

run_sync() {
  local dir="$1"; shift
  LAST_OUTPUT="$(bash "$SYNC_SH" "$dir" "$@" 2>&1)"
  LAST_EXIT=$?
}

# =============================================================================
# テストケース本体
# =============================================================================

# ---- 正常置換・複数ファイル分配 ----------------------------------------------

test_normal_replace_multiple_files() {
  new_perturbed_git_case_dir; local dir="$NEW_CASE_DIR"
  run_sync "$dir"
  local ok=0
  assert_exit 0 "正常置換はexit 0（validate.shの整合確認も含めて成功）" || ok=1
  assert_contains '変更検出: 判断手順共通文言（9e）（対象候補 2 件）' "複数ファイル（2件）が対象分配される" || ok=1
  assert_contains '更新: agents/eng-backend.md' "1件目のファイルが更新される" || ok=1
  assert_contains '更新: agents/qa-test.md' "2件目のファイルが更新される" || ok=1
  assert_contains '変更検出 1 項目 / 適用 2 件 / ERROR 0 件 / dry-run=0' "同期結果サマリが期待どおり" || ok=1
  if file_contains "$dir/agents/eng-backend.md" 'SYNC-TEST-OLD-MARKER'; then
    echo '  NG: agents/eng-backend.md に旧マーカーが残っている'
    ok=1
  fi
  if file_contains "$dir/agents/qa-test.md" 'SYNC-TEST-OLD-MARKER'; then
    echo '  NG: agents/qa-test.md に旧マーカーが残っている'
    ok=1
  fi
  if ! file_contains "$dir/agents/eng-backend.md" "$NEW_VAL"; then
    echo '  NG: agents/eng-backend.md に現在値（正典）が反映されていない'
    ok=1
  fi
  return $ok
}

# ---- 旧文言未検出はERROR（静かに失敗しない） --------------------------------

test_missing_old_text_is_error() {
  new_perturbed_git_case_dir; local dir="$NEW_CASE_DIR"
  # qa-test.md だけ、事前に旧文言を無関係な文字列へ書き換えておく（同期対象文言が見つからない状態）。
  corrupt_file_text "$dir/agents/qa-test.md" "$OLD_VAL"
  run_sync "$dir"
  local ok=0
  assert_exit 1 "旧文言未検出を含む場合はexit 1" || ok=1
  assert_contains 'ERROR: agents/qa-test.md に旧文言（判断手順共通文言（9e））が見つかりません' "旧文言未検出のERRORが報告される" || ok=1
  assert_contains '更新: agents/eng-backend.md' "他方の正常なファイルは更新される（1件の失敗が他へ波及しない）" || ok=1
  return $ok
}

# ---- 新文言化済みファイルが混在するケース（ERRORにならず他ファイルは置換される） ----

test_already_migrated_file_is_skipped_not_error() {
  new_mixed_already_migrated_case_dir; local dir="$NEW_CASE_DIR"
  run_sync "$dir"
  local ok=0
  assert_exit 0 "新文言化済みファイル混在でもexit 0（ERROR扱いにしない）" || ok=1
  assert_contains '更新: agents/eng-backend.md' "旧文言のままのファイルは通常どおり更新される" || ok=1
  assert_contains '対応不要（既に新文言）: agents/qa-test.md は旧文言を含まず、既に新文言' "新文言化済みファイルはスキップ報告される" || ok=1
  assert_not_contains 'ERROR: agents/qa-test.md' "新文言化済みファイルはERROR報告されない（validate.shサマリの'ERROR: 0 件'とは別物）" || ok=1
  assert_contains '対応不要（既に新文言） 1 件' "サマリに対応不要件数が出る" || ok=1
  if file_contains "$dir/agents/eng-backend.md" 'SYNC-TEST-OLD-MARKER'; then
    echo '  NG: agents/eng-backend.md に旧マーカーが残っている'
    ok=1
  fi
  if ! file_contains "$dir/agents/qa-test.md" "$NEW_VAL"; then
    echo '  NG: agents/qa-test.md（既に新文言）の内容が保たれていない'
    ok=1
  fi
  return $ok
}

# ---- dry-run は無変更 ---------------------------------------------------------

test_dry_run_does_not_write() {
  new_perturbed_git_case_dir; local dir="$NEW_CASE_DIR"
  run_sync "$dir" --dry-run
  local ok=0
  assert_exit 0 "dry-runはexit 0" || ok=1
  assert_contains '[dry-run] 更新予定: agents/eng-backend.md' "dry-run表示（1件目）" || ok=1
  assert_contains '[dry-run] 更新予定: agents/qa-test.md' "dry-run表示（2件目）" || ok=1
  assert_contains 'dry-run=1' "サマリにdry-runである旨が出る" || ok=1
  assert_not_contains '整合確認' "dry-run時はvalidate.shの自動実行をしない" || ok=1
  if ! file_contains "$dir/agents/eng-backend.md" 'SYNC-TEST-OLD-MARKER'; then
    echo '  NG: dry-runなのに agents/eng-backend.md が書き換わっている'
    ok=1
  fi
  if ! file_contains "$dir/agents/qa-test.md" 'SYNC-TEST-OLD-MARKER'; then
    echo '  NG: dry-runなのに agents/qa-test.md が書き換わっている'
    ok=1
  fi
  return $ok
}

# ---- lib未変更時はno-op -------------------------------------------------------

test_noop_when_lib_unchanged() {
  new_clean_git_case_dir; local dir="$NEW_CASE_DIR"
  run_sync "$dir"
  local ok=0
  assert_exit 0 "no-opはexit 0" || ok=1
  assert_contains '正典(lib)にHEAD時点からの差分がある項目はありません（no-op）' "no-opメッセージが出る" || ok=1
  assert_not_contains '更新:' "no-opでは何も更新されない" || ok=1
  return $ok
}

# ---- lib がHEAD時点に存在しない場合（初回コミット前等）は正常終了 ------------

test_no_head_lib_exits_cleanly() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  # .claude/scripts/lib/ を用意しないまま（=lib非存在のまま）1コミットする。
  git_commit_all "$dir"
  run_sync "$dir"
  local ok=0
  assert_exit 0 "lib未コミットは正常終了（exit 0）" || ok=1
  assert_contains '同期対象なし' "同期対象なしのメッセージが出る" || ok=1
  assert_contains 'HEAD時点に存在しません' "HEAD時点に存在しない旨のメッセージが出る" || ok=1
  return $ok
}

# =============================================================================
# 実行
# =============================================================================

run_test test_normal_replace_multiple_files
run_test test_missing_old_text_is_error
run_test test_already_migrated_file_is_skipped_not_error
run_test test_dry_run_does_not_write
run_test test_noop_when_lib_unchanged
run_test test_no_head_lib_exits_cleanly

finish_test_run
