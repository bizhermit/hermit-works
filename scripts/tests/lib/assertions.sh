#!/usr/bin/env bash
#
# scripts/tests/run-tests.sh と scripts/tests/run-git-changelog-tests.sh が共有する
# アサーションヘルパー・一時ディレクトリ管理・テスト集計ロジック（M16 是正）。
#
# 方針:
#   - 各ハーネスから `source` して使う前提のライブラリであり、単体で実行するものではない
#     （実行ビットは既存スクリプト群との統一のために付与しているのみ）。
#   - パス解決を一切持たない（BASH_SOURCE を使わない）。SCRIPT_DIR・REPO_ROOT・対象
#     スクリプトのパス・フィクスチャのパス等は、呼び出し側ハーネスがそれぞれ自前で
#     用意し、必要な変数（VALIDATE_SH 等）はハーネス側で定義してから利用すること。
#   - `set -e` はここでは設定しない。呼び出し側ハーネスが `set -uo pipefail` を敷いた
#     状態で source する前提とし、個々のテストケース内で対象コマンドの非ゼロ終了を
#     扱えるようにする（run-tests.sh / run-git-changelog-tests.sh 本体と同じ方針）。
#
# 提供するもの:
#   - LAST_OUTPUT / LAST_EXIT               : 直近実行したコマンドの出力・終了コード
#                                              （run_validate 等、呼び出し側の実行ヘルパー
#                                              が代入する。ハーネス側で運用する規約）
#   - assert_exit / assert_contains / assert_not_contains
#   - count_lines_containing / assert_line_count
#   - TMP_DIRS 配列 + cleanup() + trap        : 一時ディレクトリの後始末
#   - PASS_COUNT / FAIL_COUNT / FAILED_NAMES + run_test()
#   - finish_test_run()                       : 集計出力・偽合格ガード・exit判定
#

# ---------------------------------------------------------------------------
# 一時ディレクトリ管理
# ---------------------------------------------------------------------------

TMP_DIRS=()

cleanup() {
  local d
  for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# コマンド実行結果 & アサーション用ヘルパー
# ---------------------------------------------------------------------------

LAST_OUTPUT=""
LAST_EXIT=0

assert_exit() {
  local expected="$1" label="$2"
  if [ "$LAST_EXIT" != "$expected" ]; then
    echo "  NG: $label (期待exit=$expected, 実際exit=$LAST_EXIT)"
    return 1
  fi
  return 0
}

assert_contains() {
  local needle="$1" label="$2"
  case "$LAST_OUTPUT" in
    *"$needle"*) return 0 ;;
    *)
      echo "  NG: $label (出力に '$needle' が含まれない)"
      return 1
      ;;
  esac
}

assert_not_contains() {
  local needle="$1" label="$2"
  case "$LAST_OUTPUT" in
    *"$needle"*)
      echo "  NG: $label (出力に '$needle' が含まれてはいけない)"
      return 1
      ;;
    *) return 0 ;;
  esac
}

# LAST_OUTPUT中で $1 を含む行の件数を返す（重複ERROR混入がないことの確認用）。
count_lines_containing() {
  local needle="$1"
  printf '%s\n' "$LAST_OUTPUT" | grep -F -c -- "$needle"
}

assert_line_count() {
  local needle="$1" expected="$2" label="$3"
  local actual
  actual="$(count_lines_containing "$needle")"
  if [ "$actual" != "$expected" ]; then
    echo "  NG: $label ('$needle' を含む行数 期待=$expected 実際=$actual)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# テスト集計
# ---------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()

run_test() {
  local name="$1"
  echo "== $name =="
  if "$name"; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_NAMES+=("$name")
  fi
  echo
}

# 集計出力・偽合格ガード・exit判定をまとめて行う。呼び出し側ハーネスは全テストケースの
# run_test 呼び出しが終わった後に一度だけ呼ぶこと（このままスクリプトのexitまで行う）。
#
# 偽合格ガード: このlibのsource失敗やハーネス側の記述ミス等で run_test が一度も
# 呼ばれないままここに到達すると、PASS_COUNT=FAIL_COUNT=0 のまま集計出力を経て
# exit 0 してしまい、テストが実質何も実行されていないのに成功したように見える事故が
# 起きうる。集計出力の直前に実行ケース数（PASS_COUNT + FAIL_COUNT）が0でないことを
# 確認し、0であればエラーメッセージを出して異常終了する。
finish_test_run() {
  local total=$((PASS_COUNT + FAIL_COUNT))
  if [ "$total" -eq 0 ]; then
    echo "Error: 実行されたテストケースが0件です（ハーネスの実行手順を確認してください）" >&2
    exit 1
  fi

  echo '==================================================='
  echo "テスト結果: PASS ${PASS_COUNT} 件 / FAIL ${FAIL_COUNT} 件"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "失敗したテスト: ${FAILED_NAMES[*]}"
  fi
  echo '==================================================='

  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
}
