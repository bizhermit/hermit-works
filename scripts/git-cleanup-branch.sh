#!/usr/bin/env bash
#
# ブランチ運用（作業ブランチは develop から分岐・派生元は develop 統合ライン）に合わせ、
# 対象ブランチへ切り替えたうえで、リモートで削除済み（upstream追跡が [gone]）のローカル
# 作業ブランチをまとめて削除する。引数省略時の既定切り替え先は develop とする
# （main 等 develop 以外を対象にしたい場合は第1引数で明示する。以前は origin の
# デフォルトブランチ（main）を自動検出していたが、作業ブランチ起点が develop のため
# 都度の引数明示が手間だった。2026-08-02 に既定 develop へ変更）。
#
# 実行例:
#   bash scripts/git-cleanup-branch.sh          # develop に切り替えて cleanup
#   bash scripts/git-cleanup-branch.sh feature/x # feature/x に切り替えて cleanup
#   # VSCode からは .vscode/tasks.json 経由でも実行可能（既定 develop・入力欄で上書き可）
#
# 回帰テスト:
#   分岐（ブランチ名検証の case 文）・パース処理（[gone] 判定の awk）は存在するが、
#   いずれも1〜2行の単純な等値比較・パターンマッチにとどまり誤り混入リスクが低く、
#   他資材の合否判定にも関与しないため CONTRIBUTING.md 8.4 の基準に実質該当しないと
#   判断し、回帰テストは新設していない（既定 develop 化後もこの判断に変更なし）。
set -euo pipefail

# git リポジトリ外での実行を早期に検出する（git-changelog.sh と同様のチェック）。
# これが無いと、git リポジトリ外では後段の `git status --porcelain` が空出力を返し
# 「クリーン」と誤判定されたまま、分かりにくい箇所で失敗する。
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: 現在のディレクトリは git リポジトリではありません。" >&2
  exit 1
fi

target_branch="${1:-develop}"

# 作業ディレクトリがクリーンかチェック
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: Working directory is not clean." >&2
  echo "Please commit or stash your changes before running this script." >&2
  exit 1
fi

is_safe_branch_name() {
  local name="$1"
  case "$name" in
    (""|-*) return 1 ;;
    (*[!A-Za-z0-9._/-]*) return 1 ;;
    (*) return 0 ;;
  esac
}

if ! is_safe_branch_name "$target_branch"; then
  echo "Error: Suspicious branch name detected: $target_branch" >&2
  exit 1
fi

echo "Target branch: $target_branch"

git fetch --prune

remote_target_branch="origin/$target_branch"

if ! git show-ref --verify --quiet "refs/remotes/$remote_target_branch"; then
  echo "Error: Remote branch $remote_target_branch not found." >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/heads/$target_branch"; then
  git switch -- "$target_branch"
else
  echo "Creating local tracking branch $target_branch from $remote_target_branch..."
  git switch --track -c "$target_branch" -- "$remote_target_branch"
fi

git merge --ff-only "$remote_target_branch"

# 削除対象ブランチ抽出
if ! gone_branches=$(
  git for-each-ref --format '%(refname:short) %(upstream:track)' refs/heads \
  | awk '$2 == "[gone]" {print $1}'
); then
  echo "Error: Failed to list local branches (git for-each-ref | awk pipeline failed)." >&2
  exit 1
fi

if [ -z "$gone_branches" ]; then
  echo
  echo "No branches to delete."
else
  echo
  echo "Deleting branches:"
  # パイプ経由（... | while）だとwhileがサブシェルで実行され、ループ内での変数更新が
  # 外側に反映されなくなる（本スクリプトでは実害はないが、他スクリプトの回避方針と
  # 揃えるため <<< 方式にする）。
  while IFS= read -r branch; do
    # 空行対策
    if [ -n "$branch" ]; then
      echo "  - $branch"
      if ! is_safe_branch_name "$branch"; then
        echo "    Skipped (unsafe branch name detected)" >&2
        continue
      fi
      if ! git branch -d -- "$branch"; then
        echo "    Failed (maybe not fully merged)"
      fi
    fi
  done <<< "$gone_branches"
fi

echo
echo "Done!"
echo
