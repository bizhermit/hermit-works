#!/usr/bin/env bash
#
# .claude/scripts/verify-assets.sh の回帰テストハーネス。
#
# 方針:
#   - 外部ランタイム非依存（bash + POSIX標準ツール + git のみ）。他ハーネスと同じ方針を踏襲する。
#     実物の `.claude/scripts/validate.sh` には依存しない（使い捨ての一時ディレクトリに擬似
#     リポジトリ（git init 済み）と validate.sh のスタブを用意して検証する）。
#   - アサーション・一時ディレクトリ管理・テスト集計は .claude/scripts/tests/lib/assertions.sh を
#     source して使う（ハーネスごとの再実装をしない。CONTRIBUTING 8.4）。
#   - `claude` コマンドは対象環境（実行者のPATH上）に実在しうるため、対象スクリプト実行時は
#     PATH を標準ディレクトリのみ（/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin）に
#     絞る。verify-assets.sh は claude plugin validate / validate.sh の両方が実行されて初めて
#     全体PASSとなる（issue #76 品質ゲートR1 qa M1是正: 必須2ステップの対称化）ため、
#     「両方PASSで全体PASS」を検証するテストでは、この制限PATHの先頭に `claude` のスタブ
#     （常に成功する擬似実装）を追加したPATHを使う（run_target、既定）。「claude plugin
#     validateがSKIPする」ことそのものを検証するテストでは、スタブなしの制限PATH
#     （RESTRICTED_PATH）を使う（run_target_without_claude）。
#
# 実行方法:
#   bash .claude/scripts/tests/run-verify-assets-tests.sh
#
# 終了コード: 全ケースPASSなら0、1件でもFAILがあれば1。
#
set -uo pipefail
# 注意: -e は使わない（他ハーネス同様、個々のテストケース内で非ゼロ終了を扱うため）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET_SH="$REPO_ROOT/.claude/scripts/verify-assets.sh"
ASSERTIONS_LIB="$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$TARGET_SH" ]; then
  echo "Error: verify-assets.sh が見つかりません: $TARGET_SH" >&2
  exit 1
fi
if [ ! -f "$ASSERTIONS_LIB" ]; then
  echo "Error: assertions.sh が見つかりません: $ASSERTIONS_LIB" >&2
  exit 1
fi

source "$ASSERTIONS_LIB"

# claude コマンドを確実に不在にするための制限PATH（上記コメント参照）。
RESTRICTED_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

# `claude plugin validate <path>` を模した、常に成功するスタブ（上記コメント参照）。
# 引数の中身は検証しない（本ハーネスが対象とするのは verify-assets.sh 側の呼び出し・
# ステータス判定ロジックであり、claude本体の挙動ではないため）。
CLAUDE_STUB_DIR="$(mktemp -d)"
TMP_DIRS+=("$CLAUDE_STUB_DIR")
cat > "$CLAUDE_STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# テスト用 claude スタブ（.claude/scripts/tests/run-verify-assets-tests.sh 専用）。
echo 'Validating marketplace manifest: (stub)'
echo ''
echo '✔ Validation passed'
exit 0
STUB
chmod +x "$CLAUDE_STUB_DIR/claude"
PATH_WITH_CLAUDE_STUB="$CLAUDE_STUB_DIR:$RESTRICTED_PATH"

# `claude plugin validate <path>` を模した、常に失敗するスタブ（qa L-R2-2: claude plugin
# validateが非0終了するFAIL分岐の回帰テスト用。従来はexit 0固定のスタブしかなく、
# PLUGIN_VALIDATE_STATUS='FAIL'の経路が未検証だった）。
CLAUDE_FAIL_STUB_DIR="$(mktemp -d)"
TMP_DIRS+=("$CLAUDE_FAIL_STUB_DIR")
cat > "$CLAUDE_FAIL_STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# テスト用 claude 失敗スタブ（.claude/scripts/tests/run-verify-assets-tests.sh 専用）。
echo 'Validating marketplace manifest: (stub-fail)'
echo ''
echo '✘ Validation failed: stub induced failure'
exit 1
STUB
chmod +x "$CLAUDE_FAIL_STUB_DIR/claude"
PATH_WITH_FAILING_CLAUDE_STUB="$CLAUDE_FAIL_STUB_DIR:$RESTRICTED_PATH"

