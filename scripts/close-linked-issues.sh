#!/usr/bin/env bash
#
# develop へマージ済みの PR に紐づく issue（PR 本文の Closes/Fixes/Resolves 参照）を抽出し、
# 確認のうえクローズする。案件完了時の手動クローズ作業（対象の洗い出し・取り違えの確認・
# 定型コメント投稿・クローズ）を1コマンドにまとめるためのもの。
#
# なぜ CI ではなくスクリプトなのか:
#   GitHub の closing キーワード（Closes #n 等）は、PR が既定ブランチ（本リポジトリでは main）
#   を対象とする場合にのみ解釈される。既定ブランチ以外を対象とする PR ではキーワードは無視され、
#   **リンク自体が作成されない**（GitHub 公式ドキュメント「Linking a pull request to an issue」）。
#   本リポジトリの案件は develop 向け PR で統合するため、GitHub 標準の自動クローズも、
#   GraphQL の closingIssuesReferences を用いた CI での自動化も成立しない（実データでも
#   PR #62 の closingIssuesReferences が空であることを確認済み。判断記録は .hw/decisions.md
#   2026-08-05 行）。そのため自動発火はあきらめ、手動クローズ運用を維持したうえで、
#   その作業自体をスクリプト化する方針を採った。
#
# 実行例:
#   bash scripts/close-linked-issues.sh 62              # dry-run（既定。何も変更しない）
#   bash scripts/close-linked-issues.sh 62 --apply      # 対象を表示し y/N 確認のうえクローズ
#   bash scripts/close-linked-issues.sh 62 --apply --yes # 確認を省略（非対話実行時は必須）
#   bash scripts/close-linked-issues.sh 62 --apply --yes --no-comment  # コメントを投稿しない
#
# 前提: gh CLI が認証済みであること（gh auth status が通ること）。
#
# 実行タイミング: **マージ後、速やかに実行すること**。PR 本文はマージ後も編集可能であり、
# 本スクリプトは「実行時点の本文」を評価するため、マージ後に本文が編集されていると、
# その PR の対応内容とは無関係な issue が対象に混入しうる（GitHub 純正のキーワード解釈は
# マージ時点の内容で決まるのに対し、本スクリプトはこの点で信頼境界が広い）。
#
# 既知の限界（いずれも dry-run での目視確認を前提に許容している）:
#   - コードフェンスは「バッククォート3個以上」の行のみを扱う（`~~~` 形式は非対応）。
#     開始フェンスと同数以上のバッククォートでのみ閉じる（入れ子の例示に対応）。閉じ忘れが
#     ある本文では、以降を抽出対象から除外したうえで警告を出す
#   - 引用は行頭 `>` のみを除外する。GFM の lazy continuation（直前行の継続として `>` を
#     省略した引用行）は除外できない
#   - `Closes #10, #11` のようにキーワードを繰り返さない書き方は、2件目以降を拾わない
#     （GitHub 側も「issue ごとにキーワードの繰り返しが必要」と定めており、その仕様に合わせている）
#
# 回帰テスト:
#   本文からのキーワード抽出（正規表現・コードブロック/引用/インラインコードの除外）と、
#   対象判定の分岐（未マージ・base 不一致・fork・PR 番号の誤参照・クローズ済み・件数上限）を
#   含むため、CONTRIBUTING.md 8.4 の基準（分岐・正規表現・パース処理を含む）に該当する。
#   回帰テストハーネスは scripts/tests/run-close-linked-issues-tests.sh に新設済み。
#
set -euo pipefail
export LC_ALL=C

# 一度に処理する issue 数の上限。本リポジトリは「1ブランチ = 1案件」運用（CONTRIBUTING 9.1）
# のため、1 PR に紐づく issue は通常1件である。想定を大きく超える件数が抽出された場合は
# 参照の誤りを疑い、1件も操作せずに中止する（誤クローズは通知が飛び、実質的に取り返しが
# つかないため、部分的に実行するより止める方を選ぶ）。
MAX_ISSUES=10

