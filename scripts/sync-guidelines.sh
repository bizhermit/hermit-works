#!/usr/bin/env bash
#
# 正典 scripts/lib/guidelines.sh の逐語検証用文言（GUIDELINE_*）を編集した際、変更差分
# （直前の git HEAD時点との比較）を対象ファイル群へ機械的に反映（伝播）するスクリプト。
#
# 位置づけ（2026-08-01案件B。DESIGN.md 2.30参照）:
#   正典＝scripts/lib/guidelines.sh／検証＝scripts/validate.sh／伝播＝本スクリプトの3分掌。
#   本スクリプトは lib の「現在の値」と「git HEAD時点でコミットされている値」を比較し、
#   差分がある定数だけを対象ファイルへ反映する。対象ファイルへの分配は scripts/validate.sh の
#   検証分配（セクション9(a)(c)(e)(d)(f)(g)(h)）と同一にする。
#
# 採用方式（推奨方式どおり。担当判断での調整なし）:
#   旧文言は `git show HEAD:scripts/lib/guidelines.sh` を一時ファイル化して source した値から
#   導出し、作業ツリーの lib（本スクリプトが SCRIPT_DIR 相対で source する現在値）と差分が
#   ある定数のみを置換対象にする。GUIDELINE_ で始まる変数名は、宣言側・参照側を問わずすべて
#   OLD_ 接頭辞に置換してから source することで、現在値（作業ツリーの lib から既にこのプロセス
#   継承済み）を巻き込まずに旧値だけを取り出す（ガードレール文言の本文は自然文であり
#   "GUIDELINE_" という部分文字列を含まないため、この一括置換で本文を壊す心配はない）。
#
# 置換方式:
#   固定文字列のリテラル置換（bash の `${content//"$old"/"$new"}`）のみを用いる。正規表現解釈は
#   一切行わない（対象文言にはバッククォート・丸括弧等の正規表現特殊文字が含まれるため）。
#
# 対象ファイルが旧文言を含まない場合の扱い:
#   対象ファイルが旧文言を含まない場合、まず「既に新文言（正典の現在値）を含んでいるか」を
#   確認する。含んでいれば他ブランチでの先行適用・手編集等により伝播済みとみなし、ERROR に
#   せず「対応不要（既に新文言）」としてスキップ報告する（SKIPPED_COUNTに計上。ERROR
#   COUNTには含めない）。新文言も含まない場合のみ、静かに失敗せずERRORとして報告する。
#
# 実行末尾の自動整合確認について（担当判断の調整点。理由を明記する）:
#   要件は「実行末尾で validate.sh を自動実行し整合を確認する」ことだが、--dry-run 実行時は
#   ファイルを一切書き換えないため、その場で validate.sh を走らせても「まだ適用していない
#   差分」を欠落として誤検出するだけで確認にならない（dry-runの意味と矛盾する）。そのため
#   本スクリプトは、正典(lib)にHEAD以降の差分が実在しない場合（後述「同期対象なし」）を除き、
#   --dry-run 以外の実行（実際に書き込みを行った場合・書き込む変更がなかった場合の双方）の
#   末尾で validate.sh を自動実行し、整合を確認する。
#
# 実行例:
#   bash scripts/sync-guidelines.sh              # 現在のリポジトリに対して実行
#   bash scripts/sync-guidelines.sh --dry-run    # 適用対象を確認するだけ（書き込みなし）
#   bash scripts/sync-guidelines.sh /path/to/repo-root --dry-run
#
# 信頼前提（重要。sec-audit M-1）:
#   引数 repo_root は本プラグイン自身の作業ツリー、または回帰テストが生成する使い捨て
#   フィクスチャに限定すること。任意の外部・利用者リポジトリを指定して実行してはならない。
#   本スクリプトは `git -C "$REPO_ROOT" show HEAD:scripts/lib/guidelines.sh` の結果を
#   一時ファイルへ書き出したうえで source する（旧値抽出のため）。これは repo_root の
#   git HEAD 時点に置かれたシェルコードをそのまま実行することを意味するため、HEAD に
#   悪意あるコードが仕込まれていた場合は任意コード実行につながり得る。
#
set -euo pipefail
export LC_ALL=C
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
使い方: bash scripts/sync-guidelines.sh [--dry-run] [repo_root]

