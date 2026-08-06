#!/usr/bin/env bash
#
# verify-assets.sh — hermit-works 資材変更の検証一括実行スクリプト
#
# 位置づけ:
#   CONTRIBUTING.md 8章（スクリプト・CI 定義の追加・変更手順）の対象となる保守用スクリプト
#   （`.claude/scripts/<name>.sh`）。手順資産 .hw/procedures/hw-flow-policy-integration.md 手順5
#   （`claude plugin validate .` ＋ `bash .claude/scripts/validate.sh` の実行・合否判定・増分diffの
#   スナップショット取得の一括化）のスクリプト化候補実装。
#
#   旧実体は `.hw/scripts/hw-verify.sh`（`.hw/` 配下の既定配置スクリプト。.gitignoreによりバージョン
#   管理対象外）だったが、#71 での validate.sh の `scripts/validate.sh` → `.claude/scripts/validate.sh`
#   移設に旧実体が追従できておらず（`.hw/` が非git管理のため通常の変更検知・レビュー対象に乗らない）、
#   常にフォールバック側（`scripts/validate.sh`）を探して見つからずSKIPし、かつSKIPしたことが
#   「[PASS] 検証はすべて合格しました」という文言に埋もれて誤って検証済みと誤認しうる状態に
#   なっていた（issue #76）。本移設で git 管理下の `.claude/scripts/` 配下へ置き直し、
#   以下の3点を是正した:
#     1. validate.sh の解決順を `.claude/scripts/validate.sh` 優先 → `scripts/validate.sh`
#        フォールバックに変更する（移設前後・利用側の双方に対応する）
#     2. 本リポジトリ（`.claude-plugin/marketplace.json` が存在する＝プラグイン本体リポジトリ）で
#        validate.sh がどちらの場所にも見つからない場合は SKIP でなく FAIL とする（利用側
#        リポジトリでの正当な不在のみ SKIP のまま）
#     3. 主要ステップ（validate.sh 相当）が SKIP のとき、結果サマリに「[PASS]」と読める文言を
#        出さないようにする
#
#   さらに、初回品質ゲート（T6 R1）で以下の是正を統括裁定として追加した:
#     4. [qa M1] 必須2ステップ（claude plugin validate / validate.sh）は対称に扱う。片方
#        （claude plugin validate）だけがSKIPし、もう片方（validate.sh）がPASSという理由で
#        最終行が「[PASS]」/ exit 0 になっていたのは、3で是正した経路と同型の「静かにSKIPして
#        合格に見える」バグだったため、いずれか一方でもSKIPすれば結果は「[未検証]」/ exit 2 とし、
#        どのステップがSKIPしたかを文言に明示する（詳細は下記「実行内容」1・「結果サマリー」参照）。
#     5. [sec M-s1] diffスナップショットの既定保存先は `mktemp` でランダムなパスを新規生成し、
#        パーミッションを0600にする（詳細は下記「実行内容」4参照）。
#
#   2巡目の品質ゲート（T6 R2）で以下を追加是正した:
#     6. [sec R2 M2] `.claude/scripts/tests/lib/assertions.sh` の `cleanup()` ガードに
#        パス正規化（`pwd -P`）を追加し、`..` を含む派生パス・中間symlink経由の混入も
#        弾くようにした（詳細は同ファイルのコメント参照）。
#     7. [sec R2 L1] 第2引数で保存先を明示指定した場合も、書き込み後にパーミッションを
#        0600へ揃えるようにした（詳細は下記「実行内容」4参照）。
#
# 実行内容:
#   1. `claude plugin validate <repo-root>` を実行し、出力を表示する（`--strict`は
#      付けない。CI（.github/workflows/validate.yml）・CLAUDE.md・CONTRIBUTING.md
#      が示す基準と同じ無印コマンドに統一している）。終了コード（0=PASS/
#      非0=FAIL）をそのまま合否判定に用いる。`claude` コマンドが見つからない場合は
#      このステップをSKIPする（環境側の制約）。ただし本ステップのSKIPは
#      「未検証」（結果サマリー参照。上記4）として扱い、validate.sh側がPASSでも
#      全体を無条件PASSにはしない。
#   2. validate.sh を次の優先順で解決し、見つかった側を実行して出力を表示する:
#        (1) `<repo-root>/.claude/scripts/validate.sh`
#        (2) `<repo-root>/scripts/validate.sh`（将来の配布用スクリプト置き場。CONTRIBUTING 8.2）
#      末尾の「ERROR: N 件 / WARN: N 件」（validate.sh の結果出力セクション）を解析し、
#      いずれか1件以上でFAILとする（validate.sh 自体は現状ERROR>0でのみ非0終了するため、
#      将来WARNのみの検出が追加された場合にも本スクリプト側でFAIL判定できるようにする追加解析。
#      解析できない場合は終了コードにフォールバックする）。
#      どちらの場所にも validate.sh が見つからない場合:
#        - 本リポジトリ（`<repo-root>/.claude-plugin/marketplace.json` が存在する）なら FAIL
#          とする（本来存在すべきものが欠落している異常事態であり、静かにSKIPして検証済みと
#          誤認させない）
#        - それ以外（利用者側リポジトリでの実行と判断）なら SKIP とし、全体の合否判定には
#          算入しない
#   3. 1・2は片方が失敗してももう片方を必ず実行する（結果を代入する if 文の条件式として
#      各コマンドを実行し、set -e の直接影響を受けないようにしている）。
#   4. リポジトリが git 管理下にある場合、未コミット変更の増分diffをスナップショットとして
#      保存する:
#        - 追跡ファイルの増分: `git diff HEAD`
#        - 未追跡ファイルのうちプラグイン資材（ASSET_PATH_PREFIXES）に該当するもの:
#          `git diff --no-index /dev/null <file>` 形式で追記
#      保存先は第2引数（省略時: `mktemp` が `${TMPDIR:-/tmp}` 配下に新規生成するランダムな
#      パス）。第2引数で保存先を明示指定した場合は書き込み先パスそのものは変えない
#      （呼び出し側の意図したパスへそのまま書く）が、いずれの経路でも書き込み直前に
#      対象パスがシンボリックリンクでないことを確認し、シンボリックリンクの場合は追従せず
#      書き込みを拒否してFAILとする（sec-audit M-s1: 秒精度日時の予測可能な既定パスへ
#      `>` が事前配置されたsymlinkを追従してしまうCWE-377/CWE-59系のリスクへの対処。
#      既定生成側はmktempが新規ファイルを払い出すため通常は該当しないが、TOCTOU・
#      第三者による事前配置への備えとして両経路に同じガードをかける）。書き込み成功後、
#      パーミッションは既定・明示指定のいずれの経路でも0600（所有者のみ読み書き可）へ
#      揃える（sec-audit R2 L1: diff内容の秘匿性が本旨であり、呼び出し元のumask等の
#      環境依存に頼らないため。呼び出し側が別の権限を必要とする場合は、呼び出し側で
#      改めて `chmod` する運用とする）。
#      なお、symlinkチェックと直後の`>`書き込みの間には理論上TOCTOU（チェック後・
#      使用前の差し替え）が残る（sec-audit R2 L2・統括裁定で残余リスクとして受容）。
#      対策候補の`set -C`（noclobber）は同一パスへの再実行を失敗させ、本スクリプトの
#      主用途（同じ保存先へ繰り返し取得する運用）を壊すため採らない。既定パスは
#      mktempのアトミック生成＋`/tmp`のsticky bitで実質的リスクは小さく、残るのは
#      「第三者が書き込めるディレクトリを呼び出し側が明示指定した場合」に限られる。
#      git管理下でない場合はこのステップをスキップし、検証（1・2）のみ行う。
#      `.hw/` は含めない: リポジトリの `.gitignore` がディレクトリごと除外しており
#      （バージョン管理対象外という設計上の位置づけ）、`git ls-files .hw/` が常に0件
#      （本スクリプト自身は `.claude/scripts/` 配下のためgit管理下にあるが、`.hw/` 配下は
#      対象外のまま）。`.hw/` 配下の成果物を品質ゲートへ渡す必要がある場合は、完了報告で
#      ファイルパスを明示する運用とする。
#   5. 結果サマリーを表示する（合否判定の根拠は上記のとおり）。
#
# 採用理由:
#   validate.sh と同様、追加ランタイムを要求しない bash のみで実装する（CONTRIBUTING.md 8.3）。
#   ネットワークアクセス・外部送信は行わない。
#
# 実行例:
#   bash .claude/scripts/verify-assets.sh
#   bash .claude/scripts/verify-assets.sh /path/to/other-repo
#   bash .claude/scripts/verify-assets.sh /path/to/other-repo /path/to/diff-snapshot.patch
#
set -euo pipefail

