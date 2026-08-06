#!/usr/bin/env bash
#
# git履歴から、前回リリース（または任意の起点）以降の変更一覧を Conventional Commits の
# 種別（feat/fix/docs/...）ごとに整形して出力する軽量スクリプト。
#
# 用途:
#   hermit-works 内で繰り返し発生する「git 履歴の変更一覧整形」を、都度アドホックに
#   re実装しないための共通スクリプト（定型作業はスクリプト/skill化する方針。
#   CONTRIBUTING.md 参照）。主な利用箇所:
#     - mgmt-release（リリースマネージャー）のリリース準備作業での変更一覧作成
#     - /hw:standup（スタンドアップ）での「前回レポート以降の変化」の把握
#       （commands/standup.md は本トラック(トラックC)の編集対象外のため未接続。
#       接続は別途 docs-tech / mgmt-pm 側での対応を想定）
#
# 対象範囲:
#   モノレポでの利用を想定し、第3引数以降（-- の後）でパスを指定すると、そのパス配下の
#   変更のみに絞り込める（例: 特定プロジェクトのリリースノート作成時）。
#
# 分類方法:
#   コミット件名の先頭が "<type>: " または "<type>(<scope>): " / "<type>!: "
#   （Conventional Commits）に一致するものは種別ごとにグルーピングする。
#   一致しないものは「その他」にまとめる。本リポジトリの既存コミット履歴（git log 参照）が
#   feat:/fix:/docs: 等の記法を採用しているため、この規約に合わせている。
#
# 実行例:
#   # 直前のタグから現在(HEAD)までの変更一覧（タグが無ければ全履歴）
#   bash .claude/scripts/git-changelog.sh
#
#   # 起点・終点を明示的に指定
#   bash .claude/scripts/git-changelog.sh v1.2.0 HEAD
#
#   # 特定プロジェクト配下の変更のみに絞り込む（モノレポでのプロジェクト別リリース向け）
#   bash .claude/scripts/git-changelog.sh v1.2.0 HEAD -- services/billing
#
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: $REPO_ROOT は git リポジトリではありません。" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 引数解析: 位置引数（from-ref, to-ref） + '--' 以降はパス指定（複数可）
# ---------------------------------------------------------------------------

FROM_REF=""
TO_REF="HEAD"
PATHS=()

positional=()
i=0
args=("$@")
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  if [ "$a" = "--" ]; then
    i=$((i + 1))
    while [ "$i" -lt "${#args[@]}" ]; do
      PATHS+=("${args[$i]}")
      i=$((i + 1))
    done
    break
  fi
  positional+=("$a")
  i=$((i + 1))
done

if [ "${#positional[@]}" -ge 1 ]; then FROM_REF="${positional[0]}"; fi
if [ "${#positional[@]}" -ge 2 ]; then TO_REF="${positional[1]}"; fi

if [ -z "$FROM_REF" ]; then
  # 直前のタグを起点にする。タグが無ければ全履歴（FROM_REF空のまま）を対象にする。
  FROM_REF="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
fi

# FROM_REF/TO_REF が `-` で始まる値の場合、後段の `git log` にオプションとして誤解釈
# されるおそれがあるため拒否する（git-cleanup-branch.sh の is_safe_branch_name と同様の
# 防御。空文字列は上記の自動検出フォールバックのため引き続き許容する）。
reject_dash_prefixed_ref() {
  local label="$1" value="$2"
  case "$value" in
    -*)
      echo "Error: ${label} に '-' で始まる値は指定できません: ${value}" >&2
      exit 1
      ;;
  esac
}
reject_dash_prefixed_ref "FROM_REF" "$FROM_REF"
reject_dash_prefixed_ref "TO_REF" "$TO_REF"

RANGE="$TO_REF"
if [ -n "$FROM_REF" ]; then
  RANGE="${FROM_REF}..${TO_REF}"
fi

# ---------------------------------------------------------------------------
# git log 取得（1行1コミット、"<hash>\t<date>\t<subject>" 形式）
# ---------------------------------------------------------------------------

# git log の終了コードを検査する。存在しないref/範囲指定などで失敗した場合に、
# それを握りつぶして「対象範囲に変更コミットはありません」という誤った成功メッセージ
# （exit 0）を出さないよう、ここでエラーを検出してexit 1する
# （2>&1で標準エラーもLOG_OUTPUTに含めて診断に使う。失敗時のみ出力する）。
if ! LOG_OUTPUT="$(git -C "$REPO_ROOT" log --no-merges --date=short --pretty=format:'%h%x09%ad%x09%s' "$RANGE" -- "${PATHS[@]}" 2>&1)"; then
  echo "Error: git log の実行に失敗しました。範囲指定 '${RANGE}' を確認してください。" >&2
  if [ -n "$LOG_OUTPUT" ]; then
    echo "$LOG_OUTPUT" >&2
  fi
  exit 1
fi

if [ -z "$LOG_OUTPUT" ]; then
  echo "対象範囲に変更コミットはありません（範囲: ${RANGE}）。"
  exit 0
fi

# Conventional Commits の既定タイプ（本リポジトリの実績に基づく想定リスト。
# このリストに無い type を使ったコミットは「その他」に分類されるだけで、ERRORにはならない）。
TYPES="feat fix refactor perf docs style test build ci chore revert"

declare -A BUCKET=()
OTHER=""
TOTAL=0

# 注意: [[ =~ ]] の右辺（正規表現）はリテラルで書くと丸括弧の扱いをめぐって
# bashのパーサがシンタックスエラーを起こすことがあるため、いったん変数に格納してから
# 展開する（bashのよくある落とし穴）。
CONVENTIONAL_COMMIT_PATTERN='^([A-Za-z]+)(\([^)]*\))?!?:[[:space:]](.*)$'

while IFS=$'\t' read -r hash date subject; do
  [ -z "$hash" ] && continue
  TOTAL=$((TOTAL + 1))
  matched=0
  if [[ "$subject" =~ $CONVENTIONAL_COMMIT_PATTERN ]]; then
    type_raw="${BASH_REMATCH[1]}"
    type_lc="$(printf '%s' "$type_raw" | tr '[:upper:]' '[:lower:]')"
    for t in $TYPES; do
      if [ "$t" = "$type_lc" ]; then
        BUCKET["$type_lc"]+="- \`${hash}\` ${date} ${subject}"$'\n'
        matched=1
        break
      fi
    done
  fi
  if [ "$matched" -eq 0 ]; then
    OTHER+="- \`${hash}\` ${date} ${subject}"$'\n'
  fi
done <<< "$LOG_OUTPUT"

echo "## 変更一覧（範囲: ${RANGE}、コミット数: ${TOTAL}）"
echo

for t in $TYPES; do
  if [ -n "${BUCKET[$t]+x}" ]; then
    echo "### ${t}"
    printf '%s' "${BUCKET[$t]}"
    echo
  fi
done

if [ -n "$OTHER" ]; then
  echo "### その他"
  printf '%s' "$OTHER"
  echo
fi
