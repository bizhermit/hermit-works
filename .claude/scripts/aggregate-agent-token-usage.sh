#!/usr/bin/env bash
#
# ~/.claude/projects/ 配下のトランスクリプト（JSONL）から、エージェント
# （サブエージェントタイプ）別のトークン使用量（input/output/cache_creation/cache_read）と
# 委任回数を集計する（DESIGN.md 4章「エージェント間の委任実績の定量把握」の実測手段）。
#
# 対象データの構造（実データ確認済み。~/.claude/projects/<project>/ 配下）:
#   - トップレベルセッション: <project>/<session-id>.jsonl
#     （オーケストレーターの発話。サブエージェントへの委任そのものではない）
#   - サブエージェント委任1回につき: <project>/<session-id>/subagents/agent-<hash>.meta.json
#     （"agentType" フィールドにエージェント種別。例: "hw:qa-review"）と
#     同名の agent-<hash>.jsonl（そのサブエージェントの発話・usage）が対になっている。
#   - usage は各 assistant 発話行の "message":{"usage":{...}} に
#     input_tokens / output_tokens / cache_creation_input_tokens / cache_read_input_tokens
#     を持つ。ただし同じ usage オブジェクト内の "iterations" 配列にも同名フィールドが
#     再掲されるため、単純な正規表現全数カウントだと二重計上になる。
#
# 採用理由:
#   - jq 等の追加ランタイムを導入せず bash + 標準ツール（find/grep/awk）のみで完結させる
#     （CONTRIBUTING.md 8.3。JSONL は1行1オブジェクトのため、.claude/scripts/validate.sh の
#     .claude-plugin/*.json 解析と同じ「行単位の正規表現照合」方針で対応できる）。
#   - 二重計上対策: 実データ全数（本スクリプト作成時点の ~/.claude/projects 全体、
#     usage行8000件超）を確認した結果、"iterations" キーはusageオブジェクト内で常に
#     4フィールドより後方に出現していた。そのため「行内でのフィールド名の最初の出現」を
#     採ればトップレベル値と一致する。この前提が崩れた場合の対処は下記 field_value() 直上の
#     コメント、および値が丸ごと欠落した場合の扱いは MISSING_FIELD_COUNT 集計を参照
#     （.claude/scripts/validate.sh 側の同種の割り切り［JSON専用パーサ不使用の代わりに前提を明記し
#     複雑な実装は見送る］を踏襲）。この前提はスキーマで保証されたものではなく実データ観測に
#     基づく経験則であり、崩れても静かに誤集計するだけで検知できないため、年次程度を目安に
#     実データで前提が崩れていないか再確認すること（運用注記）。
#   - 本スクリプトの主対象はリポジトリ内資材ではなく利用者ホームの Claude Code
#     データディレクトリのため、CONTRIBUTING 8.3「対象は第1引数、省略時は自動解決」の
#     精神を「対象ディレクトリ（トランスクリプトルート）」に読み替えて適用する
#     （省略時デフォルトは $HOME/.claude/projects。フィクスチャ差し替えによる
#     テスト実行のため引数で上書きできるようにしている）。
#   - 出力は集計値・件数・パス（ディレクトリ単位）のみとし、会話本文・タスク説明文
#     （meta.json の "description" 等）・秘密情報は一切読み取り・出力しない。
#
# 実行例:
#   bash .claude/scripts/aggregate-agent-token-usage.sh
#   bash .claude/scripts/aggregate-agent-token-usage.sh /path/to/.claude/projects   # 対象ディレクトリを明示指定（テスト等）
#
# 回帰テストの要否（CONTRIBUTING 8.4）:
#   本スクリプトは正規表現によるパース処理を含む（基準2に該当）ため回帰テストを新設する。
#   ハーネス: .claude/scripts/tests/run-aggregate-agent-token-usage-tests.sh
#
set -euo pipefail
export LC_ALL=C

TRANSCRIPTS_ROOT="${1:-}"
if [ -z "$TRANSCRIPTS_ROOT" ]; then
  TRANSCRIPTS_ROOT="$HOME/.claude/projects"
fi

if [ ! -d "$TRANSCRIPTS_ROOT" ]; then
  echo "対象ディレクトリが見つかりません（データなしとして扱います）: $TRANSCRIPTS_ROOT"
  echo "エージェント別トークン使用量: 対象0件"
  exit 0
fi

