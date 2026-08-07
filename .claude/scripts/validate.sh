#!/usr/bin/env bash
#
# hermit-works リポジトリ（agents / commands / skills）の静的検証スクリプト。
#
# 検証内容:
#   1. frontmatter 必須項目の欠落チェック
#      - agents/*.md              : name, model, description
#      - commands/*.md            : description
#      - .claude/commands/*.md    : description（保守用ローカルコマンド。issue #72。
#        配置規約は CONTRIBUTING 3.6。README一覧突合（セクション5）の対象外）
#      - skills/<dir>/SKILL.md    : name, description
#      - .claude/skills/<dir>/SKILL.md : name, description（保守用ローカルスキル。
#        CONTRIBUTING 4.6。README一覧突合（セクション5）の対象外）
#   2. agents の命名規則違反チェック
#      - ファイル名と frontmatter の name が一致していること（大文字小文字を区別する完全一致）
#      - name が "<group>-<role>" 形式であること
#      - group が既定10種（strat/mgmt/biz/ana/eng/infra/qa/sec/docs/ai）に含まれること
#   3. agents の frontmatter name 重複チェック（大文字小文字を区別する完全一致）
#   4. skills のディレクトリ名と frontmatter name の一致チェック
#      （skills/<dir>/SKILL.md・.claude/skills/<dir>/SKILL.md の両方が対象）
#   5. README.md 記載のエージェント一覧・コマンド一覧・スキル一覧と、実ファイル構成の整合性チェック
#      （記載漏れ・余剰・件数の不一致を検出）
#      加えて、見出し未検出または該当テーブルからのトークン抽出が0件だった場合もERRORとする
#      （README見出し文言の変更等により検証が静かに空振りするリスクへの対処）
#      README.md が不在の場合も即終了はせず、他セクション（1〜3）の検知結果を握りつぶさない
#      よう通常のERRORとして記録したうえで、README依存のセクション4のみをスキップする。
#   （6は B8 対応でチェック自体を撤去。旧: agents/mgmt-coordinator.md の
#      「組織構成（振り分け先）」表との整合性チェック。組織図の正は
#      README.md / commands/show-org.md の2箇所に整理。欠番は振り直さない）
#   7. commands/show-org.md と、.claude/scripts/generate-show-org.sh の生成結果との差分チェック
#      （show-org.md は本来 agents/*.md の frontmatter から機械的に再生成すべき内容であり、
#      手書きで乖離していないかを検出する。生成スクリプト自体の実行失敗もERRORとする）
#   8. 秘密情報混入チェック（シークレットスキャン）
#      リポジトリ内の追跡対象ファイル全般（.git 配下・本チェックの回帰テスト用ハーネスを除く）を
#      対象に、AWSアクセスキー・既知プレフィックスのAPIキー/トークン・秘密鍵ブロック・
#      パスワード等の代入形・認証情報付き接続文字列を検出する。変更種別を問わず全変更で
#      常時実施する必須ゲート（sec-lead方針）として、人手（目視）チェックを機械チェックに
#      置き換えるもの。
#   9. エージェント作業ガードレール（第1弾1-2・第2弾2-1）の機械検証
#      正典（GUIDELINE_* 定数・対象ファイルリスト）は .claude/scripts/lib/guidelines.sh。本スクリプトは
#      それを source して検証のみを行う（2026-08-01案件B。DESIGN.md 2.30参照）。
#      (a) 共通ガードレール6短文（SEC-12/PI-6/AI-2統合。利用者資材優先の共通文の直後に
#          挿入される短文6行。正典: .claude/scripts/lib/guidelines.sh の GUIDELINE_COMMON_LINES 定数）が、
#          agents/*.md 全件で当該共通文の直後に連続6行としてバイト同一で存在するかを検証する
#          （欠落・改変・位置ずれ・分断はいずれもERROR）。
#      (b) 非リーダー（ファイル名が mgmt-coordinator と不一致、かつ末尾が -lead でない）
#          エージェントの frontmatter disallowedTools に Agent が含まれているかを検証する
#          （TK-7。委任経路の統制。tools 許可リストで元々Agent/Taskが許可されていないエージェント
#          （例: qa-review.md）は対象外）。
#      (c) 非リーダー全件の本文に TK-2/E-1統合文（正典⑤節。連携節の実行主体明文化。
#          `## 連携` 節冒頭に挿入される1行）が逐語存在するかを検証する（欠落はERROR。
#          リーダーは対象外＝委任行為自体が業務のため）。
#      (d) 利用者資材を直接読む commands/skills 固定5ファイル（skills/conventions/SKILL.md・
#          skills/repo-map/SKILL.md・commands/optimize-assets.md・commands/audit-assets.md・
#          commands/draft-docs.md）に、
#          注入耐性文言（正典: .claude/scripts/lib/guidelines.sh の GUIDELINE_INJECTION_NOTE_LINE 定数。P-4a/P-4b
#          対応）が逐語存在するかを検証する（欠落はERROR。前後文脈・行位置には依存しない
#          存在検証）。対象ファイルが存在しない検証対象ディレクトリ（テストフィクスチャ等）は
#          セクション6・10(b)と同様にERRORにはせず静かにスキップする。
#      (e) 判断手順共通文言（正典: .claude/scripts/lib/guidelines.sh の GUIDELINE_DECISION_PROCEDURE_LINE 定数。
#          「判断に迷った場合の段階的判断手順」案件T1で作業方針節へ挿入された1行）が、
#          agents/mgmt-coordinator.md を除く agents/*.md 全件（リーダー・非リーダー問わず）に
#          逐語存在するかを検証する（欠落はERROR。前後文脈・行位置には依存しない存在検証。
#          mgmt-coordinator.md は別文言のため対象外）。
#      (f) tracker連携スキル固定2ファイル（skills/tracker-setup/SKILL.md・
#          skills/tracker-sync/SKILL.md。TRACKER_SKILLS_EXTERNAL_INPUT_FILES）に、外部
#          トラッカー由来の非信頼入力宣言（正典: .claude/scripts/lib/guidelines.sh の GUIDELINE_EXTERNAL_INPUT_NOTE_LINE
#          定数。両ファイルに逐語同一で存在する1文。外部進捗管理ツール連携 7.10 f1対応）が
#          逐語存在するかを検証する（欠落はERROR。(d)と同様、前後文脈・行位置に依存しない
#          存在検証で、対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする）。
#          あわせて skills/tracker-sync/SKILL.md のスナップショットテンプレート内の非信頼
#          データ宣言文言（正典: GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_BLOCK 定数）が逐語存在
#          するかも検証する（欠落はERROR。同ファイル不在時は静かにスキップする）。
#      (g) skills/import-assets/SKILL.md 固定1ファイル（IMPORT_ASSETS_UNTRUSTED_INPUT_FILES）に、
#          zip 同梱資産由来の非信頼入力宣言（正典: .claude/scripts/lib/guidelines.sh の
#          GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_LINE 定数。AI資産の横展開（エクスポート／
#          インポート）案件 qa-review High-1・CONTRIBUTING 1.4 原則4対応）が逐語存在するかを
#          検証する（欠落はERROR。(d)(f)と同様、前後文脈・行位置に依存しない存在検証で、
#          対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする）。
#      (h) permission-rules トリガー行固定3ファイル（agents/sec-audit.md・
#          agents/sec-appsec.md・agents/infra-devops.md。PERMISSION_TRIGGER_LINE_FILES）に、
#          `hw:permission-rules` スキル参照トリガー行（正典: .claude/scripts/lib/guidelines.sh の
#          GUIDELINE_PERMISSION_TRIGGER_LINE 定数。DESIGN 2.27 追補・CONTRIBUTING 1.4
#          原則4「検知手段のない規範は追加しない」対応）が逐語存在するかを検証する
#          （欠落はERROR。(d)(f)(g)と同様、前後文脈・行位置に依存しない存在検証で、
#          対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする）。
#      (i) 非リーダー（is_leader_agent_name が偽）の agents/*.md 本文に、context: fork
#          スキル呼び出しトークン（正典: .claude/scripts/lib/guidelines.sh の FORK_SKILL_CALL_TOKENS
#          定数＝`hw:repo-map`・`hw:conventions`。CONTRIBUTING 4.2 運用規範「fork スキルは
#          メイン会話・リーダー層から呼ぶ」対応。2026-08-03案件issue28 sec-audit差し戻し
#          M-s3・CONTRIBUTING 1.4 原則4「検知手段のない規範は追加しない」対応）が部分文字列
#          として含まれていないかを検証する（検出はERROR。リーダー層（mgmt-coordinator・
#          *-lead）は運用規範上呼び出しが許容されるため対象外。commands/・skills/ 本文は
#          これらのスキルを実際に呼び出す定型手順を持つため（正当な呼び出し）検査対象に
#          含めない）。
#      (j) commands/*.md 固定12ファイル（COMMANDS_URL_DELIMITER_FILES）に、URL区切り規約行
#          （正典: .claude/scripts/lib/guidelines.sh の GUIDELINE_URL_DELIMITER_LINE 定数。
#          2026-08-04案件「URL 区切り規約の commands 展開＋機械検証化」T2対応。統括が
#          PR報告で URL を `**` 強調＋全角括弧で挟みリンク不能にした事象への再発防止）が
#          逐語存在するかを検証する（欠落はERROR。(d)(f)(g)(h)と同様、前後文脈・行位置に
#          依存しない存在検証で、対象ファイルが存在しない検証対象ディレクトリでは静かに
#          スキップする）。
#   10. エージェント数量表記の検証射程拡張（AI資材最適化計画 C-1。従来の数量チェック
#       [5] が README.md のみを対象とし、.claude-plugin/*.json・DESIGN.md・
#       DEVELOPMENT.md が死角になっていた是正）
#      (a) .claude-plugin/marketplace.json・plugin.json の description に、数値による
#          エージェント数表記（例:「49エージェント」「50名」）が再混入していないかを
#          検証する（ERROR。数値非依存の表現への統一方針を機械的に担保する）。
#      (b) DESIGN.md の「Nグループ・M名」・DEVELOPMENT.md の「エージェント定義（N体」
#          という、現在値としてのエージェント数表記を実体（agents/*.md の数）と突合する
#          （ERROR）。時点明示付きの履歴記述（例:「当時（49体時点）」）は表記の形が
#          異なるため対象外（誤検知しない）。
#   11. スクリプト・CI定義のファイルモード検査（CONTRIBUTING 8.2 の機械化。
#       トークン消費効率改善 第2弾T3）
#       対象範囲は CONTRIBUTING 8.1 と同一（.claude/scripts/ 配下全体・.github/workflows/ 配下・
#       .github/dependabot.yml）。この範囲内の git index 上のファイルモード
#       （`git ls-files -s` で確認できる値）が、`.sh` は 100755、それ以外（.yml・
#       fixtures配下のデータファイル等）は 100644 であることを検証する（ERROR）。
#       第1弾コミット時に 100644 の .sh がすり抜けた実害（WSL2 の core.fileMode 環境）
#       への対処。REPO_ROOT が git 作業ツリーでない場合は判定根拠がないため静かに
#       スキップする（エラーにはしない）。
#   12. Markdown 文書中のリポジトリ内パス参照の実在検証（issue #34。文書間のパス相互
#       参照が多く、リネーム・削除時に散文中の参照が「静かに嘘になる」死角への対処。
#       セクション4のREADME一覧突合は表形式の一覧のみが対象で、通常の散文中の
#       バッククォート付きパス参照は対象外だった）
#       対象文書: README.md / CLAUDE.md / CONTRIBUTING.md / DESIGN.md /
#       DEVELOPMENT.md / agents/*.md / commands/*.md / skills/*/SKILL.md /
#       .claude/commands/*.md（保守用ローカルコマンド。issue #72）/
#       .claude/skills/*/SKILL.md（保守用ローカルスキル。CONTRIBUTING 4.6）。対象文書が
#       存在しない検証対象ディレクトリ（テストフィクスチャ等）は、該当ファイルのみ
#       静かにスキップし（セクション6・9(d)・10・11と同様）、対象文書が1件も
#       存在しない場合は本セクション自体を静かにスキップする（エラーにはしない）。
#       検出: バッククォートで囲まれた文字列を空白区切りの単語に分割し、先頭が
#       agents/ commands/ skills/ scripts/ .claude/ .github/ .claude-plugin/ .hw/ のいずれかで
#       始まり、末尾が .md/.sh/.json/.yml/.yaml のいずれかで終わる単語を
#       「リポジトリ内パス形トークン」として抽出する（実行例のような複数語の
#       バッククォート内でも、パス部分のみを単語として正しく拾う）。不在はERROR。
#       除外（4分類。件数は0件でも必ずサマリーへ出力する。セクション5と同思想）:
#         (1) .hw/ 配下（利用者側生成パス）
#         (2) `<` または `…` を含む（プレースホルダ）
#         (3) `*` を含む（ワイルドカード。REPO_ROOT基準でglob展開し1件以上実在すれば
#             PASS、0件はERROR）
#         (4) 実在検証の対象外として個別に許容する明示除外リスト（.github/copilot-instructions.md
#             は commands/optimize-assets.md・skills/conventions/SKILL.md が他AIツール向け
#             資材の例として挙げているだけで本リポジトリ内には実在しないことを承知のうえでの
#             例示。.claude/settings.local.json は .gitignore 済みで実在しないファイルへの
#             言及があるため）
#       対象文書全体（存在するファイルのみ）から抽出条件に一致するトークンが1件も
#       取れなかった場合もERRORとする（検出パターンの変化等による検証の静かな空振り
#       検知。セクション4のREADME抽出0件チェックと同思想）。
#       トラバーサル拒否: 抽出後トークンが `..` を含む場合は、上記4分類の除外判定
#       および実在確認（-f 判定・compgen -G によるワイルドカード展開）へ到達する前に
#       短絡し、doc-path-ref-traversal カテゴリでERRORとする（差し戻し対応
#       SEC-L1/qa-L3）。正当な文書内パス参照はリポジトリ直下からの相対パスのみを
#       想定しており `..` が現れる余地はないため、この短絡はREPO_ROOT外パスの
#       存在有無をファイルシステムへ探査させない安全側の設計。件数はサマリー行へ
#       0件でも出力する（他4分類と同様）。
#       既知の限界（現時点で顕在化なし。品質ゲート差し戻しでの指摘・記録事項）:
#         - フェンス付きコードブロック（```で囲まれた範囲）内のバッククォート付き
#           パス例示も区別せず抽出対象とする（qa-review M1）。将来コードブロック内の
#           例示パスが誤検知になりうる。
#         - バッククォートの対応は1行内で完結する前提で、複数行にまたがるバック
#           クォートのスパンには対応しない（qa-review N3）。
#
# 採用理由（旧 scripts/validate.ps1 からの移行にあたって）:
#   devcontainer（Linux）ベースの開発環境への移行に伴い、実行環境の前提を
#   Windows/PowerShell 5.1 から Linux/bash に変更する。
#   本リポジトリは Node.js / Python 等の外部ランタイムに依存しない方針を維持しており、
#   対象ファイルは frontmatter（単純な "key: value" 形式のYAML）+ Markdown本文のみで、
#   複雑なYAMLパース（ネスト・多行文字列・配列等）は不要なため、
#   devcontainer に標準搭載されている bash + POSIX 標準ツール（grep/sed/awk/sort等）のみで
#   実装する（jq/yq/python 等の追加ランタイムは導入しない）。
#
# 実行例:
#   bash .claude/scripts/validate.sh
#   bash .claude/scripts/validate.sh /path/to/repo-root
#
set -euo pipefail

