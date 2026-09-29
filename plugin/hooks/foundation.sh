#!/bin/sh
# 作業品質の基盤（assets/foundation.md）を、引数のフックイベントのadditionalContextとして出力する
set -eu

event="$1"
foundation="$(dirname "$0")/../assets/foundation.md"

awk -v event="$event" '
{
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    gsub(/\t/, "\\t")
    body = body (NR > 1 ? "\\n" : "") $0
}
END {
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"%s\",\"additionalContext\":\"%s\"}}\n", event, body
}
' "$foundation"
