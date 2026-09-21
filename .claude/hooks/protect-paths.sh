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
    # Only a *committed* migration is protected. Adding a new one is the entire
    # point of the folder, and a migration written minutes ago and not yet
    # committed has not shipped -- it is still being drafted, and MariaDB
    # rejecting a constraint is the ordinary way that drafting goes.
    #
    # The test used to be `[ -f ]`, which blocked the draft too: the author
    # could create the file but never correct it, which is not what invariant 8
    # protects. Invariant 8 is about migrations other servers have already
    # applied, and "in git" is the closest available proxy for that.
    #
    # Fails closed. If git cannot answer -- not a repository, no HEAD yet --
    # an existing file is treated as shipped, because the cost of blocking a
    # legitimate edit is a second migration and the cost of allowing an
    # illegitimate one is a schema that silently differs between servers.
    if [ -f "$file_path" ]; then
      if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
        echo "Blocked: $relative exists and this is not a git repository." >&2
        echo "database/migrations/ is append-only (invariant 8), and without git there is no way to tell a draft from a shipped migration. Add a new numbered migration instead." >&2
        exit 2
      fi

      # `cat-file -e HEAD:<path>`, not `ls-files`. The index is not the
      # proxy we want: `git rm --cached` on a shipped migration would take it
      # out of the index while the file still sits on disk and in every other
      # server's schema history, and the hook would then wave an edit through.
      # What "has shipped" means is "is in a commit".
      if git -C "$repo_root" cat-file -e "HEAD:$relative" 2>/dev/null; then
        echo "Blocked: $relative has already shipped." >&2
        echo "database/migrations/ is append-only (invariant 8). Add a new numbered migration instead -- do not edit this one, not even a comment." >&2
        exit 2
      fi
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
