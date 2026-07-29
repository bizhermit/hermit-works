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

# Windows ホストの bind mount では、UID/GID をホストに合わせていても
# (Dockerfile 参照) Windows 側に UNIX の UID/GID 概念がなく、Docker Desktop の
# ファイル共有経由でマウントすると所有者情報が想定通りにならないことがあり、
# git に "dubious ownership" として拒否されるケースがあるため safe.directory 登録が必要。
# ワイルドカード '*' は任意のパスを無条件に信頼してしまうため使わず、対象を /workspace に限定する。
# postStart は毎起動実行されるため、--add による重複登録を避けて冪等にする。
if ! git config --global --get-all safe.directory | grep -qx '/workspace'; then
  git config --global --add safe.directory /workspace
fi

if ! gh auth status </dev/null >/dev/null 2>&1; then
  warn "gh が未認証です。ターミナルでログインしてください。
  $(code 'gh auth login --git-protocol ssh')"
fi

# 本スクリプトは (先頭の set -eu の通り) pipefail を使用していないため、
# パイプの終了ステータスは最終コマンド (grep) のものだけで判定される。
# claude が異常終了してもここでは検知されないが、claude の認証状態表示は
# ベストエフォートであれば十分なため、それで足りるとしている。
if ! command -v claude >/dev/null 2>&1; then
  warn "claude コマンドが見つかりません。Claude Code のインストールを確認してください。"
elif unauthorized=$(timeout --foreground -k 5 30 claude mcp list </dev/null 2>/dev/null | grep 'Needs authentication'); then
  echo ''
  info "${c_bold}未認可の claude.ai コネクタがあります${c_reset}。使用する場合は認可してください"
  printf '%s%s%s\n' "${c_dim}" "${unauthorized}" "${c_reset}"
fi