# usage を含む1行から4フィールドを抽出し合算する awk プログラム。
# mawk を含む POSIX 準拠 awk 全般で動くよう、3引数 match()・連想配列等の
# gawk 拡張機能には依存しない（index() + 2引数 match() + RSTART/RLENGTH のみ使用）。
# 出力は1行（tab区切り）: usage行数 input output cache_creation cache_read 欠落フィールド数
read -r -d '' USAGE_AWK <<'AWK_EOF' || true
function field_value(line, key,    p, rest) {
  p = index(line, key)
  if (p == 0) {
    missing_count++
    return 0
  }
  rest = substr(line, p + length(key))
  if (match(rest, /^[0-9]+/)) {
    return substr(rest, RSTART, RLENGTH) + 0
  }
  missing_count++
  return 0
}
{
  if (index($0, "\"usage\":{") == 0) next
  usage_lines++
  in_sum  += field_value($0, "\"input_tokens\":")
  out_sum += field_value($0, "\"output_tokens\":")
  cc_sum  += field_value($0, "\"cache_creation_input_tokens\":")
  cr_sum  += field_value($0, "\"cache_read_input_tokens\":")
}
END {
  printf "%d\t%d\t%d\t%d\t%d\t%d\n", usage_lines + 0, in_sum + 0, out_sum + 0, cc_sum + 0, cr_sum + 0, missing_count + 0
}
AWK_EOF

# キャッシュヒット率 = cache_read ÷ (input + cache_creation + cache_read) を
# パーセント表示（小数1桁）で返す。分母が0の場合は "-" を返す（0除算回避・無意味な
# 100%/0%表示を避けるため）。浮動小数演算はbash組み込みでは行えないためawkに委譲する
# （本スクリプトの他の集計処理は整数のみでbash算術式のまま完結しているが、この算出だけ
# 例外的にawkを使う）。
calc_cache_hit_rate() {
  local cr="$1" in_t="$2" cc="$3"
  local denom=$((in_t + cc + cr))
  if [ "$denom" -eq 0 ]; then
    echo "-"
    return
  fi
  awk -v cr="$cr" -v denom="$denom" 'BEGIN { printf "%.1f%%", (cr / denom) * 100 }'
}

# --- サブエージェント（委任）別の集計 ---------------------------------------
declare -A DELEGATIONS=()
declare -A T_LINES=()
declare -A T_INPUT=()
declare -A T_OUTPUT=()
declare -A T_CACHE_CREATE=()
declare -A T_CACHE_READ=()
SUBAGENT_META_COUNT=0
TOTAL_MISSING=0