# run_target がスナップショット保存先を省略された場合のデフォルト置き場（TMP_DIRSで管理される
# 一時ディレクトリの内側に限定し、実マシンの /tmp 直下へパッチファイルを毎回散らかさないため。
# verify-assets.sh 本体の既定値（${TMPDIR:-/tmp}/verify-assets-diff-<日時>.patch）はこの
# ハーネスでは使わない）。
SHARED_SNAPSHOT_DIR="$(mktemp -d)"
TMP_DIRS+=("$SHARED_SNAPSHOT_DIR")
SNAPSHOT_SEQ=0

# ---------------------------------------------------------------------------
# フィクスチャ・ヘルパー
# ---------------------------------------------------------------------------

# 一時ディレクトリを新規作成し、グローバル変数 NEW_CASE_DIR にパスを格納する。
NEW_CASE_DIR=""
new_case_dir() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  NEW_CASE_DIR="$d"
}

# ディレクトリを git リポジトリ化し、現状を1コミットとして積む（HEADを存在させ、
# `git diff HEAD` が正常に動く状態にする）。
git_init_and_commit() {
  local d="$1"
  git -C "$d" init -q
  # テスト実行環境のグローバル設定（署名必須等）の影響を受けないようにする。
  git -C "$d" -c user.email='verify-assets-test@example.com' -c user.name='verify-assets-test' \
    -c commit.gpgsign=false add -A
  git -C "$d" -c user.email='verify-assets-test@example.com' -c user.name='verify-assets-test' \
    -c commit.gpgsign=false commit -q -m init >/dev/null
}

# 本リポジトリ（プラグイン本体）相当のフィクスチャを作る: .claude-plugin/marketplace.json を
# 用意する。
make_plugin_repo_marker() {
  local d="$1"
  mkdir -p "$d/.claude-plugin"
  printf '{}\n' > "$d/.claude-plugin/marketplace.json"
}

# validate.sh のスタブを配置する。
#   $1: 配置先パス（例: "$d/.claude/scripts/validate.sh"）
#   $2: 出力に含める「ERROR: N 件 / WARN: N 件」の行（空文字なら出力しない＝解析不能ケース用）
#   $3: 終了コード
write_validate_stub() {
  local path="$1" summary_line="$2" exit_code="$3"
  mkdir -p "$(dirname -- "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "stub validate.sh 実行: %s"\n' "$path"
    if [ -n "$summary_line" ]; then
      printf 'echo "%s"\n' "$summary_line"
    else
      printf 'echo "（サマリ行なし: 解析不能ケース）"\n'
    fi
    printf 'exit %s\n' "$exit_code"
  } > "$path"
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# 対象スクリプト実行ヘルパー
# ---------------------------------------------------------------------------

# 共通実装。$1=PATH に使う値、$2=repo-root、以降はrun_target/run_target_without_claudeへ
# 渡された残り引数（[diff-snapshot-path]）。
_run_target_with_path() {
  local use_path="$1" dir="$2"
  shift 2
  local snapshot_path
  if [ "$#" -gt 0 ]; then
    snapshot_path="$1"
    shift
  else
    # diff-snapshot-path省略時は SHARED_SNAPSHOT_DIR 配下の使い捨てパスを補う（実マシンの
    # /tmp 直下を汚さないため）。
    SNAPSHOT_SEQ=$((SNAPSHOT_SEQ + 1))
    snapshot_path="$SHARED_SNAPSHOT_DIR/default-${SNAPSHOT_SEQ}.patch"
  fi
  LAST_OUTPUT="$(PATH="$use_path" bash "$TARGET_SH" "$dir" "$snapshot_path" "$@" 2>&1)"
  LAST_EXIT=$?
}

# 使い方: run_target <repo-root> [diff-snapshot-path]
# claudeスタブを含むPATHで実行する（既定。claude plugin validateもPASSする前提のテスト用）。
run_target() {
  _run_target_with_path "$PATH_WITH_CLAUDE_STUB" "$@"
}