正典 scripts/lib/guidelines.sh の GUIDELINE_* 定数について、直前の git HEAD時点の値と
現在の値を比較し、差分がある定数を対象ファイル群（agents/*.md・commands/*.md・
skills/*/SKILL.md の該当ファイル）へリテラル置換で反映する。

オプション:
  --dry-run   実際には書き込まず、適用対象・件数のみを表示する。
  -h, --help  このヘルプを表示する。

引数:
  repo_root   検証・伝播の対象リポジトリルート（省略時はこのスクリプトの1階層上）。
USAGE
}

DRY_RUN=0
REPO_ROOT_ARG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Error: 未知のオプションです: $arg" >&2
      usage >&2
      exit 1
      ;;
    *) REPO_ROOT_ARG="$arg" ;;
  esac
done

REPO_ROOT="$REPO_ROOT_ARG"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
fi

LIB_FILE="$SCRIPT_DIR/lib/guidelines.sh"
if [ ! -f "$LIB_FILE" ]; then
  echo "Error: 正典 lib が見つかりません: $LIB_FILE" >&2
  exit 1
fi

# 現在値（作業ツリーの正典）を読み込む。
source "$LIB_FILE"

# ---------------------------------------------------------------------------
# 旧値（git HEAD時点の正典）の取得
# ---------------------------------------------------------------------------

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "同期対象なし: $REPO_ROOT は git ワークツリーではないため、旧文言（git HEAD時点）との比較基準がありません。"
  exit 0
fi

# `git show HEAD:path` の path はリポジトリ最上位（REPO_ROOT）基準のパスであるという前提
# （git の仕様どおり。CWDが$REPO_ROOT配下の別ディレクトリであっても、-Cで指定した
# $REPO_ROOTが最上位である限りこの相対パス表記でよい）。
if ! OLD_LIB_CONTENT="$(git -C "$REPO_ROOT" show 'HEAD:scripts/lib/guidelines.sh' 2>/dev/null)"; then
  echo "同期対象なし: scripts/lib/guidelines.sh が git HEAD時点に存在しません（初回コミット前等）。正常終了します。"
  exit 0
fi

OLD_LIB_TMP="$(mktemp)"
trap 'rm -f "$OLD_LIB_TMP"' EXIT

# GUIDELINE_ で始まる識別子（宣言側・参照側の双方）をすべて OLD_GUIDELINE_ にリネームする。
# ガードレール文言の本文（自然文）に "GUIDELINE_" という部分文字列は含まれないため、この
# 一括置換は本文を破壊しない（設計判断は冒頭コメント参照）。
printf '%s\n' "$OLD_LIB_CONTENT" | sed 's/GUIDELINE_/OLD_GUIDELINE_/g' > "$OLD_LIB_TMP"

# リネーム前提の崩れ検知（qa L-5）: sedは"GUIDELINE_"の出現ごとに"OLD_"を前置するだけなので、
# リネーム前の"GUIDELINE_"出現数とリネーム後の"OLD_GUIDELINE_"出現数は必ず一致するはずである
# （一致しない場合、想定していない出現パターン＝前提の崩れがあるということなので、
# 静かに読み進めず異常終了する）。
GUIDELINE_OCCURRENCE_BEFORE="$(grep -o 'GUIDELINE_' <<<"$OLD_LIB_CONTENT" | wc -l | tr -d ' ')"
GUIDELINE_OCCURRENCE_AFTER="$(grep -o 'OLD_GUIDELINE_' "$OLD_LIB_TMP" | wc -l | tr -d ' ')"
if [ "$GUIDELINE_OCCURRENCE_BEFORE" != "$GUIDELINE_OCCURRENCE_AFTER" ]; then
  echo "Error: GUIDELINE_ -> OLD_GUIDELINE_ のリネーム前提が崩れています（前:${GUIDELINE_OCCURRENCE_BEFORE} 件 / 後:${GUIDELINE_OCCURRENCE_AFTER} 件）。scripts/lib/guidelines.sh のHEAD時点の内容を確認してください。" >&2
  exit 1
fi

OLD_VARS_DUMP="$(
  source "$OLD_LIB_TMP"
  names="${!OLD_GUIDELINE_@}"
  if [ -n "$names" ]; then
    declare -p $names
  fi
)"
eval "$OLD_VARS_DUMP"

