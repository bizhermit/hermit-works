#!/usr/bin/env bash
#
# .claude/scripts/close-linked-issues.sh の回帰テストハーネス。
#
# 方針:
#   - 外部ランタイム非依存（bash + POSIX標準ツール + git のみ）。他ハーネスと同じ方針を踏襲する。
#   - アサーション・一時ディレクトリ管理・テスト集計は .claude/scripts/tests/lib/assertions.sh を
#     source して使う（ハーネスごとの再実装をしない。CONTRIBUTING 8.4）。
#   - 対象スクリプトは gh CLI 経由で GitHub と通信するため、テストでは gh のスタブを
#     一時ディレクトリに作り PATH の先頭へ差し込む。実際の GitHub へは一切アクセスしない
#     （ネットワーク非依存・副作用なし）。スタブの応答は環境変数で与える:
#       STUB_PR_META   : "<state>\t<baseRefName>\t<isCrossRepository>" 相当の3項目（タブ区切り）
#       STUB_PR_BODY_FILE : PR 本文として返すフィクスチャファイルのパス
#       STUB_ISSUES    : "<番号>:<state>:<issue|pr>" を空白区切りで並べたもの（未列挙は取得失敗）
#       STUB_FAIL_PATCH: この番号の PATCH を失敗させる（省略時はすべて成功）
#       STUB_CALL_LOG  : 書き込み系 API 呼び出しの記録先ファイル
#   - PR 本文のフィクスチャは .claude/scripts/tests/fixtures/close-linked-issues/ に置く（8.4）。
#
# 実行方法:
#   bash .claude/scripts/tests/run-close-linked-issues-tests.sh
#
# 終了コード: 全ケースPASSなら0、1件でもFAILがあれば1。
#
set -uo pipefail
# 注意: -e は使わない（他ハーネス同様、個々のテストケース内で非ゼロ終了を扱うため）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET_SH="$REPO_ROOT/.claude/scripts/close-linked-issues.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/close-linked-issues"
ASSERTIONS_LIB="$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$TARGET_SH" ]; then
  echo "Error: close-linked-issues.sh が見つかりません: $TARGET_SH" >&2
  exit 1
fi
if [ ! -d "$FIXTURE_DIR" ]; then
  echo "Error: フィクスチャが見つかりません: $FIXTURE_DIR" >&2
  exit 1
fi
if [ ! -f "$ASSERTIONS_LIB" ]; then
  echo "Error: assertions.sh が見つかりません: $ASSERTIONS_LIB" >&2
  exit 1
fi

source "$ASSERTIONS_LIB"

# ---------------------------------------------------------------------------
# gh スタブ・実行ヘルパー
# ---------------------------------------------------------------------------

STUB_DIR="$(mktemp -d)"
TMP_DIRS+=("$STUB_DIR")
CALL_LOG="$STUB_DIR/calls.log"

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# テスト用 gh スタブ（.claude/scripts/tests/run-close-linked-issues-tests.sh 専用）。
set -uo pipefail

log_call() {
  [ -n "${STUB_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_CALL_LOG"
  return 0
}

# gh repo view --json nameWithOwner --jq .nameWithOwner
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  printf '%s\n' "bizhermit/hermit-works"
  exit 0
fi

# gh pr view <n> --json ...
# 本物の gh は未知の --json フィールドをエラーにするため、スタブも想定した2種類の呼び出し以外は
# 失敗させる（スタブが寛容だと、実在しないフィールド名の指定をテストが見逃す。2026-08-05 に
# `--json merged`（実在しない）を実機で初めて検知した反省による）。
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *"--json body"*)
      cat "${STUB_PR_BODY_FILE}"
      exit 0
      ;;
    *"--json state,baseRefName,isCrossRepository"*)
      printf '%s\n' "${STUB_PR_META}"
      exit 0
      ;;
    *)
      echo "stub: Unknown JSON field in: $*" >&2
      exit 1
      ;;
  esac
fi