# 使い方: run_target_without_claude <repo-root> [diff-snapshot-path]
# claudeを含まない制限PATHで実行する（claude plugin validateがSKIPすることを検証するテスト用）。
run_target_without_claude() {
  _run_target_with_path "$RESTRICTED_PATH" "$@"
}

# 使い方: run_target_with_failing_claude <repo-root> [diff-snapshot-path]
# 常に失敗するclaudeスタブを含むPATHで実行する（claude plugin validateがFAILすることを
# 検証するテスト用。qa L-R2-2）。
run_target_with_failing_claude() {
  _run_target_with_path "$PATH_WITH_FAILING_CLAUDE_STUB" "$@"
}

# =============================================================================
# テストケース本体
# =============================================================================

# ---- (a) .claude/scripts/validate.sh が存在する場合にそちらが選ばれる ----------

test_prefers_claude_scripts_validate_sh() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  write_validate_stub "$dir/scripts/validate.sh" 'ERROR: 9 件 / WARN: 9 件' 1
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 0 ".claude/scripts/validate.sh 側（合格スタブ）が選ばれてexit 0" || ok=1
  assert_contains "(解決先: $dir/.claude/scripts/validate.sh)" ".claude/scripts/validate.sh が優先解決される" || ok=1
  assert_not_contains "(解決先: $dir/scripts/validate.sh)" "scripts/validate.sh 側は実行されない" || ok=1
  assert_contains 'claude plugin validate : PASS' "claude plugin validateもPASSしている（スタブ）" || ok=1
  assert_contains '[PASS] 必須2ステップ（claude plugin validate / validate.sh）とも実行し、合格しました。' "全体PASSと判定される（必須2ステップとも実行）" || ok=1
  return $ok
}

# ---- (b) .claude/scripts/validate.sh が無く scripts/validate.sh のみある場合にフォールバックする ----

test_falls_back_to_scripts_validate_sh() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 0 "scripts/validate.sh へフォールバックしてexit 0" || ok=1
  assert_contains "(解決先: $dir/scripts/validate.sh)" "scripts/validate.sh が解決先として使われる" || ok=1
  assert_contains '[PASS]' "全体PASSと判定される" || ok=1
  return $ok
}

# ---- (c) 本リポジトリ判定が真でvalidate.shがどちらにも無い場合はSKIPでなくFAIL ----

test_plugin_repo_missing_validate_sh_is_fail() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  make_plugin_repo_marker "$dir"
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 1 "本リポジトリでvalidate.sh不在はexit 1（FAIL）" || ok=1
  assert_contains '[FAIL] 本リポジトリ' "SKIPでなくFAILの理由が表示される" || ok=1
  assert_not_contains 'validate.sh             : SKIP' "サマリ上もSKIPではない" || ok=1
  assert_contains 'validate.sh             : FAIL' "サマリ上でFAILと表示される" || ok=1
  return $ok
}

# ---- (d) 利用側リポジトリ相当（marketplace.jsonなし）でvalidate.sh不在はSKIPで、[PASS]と読める文言を出さない ----
# claudeは実行できる（PASS）前提でも、validate.sh側がSKIPすれば対称化ルールにより全体は
# [未検証]になることを確認する（qa M1: 必須2ステップの対称化。片方だけの成功で合格に見せない）。

test_user_repo_missing_validate_sh_is_skip_not_pass() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 2 "利用側リポジトリでvalidate.sh不在は非0終了（未検証）だがFAILの1ではない" || ok=1
  assert_contains 'claude plugin validate : PASS' "claude plugin validate自体はPASSしている（スタブ）" || ok=1
  assert_contains 'validate.sh             : SKIP' "サマリ上でSKIPと表示される" || ok=1
  if printf '%s' "$LAST_OUTPUT" | grep -qF '[PASS]'; then
    echo "  NG: 必須ステップSKIP時に[PASS]と読める文言が出力されている"
    ok=1
  fi
  assert_contains '[未検証] 必須ステップ（validate.sh）がSKIPしたため' "SKIPしたステップ名（validate.shのみ）が明示される" || ok=1
  assert_not_contains 'claude plugin validate /' "PASSした側（claude plugin validate）はSKIPステップ名に含まれない" || ok=1
  return $ok
}