# usage は標準出力へ書き、エラー時のみ呼び出し側で >&2 へ回す（sync-guidelines.sh と同じ方針。
# `--help | less` のようにヘルプを読む用途を壊さないため）。
usage() {
  cat <<'USAGE'
Usage: bash scripts/close-linked-issues.sh <PR番号> [--apply] [--yes] [--no-comment]

  <PR番号>       develop へマージ済みの PR の番号
  --apply       実際にクローズする（既定は dry-run で表示のみ）
  --yes         --apply 時の y/N 確認を省略する（非対話実行では指定必須。ただし利用者の
                承認を代替するものではない。CONTRIBUTING.md 9.1 参照）
  --no-comment  クローズ時の定型コメントを投稿しない（--apply と併用）

マージ後、速やかに実行してください（PR 本文はマージ後も編集可能で、本スクリプトは
実行時点の本文を評価するため）。
USAGE
}

pr_number=""
apply=0
post_comment=1
assume_yes=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --yes) assume_yes=1 ;;
    --no-comment) post_comment=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Error: 不明なオプション: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -n "$pr_number" ]; then
        echo "Error: PR 番号は1つだけ指定してください（重複指定: $1）。" >&2
        exit 1
      fi
      pr_number="$1"
      ;;
  esac
  shift
done

if [ -z "$pr_number" ]; then
  echo "Error: PR 番号を指定してください。" >&2
  usage >&2
  exit 1
fi

case "$pr_number" in
  ''|*[!0-9]*)
    echo "Error: PR 番号は数字で指定してください: $pr_number" >&2
    exit 1
    ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: 現在のディレクトリは git リポジトリではありません。" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI が見つかりません。GitHub CLI をインストールしてください。" >&2
  exit 1
fi

if ! repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"; then
  echo "Error: リポジトリ情報を取得できませんでした（gh の認証状態を確認してください）。" >&2
  exit 1
fi
if [ -z "$repo" ]; then
  echo "Error: リポジトリを特定できませんでした（gh repo view が空を返しました）。" >&2
  exit 1
fi

# PR のメタ情報（スカラー3項目）と本文を取得する。本文は改行を含むため別呼び出しにする。
# マージ済みかの判定には `state`（OPEN / CLOSED / MERGED）を使う（`gh pr view --json merged` は
# 存在しないフィールドで、指定すると gh がエラーになる）。
if ! pr_meta="$(gh pr view "$pr_number" --json state,baseRefName,isCrossRepository \
  --jq '[.state, .baseRefName, (.isCrossRepository|tostring)] | @tsv')"; then
  echo "Error: PR #${pr_number} の情報を取得できませんでした。" >&2
  exit 1
fi

pr_state="$(printf '%s' "$pr_meta" | cut -f1)"
pr_base="$(printf '%s' "$pr_meta" | cut -f2)"
pr_cross_repo="$(printf '%s' "$pr_meta" | cut -f3)"

# 対象を多層に絞り込む（1つでも満たさなければ何も操作せずに中止する）。
#   1. マージ済みであること（未マージ・クローズのみの PR は対象外）
#   2. base が develop であること（main へのリリース PR は 9.2 の別運用）
#   3. fork からの PR でないこと（本文＝外部から制御可能な入力となる経路を塞ぐ）
if [ "$pr_state" != "MERGED" ]; then
  echo "Error: PR #${pr_number} はマージされていません（state=${pr_state}）。" >&2
  exit 1
fi
if [ "$pr_base" != "develop" ]; then
  echo "Error: PR #${pr_number} の base が develop ではありません（base=${pr_base}）。" >&2
  echo "       develop 向け PR のみを対象とします（main へのリリース PR は CONTRIBUTING 9.2 の運用）。" >&2
  exit 1
fi
if [ "$pr_cross_repo" = "true" ]; then
  echo "Error: PR #${pr_number} は fork からの PR のため対象外です。手動で確認してください。" >&2
  exit 1
fi