if [ "${1:-}" = "api" ]; then
  # 書き込み系: gh api --method PATCH|POST <path> ...
  if [ "${2:-}" = "--method" ]; then
    method="${3:-}"
    path="${4:-}"
    number="${path##*/issues/}"
    number="${number%%/*}"
    if [ "$method" = "PATCH" ] && [ -n "${STUB_FAIL_PATCH:-}" ] && [ "$number" = "${STUB_FAIL_PATCH}" ]; then
      log_call "FAIL PATCH $number"
      exit 1
    fi
    log_call "$method $path"
    exit 0
  fi
  # 読み取り系: gh api repos/<owner>/<repo>/issues/<n> --jq ...
  path="${2:-}"
  number="${path##*/issues/}"
  for entry in ${STUB_ISSUES:-}; do
    n="${entry%%:*}"
    rest="${entry#*:}"
    state="${rest%%:*}"
    kind="${rest#*:}"
    if [ "$n" = "$number" ]; then
      printf '%s\t%s\n' "$state" "$kind"
      exit 0
    fi
  done
  exit 1
fi

echo "stub: unsupported gh invocation: $*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

# 既定値（各ケースで上書きする）
DEFAULT_META="$(printf 'MERGED\tdevelop\tfalse')"

run_target() {
  # 使い方: run_target <body-fixture> <issues指定> [追加引数...]
  # 標準入力は必ず /dev/null に固定する。固定しないと、対話端末から本ハーネスを直接実行した
  # 場合に対象スクリプトの `-t 0` 判定が真になり、`--apply` の y/N 確認で入力待ちに入って
  # テスト全体が停止する（コマンド置換の中で read するため無応答になる）。
  local body_file="$1" issues="$2"
  shift 2
  : > "$CALL_LOG"
  LAST_OUTPUT="$(
    cd "$REPO_ROOT" && \
    PATH="$STUB_DIR:$PATH" \
    STUB_PR_META="${STUB_META_OVERRIDE:-$DEFAULT_META}" \
    STUB_PR_BODY_FILE="$FIXTURE_DIR/$body_file" \
    STUB_ISSUES="$issues" \
    STUB_FAIL_PATCH="${STUB_FAIL_PATCH_OVERRIDE:-}" \
    STUB_CALL_LOG="$CALL_LOG" \
    bash "$TARGET_SH" "$@" < /dev/null 2>&1
  )"
  LAST_EXIT=$?
}

call_log_content() {
  cat "$CALL_LOG" 2>/dev/null
}

assert_no_write_calls() {
  local label="$1"
  if [ -s "$CALL_LOG" ]; then
    echo "  NG: $label (書き込み系 API が呼ばれてはいけない: $(call_log_content | tr '\n' ' '))"
    return 1
  fi
  return 0
}

assert_call_log_contains() {
  local needle="$1" label="$2"
  if ! call_log_content | grep -qF -- "$needle"; then
    echo "  NG: $label (呼び出しログに '$needle' が含まれない: $(call_log_content | tr '\n' ' '))"
    return 1
  fi
  return 0
}