# ---- (追加) claude plugin validateがSKIPする場合も対称に[未検証]/exit 2になる（qa M1是正の回帰） ----

test_plugin_validate_missing_is_unverified_not_pass() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  git_init_and_commit "$dir"
  run_target_without_claude "$dir"
  local ok=0
  assert_exit 2 "claude不在・validate.shはPASSでも非0終了（未検証）" || ok=1
  assert_contains 'claude plugin validate : SKIP' "claude plugin validate側がSKIPと表示される" || ok=1
  assert_contains 'validate.sh             : PASS' "validate.sh側は実際にPASSしている" || ok=1
  if printf '%s' "$LAST_OUTPUT" | grep -qF '[PASS]'; then
    echo "  NG: 必須ステップSKIP時に[PASS]と読める文言が出力されている（validate.sh側がPASSでも合格扱いしてはいけない）"
    ok=1
  fi
  assert_contains '[未検証] 必須ステップ（claude plugin validate）がSKIPしたため' "SKIPしたステップ名（claude plugin validateのみ）が明示される" || ok=1
  return $ok
}

# ---- (追加) 両ステップともSKIPした場合は両方の名前が列挙される ----

test_both_required_steps_skip_lists_both_names() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  git_init_and_commit "$dir"
  run_target_without_claude "$dir"
  local ok=0
  assert_exit 2 "両ステップSKIPでも非0終了（未検証）" || ok=1
  assert_contains 'claude plugin validate : SKIP' "claude plugin validate側がSKIP" || ok=1
  assert_contains 'validate.sh             : SKIP' "validate.sh側もSKIP" || ok=1
  assert_contains '[未検証] 必須ステップ（claude plugin validate / validate.sh）がSKIPしたため' "両方のステップ名が列挙される" || ok=1
  return $ok
}

# ---- (追加) claude plugin validateが非0終了した場合は全体FAILになる（qa L-R2-2） ----
# 従来のスタブは常にexit 0固定で、PLUGIN_VALIDATE_STATUS='FAIL'の経路が未検証だった。

test_plugin_validate_failure_triggers_overall_fail() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  git_init_and_commit "$dir"
  run_target_with_failing_claude "$dir"
  local ok=0
  assert_exit 1 "claude plugin validateが失敗すればexit 1" || ok=1
  assert_contains 'claude plugin validate : FAIL' "サマリでclaude plugin validateがFAILと表示される" || ok=1
  assert_contains '[FAIL]' "全体FAILと判定される" || ok=1
  return $ok
}

# ---- (e-1) ERROR>0 の解析でFAIL ------------------------------------------------

test_parses_error_count_as_fail() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 2 件 / WARN: 0 件' 1
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 1 "ERROR>0はexit 1" || ok=1
  assert_contains 'validate.sh             : FAIL' "validate.shステータスがFAIL" || ok=1
  assert_contains '[FAIL]' "全体FAILと判定される" || ok=1
  return $ok
}

# ---- (e-2) WARN>0のみでもFAIL（終了コード0でも解析結果を優先） ----------------

test_parses_warn_only_as_fail_even_if_exit_zero() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 3 件' 0
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 1 "終了コード0でもWARN>0ならexit 1" || ok=1
  assert_contains 'validate.sh             : FAIL' "WARN>0でFAIL判定される" || ok=1
  return $ok
}

# ---- (e-3) ERROR/WARNともに0はPASS ---------------------------------------------

test_parses_zero_zero_as_pass() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 0 "ERROR0・WARN0はexit 0" || ok=1
  assert_contains 'validate.sh             : PASS' "validate.shステータスがPASS" || ok=1
  assert_contains '[PASS]' "全体PASSと判定される" || ok=1
  return $ok
}

# ---- (e-4) サマリ行が解析不能な場合は終了コードにフォールバックする（成功側） ----

test_falls_back_to_exit_code_when_summary_unparsable_success() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" '' 0
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 0 "解析不能・終了コード0はexit 0" || ok=1
  assert_contains 'validate.sh             : PASS' "終了コードにフォールバックしてPASS" || ok=1
  return $ok
}

# ---- (e-5) サマリ行が解析不能な場合は終了コードにフォールバックする（失敗側） ----

