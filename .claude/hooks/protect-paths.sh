#!/usr/bin/env bash
# PreToolUse hook: refuse edits that the invariants say must never happen.
#
# CLAUDE.md guides behavior; a hook enforces it (spec 18.2). Exit 2 blocks the
# tool call and shows the message to Claude.
#
# Blocked here:
#   - editing a migration that already exists (invariant 8, append-only);
#   - editing a real environment file (invariant 7, secrets);
#   - editing generated code by hand.

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

[ -z "$file_path" ] && exit 0

# Repo-relative, so the rules read the same wherever the checkout lives.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
relative="${file_path#"$repo_root"/}"

case "$relative" in
  database/migrations/*.sql)
    # Only an *existing* migration is protected: adding a new one is the
    # entire point of the folder.
    if [ -f "$file_path" ]; then
      echo "Blocked: $relative has already shipped." >&2
      echo "database/migrations/ is append-only (invariant 8). Add a new numbered migration instead -- do not edit this one, not even a comment." >&2
      exit 2
    fi
    ;;

  .env|.env.*|*/.env|*/.env.*)
    case "$relative" in
      *.example) exit 0 ;;
    esac
    echo "Blocked: $relative holds secrets." >&2
    echo "Secrets live in \`set\` convars and gateway environment variables, never in the repository (invariant 7). Edit .env.example instead, with placeholder values." >&2
    exit 2
    ;;

  *shared/generated/*)
    echo "Blocked: $relative is generated." >&2
    echo "Edit packages/schema/src/ and run \`pnpm schema:gen\`. Hand-editing generated Lua is exactly the drift the generator exists to prevent." >&2
    exit 2
    ;;
esac

exit 0