# ロケールをCに固定する（validate.sh と同じ理由。ASCII範囲の正規表現・文字列比較が
# ロケール依存で揺れることを防ぐ）。
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 引数・リポジトリルートの決定
# ---------------------------------------------------------------------------
# 第1引数: リポジトリルート（省略時は本スクリプトの配置場所 .claude/scripts/ から
# 相対的に自動解決する。validate.sh・sync-guidelines.sh と同じ方式。CONTRIBUTING 8.3）。
# 第2引数: diffスナップショットの保存先（省略時は mktemp が新規生成するランダムなパス。
# sec-audit M-s1参照）。
REPO_ROOT="${1:-}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
fi
readonly REPO_ROOT

DIFF_SNAPSHOT_PATH="${2:-}"
if [ -z "$DIFF_SNAPSHOT_PATH" ]; then
  # 既定の保存先は mktemp でランダムなファイル名を新規生成する（秒精度日時の予測可能パスへ
  # symlinkを事前配置され `>` がそれを追従してしまうリスクを避けるため。sec-audit M-s1）。
  # mktemp は既定でファイルを0600（所有者のみ読み書き）で作成するが、実装差を吸収するため
  # 直後に明示的にも0600へ揃える。
  DIFF_SNAPSHOT_PATH="$(mktemp "${TMPDIR:-/tmp}/verify-assets-diff-XXXXXXXXXX.patch")"
  chmod 600 "$DIFF_SNAPSHOT_PATH"