# ロケールをCに固定する。
# devcontainer既定の LANG=ja_JP.UTF-8 等、Cでないロケール下では、bashの正規表現の
# 文字クラス（[a-z0-9]等）がロケール依存の照合順序で解釈され、想定外の文字（大文字等）
# にもマッチしてしまうことがある（例: AGENT_NAME_PATTERN の [a-z0-9]+ が
# ja_JP.UTF-8 下では大文字にもマッチし、命名規則違反=naming-formatの検知漏れを起こす）。
# 本スクリプトの正規表現はASCII範囲のみを対象とする設計のため、LC_ALL=C固定でこれを防ぐ。
# README等のUTF-8日本語見出し（例: 組織図）はバイト列としてのリテラル一致で扱われるため、
# この固定による検出への影響はない。
export LC_ALL=C

# ---------------------------------------------------------------------------
# リポジトリルートの決定（第1引数 省略時はこのスクリプトの1階層上）
# ---------------------------------------------------------------------------

# SCRIPT_DIR は「このバリデータ自身が置かれているディレクトリ」であり、REPO_ROOT
# （検証対象。フィクスチャ等の別ディレクトリの場合がある）とは独立に、常に計算する
# （generate-show-org.sh の解決に REPO_ROOT ではなく SCRIPT_DIR を使うため。後述セクション6）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

shopt -s nullglob

# ---------------------------------------------------------------------------
# 定数
# ---------------------------------------------------------------------------

ALLOWED_GROUPS="strat mgmt biz ana eng infra qa sec docs ai"
# AGENT_NAME_PATTERN は ALLOWED_GROUPS から動的生成する（二重管理を避けるため）。
ALLOWED_GROUPS_ALT="${ALLOWED_GROUPS// /|}"
AGENT_NAME_PATTERN="^(${ALLOWED_GROUPS_ALT})-[a-z0-9]+\$"

# エージェント作業ガードレールの逐語検証用文言・対象ファイルリスト定数（GUIDELINE_* および
# COMMANDS_SKILLS_INJECTION_FILES 等）は、正典 .claude/scripts/lib/guidelines.sh へ移設した
# （2026-08-01案件B。DESIGN.md 2.30参照）。SCRIPT_DIR 相対で source する（REPO_ROOT 相対に
# しない理由は .claude/scripts/lib/guidelines.sh 内の設計判断コメント参照。フィクスチャ独立性・
# テスト独立性の本旨は lib 切り出し後も維持している）。
source "$SCRIPT_DIR/lib/guidelines.sh"

# ---------------------------------------------------------------------------
# 共通ユーティリティ
# ---------------------------------------------------------------------------

# 検出した問題を貯めるリスト。各要素は "SEVERITY<TAB>CATEGORY<TAB>TARGET<TAB>MESSAGE"。
ISSUES=()

add_issue() {
  # $1=Severity(ERROR/WARN) $2=Category $3=Target $4=Message
  # 注: 現時点では 'WARN' を渡す呼び出しは存在せず、常に 'ERROR' のみが使われる
  # （検出する問題はすべてリリース判定に関わる必須項目として扱う方針のため）。
  # WARN 区分・集計の仕組み自体は、将来 ERROR ほど厳格でない指摘（将来的な非推奨警告等）を
  # 追加する余地を残すために維持している。
  ISSUES+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
}

# 文字列末尾の空白（スペース・タブ）を除去する。
trim_trailing_ws() {
  local v="$1"
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# frontmatter（先頭の --- ... --- ブロック）を単純な key: value として読み取り、
# グローバル連想配列 FM に格納する。複雑なYAML（配列・ネスト・多行文字列）は対象外
# （本リポジトリの規約上不要のため）。
#
# 注意:
#   - キーは大文字小文字を区別する（bash連想配列のキーは既定で大文字小文字を区別する
#     ため、'Name: xxx' のような不正な大文字混じりキーは 'name' とは別物として扱われ、
#     必須項目チェックで欠落として検知される）。
#   - 同一キーが複数ある場合は最初の値を採用する。
#   - CRLF 混在に対応するため、読み取った各行の末尾 \r を除去する。
#   - frontmatterブロックが見つからない場合（先頭行が "---" でない、または閉じの
#     "---" が見つからないまま終端した場合）は戻り値 1（false）を返す。
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
        local val
        val="$(trim_trailing_ws "${BASH_REMATCH[2]}")"
        if [ -z "${FM[$key]+x}" ]; then
          FM[$key]="$val"
        fi
      fi
    fi
  done < "$file"

  # 閉じの "---" が見つからないまま終端した
  return 1
}

# FM[$1] が存在し、かつ空白のみでない（=有効な値を持つ）かを判定する。
fm_has_value() {
  local key="$1"
  if [ -z "${FM[$key]+x}" ]; then
    return 1
  fi
  local v="${FM[$key]}"
  if [[ "$v" =~ ^[[:space:]]*$ ]]; then
    return 1
  fi
  return 0
}

# frontmatter中の指定キー（$2、例: 'tools' / 'disallowedTools'）の値を配列として読み取り、
# グローバル配列 FM_LIST に格納する（parse_frontmatter は単純な "key: value" の1行のみを
# 対象とする単純実装のため、配列値を持つキーは別関数として分離している）。
#
# 対応する記法（本リポジトリで実際に使われている/使われうる範囲のみ。ネスト等の複雑な
# YAMLは非対応の既存方針を踏襲する）:
#   - ブロックスタイル: "key:" の次行以降に "  - 値" が連続する形
#       例: disallowedTools:\n  - Write\n  - Edit
#   - フロースタイル:   "key: [値1, 値2]"
#   - カンマ区切りインライン（値1件のみの場合を含む）: "key: 値1, 値2" / "key: 値1"
#
# frontmatterブロックが見つからない、または指定キーが存在しない場合は空配列のまま返す
# （呼び出し側で frontmatter-missing 等は既に別途検知済みの前提）。
extract_frontmatter_list_field() {
  local file="$1" field="$2"
  FM_LIST=()
  local in_block=0
  local is_first_line=1
  local collecting=0
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"

    if [ "$is_first_line" -eq 1 ]; then
      is_first_line=0
      if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
        in_block=1
        continue
      else
        return 0
      fi
    fi

    [ "$in_block" -eq 1 ] || continue

    if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
      return 0
    fi

    if [ "$collecting" -eq 1 ]; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.+)$ ]]; then
        local item
        item="$(trim_trailing_ws "${BASH_REMATCH[1]}")"
        [ -n "$item" ] && FM_LIST+=("$item")
        continue
      else
        collecting=0
        # ブロックスタイルの終端（インデント解除 or 空行）。このまま同じ行を
        # 下の通常キー判定に読み進める（次のキー行の可能性があるため continue しない）。
      fi
    fi

    if [[ "$line" =~ ^${field}:[[:space:]]*(.*)$ ]]; then
      local rest
      rest="$(trim_trailing_ws "${BASH_REMATCH[1]}")"
      if [ -z "$rest" ]; then
        collecting=1
      elif [[ "$rest" =~ ^\[(.*)\]$ ]]; then
        local inner="${BASH_REMATCH[1]}"
        # sec-audit差し戻し(1回目) [Low] への対応: 非クォートの `for tok in $inner` は
        # 単語分割後にパス名展開（グロブ）を受けうる（例: 値に "*" を含む場合）。
        # `read -ra` は入力をIFSで分割して配列へ格納するのみでグロブを行わないため、
        # こちらに置き換える（IFSはreadコマンドへの一時代入としてこの1行のみに限定する）。
        local -a toks=()
        IFS=',' read -ra toks <<< "$inner"
        local tok
        for tok in "${toks[@]}"; do
          tok="$(printf '%s' "$tok" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          [ -n "$tok" ] && FM_LIST+=("$tok")
        done
      else
        local -a toks=()
        IFS=',' read -ra toks <<< "$rest"
        local tok
        for tok in "${toks[@]}"; do
          tok="$(printf '%s' "$tok" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          [ -n "$tok" ] && FM_LIST+=("$tok")
        done
      fi
    fi
  done < "$file"

  return 0
}

# ファイル名（agents/<name>.md の <name> 部分）がリーダー職（mgmt-coordinator または
# 末尾が -lead）かどうかを判定する。TK-7の対象外判定（リーダーは委任行為自体が業務のため
# disallowedTools への Agent 追加を要求しない）に使う。.claude/scripts/tests/ の判定規則
# （末尾 -lead / mgmt-coordinator 一致）と同一にする。
# is_leader_agent_name は .claude/scripts/lib/guidelines.sh（正典）で定義され、source 済み
# （2026-08-01案件T6で自前実装を撤去し集約。CONTRIBUTING.md 1.5・1.8参照）。

