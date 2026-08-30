#!/usr/bin/env bash

set -euo pipefail

# gitリポジトリ外での実行を早期に検出する
# git リポジトリ外では後段の`git status --porcelain`が空出力を返し、「クリーン」と誤判定されたまま分かりにくい箇所で失敗する
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: 現在のディレクトリはgitリポジトリではありません。" >&2
  exit 1
fi

# 既定ブランチは`develop`
target_branch="${1:-develop}"

# 作業ディレクトリがクリーンかチェックする
if [ -n "$(git status --porcelain)" ]; then
  echo "Warning: Working directory is not clean." >&2
  git status --short >&2
  # 非対話実行（VSCodeタスク・CI等で標準入力が端末でない）では問えないため、従来どおり中断する。
  if [ ! -t 0 ]; then
    echo "Error: 非対話実行のため中断する。commit または stash してから再実行すること。" >&2
    exit 1
  fi
  # クリーンでなくても、対話実行なら続行可否を問う
  #（後段の switch / merge --ff-only は変更を上書きしそうな場合にgit自身が失敗するため、強制続行しても未コミットの変更は失われない）
  read -r -p "未コミットの変更を残したまま続行しますか？ [y/N]: " force_answer || force_answer=""
  case "$force_answer" in
    (y|Y|yes|YES) echo "続行する。" ;;
    (*)
      echo "Aborted. Please commit or stash your changes before running this script." >&2
      exit 1
      ;;
  esac
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

# ブランチの変更がtarget_branchに取り込み済みかを判定する
# squashマージでは元のコミットが残らないため、`git branch -d`のマージ判定は通らない。
# ブランチのツリーをmerge-base上に載せた合成コミットを作り、`git cherry`のパッチID比較で
# 同じ変更がtarget側にあるか（先頭が`-`なら取り込み済み）を見る。
is_merged_into_target() {
  local branch="$1"
  local base synth
  base=$(git merge-base "$target_branch" "$branch") || return 1
  synth=$(git commit-tree "$branch^{tree}" -p "$base" -m _) || return 1
  case "$(git cherry "$target_branch" "$synth")" in
    (-*) return 0 ;;
    (*) return 1 ;;
  esac
}

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
  skipped=0
  # パイプ経由（... | while）だとwhileがサブシェルで実行され、ループ内での変数更新が外側に反映されなくなる
  while IFS= read -r branch; do
    # 空行対策
    if [ -n "$branch" ]; then
      echo "  - $branch"
      if ! is_safe_branch_name "$branch"; then
        echo "    Skipped (unsafe branch name detected)" >&2
        continue
      fi
      # 通常マージ済みなら-dで削除できる（エラー出力は後段の判定に回すため抑止する）
      if git branch -d -- "$branch" >/dev/null 2>&1; then
        echo "    Deleted"
      elif is_merged_into_target "$branch"; then
        # squashマージ済み: -dは拒否するが、変更はtarget_branchに入っている
        git branch -D -- "$branch" >/dev/null
        echo "    Deleted (squash merged)"
      else
        echo "    Skipped (未マージの変更があります。破棄してよければ git branch -D -- $branch)" >&2
        skipped=1
      fi
    fi
  done <<< "$gone_branches"
fi

echo
if [ "${skipped:-0}" -ne 0 ]; then
  echo "Done (未マージのため残したブランチがあります)."
  echo
  exit 1
fi
echo "Done!"
echo
