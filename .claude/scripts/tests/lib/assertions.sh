#!/usr/bin/env bash
#
# .claude/scripts/tests/run-tests.sh と .claude/scripts/tests/run-git-changelog-tests.sh が共有する
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

# cleanup(): TMP_DIRS に積まれた各パスを rm -rf する。
#
# 実行時ガード（issue #76 品質ゲートR1 sec参考指摘・統括裁定で追加）:
#   本案件の回帰テスト作成中に、TMP_DIRS へ「mktemp -d の戻り値そのもの」ではなく
#   派生パス（`"$dir-snapshot.patch"` のdirname）を誤って積んでしまい、その値が
#   tmpルート（/tmp）そのものに化けて `rm -rf /tmp` 相当を実行しかけた事故が実際に起きた。
#   それまでの安全性は「TMP_DIRSに積む値は必ずmktemp -d由来」という規律のみに依存しており、
#   技術的な歯止めがなかった。以後は rm -rf の直前に、対象パスが tmp ルート
#   （${TMPDIR:-/tmp}）の直下より深い場所（tmpルート自身ではない）であることを確認し、
#   外れる場合は削除をスキップして警告を stderr に出す。
#   本ライブラリは全ハーネス（5章列挙）が共有するため、本ガードの変更は全ハーネスに影響する
#   （CONTRIBUTING 8.4「.claude/scripts/tests/lib/ 配下の変更は…5章に列挙された全ハーネスを
#   実行して確認する」）。
#
# パス正規化（issue #76 品質ゲートR2 sec M2是正）:
#   上記ガードを `case` によるレキシカル前方一致のみで実装すると、`..` を含む派生パス
#   （例: `/tmp/../etc`）を「tmpルート配下でない」と誤って安全側に倒せず、逆に
#   「tmpルート配下」と誤判定して通してしまう（文字列上は `/tmp/` で始まらないため実際には
#   拒否されるが、`/tmp/foo/../../etc` のように一見tmpルート配下に見える形で拒否をすり抜ける
#   ケースが実機で確認されている）。加えて、中間コンポーネントがsymlinkの場合、`rm -rf` は
#   カーネルのパス解決に従いリンク先の中身を実際に削除してしまう（最終コンポーネントが
#   symlinkの場合はリンク自体のunlinkのみで安全だが、中間symlinkは危険）。そのため、
#   rm -rf の直前に `cd "$d" && pwd -P` 相当で実体パスへ正規化してから判定する
#   （`pwd -P` はsymlinkも解決するため、`..`混入・中間symlink経由の混入を同時に弾ける）。
#   比較基準となる tmp_root 側も同様に正規化する（TMPDIR自体がsymlinkを含む環境で
#   基準とズレて全件を誤ってスキップし、一時ディレクトリが残留する事故を避けるため）。
#   正規化に失敗した場合（cd不可等）は基準・対象のいずれであっても安全側（削除しない）に倒す。
cleanup() {
  local d tmp_root tmp_root_real d_real
  tmp_root="${TMPDIR:-/tmp}"
  tmp_root_real="$(cd "$tmp_root" 2>/dev/null && pwd -P)"
  for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    if [ -z "$tmp_root_real" ]; then
      echo "警告: cleanup() をスキップしました。tmpルート（$tmp_root）の正規化に失敗したため、安全のため'$d' を削除しません。" >&2
      continue
    fi
    d_real="$(cd "$d" 2>/dev/null && pwd -P)"
    if [ -z "$d_real" ]; then
      echo "警告: cleanup() をスキップしました。'$d' の正規化に失敗したため、安全のため削除しません。" >&2
      continue
    fi
    case "$d_real" in
      "$tmp_root_real"/?*)
        rm -rf "$d"
        ;;
      *)
        echo "警告: cleanup() をスキップしました。'$d'（正規化後: $d_real）はtmpルート（正規化後: $tmp_root_real）配下の想定パスではありません（安全のため削除しません。TMP_DIRSへ積む値はmktemp -dの戻り値そのものにしてください）。" >&2
        ;;
    esac
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