# README.md の指定見出し（正規表現、行頭からの部分一致）直後にある Markdown テーブル
# （| で始まる行の連続）から、バッククォートで囲まれたトークンを1行1トークンで標準出力する。
# 見出し直後の最初のテーブルのみを対象とするため、無関係な別テーブル（例: モデル割り当て表）は
# 混入しない。見出しが見つからない場合は何も出力しない。
#
# 注意（旧 validate.ps1 からの申し送り事項への対応）:
#   見出しが見つからない場合、または見出しは見つかったがテーブルからトークンを1件も抽出できない
#   場合、本関数は「黙って」空を返す（副作用なし）。README の見出し文言変更等でこの状態に陥ると
#   検証が静かに空振りしてしまうため、呼び出し側で戻り値（抽出件数）が0件の場合に必ずERRORを
#   記録すること（本ファイル内の呼び出し箇所を参照）。
extract_readme_table_tokens() {
  local header_pattern="$1"
  local n=${#README_LINES[@]}
  local header_idx=-1
  local i

  for ((i = 0; i < n; i++)); do
    if [[ "${README_LINES[$i]}" =~ $header_pattern ]]; then
      header_idx=$i
      break
    fi
  done
  if [ "$header_idx" -lt 0 ]; then
    return 0
  fi

  i=$((header_idx + 1))
  while [ "$i" -lt "$n" ] && [[ "${README_LINES[$i]}" =~ ^[[:space:]]*$ ]]; do
    i=$((i + 1))
  done

  local bt_pattern='`([^`]+)`'
  while [ "$i" -lt "$n" ] && [[ "${README_LINES[$i]}" =~ ^[[:space:]]*\| ]]; do
    local rest="${README_LINES[$i]}"
    while [[ "$rest" =~ $bt_pattern ]]; do
      printf '%s\n' "${BASH_REMATCH[1]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    i=$((i + 1))
  done
}

# 配列を ", " 区切りで連結する（メッセージ整形用）。
join_comma() {
  local result="" first=1 x
  for x in "$@"; do
    if [ "$first" -eq 1 ]; then
      result="$x"
      first=0
    else
      result="$result, $x"
    fi
  done
  printf '%s' "$result"
}

# 名前集合（左側集合 vs 実ファイル集合）を突合する汎用関数。差分があればERRORを記録する。
#
# 統合の経緯（M15是正。eng-lead承認済みの実装方針に厳密に従う）: 元は README用の
# compare_readme_to_files と mgmt-coordinator用の compare_coordinator_to_files の
# 2関数に分かれていたが、約45行がほぼ完全重複しており片側のみ修正されるドリフトの
# リスクがあったため、本関数へ統合した。呼び出し側の違い（ラベル・カテゴリ・
# 対象ファイル・突合先の呼称）はすべて引数で表現する。
#
# 引数:
#   $1 label         : メッセージ先頭に付ける接頭辞（例:「エージェント一覧」「コマンド一覧」）。
#                       空文字列を渡した場合は接頭辞（"${label}: "）を付けない。
#                       これにより、元コードで非対称だった2種類のメッセージ文字列
#                       （README側は "${label}: " 付き、mgmt-coordinator側は接頭辞なし）を、
#                       単一の実装のままバイト同一で再現する。
#   $2 category      : add_issue の第2引数（例: 'readme-sync' / 'coordinator-sync'）。
#   $3 target_file   : add_issue の第3引数（例: 'README.md' / 'agents/mgmt-coordinator.md'）。
#   $4 listing_noun  : 突合先の呼称（例: 'README一覧' / '振り分け表'）。メッセージ文中の
#                       「〜に記載がない」「〜に記載があるが」の主語として使う。
#   $5 左側集合の配列（nameref）: README側トークン一覧 / mgmt-coordinator振り分け表トークン一覧 等。
#   $6 実ファイル一覧の配列（nameref）。
#
# nameref のローカル名 _cmp_left_arr / _cmp_files_arr は、呼び出し側の実引数名
# （README_AGENT_TOKENS・COMMAND_NAMES_FROM_FILES・AGENT_NAMES_FROM_FILES 等。
#   旧 COORDINATOR_AGENT_TOKENS 含む）のいずれとも衝突しない名前にしてある
# （nameref循環参照回避。元の _readme_arr / _coord_arr / _files_arr 方式を踏襲）。
#
# 結果件数はグローバル変数 CMP_LEFT_COUNT / CMP_FILE_COUNT に格納する（本関数を
# コマンド置換 $(...) 内で呼ぶと ISSUES への追記がサブシェル内に閉じ込められて
# 失われるため、戻り値はグローバル変数経由で受け渡す。元の2関数それぞれが個別に
# 持っていた同種の設計判断を統合後も引き継ぐ）。
#
# （B8対応で mgmt-coordinator 突合の呼び出し箇所は撤去済み。現行の呼び出し元は
# README突合の3箇所のみ）。
compare_name_sets() {
  local label="$1"
  local category="$2"
  local target_file="$3"
  local listing_noun="$4"
  local -n _cmp_left_arr="$5"
  local -n _cmp_files_arr="$6"

  local prefix=""
  if [ -n "$label" ]; then
    prefix="${label}: "
  fi

  local -A left_set=()
  local -A file_set=()
  local n

  if [ "${#_cmp_left_arr[@]}" -gt 0 ]; then
    for n in "${_cmp_left_arr[@]}"; do left_set["$n"]=1; done
  fi
  if [ "${#_cmp_files_arr[@]}" -gt 0 ]; then
    for n in "${_cmp_files_arr[@]}"; do file_set["$n"]=1; done
  fi

  local missing_in_left=() missing_in_files=()
  if [ "${#file_set[@]}" -gt 0 ]; then
    for n in "${!file_set[@]}"; do
      if [ -z "${left_set[$n]+x}" ]; then missing_in_left+=("$n"); fi
    done
  fi
  if [ "${#left_set[@]}" -gt 0 ]; then
    for n in "${!left_set[@]}"; do
      if [ -z "${file_set[$n]+x}" ]; then missing_in_files+=("$n"); fi
    done
  fi

  if [ "${#missing_in_left[@]}" -gt 0 ]; then
    local sorted_str
    sorted_str="$(printf '%s\n' "${missing_in_left[@]}" | LC_ALL=C sort)"
    local -a sorted=()
    while IFS= read -r n; do sorted+=("$n"); done <<< "$sorted_str"
    add_issue 'ERROR' "$category" "$target_file" \
      "${prefix}実ファイルには存在するが${listing_noun}に記載がない → $(join_comma "${sorted[@]}")"
  fi
  if [ "${#missing_in_files[@]}" -gt 0 ]; then
    local sorted_str
    sorted_str="$(printf '%s\n' "${missing_in_files[@]}" | LC_ALL=C sort)"
    local -a sorted=()
    while IFS= read -r n; do sorted+=("$n"); done <<< "$sorted_str"
    add_issue 'ERROR' "$category" "$target_file" \
      "${prefix}${listing_noun}に記載があるが実ファイルが存在しない → $(join_comma "${sorted[@]}")"
  fi

  CMP_LEFT_COUNT=${#left_set[@]}
  CMP_FILE_COUNT=${#file_set[@]}
}

# ---------------------------------------------------------------------------
# 1) agents/*.md の検証
# ---------------------------------------------------------------------------

AGENTS_DIR="$REPO_ROOT/agents"

# qa-review検出(L8)への対応: agents/ ディレクトリ自体が存在しない場合、nullglobにより
# 下記の "$AGENTS_DIR"/*.md は単に空配列になり、後続のforループも0件のまま黙って
# 通過してしまう（「0件」なのか「ディレクトリごと不在」なのかが区別できない）。
# README.md 不在チェック（セクション4）と対称に、ここでも専用のERRORを記録する
# （即exitはせず、後続セクションの検知結果は握りつぶさない設計も README 同様）。
if [ ! -d "$AGENTS_DIR" ]; then
  add_issue 'ERROR' 'agents-dir-missing' 'agents/' \
    "agents/ ディレクトリが見つかりません: $AGENTS_DIR （リポジトリルートの指定が正しいか確認してください。第1引数、既定はこのスクリプトの1階層上）"
fi

AGENT_FILES=("$AGENTS_DIR"/*.md)

AGENT_NAMES_FROM_FILES=()
declare -A AGENT_NAME_COUNT=()

for f in "${AGENT_FILES[@]}"; do
  [ -f "$f" ] || continue
  base_name="$(basename "$f" .md)"
  AGENT_NAMES_FROM_FILES+=("$base_name")

  if ! parse_frontmatter "$f"; then
    add_issue 'ERROR' 'frontmatter-missing' "agents/$(basename "$f")" \
      'frontmatterブロック（---で囲まれた領域）が見つかりません'
    continue
  fi

  for req in name model description; do
    if ! fm_has_value "$req"; then
      add_issue 'ERROR' 'frontmatter-required' "agents/$(basename "$f")" \
        "必須項目 '$req' が欠落しています"
    fi
  done

  # name が空/欠落の場合は、既に上の frontmatter-required で欠落として検知済みのため、
  # ここでの命名規則チェック（mismatch/format/重複カウント）は連鎖的なERRORを避けるためスキップする。
  if fm_has_value 'name'; then
    name_val="${FM[name]}"

    if [ "$name_val" != "$base_name" ]; then
      add_issue 'ERROR' 'naming-mismatch' "agents/$(basename "$f")" \
        "ファイル名 '$base_name' と frontmatter name '$name_val' が一致しません"
    fi
    if ! [[ "$name_val" =~ $AGENT_NAME_PATTERN ]]; then
      add_issue 'ERROR' 'naming-format' "agents/$(basename "$f")" \
        "name '$name_val' が '<group>-<role>' 形式でないか、既定10グループ（${ALLOWED_GROUPS// /\/}）に該当しません"
    fi

    # 重複カウントは大文字小文字を区別する完全一致で行う（bash連想配列のキーは既定で
    # 大文字小文字を区別するため 'infra-devops' と 'Infra-Devops' は別キーとして扱われる）。
    AGENT_NAME_COUNT["$name_val"]=$(( ${AGENT_NAME_COUNT["$name_val"]:-0} + 1 ))
  fi
done

if [ "${#AGENT_NAME_COUNT[@]}" -gt 0 ]; then
  for k in "${!AGENT_NAME_COUNT[@]}"; do
    if [ "${AGENT_NAME_COUNT[$k]}" -gt 1 ]; then
      add_issue 'ERROR' 'name-duplicate' 'agents/' \
        "frontmatter name '$k' が ${AGENT_NAME_COUNT[$k]} 件のファイルで重複しています"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2) commands/*.md の検証
# ---------------------------------------------------------------------------

COMMANDS_DIR="$REPO_ROOT/commands"
COMMAND_FILES=("$COMMANDS_DIR"/*.md)
COMMAND_NAMES_FROM_FILES=()

for f in "${COMMAND_FILES[@]}"; do
  [ -f "$f" ] || continue
  base_name="$(basename "$f" .md)"
  COMMAND_NAMES_FROM_FILES+=("$base_name")

  if ! parse_frontmatter "$f"; then
    add_issue 'ERROR' 'frontmatter-missing' "commands/$(basename "$f")" \
      'frontmatterブロックが見つかりません'
    continue
  fi
  if ! fm_has_value 'description'; then
    add_issue 'ERROR' 'frontmatter-required' "commands/$(basename "$f")" \
      "必須項目 'description' が欠落しています"
  fi
done

# ---------------------------------------------------------------------------
# 2b) .claude/commands/*.md（保守用ローカルコマンド）の frontmatter 必須項目検証
#     （issue #72。配置規約は CONTRIBUTING 3.6。frontmatter description のみ必須。
#      対象ディレクトリが存在しない検証対象（テストフィクスチャ等）は、他の
#      「対象ファイルが存在しない検証対象ディレクトリ」系チェック（セクション6・
#      9(d)等）と同様に静かにスキップする（ERRORにはしない。agents/ ディレクトリ
#      不在チェックとは異なり、保守用ローカルコマンドは0件が正常状態でもあるため）。
#      README一覧突合（セクション4・COMMAND_NAMES_FROM_FILES）には含めない
#      （CONTRIBUTING 3.6: 保守用ローカルコマンドはREADME非更新のため）。
# ---------------------------------------------------------------------------

LOCAL_COMMANDS_DIR="$REPO_ROOT/.claude/commands"
LOCAL_COMMAND_FILES=("$LOCAL_COMMANDS_DIR"/*.md)

for f in "${LOCAL_COMMAND_FILES[@]}"; do
  [ -f "$f" ] || continue
  base_name="$(basename "$f")"

  if ! parse_frontmatter "$f"; then
    add_issue 'ERROR' 'frontmatter-missing' ".claude/commands/$base_name" \
      'frontmatterブロックが見つかりません'
    continue
  fi
  if ! fm_has_value 'description'; then
    add_issue 'ERROR' 'frontmatter-required' ".claude/commands/$base_name" \
      "必須項目 'description' が欠落しています"
  fi
done

# ---------------------------------------------------------------------------
# 3) skills/<dir>/SKILL.md の検証
# ---------------------------------------------------------------------------

SKILLS_DIR="$REPO_ROOT/skills"
SKILL_DIRS=("$SKILLS_DIR"/*/)
SKILL_NAMES_FROM_FILES=()

for d in "${SKILL_DIRS[@]}"; do
  [ -d "$d" ] || continue
  dir_name="$(basename "$d")"
  skill_file="$d/SKILL.md"

  if [ ! -f "$skill_file" ]; then
    add_issue 'ERROR' 'skill-missing-file' "skills/$dir_name/" 'SKILL.md が存在しません'
    continue
  fi
  SKILL_NAMES_FROM_FILES+=("$dir_name")

  if ! parse_frontmatter "$skill_file"; then
    add_issue 'ERROR' 'frontmatter-missing' "skills/$dir_name/SKILL.md" \
      'frontmatterブロックが見つかりません'
    continue
  fi
  for req in name description; do
    if ! fm_has_value "$req"; then
      add_issue 'ERROR' 'frontmatter-required' "skills/$dir_name/SKILL.md" \
        "必須項目 '$req' が欠落しています"
    fi
  done
  # name が空/欠落の場合は frontmatter-required 側で既に検知済みのため、ここではスキップする
  # （agentsの命名規則チェックと同様の連鎖ERROR回避）。
  if fm_has_value 'name' && [ "${FM[name]}" != "$dir_name" ]; then
    add_issue 'ERROR' 'naming-mismatch' "skills/$dir_name/SKILL.md" \
      "ディレクトリ名 '$dir_name' と frontmatter name '${FM[name]}' が一致しません"
  fi
done

# ---------------------------------------------------------------------------
# 3b) .claude/skills/<dir>/SKILL.md（保守用ローカルスキル）の検証
#     （CONTRIBUTING 4.6。保守用ローカルスキルを初めて追加する際、3.6（保守用
#      ローカルコマンド。セクション2b）と同様の対象拡張を行う定めに基づく。
#      必須項目（name/description）の欠落チェックはセクション2bと同型、
#      ディレクトリ名と frontmatter name の一致チェックは直上セクション3
#      （配布スキル向け）と同型で行う。
#      対象ディレクトリ（.claude/skills/）が存在しない、またはスキルが0件の場合
#      （保守用ローカルスキル0件が正常状態。2b・.claude/commands/と同様）は、
#      nullglobにより下記ループが自然に0回実行され、ERRORにはならない
#      （agents/ ディレクトリ不在チェックとは異なる扱い）。
#      README一覧突合（セクション4）の対象には含めない（CONTRIBUTING 4.6:
#      保守用ローカルスキルはREADME非更新のため）。
# ---------------------------------------------------------------------------

LOCAL_SKILLS_DIR="$REPO_ROOT/.claude/skills"
LOCAL_SKILL_DIRS=("$LOCAL_SKILLS_DIR"/*/)

for d in "${LOCAL_SKILL_DIRS[@]}"; do
  [ -d "$d" ] || continue
  dir_name="$(basename "$d")"
  skill_file="$d/SKILL.md"

  if [ ! -f "$skill_file" ]; then
    add_issue 'ERROR' 'skill-missing-file' ".claude/skills/$dir_name/" 'SKILL.md が存在しません'
    continue
  fi

  if ! parse_frontmatter "$skill_file"; then
    add_issue 'ERROR' 'frontmatter-missing' ".claude/skills/$dir_name/SKILL.md" \
      'frontmatterブロックが見つかりません'
    continue
  fi
  for req in name description; do
    if ! fm_has_value "$req"; then
      add_issue 'ERROR' 'frontmatter-required' ".claude/skills/$dir_name/SKILL.md" \
        "必須項目 '$req' が欠落しています"
    fi
  done
  # name が空/欠落の場合は frontmatter-required 側で既に検知済みのため、ここではスキップする
  # （直上セクション3・agentsの命名規則チェックと同様の連鎖ERROR回避）。
  if fm_has_value 'name' && [ "${FM[name]}" != "$dir_name" ]; then
    add_issue 'ERROR' 'naming-mismatch' ".claude/skills/$dir_name/SKILL.md" \
      "ディレクトリ名 '$dir_name' と frontmatter name '${FM[name]}' が一致しません"
  fi
done

# ---------------------------------------------------------------------------
# 4) README.md との整合性チェック
# ---------------------------------------------------------------------------

README_PATH="$REPO_ROOT/README.md"

# README突合系の集計値（README不在時はサマリー表示用に "-" のままにする）。
AGENT_README_COUNT='-'
AGENT_FILE_COUNT='-'
CMD_README_COUNT='-'
CMD_FILE_COUNT='-'
SKILL_README_COUNT='-'
SKILL_FILE_COUNT='-'

if [ ! -f "$README_PATH" ]; then
  # README.md が不在でも、ここで即終了すると、既にセクション1〜3
  # （agents/commands/skills検証）でISSUESに蓄積済みのERRORが一切出力されないまま
  # プロセスが終了してしまう（蓄積済みISSUESの握りつぶし）。そのため即exitはせず、
  # 通常のISSUESフローに乗せ、README依存のセクション4（整合性チェック）のみを
  # スキップして、最終の集計・出力・exit判定（結果出力セクション）へ必ず合流させる。
  add_issue 'ERROR' 'readme-missing' 'README.md' \
    "README.md が見つかりません: $README_PATH （リポジトリルートの指定が正しいか確認してください。第1引数、既定はこのスクリプトの1階層上）"
else
  README_LINES=()
  while IFS= read -r line || [ -n "$line" ]; do
    README_LINES+=("${line%$'\r'}")
  done < "$README_PATH"

  mapfile -t README_AGENT_TOKENS < <(extract_readme_table_tokens '^##[[:space:]]*組織図')
  if [ "${#README_AGENT_TOKENS[@]}" -eq 0 ]; then
    add_issue 'ERROR' 'readme-extract' 'README.md' \
      '「組織図」見出しが見つからないか、直後のテーブルからバッククォート付きトークンを1件も抽出できませんでした（見出し文言の変更等で検証が空振りしている可能性があります）'
  fi

  # 注意: 以下の見出しアンカー（'^##[[:space:]]*使い方' / '^##[[:space:]]*スキル'）
  # および `/hw:…`・`hw:…` トークン形式は commands/help.md 手順1（README走査）の実行時抽出も
  # 同一の前提に依存している（両者は独立に同じ見出しへ依存しているだけで、一方が他方を
  # 参照する関係ではない）。README.md の当該見出し文言を変更する場合は、本セクションだけでなく
  # commands/help.md 側の追従も必要になるため、変更する際は help.md 側も併せて確認すること
  # （issue #71 で help.md 側の本チェックへの名指し言及は削除したが、結合自体はここに残る）。
  README_COMMAND_TOKENS=()
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if [[ "$t" =~ ^/hw:([a-zA-Z0-9_-]+) ]]; then
      README_COMMAND_TOKENS+=("${BASH_REMATCH[1]}")
    fi
  done < <(extract_readme_table_tokens '^##[[:space:]]*使い方')
  if [ "${#README_COMMAND_TOKENS[@]}" -eq 0 ]; then
    add_issue 'ERROR' 'readme-extract' 'README.md' \
      '「使い方」見出しが見つからないか、直後のテーブルから /hw: コマンドトークンを1件も抽出できませんでした（見出し文言の変更等で検証が空振りしている可能性があります）'
  fi

  README_SKILL_TOKENS=()
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if [[ "$t" =~ ^hw:([a-zA-Z0-9_-]+) ]]; then
      README_SKILL_TOKENS+=("${BASH_REMATCH[1]}")
    fi
  done < <(extract_readme_table_tokens '^##[[:space:]]*スキル')
  if [ "${#README_SKILL_TOKENS[@]}" -eq 0 ]; then
    add_issue 'ERROR' 'readme-extract' 'README.md' \
      '「スキル」見出しが見つからないか、直後のテーブルから hw: スキルトークンを1件も抽出できませんでした（見出し文言の変更等で検証が空振りしている可能性があります）'
  fi

  compare_name_sets 'エージェント一覧' 'readme-sync' 'README.md' 'README一覧' README_AGENT_TOKENS AGENT_NAMES_FROM_FILES
  AGENT_README_COUNT=$CMP_LEFT_COUNT
  AGENT_FILE_COUNT=$CMP_FILE_COUNT

  compare_name_sets 'コマンド一覧' 'readme-sync' 'README.md' 'README一覧' README_COMMAND_TOKENS COMMAND_NAMES_FROM_FILES
  CMD_README_COUNT=$CMP_LEFT_COUNT
  CMD_FILE_COUNT=$CMP_FILE_COUNT

  compare_name_sets 'スキル一覧' 'readme-sync' 'README.md' 'README一覧' README_SKILL_TOKENS SKILL_NAMES_FROM_FILES
  SKILL_README_COUNT=$CMP_LEFT_COUNT
  SKILL_FILE_COUNT=$CMP_FILE_COUNT

  # README冒頭の「Nグループ・M名」記載と実数の突合
  #
  # qa-review検出(M14)への対応: 従来は README 全文を1つの文字列にしたうえで
  # `[[ text =~ pattern ]]` に渡していたが、これはleftmost（最初の一致）しか
  # 検出できず、記載が複数出現する場合に取りこぼす（セクション10の
  # DESIGN.md/DEVELOPMENT.md突合で既に採用済みの問題への対処と同一の問題）。
  # そのためセクション10と同じ「1行ずつ読み、行内でも
  # `${rest#*"${BASH_REMATCH[0]}"}` によりマッチ済み部分を順に取り除きながら
  # 再マッチさせる」方式に統一し、全出現を行番号に関わらず検証する。
  agent_file_total=0
  for f in "${AGENT_FILES[@]}"; do [ -f "$f" ] && agent_file_total=$((agent_file_total + 1)); done

  declare -A GROUP_SET=()
  for n in "${AGENT_NAMES_FROM_FILES[@]}"; do
    GROUP_SET["${n%%-*}"]=1
  done
  actual_groups=${#GROUP_SET[@]}

  for readme_count_line in "${README_LINES[@]}"; do
    readme_count_rest="$readme_count_line"
    while [[ "$readme_count_rest" =~ ([0-9]+)グループ・([0-9]+)名 ]]; do
      stated_groups="${BASH_REMATCH[1]}"
      stated_agents="${BASH_REMATCH[2]}"
      readme_count_rest="${readme_count_rest#*"${BASH_REMATCH[0]}"}"

      if [ "$stated_agents" -ne "$agent_file_total" ]; then
        add_issue 'ERROR' 'readme-count' 'README.md' \
          "README冒頭記載のエージェント数 '$stated_agents' と実ファイル数 '$agent_file_total' が一致しません"
      fi
      if [ "$stated_groups" -ne "$actual_groups" ]; then
        add_issue 'ERROR' 'readme-count' 'README.md' \
          "README冒頭記載のグループ数 '$stated_groups' と実際のグループ数 '$actual_groups' が一致しません"
      fi
    done
  done
fi

# 5) は B8 対応で撤去（agents/mgmt-coordinator.md の「組織構成（振り分け先）」表との
# 整合性チェック。組織図の正は README.md / commands/show-org.md の2箇所に整理。
# 欠番は振り直さない）。

# ---------------------------------------------------------------------------
# 6) commands/show-org.md と .claude/scripts/generate-show-org.sh の生成結果との差分チェック
#
# commands/show-org.md のうち組織図部分は、本来 agents/*.md の frontmatter から
# 機械的に再生成できる（generate-show-org.sh）。手書きの実ファイルが生成結果と
# 乖離していないかをここで検出する。
#
# 生成スクリプトは REPO_ROOT 側（検証対象。テスト用フィクスチャ等の場合もある）ではなく、
# このバリデータ自身と同じディレクトリ（SCRIPT_DIR）から解決する。フィクスチャ等
# 検証対象ディレクトリにはスクリプト一式（`.claude/scripts/` 相当）が存在しない場合があるため。
# ---------------------------------------------------------------------------

SHOW_ORG_PATH="$REPO_ROOT/commands/show-org.md"
GENERATE_SHOW_ORG_SH="$SCRIPT_DIR/generate-show-org.sh"

SHOW_ORG_DIFF_STATUS='-'

# 注意: commands/show-org.md が存在しない場合も、本チェックより前からある最小テスト
# フィクスチャ（.claude/scripts/tests/fixtures/base/）等、意図的に一部のファイルしか持たない
# 検証対象ディレクトリでの誤検知を避けるため、ERRORにはせず静かにスキップする。一方
# .claude/scripts/generate-show-org.sh は SCRIPT_DIR（このバリデータ自身のディレクトリ）から
# 解決するため、検証対象ディレクトリの構成に関わらず常に存在するはずのファイルであり、
# こちらが見つからない場合は通常どおりERRORとする。
if [ ! -f "$SHOW_ORG_PATH" ]; then
  :
elif [ ! -f "$GENERATE_SHOW_ORG_SH" ]; then
  add_issue 'ERROR' 'show-org-generate-missing' '.claude/scripts/generate-show-org.sh' \
    ".claude/scripts/generate-show-org.sh が見つかりません: $GENERATE_SHOW_ORG_SH"
else
  SHOW_ORG_TMP="$(mktemp)"
  # sec-audit/qa-review検出(L7)への対応: 割込み（Ctrl-C等）でスクリプトが中断した場合、
  # 下の正常経路の rm -f まで到達せず一時ファイルが残留しうる。EXIT/INT/TERM に
  # trapを張り、どちらの経路でも確実に削除されるようにする（正常経路の rm -f は
  # 冗長になるが、既に削除済みのパスへの rm -f はエラーにならないため両立させて問題ない）。
  trap 'rm -f "$SHOW_ORG_TMP"' EXIT INT TERM
  GENERATE_STDERR=""
  if GENERATE_STDERR="$(bash "$GENERATE_SHOW_ORG_SH" "$REPO_ROOT" "$SHOW_ORG_TMP" 2>&1 1>/dev/null)"; then
    if diff -q "$SHOW_ORG_PATH" "$SHOW_ORG_TMP" >/dev/null 2>&1; then
      SHOW_ORG_DIFF_STATUS='一致'
    else
      SHOW_ORG_DIFF_STATUS='差分あり'
      add_issue 'ERROR' 'show-org-drift' 'commands/show-org.md' \
        "生成スクリプト（.claude/scripts/generate-show-org.sh）の出力と実ファイルに差分があります（確認: bash .claude/scripts/generate-show-org.sh $REPO_ROOT /tmp/show-org-check.md && diff -u commands/show-org.md /tmp/show-org-check.md）"
    fi
  else
    SHOW_ORG_DIFF_STATUS='生成失敗'
    add_issue 'ERROR' 'show-org-generate-failed' '.claude/scripts/generate-show-org.sh' \
      "生成スクリプトの実行に失敗しました: ${GENERATE_STDERR}"
  fi
  rm -f "$SHOW_ORG_TMP"
fi

# ---------------------------------------------------------------------------
# 8) 秘密情報混入チェック（シークレットスキャン）
#
# 対象: リポジトリ内のファイル全般（git管理下のもの）。
#   - git 管理下（REPO_ROOT が git 作業ツリーの場合）は、以下2つの合成を対象とする。
#       (a) `git ls-files`                         : 追跡済み（コミット/ステージ済み）ファイル
#       (b) `git ls-files --others --exclude-standard` : 未追跡（git add 前）だが
#           .gitignore 等では無視されていないファイル
#     (a)のみでは「git add 前の新規ファイル」が一切スキャンされず秘密情報混入チェックが
#     素通りしてしまう（コミット前にこそ検知したいはずの状況で機能しない）ため、(b)を
#     加える。一方、.gitignore で無視されたファイル（生成物等）は --exclude-standard に
#     より引き続き自然に除外される。
#   - git 作業ツリーでない場合（本スクリプトのテストフィクスチャ等）は `find` でフォールバック
#     し、.git 配下のみ除外する（この場合は追跡状態を区別する概念自体がないため、
#     存在する全ファイルが対象になる）。
#   - 以下の既知ファイルは明示的に対象外とする（ディレクトリ丸ごとの除外ではなく、
#     個々のファイルパスを列挙する。.claude/scripts/tests/ 配下を丸ごと除外すると、
#     .claude/scripts/tests/fixtures/ 等が将来汚染された場合に検知できなくなるため）。
#       - .claude/scripts/tests/run-tests.sh              : 本チェックの回帰テスト自身が、検出対象
#         パターンの実例をハーネスのソースコードに直接埋め込むため（除外しないと、本チェックが
#         自分自身のテストコードを「本物の漏えい」として誤検知し続けてしまう）。
#       - .claude/scripts/tests/run-git-changelog-tests.sh: 同様の理由で除外対象とする既知のテスト
#         ハーネスファイル（他の回帰テストスイート）。
#       - .claude/scripts/tests/run-aggregate-agent-token-usage-tests.sh: 現状このファイルに秘密情報
#         パターン該当文字列は存在しないが、姉妹ハーネス2件（上記）との対称性確保と、将来
#         このハーネスにも検出パターンの実例をフィクスチャ等として埋め込むテストケースが
#         追加された場合に備えた予防的措置として除外対象とする。
#       - .claude/scripts/validate.sh                      : 本チェック自身。本セクションのコメントは
#         検出パターンやカテゴリ名を説明のため文章中で言及しており（例: 「api-token」という
#         カテゴリ名や、キー代入形パターンの説明文自体）、これらの語がパターンに偶然
#         マッチしてしまう（検証ロジックが自分自身の説明コメントを誤検知する）自己参照
#         問題を避けるため。
#   - バイナリファイルは grep -I により自動的にスキップする。
#
# 検出パターン（grep -E, ERE。GNU grep拡張の \b 単語境界を使用）:
#   - secret-aws-key               AWSアクセスキーID（AKIA/ASIA等の既知プレフィックス+16桁）
#   - secret-api-token             既知サービス（GitHub/Slack/OpenAI/Anthropic/Google/Stripe）の
#                                   プレフィックス付きAPIキー/トークン類
#   - secret-private-key           PEM形式の秘密鍵ブロックヘッダー（"BEGIN" .. "PRIVATE KEY" の並び）
#   - secret-credential-assignment パスワード等のキー（DB_PASSWORD/SECRET_KEY 等の複合命名を
#                                   含む）に、十分な長さ（12文字以上の非空白）を持つ値が代入
#                                   されている形（値の文字種の多様性までは検証しない）
#   - secret-connection-string     スキーム付きURLに認証情報（ユーザー+パスワード）を埋め込んだ
#                                   接続文字列の形式
#
# 誤検知抑制: 上記いずれのカテゴリも、マッチした文字列自体に明らかなプレースホルダ
#   （xxx/yyy、example、changeme、<...>、your_key 等）が含まれる場合は検出対象から除外する。
#   検出時のメッセージには値そのものではなくマスク表示（先頭4文字...末尾4文字）のみを含める
#   （validate.sh の出力・ログに実際の秘密情報をそのまま残さないための配慮）。
# ---------------------------------------------------------------------------

# マッチした値の先頭/末尾のみを残し、中間をマスクする（出力に生値を残さないため）。
mask_secret_value() {
  local v="$1"
  local len=${#v}
  if [ "$len" -le 8 ]; then
    printf '%s' '***'
  else
    printf '%s...%s' "${v:0:4}" "${v: -4}"
  fi
}

# 明らかなプレースホルダ（誤検知源）を大文字小文字区別なしで判定する。
SECRET_PLACEHOLDER_RE="(xxx|yyy|zzz|dummy|sample|example|changeme|change_me|change-me|placeholder|redact|fake|foobar|your[_-]?(key|token|secret|password|api)|<[^>]+>|\\*{4,}|123456789012|000000000000|test[_-]?only|user:pass|username:password|user:password)"

# 検出パターン定義（カテゴリごと）。
SECRET_PATTERN_AWS="\\b(AKIA|ASIA|AIDA|AROA|AGPA|ANPA|ANVA|APKA)[0-9A-Z]{16}\\b"
SECRET_PATTERN_TOKEN="\\b(gh[pousr]_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,72}|sk-ant-[A-Za-z0-9_-]{20,120}|sk-[A-Za-z0-9]{20,100}|AIza[0-9A-Za-z_-]{35}|(sk|rk)_live_[0-9a-zA-Z]{16,64})\\b"
SECRET_PATTERN_PRIVATE_KEY="-----BEGIN[[:space:]]+[A-Z0-9 ]*PRIVATE KEY-----"
# 注意: 先頭に \b を使わない（GNU grep の \b は "_" を単語構成文字とみなすため、
# DB_PASSWORD= / SECRET_KEY= のような実運用で一般的な複合命名がすり抜ける）。
# 代わりに「直前が英数字でない（行頭含む）」を境界とし、キーワード直後には
# 「_ または - で連結された後続語」（_KEY 等）のみを許容する（tokenizer 等の
# 別単語への部分一致による誤検知は防ぐ）。
SECRET_PATTERN_CRED="(^|[^A-Za-z0-9])(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)([_-][A-Za-z0-9]+)*[[:space:]]*[:=][[:space:]]*[\"']?[^\"'[:space:]]{12,}[\"']?"
SECRET_PATTERN_CONN="[a-zA-Z][a-zA-Z0-9+.-]{1,15}://[A-Za-z0-9._%+-]{1,64}:[^/@[:space:]]{1,128}@[A-Za-z0-9.-]+(:[0-9]+)?"

# grep -noE の1出力行（"行番号:マッチ文字列"）ごとに、プレースホルダでなければ ISSUES に追加する。
# $1=category $2=対象の相対パス $3=検出内容ラベル $4=grep -noE の出力（複数行、空文字列可）
report_secret_hits() {
  local category="$1" rel="$2" label="$3" hits="$4"
  [ -z "$hits" ] && return 0
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local lineno="${line%%:*}"
    local matched="${line#*:}"
    if printf '%s' "$matched" | grep -qiE "$SECRET_PLACEHOLDER_RE"; then
      continue
    fi
    local masked
    masked="$(mask_secret_value "$matched")"
    add_issue 'ERROR' "$category" "${rel}:${lineno}" \
      "${label}の疑いがある文字列を検出しました（該当箇所はマスク表示: ${masked}）"
    SECRET_HIT_COUNT=$((SECRET_HIT_COUNT + 1))
  done <<< "$hits"
}

# 走査対象ファイル一覧（REPO_ROOT からの相対パス）をグローバル配列 SECRET_SCAN_FILES に格納する。
collect_secret_scan_files() {
  SECRET_SCAN_FILES=()
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # 追跡済みファイル。
    while IFS= read -r -d '' relf; do
      SECRET_SCAN_FILES+=("$relf")
    done < <(git -C "$REPO_ROOT" ls-files -z 2>/dev/null)
    # 未追跡だが .gitignore 等では無視されていないファイル（git add 前の新規ファイルを
    # 見落とさないため。上のコメント参照）。
    while IFS= read -r -d '' relf; do
      SECRET_SCAN_FILES+=("$relf")
    done < <(git -C "$REPO_ROOT" ls-files -z --others --exclude-standard 2>/dev/null)
  fi
  # git 作業ツリーでない場合（テストフィクスチャ等）は find でフォールバックする。
  if [ "${#SECRET_SCAN_FILES[@]}" -eq 0 ]; then
    while IFS= read -r -d '' absf; do
      SECRET_SCAN_FILES+=("${absf#"$REPO_ROOT"/}")
    done < <(find "$REPO_ROOT" -type f -not -path '*/.git/*' -print0 2>/dev/null)
  fi
}
collect_secret_scan_files

SECRET_SCAN_FILE_COUNT=0
SECRET_HIT_COUNT=0

for secret_scan_rel in "${SECRET_SCAN_FILES[@]}"; do
  # ディレクトリ丸ごとではなく、既知ハーネスファイルをパス単位で明示的に除外する
  # （.claude/scripts/tests/fixtures/ 等は対象に残し、将来の汚染を検知できるようにするため）。
  case "$secret_scan_rel" in
    .claude/scripts/tests/run-tests.sh) continue ;;
    .claude/scripts/tests/run-git-changelog-tests.sh) continue ;;
    .claude/scripts/tests/run-aggregate-agent-token-usage-tests.sh) continue ;;
    .claude/scripts/validate.sh) continue ;;
  esac
  secret_scan_abs="$REPO_ROOT/$secret_scan_rel"
  [ -f "$secret_scan_abs" ] || continue
  SECRET_SCAN_FILE_COUNT=$((SECRET_SCAN_FILE_COUNT + 1))

  # 注意: パターン文字列の一部（秘密鍵ヘッダー等）は "-" で始まりうるため、
  # grep にオプションと誤解釈されないよう必ず -e でパターンであることを明示する
  # （"--" だけではファイル名側の誤解釈しか防げず、パターン側には効かない）。
  hits="$(grep -InoE -e "$SECRET_PATTERN_AWS" -- "$secret_scan_abs" 2>/dev/null || true)"
  report_secret_hits 'secret-aws-key' "$secret_scan_rel" 'AWSアクセスキー' "$hits"

  hits="$(grep -InoE -e "$SECRET_PATTERN_TOKEN" -- "$secret_scan_abs" 2>/dev/null || true)"
  report_secret_hits 'secret-api-token' "$secret_scan_rel" '既知サービスのAPIキー/トークン' "$hits"

  hits="$(grep -InoE -e "$SECRET_PATTERN_PRIVATE_KEY" -- "$secret_scan_abs" 2>/dev/null || true)"
  report_secret_hits 'secret-private-key' "$secret_scan_rel" '秘密鍵ブロック' "$hits"

  hits="$(grep -IinoE -e "$SECRET_PATTERN_CRED" -- "$secret_scan_abs" 2>/dev/null || true)"
  report_secret_hits 'secret-credential-assignment' "$secret_scan_rel" 'パスワード/トークン等の代入形' "$hits"

  hits="$(grep -InoE -e "$SECRET_PATTERN_CONN" -- "$secret_scan_abs" 2>/dev/null || true)"
  report_secret_hits 'secret-connection-string' "$secret_scan_rel" '認証情報を含む接続文字列' "$hits"
done

# ---------------------------------------------------------------------------
# 9) エージェント作業ガードレール（第1弾1-2・第2弾2-1）の機械検証
#
# (a) 共通ガードレール6短文（GUIDELINE_ANCHOR_PLUS_BLOCK = 既存共通文アンカー + 改行 +
#     6短文。定数の定義・設計判断は冒頭の定数セクション参照）が agents/*.md 全件で、
#     既存共通文の直後に連続6行としてバイト同一で存在するかを検証する（欠落・改変・
#     位置ずれ・分断はいずれもERROR）。frontmatterの妥当性とは無関係（本文側の検証の
#     ため）に全ファイルを対象とする。
# (b) 非リーダー（is_leader_agent_name が偽）のエージェントの frontmatter
#     disallowedTools に 'Agent' が含まれているかを検証する（TK-7）。
#     - リーダー判定はファイル名（basename）で行う（frontmatter `name` は使わない。
#       nameを詐称すれば判定をすり抜けられてしまう経路を塞ぐため。name偽装自体は
#       セクション1のnaming-mismatchで別途ERRORになるが、本チェックの判定はそれに
#       依存しない独立した安全側の実装にする）。
#     - frontmatterブロック自体が見つからないファイルは、セクション1で既に
#       frontmatter-missing として検知済みのため、ここでの連鎖ERRORは出さない
#       （既存の「name欠落時はnamingチェックをスキップする」等の作法を踏襲）。
#     - tools（許可リスト方式）が明示され、かつそこに Agent/Task が含まれていない
#       エージェント（例: qa-review.md の tools: [Read, Glob, Grep]）は、
#       disallowedTools の記載がなくても実質的にAgent起動不能なため対象外とする。
# (c) 非リーダー全件の本文に TK-2/E-1統合文（GUIDELINE_TK2_E1_LINE。`## 連携` 節冒頭の
#     実行主体明文化）が逐語存在するかを検証する。(a)と同様、frontmatterの妥当性とは
#     無関係（本文側の検証のため）に判定する。リーダー判定は(b)と同様ファイル名基準。
# (d) 利用者資材を直接読む commands/skills 固定5ファイル（COMMANDS_SKILLS_INJECTION_FILES）
#     に、注入耐性文言（GUIDELINE_INJECTION_NOTE_LINE。P-4a/P-4b対応）が逐語存在するかを
#     検証する。前後文脈・行位置には依存しない存在検証。対象ファイル不在時は静かに
#     スキップする。
# (e) 判断手順共通文言（GUIDELINE_DECISION_PROCEDURE_LINE。「判断に迷った場合の段階的
#     判断手順」案件T1で作業方針節へ挿入された1行）が、agents/mgmt-coordinator.md を
#     除く agents/*.md 全件（リーダー・非リーダー問わず）に逐語存在するかを検証する。
#     (a)と同様、frontmatterの妥当性とは無関係に全ファイル（mgmt-coordinator.md除く）を
#     対象とする。mgmt-coordinator.md は別文言のため対象外。
# (f) tracker連携スキル固定2ファイル（TRACKER_SKILLS_EXTERNAL_INPUT_FILES）に、外部
#     トラッカー由来の非信頼入力宣言（GUIDELINE_EXTERNAL_INPUT_NOTE_LINE。外部進捗管理
#     ツール連携 7.10 f1対応）が逐語存在するかを検証する。(d)と同様、前後文脈・行位置に
#     依存しない存在検証で、対象ファイル不在時は静かにスキップする。あわせて
#     skills/tracker-sync/SKILL.md のスナップショットテンプレート冒頭の非信頼データ宣言
#     （GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_BLOCK。F17-3対応）が逐語存在するかも検証する
#     （同ファイル不在時は静かにスキップする）。
# ---------------------------------------------------------------------------

GUIDELINE_MISSING_COUNT=0
DISALLOWED_MISSING_COUNT=0
GUIDELINE_TK2_E1_MISSING_COUNT=0
GUIDELINE_DECISION_PROCEDURE_MISSING_COUNT=0
FORK_SKILL_CALL_HITS=0

for f in "${AGENT_FILES[@]}"; do
  [ -f "$f" ] || continue
  base_name="$(basename "$f" .md)"

  # --- (a) 共通ガードレール6短文の逐語一致（既存共通文直後の位置まで検証） -------
  file_content="$(cat "$f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_ANCHOR_PLUS_BLOCK"* ]]; then
    add_issue 'ERROR' 'guideline-common-missing' "agents/$(basename "$f")" \
      '共通ガードレール6短文（正典①節）が、利用者資材優先の共通文の直後に連続6行としてバイト同一で見つかりません（欠落・改変・位置ずれ・分断の可能性があります）'
    GUIDELINE_MISSING_COUNT=$((GUIDELINE_MISSING_COUNT + 1))
  fi

  # --- (e) 判断手順共通文言の逐語一致（mgmt-coordinator.md 除く全件。リーダー・非リーダー
  #     問わず検証するため、下記のリーダー判定によるcontinueより前に実施する） ------------
  if [ "$base_name" != 'mgmt-coordinator' ]; then
    if [[ "$file_content" != *"$GUIDELINE_DECISION_PROCEDURE_LINE"* ]]; then
      add_issue 'ERROR' 'guideline-decision-procedure-missing' "agents/$(basename "$f")" \
        '判断手順共通文言（正典。「迷った場合の段階的判断手順」1行）が見つかりません（欠落・改変の可能性があります。前後文脈・行位置は問わない存在検証）'
      GUIDELINE_DECISION_PROCEDURE_MISSING_COUNT=$((GUIDELINE_DECISION_PROCEDURE_MISSING_COUNT + 1))
    fi
  fi

  # agent_name の解決（メッセージ表示用。frontmatterが読めた場合はnameで、そうでなければ
  # basenameで代替する。ただしリーダー判定そのものにはこの値を使わない＝下記参照）。
  agent_name="$base_name"
  frontmatter_ok=0
  if parse_frontmatter "$f"; then
    frontmatter_ok=1
    if fm_has_value 'name'; then
      agent_name="${FM[name]}"
    fi
  fi

  # リーダー判定はファイル名（basename）基準で行う。frontmatter name は使わない
  # （nameの詐称による判定すり抜けを防ぐ。上記コメント参照）。
  if is_leader_agent_name "$base_name"; then
    continue
  fi

  # --- (c) 非リーダーのTK-2/E-1統合文の逐語一致 --------------------------------
  if [[ "$file_content" != *"$GUIDELINE_TK2_E1_LINE"* ]]; then
    add_issue 'ERROR' 'guideline-tk2-e1-missing' "agents/$(basename "$f")" \
      "非リーダーエージェント（name: '${agent_name}'）の本文に TK-2/E-1統合文（正典⑤節。'## 連携' 節冒頭の実行主体明文化）が見つかりません（欠落・改変の可能性があります）"
    GUIDELINE_TK2_E1_MISSING_COUNT=$((GUIDELINE_TK2_E1_MISSING_COUNT + 1))
  fi

  # --- (i) 非リーダーによる context: fork スキル呼び出し検出（CONTRIBUTING 4.2 運用規範。
  #     2026-08-03案件issue28 sec-audit差し戻し M-s3対応。CONTRIBUTING 1.4 原則4対応） -----
  for fork_skill_token in "${FORK_SKILL_CALL_TOKENS[@]}"; do
    if [[ "$file_content" == *"$fork_skill_token"* ]]; then
      add_issue 'ERROR' 'fork-skill-call-non-leader' "agents/$(basename "$f")" \
        "非リーダーエージェント（name: '${agent_name}'）の本文に context: fork スキル呼び出しトークン '${fork_skill_token}' が見つかりました（CONTRIBUTING 4.2 運用規範により、fork スキル（hw:repo-map・hw:conventions）はメイン会話・リーダー層からのみ呼び出す）"
      FORK_SKILL_CALL_HITS=$((FORK_SKILL_CALL_HITS + 1))
    fi
  done

  # --- (b) 非リーダーのdisallowedTools整合検証 --------------------------------
  if [ "$frontmatter_ok" -eq 0 ]; then
    continue
  fi

  extract_frontmatter_list_field "$f" 'tools'
  tools_count=${#FM_LIST[@]}
  tools_allow_agent=0
  if [ "$tools_count" -gt 0 ]; then
    for t in "${FM_LIST[@]}"; do
      if [ "$t" = 'Agent' ] || [ "$t" = 'Task' ]; then
        tools_allow_agent=1
        break
      fi
    done
  fi
  if [ "$tools_count" -gt 0 ] && [ "$tools_allow_agent" -eq 0 ]; then
    # tools 許可リスト方式で、かつ Agent/Task が元々許可されていない
    # （リストにない=使用不可）ため、disallowedTools記載の要求対象外。
    continue
  fi

  extract_frontmatter_list_field "$f" 'disallowedTools'
  disallowed_has_agent=0
  if [ "${#FM_LIST[@]}" -gt 0 ]; then
    for t in "${FM_LIST[@]}"; do
      if [ "$t" = 'Agent' ]; then
        disallowed_has_agent=1
        break
      fi
    done
  fi

  if [ "$disallowed_has_agent" -eq 0 ]; then
    add_issue 'ERROR' 'disallowed-tools-missing' "agents/$(basename "$f")" \
      "非リーダーエージェント（name: '${agent_name}'）の frontmatter disallowedTools に 'Agent' が含まれていません（TK-7。委任経路（Agentツールによるサブエージェント起動）の統制が効いていません）"
    DISALLOWED_MISSING_COUNT=$((DISALLOWED_MISSING_COUNT + 1))
  fi
done

# --- (d) 利用者資材を直接読む commands/skills の注入耐性文言（P-4a/P-4b） -------
# 対象は COMMANDS_SKILLS_INJECTION_FILES の固定5件のみ（上記定義参照）。ファイルが
# 存在しない検証対象ディレクトリ（テストフィクスチャ等）では、セクション6・10(b)と
# 同様にERRORにはせず静かにスキップする（本チェック追加のためだけに無関係な既存
# フィクスチャ・テストを大量に更新せずに済むようにするための設計判断）。
GUIDELINE_INJECTION_NOTE_MISSING_COUNT=0

for rel_path in "${COMMANDS_SKILLS_INJECTION_FILES[@]}"; do
  f="$REPO_ROOT/$rel_path"
  [ -f "$f" ] || continue

  file_content="$(cat "$f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_INJECTION_NOTE_LINE"* ]]; then
    add_issue 'ERROR' 'guideline-injection-note-missing' "$rel_path" \
      '利用者資材を直接読む手順を持つこのファイルに、注入耐性文言（正典。P-4a/P-4b対応）が見つかりません（欠落・改変の可能性があります。行位置・前後文脈は問わない存在検証）'
    GUIDELINE_INJECTION_NOTE_MISSING_COUNT=$((GUIDELINE_INJECTION_NOTE_MISSING_COUNT + 1))
  fi
done

# --- (f) tracker連携スキル固定2ファイルの非信頼入力宣言（外部進捗管理ツール連携 7.10 f1。
#     U7で利用者承認済み） ------------------------------------------------------
# 対象は TRACKER_SKILLS_EXTERNAL_INPUT_FILES の固定2件のみ。(d)と同じ理由（本チェック
# 追加のためだけに無関係な既存フィクスチャ・テストを大量に更新せずに済ませる設計判断）で、
# 対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする。
GUIDELINE_EXTERNAL_INPUT_NOTE_MISSING_COUNT=0

for rel_path in "${TRACKER_SKILLS_EXTERNAL_INPUT_FILES[@]}"; do
  f="$REPO_ROOT/$rel_path"
  [ -f "$f" ] || continue

  file_content="$(cat "$f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_EXTERNAL_INPUT_NOTE_LINE"* ]]; then
    add_issue 'ERROR' 'guideline-external-input-note-missing' "$rel_path" \
      '外部トラッカー由来の非信頼入力宣言（正典。tracker-setup/tracker-sync 両ファイルに逐語同一で存在すべき1文）が見つかりません（欠落・改変の可能性があります。行位置・前後文脈は問わない存在検証）'
    GUIDELINE_EXTERNAL_INPUT_NOTE_MISSING_COUNT=$((GUIDELINE_EXTERNAL_INPUT_NOTE_MISSING_COUNT + 1))
  fi
done

# スナップショットテンプレートの非信頼データ宣言（skills/tracker-sync/SKILL.md のみが対象。
# F17-3・7.10 f1「宣言の逐語定数」）。対象ファイル不在時は同様に静かにスキップする。
GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_MISSING_COUNT=0

snapshot_note_target='skills/tracker-sync/SKILL.md'
snapshot_note_f="$REPO_ROOT/$snapshot_note_target"
if [ -f "$snapshot_note_f" ]; then
  file_content="$(cat "$snapshot_note_f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_BLOCK"* ]]; then
    add_issue 'ERROR' 'guideline-snapshot-template-note-missing' "$snapshot_note_target" \
      'スナップショットテンプレートの非信頼データ宣言（正典。F17-3対応）が見つかりません（欠落・改変の可能性があります）'
    GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_MISSING_COUNT=$((GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_MISSING_COUNT + 1))
  fi
fi

# --- (g) import-assets固定1ファイルの非信頼入力宣言（AI資産の横展開案件 qa-review High-1。
#     統括裁定T6。CONTRIBUTING 1.4 原則4対応） -----------------------------------
# 対象は IMPORT_ASSETS_UNTRUSTED_INPUT_FILES の固定1件のみ。(d)(f)と同じ理由（本チェック
# 追加のためだけに無関係な既存フィクスチャ・テストを大量に更新せずに済ませる設計判断）で、
# 対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする。
GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_MISSING_COUNT=0

for rel_path in "${IMPORT_ASSETS_UNTRUSTED_INPUT_FILES[@]}"; do
  f="$REPO_ROOT/$rel_path"
  [ -f "$f" ] || continue

  file_content="$(cat "$f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_LINE"* ]]; then
    add_issue 'ERROR' 'guideline-import-untrusted-input-note-missing' "$rel_path" \
      'zip同梱資産由来の非信頼入力宣言（正典。AI資産の横展開案件 qa-review High-1対応）が見つかりません（欠落・改変の可能性があります。行位置・前後文脈は問わない存在検証）'
    GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_MISSING_COUNT=$((GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_MISSING_COUNT + 1))
  fi
done

# --- (h) permission-rules トリガー行固定3ファイル（DESIGN 2.27 追補・共通ルール管理の
#     成長対応 A-3。CONTRIBUTING 1.4 原則4対応） -------------------------------------
# 対象は PERMISSION_TRIGGER_LINE_FILES の固定3件のみ。(d)(f)(g)と同じ理由（本チェック
# 追加のためだけに無関係な既存フィクスチャ・テストを大量に更新せずに済ませる設計判断）で、
# 対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする。
GUIDELINE_PERMISSION_TRIGGER_LINE_MISSING_COUNT=0

for rel_path in "${PERMISSION_TRIGGER_LINE_FILES[@]}"; do
  f="$REPO_ROOT/$rel_path"
  [ -f "$f" ] || continue

  file_content="$(cat "$f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_PERMISSION_TRIGGER_LINE"* ]]; then
    add_issue 'ERROR' 'guideline-permission-trigger-line-missing' "$rel_path" \
      'permission-rulesトリガー行（正典。DESIGN 2.27 追補対応）が見つかりません（欠落・改変の可能性があります。行位置・前後文脈は問わない存在検証）'
    GUIDELINE_PERMISSION_TRIGGER_LINE_MISSING_COUNT=$((GUIDELINE_PERMISSION_TRIGGER_LINE_MISSING_COUNT + 1))
  fi
done

# --- (j) commands/*.md 固定12ファイルのURL区切り規約行（2026-08-04案件「URL 区切り規約の
#     commands 展開＋機械検証化」T2対応） -----------------------------------------
# 対象は COMMANDS_URL_DELIMITER_FILES の固定12件（commands/*.md 全件）。(d)(f)(g)(h)と
# 同じ理由（本チェック追加のためだけに無関係な既存フィクスチャ・テストを大量に更新せずに
# 済ませる設計判断）で、対象ファイルが存在しない検証対象ディレクトリでは静かにスキップする。
GUIDELINE_URL_DELIMITER_MISSING_COUNT=0

for rel_path in "${COMMANDS_URL_DELIMITER_FILES[@]}"; do
  f="$REPO_ROOT/$rel_path"
  [ -f "$f" ] || continue

  file_content="$(cat "$f")"
  file_content="${file_content//$'\r'/}"
  if [[ "$file_content" != *"$GUIDELINE_URL_DELIMITER_LINE"* ]]; then
    add_issue 'ERROR' 'guideline-url-delimiter-missing' "$rel_path" \
      'URL区切り規約行（正典。2026-08-04案件「URL 区切り規約の commands 展開＋機械検証化」T2対応）が見つかりません（欠落・改変の可能性があります。行位置・前後文脈は問わない存在検証）'
    GUIDELINE_URL_DELIMITER_MISSING_COUNT=$((GUIDELINE_URL_DELIMITER_MISSING_COUNT + 1))
  fi
done

# ---------------------------------------------------------------------------
# 10) エージェント数量表記の検証射程拡張（AI資材最適化計画 C-1）
#
# 背景: セクション4のREADME突合チェックは README.md のみを対象としており、
# .claude-plugin/marketplace.json・.claude-plugin/plugin.json・DESIGN.md・
# DEVELOPMENT.md は検証の死角だった（実際に marketplace.json「49エージェント」・
# plugin.json「約50名」等、実体（51）とのズレが長期間すり抜けていた）。是正として
# 2つのJSONの description は数値非依存の表現（例:「10グループの専門家エージェント」）
# へ統一したため、(a) では数値表記の再混入自体をERRORとする。DESIGN.md・
# DEVELOPMENT.md は現在値としての数表記を維持する方針のため、(b) では表記自体は
# 許容し実体との一致を検証する。
#
# 対象ファイルが存在しない検証対象ディレクトリ（テストフィクスチャ等）では、
# セクション6（show-org.md）と同様にERRORにはせず
# 静かにスキップする（本チェック追加のためだけに無関係な既存フィクスチャ・
# テストを大量に更新せずに済むようにするための設計判断）。
# ---------------------------------------------------------------------------

# 数値＋エージェント数を示す語（名/体/エージェント）が直接連結された表記の候補
# （例:「49エージェント」「50名」「51体」）を検出する正規表現。「10グループ」の
# ようなグループ数表記は対象外（「グループ」は本パターンに含めない）。
AGENT_COUNT_CANDIDATE_RE='[0-9]+[[:space:]]*(名|体|エージェント)'

# qa-review差し戻し(1回目) [should-fix 2] への対応: 「体」「名」は日本語の熟語
# （体験・体重・体格・体温・体調・体力・名前・名義・名称・名簿 等）の先頭字と
# 偶発一致しうる（例:「10名前」「5体験」の一部を数量表記と誤認する）。マッチ直後に
# 続く1文字がこれら熟語の後続字であれば、数量表記ではなく熟語の一部とみなして除外
# する（「エージェント」はカタカナ語であり他語の一部として偶発一致するリスクが
# 実質的にないため対象外。既存の SECRET_PLACEHOLDER_RE と同様、既知の紛らわしい
# 語のみを対象にした狭い除外リストで対応する設計）。
AGENT_COUNT_WORD_CONTINUATION_RE='^(験|重|格|温|力|調|前|義|称|簿)'

# $1=マッチした文字列全体（例: "10名"） $2=マッチ直後に続く残り文字列
# 「名」「体」で終わるマッチのみを対象に、直後の1文字が既知の熟語後続字なら
# true（除外対象）を返す。
is_agent_count_word_continuation() {
  local matched="$1" trailing="$2"
  case "$matched" in
    *名|*体)
      [[ "$trailing" =~ $AGENT_COUNT_WORD_CONTINUATION_RE ]] && return 0
      ;;
  esac
  return 1
}

# (a) .claude-plugin/*.json の description フィールドへの数値混入チェック。
# JSON専用パーサ（jq等）は本スクリプトの既存方針（追加ランタイム非依存）により
# 導入せず、他セクション同様の単純な行単位の正規表現照合で行毎処理する
# （description値に改行・エスケープ済みダブルクォートを含まない前提。
#   本リポジトリの実ファイルはこの前提を満たす単純な一行の文字列値のみ。
#   qa-review差し戻し(1回目) [nit 6]: この前提が崩れるリスクは低いため記録のみとし、
#   複雑なJSON文字列アンエスケープの実装は見送る）。
#
# qa-review差し戻し(1回目) [should-fix 4] と同種の理由により、bash の
# `[[ desc =~ pattern ]]`（leftmost一致のみ）に頼らず、`${rest#*"$matched"}` で
# マッチ済み部分を順に取り除きながら再マッチさせることで、1つの description 内に
# 複数の候補が出現しても取りこぼさない。
check_json_description_no_agent_count() {
  local file="$1" rel="$2"
  [ -f "$file" ] || return 0
  local line lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ \"description\"[[:space:]]*:[[:space:]]*\"(.*)\" ]]; then
      local desc="${BASH_REMATCH[1]}"
      local rest="$desc"
      while [[ "$rest" =~ $AGENT_COUNT_CANDIDATE_RE ]]; do
        local matched="${BASH_REMATCH[0]}"
        rest="${rest#*"$matched"}"
        if is_agent_count_word_continuation "$matched" "$rest"; then
          continue
        fi
        add_issue 'ERROR' 'plugin-desc-agent-count' "${rel}:${lineno}" \
          "description に数値によるエージェント数表記 '${matched}' が含まれています（数値非依存の表現へ統一する方針。例:「10グループの専門家エージェント」）"
        PLUGIN_DESC_AGENT_COUNT_HITS=$((PLUGIN_DESC_AGENT_COUNT_HITS + 1))
      done
    fi
  done < "$file"
}

PLUGIN_DESC_AGENT_COUNT_HITS=0
check_json_description_no_agent_count "$REPO_ROOT/.claude-plugin/marketplace.json" '.claude-plugin/marketplace.json'
check_json_description_no_agent_count "$REPO_ROOT/.claude-plugin/plugin.json" '.claude-plugin/plugin.json'

# (b) DESIGN.md/DEVELOPMENT.md の現在値としてのエージェント数表記と実体との突合。
#
# 設計判断（重要）: 「N体/N名という表記全般を総エージェント数とみなして実体と
# 突合する」という汎用実装は採らない。DESIGN.md内には総数とは無関係な別の数値
# 表記（例:「9体の `*-lead`」＝リーダー数、「非リーダー41体」＝非リーダー数）が
# 現に存在し、汎用突合ではこれらを誤って総数(51)と比較し誤検知してしまう。
# そのため、各ファイルで実際に総数表記として使われている特定の言い回し
# （DESIGN.mdの「Nグループ・M名」＝README冒頭表記と同一の慣用句、
#   DEVELOPMENT.mdの「エージェント定義（N体」）のみを対象にした狭いパターンで
# 突合する。この設計により、時点明示付きの履歴記述（例:「当時（49体時点）」）は
# パターン形状が異なるため自然に対象外となり、除外のための個別のキーワード
# 判定（「当時」「時点」等の除外リスト）は不要になる。
# 該当パターンが1件も見つからない場合はERRORにはせず静かにスキップする
# （表記の存在自体を必須要件とはしない。存在する場合にのみ実体との一致を問う）。
#
# qa-review差し戻し(1回目) [should-fix 4] への対応: ファイル全文を1つの文字列として
# `[[ text =~ pattern ]]` に渡すとleftmost（最初の一致）しか得られず、狙いの現在値
# 記述より前に同形状のパターンが別文脈で出現した場合にそちらを誤って拾ってしまう
# （本来検証すべき記述を取りこぼす）リスクがある。1行ずつ読み、各行内でも
# `${rest#*"${BASH_REMATCH[0]}"}` により順に取り除きながら再マッチさせることで、
# ファイル中の全出現を行番号付きで検証する（出現順に依存しない）。
# qa-review差し戻し(1回目) [should-fix 3] への対応: セクション4（README冒頭の
# 「Nグループ・M名」突合）がグループ数・エージェント数を各1件のERRORとして分離
# 記録しているのに合わせ、DESIGN.mdの突合も両者を独立した add_issue に分離する。
DOC_AGENT_TOTAL=${#AGENT_NAMES_FROM_FILES[@]}
declare -A DOC_GROUP_SET=()
if [ "${#AGENT_NAMES_FROM_FILES[@]}" -gt 0 ]; then
  for n in "${AGENT_NAMES_FROM_FILES[@]}"; do
    DOC_GROUP_SET["${n%%-*}"]=1
  done
fi
DOC_GROUP_TOTAL=${#DOC_GROUP_SET[@]}

DESIGN_COUNT_MISMATCH_HITS=0
DESIGN_MD_PATH="$REPO_ROOT/DESIGN.md"
if [ -f "$DESIGN_MD_PATH" ]; then
  design_lineno=0
  while IFS= read -r design_line || [ -n "$design_line" ]; do
    design_lineno=$((design_lineno + 1))
    design_rest="$design_line"
    while [[ "$design_rest" =~ ([0-9]+)グループ・([0-9]+)名 ]]; do
      design_stated_groups="${BASH_REMATCH[1]}"
      design_stated_agents="${BASH_REMATCH[2]}"
      design_rest="${design_rest#*"${BASH_REMATCH[0]}"}"
      if [ "$design_stated_groups" -ne "$DOC_GROUP_TOTAL" ]; then
        add_issue 'ERROR' 'doc-agent-count-mismatch' "DESIGN.md:${design_lineno}" \
          "DESIGN.md記載の「Nグループ・M名」のグループ数 '${design_stated_groups}' が実体のグループ数 '${DOC_GROUP_TOTAL}' と一致しません"
        DESIGN_COUNT_MISMATCH_HITS=$((DESIGN_COUNT_MISMATCH_HITS + 1))
      fi
      if [ "$design_stated_agents" -ne "$DOC_AGENT_TOTAL" ]; then
        add_issue 'ERROR' 'doc-agent-count-mismatch' "DESIGN.md:${design_lineno}" \
          "DESIGN.md記載の「Nグループ・M名」のエージェント数 '${design_stated_agents}' が実体のエージェント数 '${DOC_AGENT_TOTAL}' と一致しません"
        DESIGN_COUNT_MISMATCH_HITS=$((DESIGN_COUNT_MISMATCH_HITS + 1))
      fi
    done
  done < "$DESIGN_MD_PATH"
fi

DEVELOPMENT_COUNT_MISMATCH_HITS=0
DEVELOPMENT_MD_PATH="$REPO_ROOT/DEVELOPMENT.md"
if [ -f "$DEVELOPMENT_MD_PATH" ]; then
  development_lineno=0
  while IFS= read -r development_line || [ -n "$development_line" ]; do
    development_lineno=$((development_lineno + 1))
    development_rest="$development_line"
    while [[ "$development_rest" =~ エージェント定義（([0-9]+)体 ]]; do
      development_stated_agents="${BASH_REMATCH[1]}"
      development_rest="${development_rest#*"${BASH_REMATCH[0]}"}"
      if [ "$development_stated_agents" -ne "$DOC_AGENT_TOTAL" ]; then
        add_issue 'ERROR' 'doc-agent-count-mismatch' "DEVELOPMENT.md:${development_lineno}" \
          "DEVELOPMENT.md記載の「エージェント定義（N体」の値 '${development_stated_agents}' が実体のエージェント数 '${DOC_AGENT_TOTAL}' と一致しません"
        DEVELOPMENT_COUNT_MISMATCH_HITS=$((DEVELOPMENT_COUNT_MISMATCH_HITS + 1))
      fi
    done
  done < "$DEVELOPMENT_MD_PATH"
fi

# ---------------------------------------------------------------------------
# 11) スクリプト・CI定義のファイルモード検査（CONTRIBUTING 8.2 の機械化）
#
# 対象範囲は CONTRIBUTING.md 8.1 の適用範囲と同一（.claude/scripts/ 配下全体・
# .github/workflows/ 配下・.github/dependabot.yml）。この範囲内の git index 上の
# ファイルモードが、`.sh` は 100755（実行可能）、それ以外（.yml・fixtures配下の
# データファイル等）は 100644 であることを検証する。
#
# 実害（トークン消費効率改善 第1弾コミット時）: WSL2 の core.fileMode が有効な
# 環境で、新規追加した .sh が 100644（非実行可能）のまま気付かれずコミットされた
# ことがある。呼び出しは `bash <path>` を正としており実行権限の有無自体は動作に
# 影響しないが、git index 上のモードが規約と食い違ったまま積み重なることを防ぐ。
#
# git 管理外（REPO_ROOT が git 作業ツリーでない。git 未導入の実行環境や、本チェックの
# 対象外である一部テストフィクスチャを想定）の場合、判定根拠となる「git index上の
# モード」自体が存在しないため、本チェックは静かにスキップする（セクション6・9(d)・
# 10 と同様の設計判断。ERRORにはしない。validate.sh 全体が壊れないことを優先する）。
#
# `git ls-files -s -z` を用いる理由: 通常の（NUL区切りでない）出力を awk 等で
# 空白分割すると、ファイル名に空白を含む場合にトークン境界を誤る（本リポジトリの
# 実ファイルには該当しないが、他セクション同様に頑健な実装を優先する）。エントリは
# "<mode> <sha> <stage>\t<path>" 形式のため、モードは最初の空白まで、パスは最初の
# タブ以降を取ればよい（パスに空白を含んでいても両者とも正しく切り出せる）。
# ---------------------------------------------------------------------------

FILE_MODE_CHECKED_COUNT=0
FILE_MODE_VIOLATION_COUNT=0

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r -d '' fm_entry; do
    [ -z "$fm_entry" ] && continue
    fm_mode="${fm_entry%% *}"
    fm_relf="${fm_entry#*$'\t'}"
    [ -z "$fm_relf" ] && continue

    FILE_MODE_CHECKED_COUNT=$((FILE_MODE_CHECKED_COUNT + 1))

    fm_expected='100644'
    case "$fm_relf" in
      *.sh) fm_expected='100755' ;;
    esac

    if [ "$fm_mode" != "$fm_expected" ]; then
      fm_chmod_flag='-x'
      [ "$fm_expected" = '100755' ] && fm_chmod_flag='+x'
      add_issue 'ERROR' 'file-mode-mismatch' "$fm_relf" \
        "git index上のファイルモードが '${fm_mode}' ですが、規約（CONTRIBUTING 8.2）上は '${fm_expected}' である必要があります（修正例: git update-index --chmod=${fm_chmod_flag} -- ${fm_relf}）"
      FILE_MODE_VIOLATION_COUNT=$((FILE_MODE_VIOLATION_COUNT + 1))
    fi
  done < <(git -C "$REPO_ROOT" ls-files -s -z -- .claude/scripts .github/workflows .github/dependabot.yml 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# 12) Markdown 文書中のリポジトリ内パス参照の実在検証（issue #34）
#
# 詳細は冒頭コメント参照。対象文書リスト・除外リストは、T2（回帰テスト追加）での
# 参照・変更を容易にするため本セクション最上部にまとめる。
# ---------------------------------------------------------------------------

# 対象文書（glob可。REPO_ROOT からの相対パス）。
DOC_PATH_REF_TARGET_GLOBS=(
  'README.md'
  'CLAUDE.md'
  'CONTRIBUTING.md'
  'DESIGN.md'
  'DEVELOPMENT.md'
  'agents/*.md'
  'commands/*.md'
  'skills/*/SKILL.md'
  '.claude/commands/*.md'
  '.claude/skills/*/SKILL.md'
)

# 除外(4): 実在検証の対象外として個別に許容する明示除外リスト（実在しなくてもERROR
# にしない）。
#   - .github/copilot-instructions.md: commands/optimize-assets.md・
#     skills/conventions/SKILL.md が他AIツール向け資材の例として挙げるのみで、本リポジトリ
#     内には実在しないことを承知のうえでの例示（2026-08-04時点の事前スキャンでの確認範囲）。
#   - .claude/settings.local.json: .gitignore 済みで実在しないファイルへの言及があるため
#     （issue #71 移設対応）。.claude/ 配下の他の参照は拡張子なしディレクトリ表記または
#     `<`プレースホルダのため既存規則（検出プレフィックス末尾が拡張子で終わらない／
#     除外(2)）で別途除外済み。
DOC_PATH_REF_EXCLUDE_LIST=(
  '.github/copilot-instructions.md'
  '.claude/settings.local.json'
)

# 検出プレフィックス・拡張子の正規表現。.hw/ を検出プレフィックスに含める理由:
# .hw/ 自体は利用者側生成パスで実在検証の対象外（除外(1)）だが、検出プレフィックス
# から外してしまうと除外(1)の件数出力が常に0固定になり、「除外規則が機能して
# 拾ったうえで弾いているのか、そもそも検出漏れで一度も動いていないのか」が
# 区別できなくなる。実際、.hw/配下の散文中の例示パス（.hw/plans/roadmap.md 等、
# 将来生成される想定の例示）には2026-08-04時点で実在しないものが十数件あり、
# 検出プレフィックスに含めたうえで除外しないと誤検知になることを事前スキャンで
# 確認済み。
DOC_PATH_REF_BT_PATTERN='`([^`]+)`'
DOC_PATH_REF_PREFIX_RE='^(agents/|commands/|skills/|scripts/|\.claude/|\.github/|\.claude-plugin/|\.hw/)'
DOC_PATH_REF_EXT_RE='\.(md|sh|json|yml|yaml)$'

DOC_PATH_REF_FILES_SCANNED=0
DOC_PATH_REF_TOKEN_TOTAL=0
DOC_PATH_REF_SKIP_HW_COUNT=0
DOC_PATH_REF_SKIP_PLACEHOLDER_COUNT=0
DOC_PATH_REF_SKIP_WILDCARD_COUNT=0
DOC_PATH_REF_SKIP_EXCLUDE_LIST_COUNT=0
DOC_PATH_REF_MISSING_COUNT=0
DOC_PATH_REF_TRAVERSAL_COUNT=0

# 除外(4)のリスト所属判定（完全一致）。
is_doc_path_ref_excluded() {
  local candidate="$1" x
  for x in "${DOC_PATH_REF_EXCLUDE_LIST[@]}"; do
    [ "$x" = "$candidate" ] && return 0
  done
  return 1
}

# 対象文書の実ファイル一覧を組み立てる（存在しないものは自然に対象外。nullglob設定済み）。
DOC_PATH_REF_TARGET_FILES=()
for doc_glob in "${DOC_PATH_REF_TARGET_GLOBS[@]}"; do
  for f in "$REPO_ROOT"/$doc_glob; do
    [ -f "$f" ] || continue
    DOC_PATH_REF_TARGET_FILES+=("$f")
  done
done

for f in "${DOC_PATH_REF_TARGET_FILES[@]}"; do
  rel_doc="${f#"$REPO_ROOT"/}"
  DOC_PATH_REF_FILES_SCANNED=$((DOC_PATH_REF_FILES_SCANNED + 1))

  doc_lineno=0
  while IFS= read -r doc_line || [ -n "$doc_line" ]; do
    doc_lineno=$((doc_lineno + 1))
    doc_line="${doc_line%$'\r'}"
    doc_rest="$doc_line"

    while [[ "$doc_rest" =~ $DOC_PATH_REF_BT_PATTERN ]]; do
      bt_content="${BASH_REMATCH[1]}"
      doc_rest="${doc_rest#*"${BASH_REMATCH[0]}"}"

      # 単語分割は pathname展開（グロブ）を伴わない `read -ra` を用いる
      # （extract_frontmatter_list_field 関数の同種の設計判断を踏襲。バッククォート
      # 内容が "*" 等のグロブ文字を含む場合に意図せず実ファイル名へ展開されるのを防ぐ）。
      read -ra bt_words <<< "$bt_content"
      for word in "${bt_words[@]}"; do
        if ! [[ "$word" =~ $DOC_PATH_REF_PREFIX_RE ]] || ! [[ "$word" =~ $DOC_PATH_REF_EXT_RE ]]; then
          continue
        fi
        DOC_PATH_REF_TOKEN_TOTAL=$((DOC_PATH_REF_TOKEN_TOTAL + 1))

        # `..` を含むトークンは、除外分類（.hw配下・プレースホルダ・ワイルドカード・
        # 利用者資材例示リスト）やファイルシステム参照（-f 判定・compgen -G）へ
        # 到達する前にここで短絡してERRORとする（差し戻し対応 SEC-L1/qa-L3）。
        # 正当な文書内パス参照に `..` が現れる余地はなく（対象文書はすべてリポジトリ
        # 直下からの相対パスで記述する規約のため）、以降の分岐でREPO_ROOT外のパスに
        # 対して -f やcompgen -Gを実行し存在有無を機械的に探査させないことが安全。
        if [[ "$word" == *'..'* ]]; then
          add_issue 'ERROR' 'doc-path-ref-traversal' "${rel_doc}:${doc_lineno}" \
            "リポジトリ内パス参照 '${word}' に親ディレクトリ参照(..)が含まれています（リポジトリ直下からの相対パスで記述してください）"
          DOC_PATH_REF_TRAVERSAL_COUNT=$((DOC_PATH_REF_TRAVERSAL_COUNT + 1))
        elif [[ "$word" == .hw/* ]]; then
          DOC_PATH_REF_SKIP_HW_COUNT=$((DOC_PATH_REF_SKIP_HW_COUNT + 1))
        elif [[ "$word" == *'<'* || "$word" == *'…'* ]]; then
          DOC_PATH_REF_SKIP_PLACEHOLDER_COUNT=$((DOC_PATH_REF_SKIP_PLACEHOLDER_COUNT + 1))
        elif [[ "$word" == *'*'* ]]; then
          DOC_PATH_REF_SKIP_WILDCARD_COUNT=$((DOC_PATH_REF_SKIP_WILDCARD_COUNT + 1))
          # compgen -G はパターンを引数として受け取り、その内部でのみglob展開する
          # （呼び出し側シェルでの単語分割・展開を経由しないため、REPO_ROOT等の
          # パスにたまたま特殊文字が含まれていても安全）。1件も一致しなければ
          # 非0で終了しwc_hitsは空になる。
          wc_hits=""
          if wc_hits="$(cd "$REPO_ROOT" && compgen -G "$word" 2>/dev/null)"; then
            :
          fi
          if [ -z "$wc_hits" ]; then
            add_issue 'ERROR' 'doc-path-ref-wildcard-empty' "${rel_doc}:${doc_lineno}" \
              "ワイルドカードパス参照 '${word}' に一致する実ファイルが1件もありません"
            DOC_PATH_REF_MISSING_COUNT=$((DOC_PATH_REF_MISSING_COUNT + 1))
          fi
        elif is_doc_path_ref_excluded "$word"; then
          DOC_PATH_REF_SKIP_EXCLUDE_LIST_COUNT=$((DOC_PATH_REF_SKIP_EXCLUDE_LIST_COUNT + 1))
        else
          if [ ! -f "$REPO_ROOT/$word" ]; then
            add_issue 'ERROR' 'doc-path-ref-missing' "${rel_doc}:${doc_lineno}" \
              "リポジトリ内パス参照 '${word}' に一致する実ファイルが見つかりません"
            DOC_PATH_REF_MISSING_COUNT=$((DOC_PATH_REF_MISSING_COUNT + 1))
          fi
        fi
      done
    done
  done < "$f"
done

# 抽出0件チェック（対象文書が1件以上存在した場合のみ判定する。対象文書自体が
# 1件も存在しない検証対象ディレクトリ＝セクション6・9(d)・10・11と同様の
# 「静かにスキップ」対象では、本チェックも自然にスキップされる）。
if [ "$DOC_PATH_REF_FILES_SCANNED" -gt 0 ] && [ "$DOC_PATH_REF_TOKEN_TOTAL" -eq 0 ]; then
  add_issue 'ERROR' 'doc-path-ref-extract-zero' 'docs' \
    '対象文書全体からリポジトリ内パス形トークンを1件も抽出できませんでした（検出パターンの変化等により検証が空振りしている可能性があります）'
fi

# ---------------------------------------------------------------------------
# 結果出力
# ---------------------------------------------------------------------------

error_count=0
warn_count=0
if [ "${#ISSUES[@]}" -gt 0 ]; then
  for entry in "${ISSUES[@]}"; do
    severity="${entry%%$'\t'*}"
    if [ "$severity" = 'ERROR' ]; then
      error_count=$((error_count + 1))
    elif [ "$severity" = 'WARN' ]; then
      warn_count=$((warn_count + 1))
    fi
  done
fi

agent_total=0
for f in "${AGENT_FILES[@]}"; do [ -f "$f" ] && agent_total=$((agent_total + 1)); done
command_total=0
for f in "${COMMAND_FILES[@]}"; do [ -f "$f" ] && command_total=$((command_total + 1)); done
skill_total=0
for d in "${SKILL_DIRS[@]}"; do [ -d "$d" ] && skill_total=$((skill_total + 1)); done

echo '==================================================='
echo 'hermit-works 静的検証結果'
echo '==================================================='
echo "対象件数: agents=$agent_total / commands=$command_total / skills=$skill_total"
echo "README突合: エージェント README=$AGENT_README_COUNT/実体=$AGENT_FILE_COUNT  コマンド README=$CMD_README_COUNT/実体=$CMD_FILE_COUNT  スキル README=$SKILL_README_COUNT/実体=$SKILL_FILE_COUNT"
echo "show-org.md 生成差分: $SHOW_ORG_DIFF_STATUS（commands/show-org.md 不在時は '-'）"
echo "秘密情報スキャン: 走査対象=${SECRET_SCAN_FILE_COUNT}ファイル（追跡済み+未追跡・.gitignore尊重） / 検出=${SECRET_HIT_COUNT}件（既知ハーネスファイル・.claude/scripts/validate.sh自身は対象外）"
echo "ガードレール整合: 共通6短文欠落=${GUIDELINE_MISSING_COUNT}件 / 非リーダーdisallowedTools欠落=${DISALLOWED_MISSING_COUNT}件 / TK-2/E-1統合文欠落=${GUIDELINE_TK2_E1_MISSING_COUNT}件 / commands・skills注入耐性文言欠落=${GUIDELINE_INJECTION_NOTE_MISSING_COUNT}件 / 判断手順共通文言欠落=${GUIDELINE_DECISION_PROCEDURE_MISSING_COUNT}件 / tracker非信頼入力宣言欠落=${GUIDELINE_EXTERNAL_INPUT_NOTE_MISSING_COUNT}件 / スナップショット宣言欠落=${GUIDELINE_SNAPSHOT_TEMPLATE_NOTE_MISSING_COUNT}件 / import-assets非信頼入力宣言欠落=${GUIDELINE_IMPORT_UNTRUSTED_INPUT_NOTE_MISSING_COUNT}件 / permission-rulesトリガー行欠落=${GUIDELINE_PERMISSION_TRIGGER_LINE_MISSING_COUNT}件 / 非リーダーfork スキル呼び出し検出=${FORK_SKILL_CALL_HITS}件 / commands URL区切り規約行欠落=${GUIDELINE_URL_DELIMITER_MISSING_COUNT}件"
echo "数量表記整合: JSON混入=${PLUGIN_DESC_AGENT_COUNT_HITS}件 / DESIGN不一致=${DESIGN_COUNT_MISMATCH_HITS}件 / DEVELOPMENT不一致=${DEVELOPMENT_COUNT_MISMATCH_HITS}件"
echo "ファイルモード検査: 走査対象=${FILE_MODE_CHECKED_COUNT}件（.claude/scripts/配下・.github/workflows/配下・.github/dependabot.yml。git管理外の場合は0のままスキップ） / 違反=${FILE_MODE_VIOLATION_COUNT}件"
echo "文書内パス参照検証: 走査対象=${DOC_PATH_REF_FILES_SCANNED}文書 / 抽出トークン=${DOC_PATH_REF_TOKEN_TOTAL}件 / 除外(.hw配下)=${DOC_PATH_REF_SKIP_HW_COUNT}件 / 除外(プレースホルダ)=${DOC_PATH_REF_SKIP_PLACEHOLDER_COUNT}件 / 除外(ワイルドカード)=${DOC_PATH_REF_SKIP_WILDCARD_COUNT}件 / 除外(利用者資材例示リスト)=${DOC_PATH_REF_SKIP_EXCLUDE_LIST_COUNT}件 / 不在検出=${DOC_PATH_REF_MISSING_COUNT}件 / トラバーサル検出=${DOC_PATH_REF_TRAVERSAL_COUNT}件"
echo ''

if [ "${#ISSUES[@]}" -eq 0 ]; then
  echo '[OK] 検出された問題はありません。'
else
  # カテゴリ別グループ表示（ISSUESに現れた順序を維持する）
  categories_seen=()
  for entry in "${ISSUES[@]}"; do
    category="$(printf '%s' "$entry" | cut -f2)"
    already=0
    if [ "${#categories_seen[@]}" -gt 0 ]; then
      for c in "${categories_seen[@]}"; do
        if [ "$c" = "$category" ]; then already=1; break; fi
      done
    fi
    if [ "$already" -eq 0 ]; then categories_seen+=("$category"); fi
  done

  for category in "${categories_seen[@]}"; do
    echo "--- $category ---"
    for entry in "${ISSUES[@]}"; do
      entry_category="$(printf '%s' "$entry" | cut -f2)"
      if [ "$entry_category" = "$category" ]; then
        severity="$(printf '%s' "$entry" | cut -f1)"
        target="$(printf '%s' "$entry" | cut -f3)"
        message="$(printf '%s' "$entry" | cut -f4)"
        echo "[$severity] $target : $message"
      fi
    done
    echo ''
  done
fi

echo '==================================================='
echo "ERROR: $error_count 件 / WARN: $warn_count 件"
echo '==================================================='

if [ "$error_count" -gt 0 ]; then
  exit 1
else
  exit 0
fi