fi
readonly DIFF_SNAPSHOT_PATH

# git 管理下かどうかは REPO_ROOT を基準に判定する（CWDではなく、引数で指定された
# 対象ディレクトリを基準にする。sync-guidelines.sh と同じ方式）。
IS_GIT_REPO=0
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT_REPO=1
fi
readonly IS_GIT_REPO

# 本リポジトリ（プラグイン本体）判定: `.claude-plugin/marketplace.json` の存在で判定する
# （プラグイン配布の必須ファイルであり、本リポジトリのみが持つ）。
IS_PLUGIN_REPO=0
if [ -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]; then
  IS_PLUGIN_REPO=1
fi
readonly IS_PLUGIN_REPO

# 全体の合否フラグ（0=問題なし、1=いずれかのステップでFAIL）。
OVERALL_FAIL=0

echo '==================================================='
echo 'verify-assets: hermit-works 検証一括実行'
echo "リポジトリルート: $REPO_ROOT"
echo '==================================================='
echo ''

# ---------------------------------------------------------------------------
# 1) claude plugin validate
# ---------------------------------------------------------------------------
echo '--- [1/2] claude plugin validate ---'
PLUGIN_VALIDATE_STATUS='SKIP'
if command -v claude >/dev/null 2>&1; then
  plugin_validate_exit=0
  plugin_validate_output=""
  if plugin_validate_output="$(claude plugin validate "$REPO_ROOT" 2>&1)"; then
    plugin_validate_exit=0
  else
    plugin_validate_exit=$?
  fi
  printf '%s\n' "$plugin_validate_output"
  if [ "$plugin_validate_exit" -eq 0 ]; then
    PLUGIN_VALIDATE_STATUS='PASS'
  else
    PLUGIN_VALIDATE_STATUS='FAIL'
    OVERALL_FAIL=1
  fi
else
  echo '[SKIP] claude コマンドが見つかりません（PATH未設定等）。このステップをスキップします。'
fi
echo ''

# ---------------------------------------------------------------------------
# 2) validate.sh（.claude/scripts/validate.sh 優先 → scripts/validate.sh フォールバック）
# ---------------------------------------------------------------------------
echo '--- [2/2] validate.sh ---'
VALIDATE_SH_STATUS='SKIP'
VALIDATE_SH_PATH=""
if [ -f "$REPO_ROOT/.claude/scripts/validate.sh" ]; then
  VALIDATE_SH_PATH="$REPO_ROOT/.claude/scripts/validate.sh"
elif [ -f "$REPO_ROOT/scripts/validate.sh" ]; then
  VALIDATE_SH_PATH="$REPO_ROOT/scripts/validate.sh"
fi