if ! pr_body="$(gh pr view "$pr_number" --json body --jq .body)"; then
  echo "Error: PR #${pr_number} の本文を取得できませんでした。" >&2
  exit 1
fi

# 本文から closing キーワード付きの issue 参照を抽出する。
#   - フェンス付きコードブロック（``` で囲まれた範囲）と引用行（先頭 >）、インラインコード
#     （`...`）は、説明のための記述であって参照ではないため除外する
#   - 対象は同一リポジトリ形式の `#<数字>` のみ。`owner/repo#12` や URL 形式は、キーワードの
#     直後が `#` でないため自然に非対象となる（他リポジトリの issue は操作しない方針と一致）
extract_issue_numbers() {
  local body="$1"
  printf '%s\n' "$body" \
    | awk '
        {
          line = $0
          trimmed = line
          sub(/^[[:space:]]*/, "", trimmed)
          # フェンス行の判定。開始フェンスのバッククォート数を覚え、同数以上の行でのみ閉じる
          # （4個で開いた中に3個の入れ子例を書く一般的な書き方で、フェンス内の記述が
          # フェンス外と誤認されるのを防ぐ）。
          if (substr(trimmed, 1, 3) == "```") {
            n = 0
            while (substr(trimmed, n + 1, 1) == "`") { n++ }
            if (!in_fence) { in_fence = 1; fence_len = n; next }
            if (n >= fence_len) { in_fence = 0; fence_len = 0; next }
            # 開始フェンスより短い場合はフェンス内の内容として扱う（next せず下の in_fence で捨てる）
          }
          if (in_fence) { next }
          if (line ~ /^[[:space:]]*>/) { next }
          print line
        }
        END {
          if (in_fence) {
            print "警告: PR 本文のコードフェンスが閉じられていません。閉じ忘れ以降の記述を抽出対象から除外しました（取りこぼしの可能性があります。本文を目視で確認してください）。" > "/dev/stderr"
          }
        }
      ' \
    | sed 's/`[^`]*`//g' \
    | grep -oiE '(^|[^0-9A-Za-z_-])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#[0-9]+' \
    | grep -oE '[0-9]+$' \
    | sort -n -u
}

# grep はマッチ0件で終了コード1を返すため、パイプライン全体の失敗と区別できるよう
# 一時的に pipefail/errexit を外して実行する。
set +e +o pipefail
candidate_numbers="$(extract_issue_numbers "$pr_body")"
set -e -o pipefail

if [ -z "$candidate_numbers" ]; then
  echo "PR #${pr_number} の本文に closing キーワード付きの issue 参照は見つかりませんでした。"
  echo "（Closes/Fixes/Resolves + #番号 の形式のみを対象としています）"
  exit 0
fi

candidate_count="$(printf '%s\n' "$candidate_numbers" | wc -l | tr -d '[:space:]')"
if [ "$candidate_count" -gt "$MAX_ISSUES" ]; then
  echo "Error: 抽出された参照が想定上限（${MAX_ISSUES} 件）を超えました（${candidate_count} 件）。" >&2
  echo "       誤クローズを避けるため何も操作せずに中止します。手動で確認してください。" >&2
  exit 1
fi

# 参照先が「未クローズの issue」であるものだけに絞り込む。
#   - PR 番号への参照（`.pull_request` を持つ）は除外する（PR を閉じてしまわないため）
#   - 既にクローズ済みの issue は再操作しない
targets=""
skipped=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  if ! info="$(gh api "repos/${repo}/issues/${n}" \
    --jq '[.state, (if .pull_request then "pr" else "issue" end)] | @tsv' 2>/dev/null)"; then
    echo "  スキップ: #${n}（取得できませんでした。番号の誤りか、参照先が存在しません）"
    skipped=$((skipped + 1))
    continue
  fi
  state="$(printf '%s' "$info" | cut -f1)"
  kind="$(printf '%s' "$info" | cut -f2)"
  if [ "$kind" = "pr" ]; then
    echo "  スキップ: #${n}（issue ではなく PR です）"
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$state" != "open" ]; then
    echo "  スキップ: #${n}（既に ${state} です）"
    skipped=$((skipped + 1))
    continue
  fi
  targets="${targets}${n}"$'\n'
done <<< "$candidate_numbers"

targets="$(printf '%s' "$targets" | sed '/^$/d')"

if [ -z "$targets" ]; then
  echo "クローズ対象の issue はありません（スキップ ${skipped} 件）。"
  exit 0
fi

comment_body="$(printf '%s\n' \
  "本 issue に紐づく PR #${pr_number} を \`develop\` へマージしました（本リポジトリでは develop への統合をもって対応完了とみなします。リリース（main への反映）は別途 CONTRIBUTING.md 9.2 の手順で行います）。" \
  "" \
  "このコメントは \`scripts/close-linked-issues.sh\` による定型投稿です。対応内容のサマリは別途記載します。")"

echo
echo "対象リポジトリ: ${repo}"
echo "対象 PR: #${pr_number}（base=${pr_base}、マージ済み）"
echo "クローズ対象の issue:"
while IFS= read -r n; do
  [ -n "$n" ] && echo "  - #${n}"
done <<< "$targets"

if [ "$apply" != "1" ]; then
  echo
  echo "[dry-run] 実際には何も変更していません。実行するには --apply を付けてください。"
  if [ "$post_comment" = "1" ]; then
    echo
    echo "--apply 時に投稿する定型コメント:"
    printf '%s\n' "$comment_body" | sed 's/^/  | /'
  fi
  exit 0
fi

# --apply でも、実行前に必ず対象を確認させる（誤クローズは通知が飛び実質的に取り返しが
# つかないため、dry-run を挟む運用手順だけに依存せずスクリプト側でも一段止める）。
# 非対話実行（パイプ・CI 等）では確認を取れないため、--yes の明示を必須とする。
target_count="$(printf '%s\n' "$targets" | wc -l | tr -d '[:space:]')"
if [ "$assume_yes" != "1" ]; then
  if [ ! -t 0 ]; then
    echo "Error: 非対話実行では確認が取れません。内容を確認のうえ --yes を付けて再実行してください。" >&2
    exit 1
  fi
  printf '上記 %s 件をクローズします。よろしいですか？ [y/N]: ' "$target_count"
  # EOF（Ctrl-D）でも `set -e` で無言終了させず、下の default 分岐（中止）へ落とす。
  read -r reply || reply=""
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "中止しました。何も変更していません。"; exit 0 ;;
  esac
fi

closed=0
failed=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  echo
  echo "issue #${n} をクローズします。"
  # 先に状態変更（クローズ）を行い、成功した場合にのみ定型コメントを投稿する。逆順にすると、
  # クローズが失敗したときに「マージしました」というコメントだけが残り、issue は open のまま
  # 虚偽の記録になる。
  if ! gh api --method PATCH "repos/${repo}/issues/${n}" \
    -f state=closed -f state_reason=completed --silent; then
    echo "  失敗: #${n} をクローズできませんでした。手動で対応してください。" >&2
    failed=$((failed + 1))
    # 1件の失敗で残りを止めない（未処理の issue を増やさないため）。最後にまとめて失敗させる。
    continue
  fi
  closed=$((closed + 1))
  echo "  クローズしました。"
  if [ "$post_comment" = "1" ]; then
    if ! gh api --method POST "repos/${repo}/issues/${n}/comments" \
      -f body="$comment_body" --silent; then
      # クローズ自体は完了しているため、コメント投稿の失敗では全体を失敗させない。
      echo "  警告: 定型コメントの投稿に失敗しました（クローズは完了しています）。" >&2
    fi
  fi
done <<< "$targets"

echo
echo "クローズ完了: ${closed} 件 / 失敗: ${failed} 件 / スキップ: ${skipped} 件"
if [ "$failed" -gt 0 ]; then
  echo "Error: ${failed} 件の issue をクローズできませんでした。未処理分は手動でクローズしてください。" >&2
  exit 1
fi

echo "Done!"
