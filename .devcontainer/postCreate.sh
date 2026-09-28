#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")"

if ! claude --version; then
  echo "エラー: 'claude --version' に失敗しました。Claude Code のインストールに問題がある可能性があります。Dockerfile の Claude Code インストール手順 (curl https://claude.ai/install.sh | bash) を確認し、コンテナを Rebuild してください。" >&2
  exit 1
fi

# リポジトリの .claude/settings.json（extraKnownMarketplaces 等）を適用させるため、/workspace を信頼済みにする
python3 - <<'EOF'
import json, os
path = os.path.expanduser("~/.claude.json")
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
data.setdefault("projects", {}).setdefault("/workspace", {})["hasTrustDialogAccepted"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
EOF