assert_call_log_not_contains() {
  local needle="$1" label="$2"
  if call_log_content | grep -qF -- "$needle"; then
    echo "  NG: $label (呼び出しログに '$needle' が含まれてはいけない)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# テストケース
# ---------------------------------------------------------------------------

test_basic_dry_run() {
  run_target pr-basic.md "50:open:issue" 62
  assert_exit 0 "dry-run は正常終了する" || return 1
  assert_contains "- #50" "抽出した issue を表示する" || return 1
  assert_contains "[dry-run]" "dry-run である旨を表示する" || return 1
  assert_no_write_calls "dry-run では書き込まない" || return 1
}

test_keyword_variants() {
  run_target pr-variants.md "11:open:issue 12:open:issue 13:open:issue 14:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "- #11" "Fixes を拾う" || return 1
  assert_contains "- #12" "RESOLVED（大文字）を拾う" || return 1
  assert_contains "- #13" "closed: 形式を拾う" || return 1
  assert_contains "- #14" "Close を拾う" || return 1
}

test_ignores_code_quote_and_other_repo() {
  run_target pr-noise.md "20:open:issue 901:open:issue 902:open:issue 903:open:issue 904:open:issue 905:open:issue 906:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "- #20" "通常の参照は拾う" || return 1
  assert_not_contains "#901" "コードブロック内は拾わない" || return 1
  assert_not_contains "#902" "引用行は拾わない" || return 1
  assert_not_contains "#903" "インラインコードは拾わない" || return 1
  assert_not_contains "#904" "他リポジトリ参照は拾わない" || return 1
  assert_not_contains "#905" "キーワードのない言及は拾わない" || return 1
}

test_nested_fence_is_excluded() {
  # 4個のバッククォートで開いたフェンス内に3個の入れ子例を書いても、フェンス内の参照は
  # 拾わない（フェンス長を見ずにトグルすると #999 を誤抽出する。sec-audit F1）。
  run_target pr-nested-fence.md "50:open:issue 999:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "- #50" "フェンス外の参照は拾う" || return 1
  assert_not_contains "#999" "入れ子フェンス内は拾わない" || return 1
}

test_unclosed_fence_warns() {
  run_target pr-unclosed-fence.md "55:open:issue 998:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "コードフェンスが閉じられていません" "閉じ忘れを警告する" || return 1
  assert_not_contains "#998" "フェンス内は拾わない" || return 1
  assert_not_contains "- #55" "閉じ忘れ以降は抽出対象外（安全側に倒す）" || return 1
}

test_hyphenated_word_is_not_matched() {
  # `auto-closes #40` のようなハイフン複合語をキーワードとして拾わない（qa L-1）。
  run_target pr-hyphen.md "40:open:issue 60:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "- #60" "通常の参照は拾う" || return 1
  assert_not_contains "#40" "ハイフン複合語は拾わない" || return 1
}

test_word_boundary_prefixes() {
  # キーワードの直前が単語構成文字（数字・英字・アンダースコア）またはハイフンの場合は
  # 参照として扱わない（sec-audit 2巡目の新規指摘。`2closes` / `x_closes` / `auto-closes`）。
  run_target pr-word-boundary.md "40:open:issue 50:open:issue 998:open:issue 999:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "- #50" "通常の参照は拾う" || return 1
  assert_not_contains "#999" "数字直後の連結は拾わない" || return 1
  assert_not_contains "#998" "アンダースコア直後の連結は拾わない" || return 1
  assert_not_contains "#40" "ハイフン複合語は拾わない" || return 1
}

test_help_option() {
  run_target pr-basic.md "50:open:issue" --help
  assert_exit 0 "ヘルプは正常終了する" || return 1
  assert_contains "Usage:" "使い方を表示する" || return 1
}

test_apply_requires_confirmation_when_non_interactive() {
  # 非対話実行（テストは常に非 TTY）で --yes を付けない場合は、確認が取れないため中止する。
  run_target pr-basic.md "50:open:issue" 62 --apply
  assert_exit 1 "確認できない場合は失敗する" || return 1
  assert_contains "--yes" "対処方法を示す" || return 1
  assert_no_write_calls "書き込まない" || return 1
}

test_duplicate_references_are_deduped() {
  run_target pr-duplicate.md "30:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_line_count "  - #30" 1 "重複参照は1件に集約する" || return 1
}

test_no_keyword() {
  run_target pr-nokeyword.md "40:open:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "見つかりませんでした" "対象なしを明示する" || return 1
  assert_no_write_calls "書き込まない" || return 1
}

test_skips_pull_request_reference() {
  run_target pr-prref.md "50:open:issue 62:open:pr" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "- #50" "issue は対象にする" || return 1
  assert_contains "スキップ: #62" "PR 番号への参照はスキップする" || return 1
}

test_skips_closed_issue() {
  run_target pr-closed-issue.md "51:closed:issue" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "スキップ: #51" "クローズ済みはスキップする" || return 1
  assert_contains "クローズ対象の issue はありません" "対象なしを明示する" || return 1
}

test_skips_unknown_reference() {
  run_target pr-basic.md "" 62
  assert_exit 0 "正常終了する" || return 1
  assert_contains "スキップ: #50" "取得できない参照はスキップする" || return 1
}

test_rejects_unmerged_pr() {
  STUB_META_OVERRIDE="$(printf 'OPEN\tdevelop\tfalse')"
  run_target pr-basic.md "50:open:issue" 62
  STUB_META_OVERRIDE=""
  assert_exit 1 "未マージ PR は失敗する" || return 1
  assert_contains "マージされていません" "理由を表示する" || return 1
  assert_no_write_calls "書き込まない" || return 1
}

test_rejects_non_develop_base() {
  STUB_META_OVERRIDE="$(printf 'MERGED\tmain\tfalse')"
  run_target pr-basic.md "50:open:issue" 62
  STUB_META_OVERRIDE=""
  assert_exit 1 "base が develop 以外は失敗する" || return 1
  assert_contains "base が develop ではありません" "理由を表示する" || return 1
  assert_no_write_calls "書き込まない" || return 1
}

test_rejects_fork_pr() {
  STUB_META_OVERRIDE="$(printf 'MERGED\tdevelop\ttrue')"
  run_target pr-basic.md "50:open:issue" 62
  STUB_META_OVERRIDE=""
  assert_exit 1 "fork からの PR は失敗する" || return 1
  assert_contains "fork" "理由を表示する" || return 1
  assert_no_write_calls "書き込まない" || return 1
}

test_rejects_over_limit() {
  run_target pr-overlimit.md "201:open:issue" 62
  assert_exit 1 "上限超過は失敗する" || return 1
  assert_contains "想定上限" "理由を表示する" || return 1
  assert_no_write_calls "1件も操作しない" || return 1
}

test_rejects_invalid_arguments() {
  run_target pr-basic.md "50:open:issue"
  assert_exit 1 "PR 番号未指定は失敗する" || return 1
  assert_contains "PR 番号を指定してください" "理由を表示する" || return 1

  run_target pr-basic.md "50:open:issue" "62x"
  assert_exit 1 "非数値の PR 番号は失敗する" || return 1
  assert_contains "数字で指定してください" "理由を表示する" || return 1

  run_target pr-basic.md "50:open:issue" 62 --unknown
  assert_exit 1 "不明なオプションは失敗する" || return 1
}

test_apply_closes_and_comments() {
  run_target pr-basic.md "50:open:issue" 62 --apply --yes
  assert_exit 0 "正常終了する" || return 1
  assert_contains "クローズ完了: 1 件" "件数を集計する" || return 1
  assert_call_log_contains "PATCH repos/bizhermit/hermit-works/issues/50" "クローズを実行する" || return 1
  assert_call_log_contains "POST repos/bizhermit/hermit-works/issues/50/comments" "定型コメントを投稿する" || return 1
}

test_apply_no_comment() {
  run_target pr-basic.md "50:open:issue" 62 --apply --yes --no-comment
  assert_exit 0 "正常終了する" || return 1
  assert_call_log_contains "PATCH repos/bizhermit/hermit-works/issues/50" "クローズを実行する" || return 1
  assert_call_log_not_contains "POST" "コメントを投稿しない" || return 1
}

test_apply_continues_after_failure() {
  STUB_FAIL_PATCH_OVERRIDE="11"
  run_target pr-variants.md "11:open:issue 12:open:issue 13:open:issue 14:open:issue" 62 --apply --yes
  STUB_FAIL_PATCH_OVERRIDE=""
  assert_exit 1 "失敗があれば異常終了する" || return 1
  assert_contains "クローズ完了: 3 件 / 失敗: 1 件" "成功・失敗を集計する" || return 1
  assert_call_log_contains "PATCH repos/bizhermit/hermit-works/issues/12" "失敗後も残りを処理する" || return 1
  assert_call_log_not_contains "POST repos/bizhermit/hermit-works/issues/11/comments" \
    "クローズ失敗した issue にはコメントしない" || return 1
}

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------

STUB_META_OVERRIDE=""
STUB_FAIL_PATCH_OVERRIDE=""

run_test test_basic_dry_run
run_test test_keyword_variants
run_test test_ignores_code_quote_and_other_repo
run_test test_nested_fence_is_excluded
run_test test_unclosed_fence_warns
run_test test_hyphenated_word_is_not_matched
run_test test_word_boundary_prefixes
run_test test_help_option
run_test test_apply_requires_confirmation_when_non_interactive
run_test test_duplicate_references_are_deduped
run_test test_no_keyword
run_test test_skips_pull_request_reference
run_test test_skips_closed_issue
run_test test_skips_unknown_reference
run_test test_rejects_unmerged_pr
run_test test_rejects_non_develop_base
run_test test_rejects_fork_pr
run_test test_rejects_over_limit
run_test test_rejects_invalid_arguments
run_test test_apply_closes_and_comments
run_test test_apply_no_comment
run_test test_apply_continues_after_failure

finish_test_run