if [ -n "$VALIDATE_SH_PATH" ]; then
  echo "(解決先: $VALIDATE_SH_PATH)"
  validate_sh_exit=0
  validate_sh_output=""
  if validate_sh_output="$(bash "$VALIDATE_SH_PATH" "$REPO_ROOT" 2>&1)"; then
    validate_sh_exit=0
  else
    validate_sh_exit=$?
  fi
  printf '%s\n' "$validate_sh_output"

  # 出力末尾の「ERROR: N 件 / WARN: N 件」（validate.sh の結果出力セクション）を解析する。
  # 解析できない場合（出力形式が変わった等）は終了コードにフォールバックする。
  summary_line="$(printf '%s\n' "$validate_sh_output" \
    | grep -E '^ERROR: [0-9]+ 件 / WARN: [0-9]+ 件$' | tail -n 1 || true)"
  if [ -n "$summary_line" ]; then
    err_count="$(printf '%s' "$summary_line" | sed -E 's/^ERROR: ([0-9]+).*/\1/')"
    warn_count="$(printf '%s' "$summary_line" | sed -E 's/.*WARN: ([0-9]+) 件$/\1/')"
    if [ "$err_count" -gt 0 ] || [ "$warn_count" -gt 0 ]; then
      VALIDATE_SH_STATUS='FAIL'
      OVERALL_FAIL=1
    else
      VALIDATE_SH_STATUS='PASS'
    fi
  else
    if [ "$validate_sh_exit" -eq 0 ]; then
      VALIDATE_SH_STATUS='PASS'
    else
      VALIDATE_SH_STATUS='FAIL'
      OVERALL_FAIL=1
    fi
  fi
elif [ "$IS_PLUGIN_REPO" -eq 1 ]; then
  echo "[FAIL] 本リポジトリ（$REPO_ROOT/.claude-plugin/marketplace.json が存在）なのに validate.sh が .claude/scripts/ にも scripts/ にも見つかりません。プラグイン本体での欠落は異常事態のためFAILとします。"
  VALIDATE_SH_STATUS='FAIL'
  OVERALL_FAIL=1
else
  echo "[SKIP] validate.sh が見つかりません（$REPO_ROOT/.claude/scripts/validate.sh・$REPO_ROOT/scripts/validate.sh のいずれも不在）。利用者側リポジトリでの実行と判断し、このステップをスキップします。"
fi
echo ''

# ---------------------------------------------------------------------------
# 3) 未コミット変更の増分diffスナップショット
# ---------------------------------------------------------------------------
# プラグイン資材の対象範囲（DEVELOPMENT.md「ディレクトリ構成」節のうち、バージョン管理対象の
# もの）。未追跡ファイルのうち、この配下・このファイル名に該当するものだけをスナップショットへ
# 含める（エディタ/OS作業ファイル等のノイズ混入を避けるための許可リスト方式。.gitignore対象は
# `git status`（--ignoredなし）の時点で既に除外されている）。
#
# `.hw/` は含めない: リポジトリの `.gitignore` がディレクトリごと除外しており
# （コメント「環境ローカルのため共有しない」）、`git ls-files .hw/` が常に0件（バージョン管理
# 対象外という設計上の位置づけ）。git はディレクトリ単位で除外された階層の配下を個別列挙しない
# ため `--ignored=matching` を付けても個々のファイルには展開できず、そもそも「差分」という
# 概念になじまない（比較対象となる版が存在しない）。`.hw/` 配下の成果物（本スクリプトの成果物を
# 含む）を品質ゲートへ渡す必要がある場合は、完了報告でファイルパスを明示する運用とする。
ASSET_PATH_PREFIXES=(
  '.claude/'
  '.claude-plugin/'
  '.devcontainer/'
  '.github/'
  'agents/'
  'commands/'
  'skills/'
  'scripts/'
  'CLAUDE.md'
  'README.md'
  'DEVELOPMENT.md'
  'CONTRIBUTING.md'
  'DESIGN.md'
  'LICENSE'
)

is_asset_path() {
  local path="$1" prefix
  for prefix in "${ASSET_PATH_PREFIXES[@]}"; do
    case "$path" in
      "$prefix"*) return 0 ;;
    esac
  done
  return 1
}

