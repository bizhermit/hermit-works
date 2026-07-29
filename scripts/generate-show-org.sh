#!/usr/bin/env bash
#
# agents/*.md の frontmatter（name / description）から commands/show-org.md を生成する。
#
# 背景:
#   組織図（グループとエージェント一覧）が README.md / commands/show-org.md /
#   agents/mgmt-coordinator.md の3箇所に手書きで重複しており（三重ハードコード）、
#   エージェントの追加・削除のたびに複数ファイルを手で同期する必要があり、ドリフトの
#   温床になっていた。本スクリプトは commands/show-org.md のうち実際にエージェント
#   構成に依存する「## 組織図」部分を agents/*.md から機械的に再生成することで、
#   agents/*.md を単一の情報源（Single Source of Truth）にする。
#   scripts/validate.sh は本スクリプトの生成結果と実ファイルの差分を検証する
#   （「6) commands/show-org.md と scripts/generate-show-org.sh の生成結果との差分チェック」）。
#
# 設計方針:
#   - commands/show-org.md のうちエージェント構成に依存しない静的な案内文
#     （frontmatter・導入文・利用方法の案内）は、エージェントの増減とは無関係な
#     コマンドの振る舞いそのものの記述であるため、本スクリプト内にテンプレートとして
#     保持し、そのまま出力する（変更する場合は本スクリプトを直接編集する）。
#   - グループの並び順・日本語ラベル（10グループ構成）は scripts/validate.sh の
#     ALLOWED_GROUPS と同様、リポジトリの組織構成そのものの定義として本スクリプト内に
#     保持する（新グループ新設のような低頻度の変更は許容し、ハードコードを避けたいのは
#     あくまで「各グループに何が所属するか」という高頻度で変化する部分）。
#   - 各エージェントの一行説明は、frontmatter description（複数文からなる長文）から
#     「。」区切りの2文目を採用する。1文目はグループ名・役割の定型的な自己紹介
#     （例:「エンジニアグループのバックエンドエンジニア。」）であり、グループ見出しと
#     内容が重複するため採用しない。2文目が無い場合（1文のみのdescription）はそのまま使う。
#     この単純な規則により、複雑な自然文解析をせずに済ませている。
#   - グループ内の並び順は「<group>-lead を先頭（mgmt グループのみ mgmt-coordinator を
#     先頭）、残りはファイル名の昇順（LC_ALL=C）」という単純な規則にする。
#
# 実行例:
#   # commands/show-org.md を直接更新する（リポジトリルートは省略時にこのスクリプトの
#   # 1階層上を使う）
#   bash scripts/generate-show-org.sh
#   bash scripts/generate-show-org.sh /path/to/repo-root
#
#   # 動作確認のみ行い、実ファイルを変更しない（出力先を明示的に指定する）
#   bash scripts/generate-show-org.sh /path/to/repo-root /tmp/show-org-check.md
#
#   # 生成結果と実ファイルの差分確認（scripts/validate.sh のセクション6も内部で同様の
#   # 手順を踏む）
#   bash scripts/generate-show-org.sh /path/to/repo-root /tmp/show-org-check.md \
#     && diff -u /path/to/repo-root/commands/show-org.md /tmp/show-org-check.md
#
set -euo pipefail
export LC_ALL=C

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
OUTPUT_FILE="${2:-$REPO_ROOT/commands/show-org.md}"

