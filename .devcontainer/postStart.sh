#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_reset=$'\033[0m'
  c_bold=$'\033[1m'
  c_dim=$'\033[2m'
  c_orange=$'\033[38;5;209m'
  c_yellow=$'\033[38;5;220m'
  c_cyan=$'\033[38;5;73m'
else
  c_reset='' c_bold='' c_dim='' c_orange='' c_yellow='' c_cyan=''
fi

info() {
  printf '%s✻%s %s\n' "${c_orange}${c_bold}" "${c_reset}" "$1"
}

warn() {
  printf '%s⚠%s %s\n' "${c_yellow}${c_bold}" "${c_reset}" "$1" >&2
}

code() {
  printf '%s%s%s' "${c_cyan}" "$1" "${c_reset}"
}

if ! git config --global --get-all safe.directory | grep -qx '/workspace'; then
  git config --global --add safe.directory /workspace
fi

if ! gh auth status </dev/null >/dev/null 2>&1; then
  warn "gh が未認証です。ターミナルでログインしてください。
  $(code 'gh auth login --git-protocol ssh')"
fi

if ! command -v claude >/dev/null 2>&1; then
  warn "claude コマンドが見つかりません。Claude Code のインストールを確認してください。"
else
  info "claude update を実行しています (更新がある場合は数分かかることがあります)"
  if ! timeout --foreground -k 5 300 claude update </dev/null; then
    warn "claude update が失敗またはタイムアウトしました。既存の版のまま続行します。"
  fi
  if unauthorized=$(timeout --foreground -k 5 30 claude mcp list </dev/null 2>/dev/null | grep 'Needs authentication'); then
    echo ''
    info "${c_bold}未認可の claude.ai コネクタがあります${c_reset}。使用する場合は認可してください"
    printf '%s%s%s\n' "${c_dim}" "${unauthorized}" "${c_reset}"
  fi
fi
