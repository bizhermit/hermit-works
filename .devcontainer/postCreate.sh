#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")"

if ! claude --version; then
  echo "エラー: 'claude --version' に失敗しました。Claude Code のインストールに問題がある可能性があります。Dockerfile の Claude Code インストール手順 (curl https://claude.ai/install.sh | bash) を確認し、コンテナを Rebuild してください。" >&2
  exit 1
fi