AGENTS_DIR="$REPO_ROOT/agents"
shopt -s nullglob
AGENT_FILES=("$AGENTS_DIR"/*.md)

if [ "${#AGENT_FILES[@]}" -eq 0 ]; then
  echo "Error: agents/*.md が見つかりません: $AGENTS_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# frontmatter読み取り（scripts/validate.sh の parse_frontmatter と同等の単純実装。
# 複雑なYAML（配列・ネスト・多行文字列）は対象外。二重管理になるが、本スクリプトは
# validate.sh と依存関係を持たせず単体で動く方針のため独立実装にしている）。
# ---------------------------------------------------------------------------
parse_frontmatter() {
  local file="$1"
  unset FM
  declare -gA FM=()
  local in_block=0
  local is_first_line=1
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"

    if [ "$is_first_line" -eq 1 ]; then
      is_first_line=0
      if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
        in_block=1
        continue
      else
        return 1
      fi
    fi

    if [ "$in_block" -eq 1 ]; then
      if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
        return 0
      fi
      if [[ "$line" =~ ^([A-Za-z0-9_-]+):[[:space:]]*(.*)$ ]]; then
        local key="${BASH_REMATCH[1]}"
        local val="${BASH_REMATCH[2]}"
        val="${val%"${val##*[![:space:]]}"}"
        if [ -z "${FM[$key]+x}" ]; then
          FM[$key]="$val"
        fi
      fi
    fi
  done < "$file"

  return 1
}

# frontmatter description（複数文）から一行説明を作る。「。」区切りで文分割し、
# 2文目があればそれを、無ければ1文目（=description全体）をそのまま使う。
#
# 注意: bash の IFS 分割は1バイトずつを区切り文字として扱うため、「。」のような
# マルチバイト文字（UTF-8で3バイト）を IFS に指定すると、その3バイトのいずれかを
# 含む他の文字（結合文字の一部等）まで誤って分割してしまい文字化けする
# （本スクリプト冒頭で LC_ALL=C を指定しているかどうかに関わらず、IFS分割自体が
# バイト単位のため発生する）。awk の FS（正規表現）はマルチバイト文字も1つの
# リテラルとして扱えるため、文分割には awk を用いる。
summarize_description() {
  local desc="$1"
  printf '%s' "$desc" | awk -F'。' '
    {
      n = 0
      for (i = 1; i <= NF; i++) {
        s = $i
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s == "") { continue }
        n++
        if (n == 1) { first = s }
        if (n == 2) { print s; exit }
      }
      if (n == 1) { print first }
    }
  '
}

# ---------------------------------------------------------------------------
# グループ定義（10グループ固定。並び順もこの配列順）
# ---------------------------------------------------------------------------
GROUP_ORDER=(strat mgmt biz ana eng infra qa sec docs ai)
declare -A GROUP_LABELS=(
  [strat]="経営・戦略"
  [mgmt]="統括・管理"
  [biz]="ビジネス・グロース"
  [ana]="アナリスト"
  [eng]="エンジニア"
  [infra]="インフラ・プラットフォーム"
  [qa]="品質管理・QA"
  [sec]="セキュリティ"
  [docs]="ドキュメント・L10n"
  [ai]="AIサポート"
)

declare -A GROUP_MEMBERS_RAW=()  # group -> "name<TAB>summary\n" の連結

for f in "${AGENT_FILES[@]}"; do
  [ -f "$f" ] || continue
  base_name="$(basename "$f" .md)"

  if ! parse_frontmatter "$f"; then
    echo "Error: frontmatterブロックが見つかりません: $f （先に scripts/validate.sh を通してください）" >&2
    exit 1
  fi

  name_val="${FM[name]:-}"
  desc_val="${FM[description]:-}"
  if [ -z "$name_val" ] || [ -z "$desc_val" ]; then
    echo "Error: name/description が欠落しています: $f （先に scripts/validate.sh を通してください）" >&2
    exit 1
  fi

  group="${name_val%%-*}"
  if [ -z "${GROUP_LABELS[$group]+x}" ]; then
    echo "Error: 未知のグループ '$group' です（$f）。GROUP_LABELS（本スクリプト内の10グループ定義）を確認してください。" >&2
    exit 1
  fi

  summary="$(summarize_description "$desc_val")"
  # summaryは後段でタブ区切り（name<TAB>summary）として連結・分割するため、summary自体に
  # タブ・改行が含まれていると連結が崩れる。frontmatterの値は通常1行だがそれを前提にせず、
  # 生成時にスペースへ正規化しておく。
  summary="${summary//$'\t'/ }"
  summary="${summary//$'\n'/ }"
  GROUP_MEMBERS_RAW["$group"]+="${name_val}"$'\t'"${summary}"$'\n'
done

# グループ内の並び順を決める: <group>-lead（mgmt グループのみ mgmt-coordinator）を
# 先頭に、残りはファイル名の昇順（LC_ALL=C）で標準出力する（1行1件、"name<TAB>summary"）。
order_group_members() {
  local group="$1"
  local raw="${GROUP_MEMBERS_RAW[$group]:-}"
  [ -z "$raw" ] && return 0

  local lead_name="${group}-lead"
  if [ "$group" = "mgmt" ]; then lead_name="mgmt-coordinator"; fi

  local lead_line=""
  local -a rest_lines=()
  while IFS=$'\t' read -r name summary; do
    [ -z "$name" ] && continue
    if [ "$name" = "$lead_name" ]; then
      lead_line="${name}"$'\t'"${summary}"
    else
      rest_lines+=("${name}"$'\t'"${summary}")
    fi
  done <<< "$raw"

  if [ -n "$lead_line" ]; then
    printf '%s\n' "$lead_line"
  fi
  if [ "${#rest_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${rest_lines[@]}" | LC_ALL=C sort
  fi
}

build_org_chart() {
  local group
  for group in "${GROUP_ORDER[@]}"; do
    printf -- '- **%s**\n' "${GROUP_LABELS[$group]}"
    while IFS=$'\t' read -r name summary; do
      [ -z "$name" ] && continue
      printf '  - `%s` — %s\n' "$name" "$summary"
    done < <(order_group_members "$group")
  done
}

{
  cat <<'HEADER'
---
description: hermit-works の組織図（グループとエージェント一覧）を表示し、誰に何を頼めるかを案内する
---

hermit-works 組織の構成を案内します。以下の組織図を、各エージェントの一行説明付きの表として日本語で表示してください（agents ディレクトリの各定義の description を参照）。

関心のある領域（省略時は全体）: $ARGUMENTS

## 組織図

HEADER
  build_org_chart
  cat <<'FOOTER'

最後に利用方法を案内する:
- 案件の依頼: `/hw:request <内容>`（統括が自動で分担）
- 特定の専門家に直接依頼: `@hw:<エージェント名>` で言及するか、依頼内容に専門領域を明記
- その他のコマンド: /hw:plan（計画のみ）/ /hw:standup（進捗報告）/ /hw:review（総合レビュー）/ /hw:release（リリース準備）/ /hw:report（定期レポート）/ /hw:routine（定期実行の設定）
FOOTER
} > "$OUTPUT_FILE"

echo "生成しました: $OUTPUT_FILE（対象エージェント数: ${#AGENT_FILES[@]}）" >&2