echo '--- diff スナップショット ---'
if [ "$IS_GIT_REPO" -eq 1 ]; then
  # 書き込み直前に対象パスがシンボリックリンクでないことを確認する（第2引数で明示指定された
  # 場合も含む。sec-audit M-s1）。symlinkだった場合は追従せず書き込みを拒否し、安全側に倒す。
  if [ -L "$DIFF_SNAPSHOT_PATH" ]; then
    echo "[FAIL] スナップショット保存先がシンボリックリンクです（追従して書き込むと意図しない場所を上書きしうるため拒否します）: $DIFF_SNAPSHOT_PATH"
    OVERALL_FAIL=1
  else
    snapshot_dir="$(dirname -- "$DIFF_SNAPSHOT_PATH")"
    if [ ! -d "$snapshot_dir" ]; then
      echo "[FAIL] スナップショット保存先のディレクトリが存在しません: $snapshot_dir"
      OVERALL_FAIL=1
    else
      if {
        echo "# verify-assets diff snapshot"
        echo "# 生成日時: $(date -Iseconds)"
        echo "# リポジトリルート: $REPO_ROOT"
        echo ''
        echo '## 追跡ファイルの増分（git diff HEAD）'
        if git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null; then
          git -C "$REPO_ROOT" diff HEAD || true
        else
          echo '(HEADが存在しないため、追跡ファイルの増分diffはスキップします)'
        fi
        echo ''
        echo '## 未追跡ファイル（プラグイン資材に該当するもののみ）'
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          status="${line:0:2}"
          path="${line:3}"
          if [ "$status" = '??' ] && is_asset_path "$path"; then
            git -C "$REPO_ROOT" diff --no-index -- /dev/null "$path" || true
          fi
        done < <(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)
      } > "$DIFF_SNAPSHOT_PATH"; then
        # 第2引数で明示指定された保存先も含め、書き込み後にパーミッションを0600へ揃える
        # （既定パス＝mktemp生成分は既にmktempが0600で作成済みだが、ここで揃えても
        # 副作用はない。sec-audit R2 L1）。
        chmod 600 "$DIFF_SNAPSHOT_PATH"
        echo "[OK] 増分diffスナップショットを保存しました: $DIFF_SNAPSHOT_PATH"
      else
        echo "[FAIL] 増分diffスナップショットの書き込みに失敗しました: $DIFF_SNAPSHOT_PATH"
        OVERALL_FAIL=1
      fi
    fi
  fi
else
  echo '[SKIP] git リポジトリではないため、diffスナップショットをスキップします（検証のみ実施済み）。'
fi
echo ''

# ---------------------------------------------------------------------------
# 結果サマリー
# ---------------------------------------------------------------------------
echo '==================================================='
echo '検証結果サマリー'
echo "claude plugin validate : $PLUGIN_VALIDATE_STATUS"
echo "validate.sh             : $VALIDATE_SH_STATUS"
echo '==================================================='

if [ "$OVERALL_FAIL" -eq 1 ]; then
  echo '[FAIL] ERROR/WARNまたは実行時エラーが検出されました。詳細は上記の出力を参照してください。'
  exit 1
elif [ "$PLUGIN_VALIDATE_STATUS" = 'SKIP' ] || [ "$VALIDATE_SH_STATUS" = 'SKIP' ]; then
  # 欠陥3・M1是正: 必須2ステップ（claude plugin validate / validate.sh）は対称に扱う。
  # どちらか一方でもSKIPしたときは、[PASS]と読める文言を出さない（他方の結果だけを根拠に
  # 検証済みと誤認させないため）。どのステップがSKIPしたかを文言に明示する。
  # 注意: このメッセージ自体にも「[PASS]」の文字列を含めない（本文言をgrepで拾う運用が
  # あった場合に誤って合格扱いされることを避けるため。是正対象の欠陥そのものの再発防止）。
  skipped_steps=""
  if [ "$PLUGIN_VALIDATE_STATUS" = 'SKIP' ]; then
    skipped_steps="claude plugin validate"
  fi
  if [ "$VALIDATE_SH_STATUS" = 'SKIP' ]; then
    if [ -n "$skipped_steps" ]; then
      skipped_steps="${skipped_steps} / validate.sh"
    else
      skipped_steps="validate.sh"
    fi
  fi
  echo "[未検証] 必須ステップ（${skipped_steps}）がSKIPしたため、検証済みとは言えません（合格を意味しません）。環境（claudeコマンドの有無・validate.shの配置有無）を確認してください。"
  exit 2
else
  echo '[PASS] 必須2ステップ（claude plugin validate / validate.sh）とも実行し、合格しました。'
  exit 0
fi
