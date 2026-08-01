#!/usr/bin/env bash
#
# scripts/aggregate-agent-token-usage.sh の回帰テストハーネス。
#
# 方針:
#   - 外部ランタイム非依存（bash + POSIX標準ツールのみ。scripts/tests/run-tests.sh 等と同じ方針）。
#   - 実データ（~/.claude/projects/）は使わず、固定フィクスチャ
#     scripts/tests/fixtures/agent-token-usage/ に対して実行し、出力を検証する
#     （利用者の実トランスクリプトに依存させず再現性を確保するため）。
#   - フィクスチャは以下を意図的に含む最小構成:
#       - 同一 agentType の複数回委任の合算（hw:qa-review, 2件）
#       - usage の "iterations" 配列による二重計上が起きないことの確認
#         （フィールド順序が異なる2パターンを含む）
#       - agentType 欠落時の "(不明)" フォールバック
#       - 対応する .jsonl が存在しない meta.json（委任回数のみ計上され集計時に落ちないこと）
#       - usage 内の1フィールドが丸ごと欠落した行（欠落検知カウントの確認）
#     期待値は手計算し、各アサーションのコメントに算出根拠を記す。
#   - 一時ディレクトリは mktemp -d で作成し、trap で必ず削除する（lib/assertions.sh 側）。
#
# 実行方法:
#   bash scripts/tests/run-aggregate-agent-token-usage-tests.sh
#
# 終了コード: 全ケースPASSなら0、1件でもFAILがあれば1。
#
set -uo pipefail
# 注意: -e は使わない（run-tests.sh 同様、個々のテストケース内で対象スクリプトの
# 非ゼロ終了を扱うため）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SH="$REPO_ROOT/scripts/aggregate-agent-token-usage.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/agent-token-usage"
ASSERTIONS_LIB="$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$TARGET_SH" ]; then
  echo "Error: aggregate-agent-token-usage.sh が見つかりません: $TARGET_SH" >&2
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

# アサーションヘルパー・一時ディレクトリ管理（TMP_DIRS/cleanup/trap）・テスト集計
# （PASS_COUNT/FAIL_COUNT/run_test/finish_test_run）は
# scripts/tests/run-tests.sh / run-git-changelog-tests.sh と共通のため lib へ切り出し済み。
source "$ASSERTIONS_LIB"

run_target() {
  local dir="$1"
  LAST_OUTPUT="$(bash "$TARGET_SH" "$dir" 2>&1)"
  LAST_EXIT=$?
}

# ---------------------------------------------------------------------------
# テストケース
# ---------------------------------------------------------------------------

test_nonexistent_dir_exits_zero() {
  run_target "$FIXTURE_DIR/does-not-exist-xyz"
  assert_exit 0 "対象ディレクトリ不在でも exit 0" || return 1
  assert_contains "対象0件" "対象0件の旨を出力" || return 1
  return 0
}

test_empty_dir_exits_zero() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  run_target "$d"
  assert_exit 0 "空ディレクトリでも exit 0" || return 1
  assert_contains "検出されませんでした" "委任0件を明示" || return 1
  return 0
}

test_real_fixture_exits_zero() {
  run_target "$FIXTURE_DIR"
  assert_exit 0 "実フィクスチャで exit 0" || return 1
  return 0
}

# 委任回数: agent-001.meta.json / agent-002.meta.json が共に agentType="hw:qa-review" のため
# 委任回数は2件になるはず。
test_delegation_count_aggregates_same_agent_type() {
  run_target "$FIXTURE_DIR"
  case "$LAST_OUTPUT" in
    *"hw:qa-review"*"2"*) : ;;
    *)
      echo "  NG: hw:qa-review の行に委任回数2が見当たらない"
      return 1
      ;;
  esac
  return 0
}

# agent-004.meta.json は agentType フィールドを持たないため "(不明)" にフォールバックする。
test_missing_agent_type_falls_back_to_fuumei() {
  run_target "$FIXTURE_DIR"
  assert_contains "(不明)" "agentType欠落時に(不明)へフォールバック" || return 1
  return 0
}

# agent-005 は対応する .jsonl が無い委任。委任回数には数えるがトークン集計はクラッシュせず
# 0のまま出力されるはず（"hw:no-jsonl" の行自体が出力されること、かつ exit 0 であること）。
test_meta_without_jsonl_does_not_crash() {
  run_target "$FIXTURE_DIR"
  assert_exit 0 "対応jsonl無しの委任があっても exit 0" || return 1
  assert_contains "hw:no-jsonl" "jsonl無し委任も委任回数として計上" || return 1
  return 0
}