test_falls_back_to_exit_code_when_summary_unparsable_failure() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" '' 1
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 1 "解析不能・終了コード非0はexit 1" || ok=1
  assert_contains 'validate.sh             : FAIL' "終了コードにフォールバックしてFAIL" || ok=1
  return $ok
}

# ---- 本リポジトリ判定が真でも validate.sh が見つかればFAILにしない（正常系の確認） ----

test_plugin_repo_with_validate_sh_present_is_not_forced_fail() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  make_plugin_repo_marker "$dir"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  git_init_and_commit "$dir"
  run_target "$dir"
  local ok=0
  assert_exit 0 "本リポジトリでもvalidate.shが見つかればexit 0" || ok=1
  assert_contains '[PASS]' "全体PASSと判定される" || ok=1
  return $ok
}

# ---- diffスナップショット: 追跡ファイルの増分・対象プレフィクスの未追跡ファイルが記録される ----

test_diff_snapshot_captures_tracked_and_asset_untracked() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  mkdir -p "$dir/agents"
  printf 'v1\n' > "$dir/agents/dummy.md"
  git_init_and_commit "$dir"
  # 追跡ファイルへの変更（未コミット）
  printf 'v2\n' > "$dir/agents/dummy.md"
  # 対象プレフィクスに該当する未追跡ファイル
  printf 'new\n' > "$dir/agents/new-agent.md"
  # 対象プレフィクス外の未追跡ファイル（ノイズとして混入しないことを確認）
  printf 'noise\n' > "$dir/random-note.txt"

  # スナップショットは専用の一時ディレクトリの中に置く（$dir の兄弟パスにすると、そのdirnameが
  # 親の一時ルート（/tmp相当）に化けてcleanup()のrm -rf対象に混入する重大な事故につながるため、
  # 必ず新規mktemp -dの内側に置く）。
  local snapshot_dir
  snapshot_dir="$(mktemp -d)"
  TMP_DIRS+=("$snapshot_dir")
  local snapshot="$snapshot_dir/verify-assets-diff.patch"
  run_target "$dir" "$snapshot"
  local ok=0
  assert_exit 0 "スナップショット取得を含め正常終了する" || ok=1
  assert_contains "[OK] 増分diffスナップショットを保存しました: $snapshot" "スナップショット保存の成功が報告される" || ok=1
  if [ ! -f "$snapshot" ]; then
    echo "  NG: スナップショットファイルが作成されていない: $snapshot"
    ok=1
  else
    local content
    content="$(cat "$snapshot")"
    case "$content" in
      *'-v1'*'+v2'*) : ;;
      *) echo "  NG: 追跡ファイルの増分（v1→v2）がスナップショットに含まれない"; ok=1 ;;
    esac
    case "$content" in
      *'agents/new-agent.md'*) : ;;
      *) echo "  NG: 対象プレフィクスの未追跡ファイルがスナップショットに含まれない"; ok=1 ;;
    esac
    case "$content" in
      *'random-note.txt'*) echo "  NG: 対象プレフィクス外の未追跡ファイルが混入している"; ok=1 ;;
      *) : ;;
    esac
  fi
  return $ok
}

# ---- (追加) スナップショット保存先がシンボリックリンクの場合は書き込みを拒否する（qa M-R2-1） ----
# sec M-s1で新設したsymlinkガード（追従して書き込むと意図しない場所を上書きしうるため拒否する
# 分岐）に、これまで回帰テストが1件も無かった（CONTRIBUTING 8.4基準3「静かに失敗する
# ガードレール」の典型）。symlinkの参照先ファイルの内容が変化しないことまで確認する。

test_snapshot_symlink_target_is_rejected_and_untouched() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  git_init_and_commit "$dir"

  local link_dir dummy link
  link_dir="$(mktemp -d)"
  TMP_DIRS+=("$link_dir")
  dummy="$link_dir/dummy-do-not-overwrite.txt"
  printf 'original-content\n' > "$dummy"
  link="$link_dir/snapshot-symlink.patch"
  ln -s "$dummy" "$link"

  run_target "$dir" "$link"
  local ok=0
  assert_exit 1 "symlinkを保存先に指定した場合はexit 1（拒否）" || ok=1
  assert_contains '[FAIL]' "全体FAILと判定される" || ok=1
  assert_contains 'スナップショット保存先がシンボリックリンクです' "symlink拒否メッセージが表示される" || ok=1

  local after
  after="$(cat "$dummy")"
  if [ "$after" != 'original-content' ]; then
    echo "  NG: symlinkの参照先ファイルの内容が変化している（上書きされた）: '$after'"
    ok=1
  fi
  return $ok
}