while IFS= read -r meta_file; do
  SUBAGENT_META_COUNT=$((SUBAGENT_META_COUNT + 1))

  # meta.json に agentType が無い場合 grep が非マッチ(exit 1)となり、pipefail 下で
  # コマンド置換全体が失敗扱いになる（set -e でスクリプトが止まる）ため `|| true` で受ける。
  # agent_type はサニタイズせずタブ区切り出力・連想配列キーにそのまま使う。ローカルの
  # Claude Code 実行系（本人環境）が書き込む信頼済みフィールドである前提に立っている。
  agent_type="$(grep -oE '"agentType"[[:space:]]*:[[:space:]]*"[^"]*"' "$meta_file" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true)"
  if [ -z "$agent_type" ]; then
    agent_type="(不明)"
  fi

  DELEGATIONS["$agent_type"]=$(( ${DELEGATIONS["$agent_type"]:-0} + 1 ))

  jsonl_file="${meta_file%.meta.json}.jsonl"
  if [ -f "$jsonl_file" ]; then
    lines=0 in_t=0 out_t=0 cc_t=0 cr_t=0 miss_t=0
    read -r lines in_t out_t cc_t cr_t miss_t < <(awk "$USAGE_AWK" "$jsonl_file")
    T_LINES["$agent_type"]=$(( ${T_LINES["$agent_type"]:-0} + lines ))
    T_INPUT["$agent_type"]=$(( ${T_INPUT["$agent_type"]:-0} + in_t ))
    T_OUTPUT["$agent_type"]=$(( ${T_OUTPUT["$agent_type"]:-0} + out_t ))
    T_CACHE_CREATE["$agent_type"]=$(( ${T_CACHE_CREATE["$agent_type"]:-0} + cc_t ))
    T_CACHE_READ["$agent_type"]=$(( ${T_CACHE_READ["$agent_type"]:-0} + cr_t ))
    TOTAL_MISSING=$((TOTAL_MISSING + miss_t))
  fi
done < <(find "$TRANSCRIPTS_ROOT" -type f -path '*/subagents/*.meta.json' 2>/dev/null | LC_ALL=C sort)

# --- トップレベル（オーケストレーター）セッションの集計（参考値。委任回数には含めない） ---
TL_SESSIONS=0
TL_LINES=0
TL_INPUT=0
TL_OUTPUT=0
TL_CACHE_CREATE=0
TL_CACHE_READ=0

while IFS= read -r jsonl_file; do
  TL_SESSIONS=$((TL_SESSIONS + 1))
  lines=0 in_t=0 out_t=0 cc_t=0 cr_t=0 miss_t=0
  read -r lines in_t out_t cc_t cr_t miss_t < <(awk "$USAGE_AWK" "$jsonl_file")
  TL_LINES=$((TL_LINES + lines))
  TL_INPUT=$((TL_INPUT + in_t))
  TL_OUTPUT=$((TL_OUTPUT + out_t))
  TL_CACHE_CREATE=$((TL_CACHE_CREATE + cc_t))
  TL_CACHE_READ=$((TL_CACHE_READ + cr_t))
  TOTAL_MISSING=$((TOTAL_MISSING + miss_t))
done < <(find "$TRANSCRIPTS_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null | LC_ALL=C sort)

# --- 出力 --------------------------------------------------------------------
echo "=== エージェント別トークン使用量集計 ==="
echo "対象ディレクトリ: $TRANSCRIPTS_ROOT"
echo "走査結果: サブエージェント委任 ${SUBAGENT_META_COUNT} 件 / トップレベルセッション ${TL_SESSIONS} 件"
echo

if [ "$SUBAGENT_META_COUNT" -eq 0 ]; then
  echo "サブエージェントへの委任は検出されませんでした。"
else
  printf '%-20s %8s %10s %12s %12s %16s %14s %14s\n' \
    "エージェント種別" "委任回数" "発話数" "input" "output" "cache_creation" "cache_read" "cache_hit_rate"

  report_lines=()
  for agent_type in "${!DELEGATIONS[@]}"; do
    total=$(( ${T_INPUT[$agent_type]:-0} + ${T_OUTPUT[$agent_type]:-0} + ${T_CACHE_CREATE[$agent_type]:-0} + ${T_CACHE_READ[$agent_type]:-0} ))
    hit_rate="$(calc_cache_hit_rate "${T_CACHE_READ[$agent_type]:-0}" "${T_INPUT[$agent_type]:-0}" "${T_CACHE_CREATE[$agent_type]:-0}")"
    report_lines+=("$(printf '%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d' \
      "$agent_type" "${DELEGATIONS[$agent_type]}" "${T_LINES[$agent_type]:-0}" \
      "${T_INPUT[$agent_type]:-0}" "${T_OUTPUT[$agent_type]:-0}" \
      "${T_CACHE_CREATE[$agent_type]:-0}" "${T_CACHE_READ[$agent_type]:-0}" "$hit_rate" "$total")")
  done

  # 合計トークン数（列9）降順で表示する。
  while IFS=$'\t' read -r a_type a_deleg a_lines a_in a_out a_cc a_cr a_hit_rate _a_total; do
    printf '%-20s %8s %10s %12s %12s %16s %14s %14s\n' \
      "$a_type" "$a_deleg" "$a_lines" "$a_in" "$a_out" "$a_cc" "$a_cr" "$a_hit_rate"
  done < <(printf '%s\n' "${report_lines[@]}" | sort -t $'\t' -k9,9nr)
fi

echo
echo "--- 参考: トップレベル（オーケストレーター）セッション合算値（委任回数には含めない） ---"
TL_HIT_RATE="$(calc_cache_hit_rate "$TL_CACHE_READ" "$TL_INPUT" "$TL_CACHE_CREATE")"
printf '%-20s %8s %10s %12s %12s %16s %14s %14s\n' \
  "(トップレベル)" "-" "$TL_LINES" "$TL_INPUT" "$TL_OUTPUT" "$TL_CACHE_CREATE" "$TL_CACHE_READ" "$TL_HIT_RATE"

echo
GRAND_INPUT=$TL_INPUT
GRAND_OUTPUT=$TL_OUTPUT
GRAND_CC=$TL_CACHE_CREATE
GRAND_CR=$TL_CACHE_READ
for agent_type in "${!DELEGATIONS[@]}"; do
  GRAND_INPUT=$((GRAND_INPUT + ${T_INPUT[$agent_type]:-0}))
  GRAND_OUTPUT=$((GRAND_OUTPUT + ${T_OUTPUT[$agent_type]:-0}))
  GRAND_CC=$((GRAND_CC + ${T_CACHE_CREATE[$agent_type]:-0}))
  GRAND_CR=$((GRAND_CR + ${T_CACHE_READ[$agent_type]:-0}))
done
GRAND_TOTAL=$((GRAND_INPUT + GRAND_OUTPUT + GRAND_CC + GRAND_CR))
echo "総計（トップレベル+全サブエージェント）: input=${GRAND_INPUT} output=${GRAND_OUTPUT} cache_creation=${GRAND_CC} cache_read=${GRAND_CR} 合計=${GRAND_TOTAL}"

if [ "$TOTAL_MISSING" -gt 0 ]; then
  echo
  echo "注意: usage行のうちフィールド欠落により集計から漏れた値が ${TOTAL_MISSING} 件あります（想定外形式の行の可能性。集計は過小評価になっている場合があります）。"
fi