# ---------------------------------------------------------------------------
# 対象ファイル一覧の算出（scripts/validate.sh の検証分配と同一にする）
# ---------------------------------------------------------------------------

# is_leader_agent_name は scripts/lib/guidelines.sh（正典）で定義され、source 済み
# （2026-08-01案件T6で自前実装 is_leader_agent_name_sync を撤去し集約。CONTRIBUTING.md 1.5・1.8参照）。

AGENTS_ALL=()
AGENTS_EXCEPT_COORDINATOR=()
AGENTS_NON_LEADER=()
for f in "$REPO_ROOT"/agents/*.md; do
  [ -f "$f" ] || continue
  base_name="$(basename "$f" .md)"
  AGENTS_ALL+=("agents/$(basename "$f")")
  if [ "$base_name" != 'mgmt-coordinator' ]; then
    AGENTS_EXCEPT_COORDINATOR+=("agents/$(basename "$f")")
  fi
  if ! is_leader_agent_name "$base_name"; then
    AGENTS_NON_LEADER+=("agents/$(basename "$f")")
  fi
done

# ---------------------------------------------------------------------------
# 同期処理本体
# ---------------------------------------------------------------------------

CHANGED_ITEMS=0
APPLIED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

# 指定の1項目（label）について、旧値(old_var)と新値(new_var)を比較し、差分があれば
# 対象ファイル群（残りの引数）へリテラル置換で反映する。
sync_item() {
  local label="$1" old_var="$2" new_var="$3"
  shift 3
  local -a targets=("$@")

  if [ -z "${!old_var+set}" ]; then
    echo "情報: ${label} は正典(lib)の新規追加項目のため、HEAD時点との比較対象がありません（同期対象外）"
    return 0
  fi

  local old_val="${!old_var}"
  local new_val="${!new_var}"

  if [ "$old_val" = "$new_val" ]; then
    return 0
  fi

  CHANGED_ITEMS=$((CHANGED_ITEMS + 1))
  echo "変更検出: ${label}（対象候補 ${#targets[@]} 件）"

  local rel f content new_content
  for rel in "${targets[@]}"; do
    f="$REPO_ROOT/$rel"
    if [ ! -f "$f" ]; then
      continue
    fi

    # 末尾の改行を保持したままファイル内容を読み込む（$(...)は末尾改行を吸収するため、
    # 番兵文字 'x' を付けて読み取り、直後に取り除く）。
    content="$(cat "$f"; printf 'x')"
    content="${content%x}"

    case "$content" in
      *"$old_val"*) ;;
      *"$new_val"*)
        # 旧文言は含まないが、既に新文言（正典の現在値）を含んでいる対象。
        # 他ブランチでの先行適用・手編集等で既に伝播済みのファイルを ERROR 扱いに
        # しない（qa M-1/M-2是正）。件数はSKIPPED_COUNTで別集計し、ERRORにはしない。
        echo "対応不要（既に新文言）: ${rel} は旧文言を含まず、既に新文言（${label}）を含んでいます（スキップ）"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
        ;;
      *)
        echo "ERROR: ${rel} に旧文言（${label}）が見つかりません（手動確認が必要です）" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
        ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] 更新予定: ${rel}"
      APPLIED_COUNT=$((APPLIED_COUNT + 1))
      continue
    fi

    # 失敗時挙動について（qa L-4 / sec L-1）: ここでの書き込みは直接上書き（mktemp+mv による
    # アトミック化はしない）。理由: mvでの置換はPOSIX標準では元ファイルのパーミッションを
    # 保証せず（mktempが作る一時ファイルのモードが引き継がれ得り、対象がagents/*.md等の
    # 644想定ファイルの権限を意図せず変える恐れがある）、GNU拡張（chmod --reference等）に
    # 頼らずに安全に権限保持する手段がPOSIX標準ツールのみでは煩雑になる（CONTRIBUTING 8.2）。
    # 本スクリプトは set -euo pipefail で動作し、途中で予期しないエラー（ディスクフル等）が
    # 起きればその場で中断する。書きかけの中途半端な状態が残った場合の復旧は、本スクリプトが
    # git ワークツリーに対して実行される前提（信頼前提は冒頭コメント参照）を利用し、
    # `git status` で差分を確認のうえ `git checkout -- <file>` 等で復旧すること
    # （本スクリプト自身はコミット・pushを行わないため、常にgitで復旧可能な状態を保つ）。
    new_content="${content//"$old_val"/"$new_val"}"
    printf '%s' "$new_content" > "$f"
    echo "  更新: ${rel}"
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
  done
}

# 対象分配は scripts/validate.sh セクション9(a)(c)(e)(d)(f)(g)(h)と同一。
sync_item '共通ガードレール6短文＋アンカー（9a）' \
  OLD_GUIDELINE_ANCHOR_PLUS_BLOCK GUIDELINE_ANCHOR_PLUS_BLOCK \
  "${AGENTS_ALL[@]+"${AGENTS_ALL[@]}"}"

sync_item '判断手順共通文言（9e）' \
  OLD_GUIDELINE_DECISION_PROCEDURE_LINE GUIDELINE_DECISION_PROCEDURE_LINE \
  "${AGENTS_EXCEPT_COORDINATOR[@]+"${AGENTS_EXCEPT_COORDINATOR[@]}"}"

sync_item 'TK-2/E-1統合文（9c）' \
  OLD_GUIDELINE_TK2_E1_LINE GUIDELINE_TK2_E1_LINE \
  "${AGENTS_NON_LEADER[@]+"${AGENTS_NON_LEADER[@]}"}"

sync_item '注入耐性文言（9d）' \
  OLD_GUIDELINE_INJECTION_NOTE_LINE GUIDELINE_INJECTION_NOTE_LINE \
  "${COMMANDS_SKILLS_INJECTION_FILES[@]+"${COMMANDS_SKILLS_INJECTION_FILES[@]}"}"

sync_item '外部トラッカー非信頼入力宣言（9f前半）' \
  OLD_GUIDELINE_EXTERNAL_INPUT_NOTE_LINE GUIDELINE_EXTERNAL_INPUT_NOTE_LINE \
  "${TRACKER_SKILLS_EXTERNAL_INPUT_FILES[@]+"${TRACKER_SKILLS_EXTERNAL_INPUT_FILES[@]}"}"

sync_item 'スナップショットテンプレート非信頼データ宣言（9f後半）' \
  OLD_GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_BLOCK GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_BLOCK \
  'skills/tracker-sync/SKILL.md'

sync_item 'import-assets非信頼入力宣言（9g）' \
  OLD_GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_LINE GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_LINE \
  "${IMPORT_ASSETS_UNTRUSTED_INPUT_FILES[@]+"${IMPORT_ASSETS_UNTRUSTED_INPUT_FILES[@]}"}"

sync_item 'permission-rulesトリガー行（9h）' \
  OLD_GUIDELINE_PERMISSION_TRIGGER_LINE GUIDELINE_PERMISSION_TRIGGER_LINE \
  "${PERMISSION_TRIGGER_LINE_FILES[@]+"${PERMISSION_TRIGGER_LINE_FILES[@]}"}"

# ---------------------------------------------------------------------------
# 結果サマリ
# ---------------------------------------------------------------------------

echo '==================================================='
if [ "$CHANGED_ITEMS" -eq 0 ]; then
  echo "同期結果: 正典(lib)にHEAD時点からの差分がある項目はありません（no-op）"
else
  echo "同期結果: 変更検出 ${CHANGED_ITEMS} 項目 / 適用 ${APPLIED_COUNT} 件 / ERROR ${ERROR_COUNT} 件 / dry-run=${DRY_RUN} / 対応不要（既に新文言） ${SKIPPED_COUNT} 件"
fi
echo '==================================================='

# 実行末尾の自動整合確認（--dry-run時は書き込みを行っていないため対象外。理由は冒頭コメント参照）。
VALIDATE_EXIT=0
if [ "$DRY_RUN" -eq 0 ]; then
  echo
  echo '--- 整合確認: bash scripts/validate.sh を実行します ---'
  bash "$SCRIPT_DIR/validate.sh" "$REPO_ROOT" || VALIDATE_EXIT=$?
fi

if [ "$ERROR_COUNT" -gt 0 ] || [ "$VALIDATE_EXIT" -ne 0 ]; then
  exit 1
fi
exit 0
