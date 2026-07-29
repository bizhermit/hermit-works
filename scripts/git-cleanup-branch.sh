#!/usr/bin/env bash
set -euo pipefail

target_branch="${1:-}"

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

# 引数が無ければデフォルトブランチを取得
if [ -z "$target_branch" ]; then
  echo "Detecting default branch from remote..."
  git remote set-head origin -a >/dev/null 2>&1 || true
  target_branch=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's!origin/!!' || true)

  if [ -z "$target_branch" ] || [ "$target_branch" = "HEAD" ]; then
    echo "Error: Could not detect default branch from origin." >&2
    exit 1
  fi
fi

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

git merge --ff-only "@{u}"

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
  echo "$gone_branches" | while IFS= read -r branch; do
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
  done
fi

echo
echo "Done!"
echo