# hw:qa-review (agent-001+agent-002) の手計算値:
#   input  = (100+5) + 1000 = 1105
#   output = (200+6) + 2000 = 2206
#   cache_creation = (300+7) + 0 = 307
#   cache_read     = (400+8) + 0 = 408
# いずれも agent-001 側は "iterations" 配列に同名フィールドが再掲されているため、
# 二重計上されていればこれらの値より大きくなる。
test_iterations_duplicate_fields_are_not_double_counted() {
  run_target "$FIXTURE_DIR"
  assert_contains "1105" "hw:qa-review input合算値(1105)がiterations二重計上なく一致" || return 1
  assert_contains "2206" "hw:qa-review output合算値(2206)がiterations二重計上なく一致" || return 1
  assert_contains "307" "hw:qa-review cache_creation合算値(307)がiterations二重計上なく一致" || return 1
  assert_contains "408" "hw:qa-review cache_read合算値(408)がiterations二重計上なく一致" || return 1
  return 0
}

# agent-003.jsonl は output_tokens フィールドを丸ごと持たない行のため、欠落検知が1件
# 記録され、注意文が出力されるはず。
test_missing_field_triggers_warning() {
  run_target "$FIXTURE_DIR"
  assert_contains "欠落" "フィールド欠落時に注意文を出力" || return 1
  assert_contains "1 件あります" "欠落件数1件が出力される" || return 1
  return 0
}

# トップレベルセッション(project-a/sess1.jsonl)の手計算値:
#   input=1+10=11, output=2+20=22, cache_creation=3+30=33, cache_read=4+40=44
# （2行目は iterations 配列に同名フィールドを持つが二重計上されない前提）。
test_toplevel_session_aggregation() {
  run_target "$FIXTURE_DIR"
  assert_contains "(トップレベル)" "トップレベル行を出力" || return 1
  assert_contains "11" "トップレベルinput合算値(11)" || return 1
  return 0
}

# キャッシュヒット率 = cache_read ÷ (input + cache_creation + cache_read) の手計算値
# （通常ケース。分母>0）:
#   hw:qa-review: cache_read=408, 分母=1105+307+408=1820 → 408/1820*100=22.417...% → 22.4%
#   hw:sec-audit: cache_read=70,  分母=50+60+70=180     → 70/180*100=38.888...%  → 38.9%
#   (トップレベル): cache_read=44, 分母=11+33+44=88      → 44/88*100=50.0%         → 50.0%
test_cache_hit_rate_normal_case() {
  run_target "$FIXTURE_DIR"
  assert_contains "22.4%" "hw:qa-reviewのキャッシュヒット率(22.4%)" || return 1
  assert_contains "38.9%" "hw:sec-auditのキャッシュヒット率(38.9%)" || return 1
  assert_contains "50.0%" "トップレベルのキャッシュヒット率(50.0%)" || return 1
  return 0
}

# hw:no-jsonl(agent-005) は対応する.jsonlが無いため input/cache_creation/cache_read が
# すべて0となり、分母(=input+cache_creation+cache_read)も0になる。この場合は0除算せず
# "-" を出力する仕様の確認（分母0ケース）。
test_cache_hit_rate_zero_denominator_shows_dash() {
  local line last_field
  run_target "$FIXTURE_DIR"
  line="$(printf '%s\n' "$LAST_OUTPUT" | grep 'hw:no-jsonl')"
  if [ -z "$line" ]; then
    echo "  NG: hw:no-jsonl の行が出力に見当たらない"
    return 1
  fi
  last_field="$(printf '%s\n' "$line" | awk '{print $NF}')"
  if [ "$last_field" != "-" ]; then
    echo "  NG: hw:no-jsonl の行の最終列（キャッシュヒット率）が '-' ではない（実際: '$last_field'）"
    return 1
  fi
  return 0
}

# --output-の-秘密情報漏出ガード: フィクスチャにもし本文相当の識別子(toolUseId等)を
# 埋めていても、それらは出力に含まれないはず（集計値・エージェント種別・パスのみ出力する設計）。
test_output_does_not_leak_transcript_internal_ids() {
  run_target "$FIXTURE_DIR"
  assert_not_contains "toolu_fixture" "meta.json内部のtoolUseIdが出力に漏れていない" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------

run_test test_nonexistent_dir_exits_zero
run_test test_empty_dir_exits_zero
run_test test_real_fixture_exits_zero
run_test test_delegation_count_aggregates_same_agent_type
run_test test_missing_agent_type_falls_back_to_fuumei
run_test test_meta_without_jsonl_does_not_crash
run_test test_iterations_duplicate_fields_are_not_double_counted
run_test test_missing_field_triggers_warning
run_test test_toplevel_session_aggregation
run_test test_cache_hit_rate_normal_case
run_test test_cache_hit_rate_zero_denominator_shows_dash
run_test test_output_does_not_leak_transcript_internal_ids

finish_test_run