# ---- git 管理下でない場合は検証のみでdiffスナップショットをスキップする ----

test_non_git_repo_skips_diff_snapshot() {
  new_case_dir; local dir="$NEW_CASE_DIR"
  write_validate_stub "$dir/.claude/scripts/validate.sh" 'ERROR: 0 件 / WARN: 0 件' 0
  # git init しない（非gitリポジトリのまま）。
  run_target "$dir"
  local ok=0
  assert_exit 0 "非gitリポジトリでも検証自体は正常終了する" || ok=1
  assert_contains 'git リポジトリではないため' "diffスナップショットのスキップが報告される" || ok=1
  assert_contains '[PASS]' "全体PASSと判定される" || ok=1
  return $ok
}

# ---- assertions.sh cleanup() の実行時ガード（issue #76 品質ゲートR1 sec参考・本案件で実際に
# 発生した/tmp巻き込み削除事故の再発防止）が機能することを、隔離したサブプロセスで直接確認する ----

test_cleanup_guard_rejects_tmp_root_and_keeps_real_subdirs() {
  local out
  out="$(
    bash -c '
      set -uo pipefail
      source "$1"
      dangerous_root="$2"
      safe_dir="$(mktemp -d)"
      : > "$safe_dir/marker"
      TMP_DIRS=("$dangerous_root" "$safe_dir")
      cleanup
      if [ -d "$dangerous_root" ]; then echo "DANGEROUS_ROOT_KEPT=1"; else echo "DANGEROUS_ROOT_KEPT=0"; fi
      if [ -d "$safe_dir" ]; then echo "SAFE_DIR_KEPT=1"; else echo "SAFE_DIR_KEPT=0"; fi
    ' _ "$ASSERTIONS_LIB" "${TMPDIR:-/tmp}" 2>&1
  )"
  local ok=0
  case "$out" in
    *'DANGEROUS_ROOT_KEPT=1'*) : ;;
    *) echo "  NG: tmpルート自身がcleanup()で削除されてしまう（危険。出力: $out）"; ok=1 ;;
  esac
  case "$out" in
    *'警告: cleanup() をスキップしました'*) : ;;
    *) echo "  NG: tmpルート拒否時の警告メッセージがstderrに出力されない（出力: $out）"; ok=1 ;;
  esac
  case "$out" in
    *'SAFE_DIR_KEPT=0'*) : ;;
    *) echo "  NG: 正規のmktemp -d由来ディレクトリが削除されない（回帰）（出力: $out）"; ok=1 ;;
  esac
  return $ok
}

# =============================================================================
# 実行
# =============================================================================

run_test test_prefers_claude_scripts_validate_sh
run_test test_falls_back_to_scripts_validate_sh
run_test test_plugin_repo_missing_validate_sh_is_fail
run_test test_user_repo_missing_validate_sh_is_skip_not_pass
run_test test_plugin_validate_missing_is_unverified_not_pass
run_test test_both_required_steps_skip_lists_both_names
run_test test_plugin_validate_failure_triggers_overall_fail
run_test test_parses_error_count_as_fail
run_test test_parses_warn_only_as_fail_even_if_exit_zero
run_test test_parses_zero_zero_as_pass
run_test test_falls_back_to_exit_code_when_summary_unparsable_success
run_test test_falls_back_to_exit_code_when_summary_unparsable_failure
run_test test_plugin_repo_with_validate_sh_present_is_not_forced_fail
run_test test_diff_snapshot_captures_tracked_and_asset_untracked
run_test test_snapshot_symlink_target_is_rejected_and_untouched
run_test test_non_git_repo_skips_diff_snapshot
run_test test_cleanup_guard_rejects_tmp_root_and_keeps_real_subdirs

finish_test_run
