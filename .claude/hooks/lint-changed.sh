#!/usr/bin/env bash
# PostToolUse hook: lint the file that was just written (spec 18.2).
#
# Feeding the error back immediately is cheaper than finding it in CI. Never
# blocks -- it reports. Exit 2 would reject the edit itself, which is too blunt
# for a style warning.

set -uo pipefail

payload="$(cat)"

file_path="$(
  printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit()
print(data.get("tool_input", {}).get("file_path", "") or "")
'
)"

[ -z "$file_path" ] || [ ! -f "$file_path" ] && exit 0

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 0

case "$file_path" in
  *.lua)
    command -v luacheck >/dev/null 2>&1 || exit 0
    luacheck --codes --ranges "$file_path" || true
    ;;

  *.ts|*.svelte|*.js|*.mjs)
    # Skip when dependencies are not installed yet.
    [ -d node_modules ] || exit 0
    pnpm exec eslint "$file_path" || true
    ;;

  */locales/*.json)
    [ -d node_modules ] || exit 0
    pnpm i18n:check || true
    ;;
esac

exit 0
