#!/usr/bin/env bash
# Push a directory of text files to a GitHub repo as ONE commit, via the
# mcp-github-home MCP server (push_files). Use when this VM has no writable
# git integration for the repo -- e.g. a repo it just created.
#
#   push-tree.sh <owner> <repo> <branch> <message> <dir> [-- <git-pathspec>...]
#
# Files are taken from `git ls-files` if <dir> is a git worktree (so .gitignore
# is honoured), otherwise from `find`. Binary files are refused: push_files
# carries content as a JSON string, not base64.
set -euo pipefail
[ $# -ge 5 ] || { echo "usage: push-tree.sh <owner> <repo> <branch> <message> <dir> [-- pathspec...]" >&2; exit 2; }
owner=$1 repo=$2 branch=$3 msg=$4 dir=$5; shift 5
if [ "${1:-}" = -- ]; then shift; fi

HERE=$(dirname "$(readlink -f "$0")")
cd "$dir"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files -- "$@")
else
  mapfile -t files < <(find . -type f -not -path './.git/*' -printf '%P\n' | sort)
fi
[ ${#files[@]} -gt 0 ] || { echo "push-tree: no files" >&2; exit 1; }

# `push_files` carries each file as a JSON *string*, so the content must be
# valid UTF-8 with no NUL bytes. Both checks are needed and neither implies the
# other: `iconv` accepts NUL happily, and grep's own binary heuristic is *only*
# NUL, so a file of random bytes with no NUL in it sails through as "text" and
# is then silently corrupted on the way up. Refuse loudly here instead.
for f in "${files[@]}"; do
  if [ "$(tr -d '\000' < "$f" | wc -c)" -ne "$(wc -c < "$f")" ]; then
    echo "push-tree: $f contains NUL bytes; push_files cannot carry binary" >&2; exit 1
  fi
  if ! iconv -f UTF-8 -t UTF-8 < "$f" > /dev/null 2>&1; then
    echo "push-tree: $f is not valid UTF-8; push_files cannot carry it" >&2; exit 1
  fi
done

payload=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s \
  --arg owner "$owner" --arg repo "$repo" --arg branch "$branch" --arg msg "$msg" \
  'map({path: ., content: null}) as $stub | {owner:$owner, repo:$repo, branch:$branch, message:$msg, files:$stub}')

# Fill in contents (jq cannot read files by name portably).
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
printf '%s' "$payload" > "$tmp"
for i in "${!files[@]}"; do
  jq --argjson i "$i" --rawfile c "${files[$i]}" '.files[$i].content = $c' "$tmp" > "$tmp.n" && mv "$tmp.n" "$tmp"
done

"$HERE/gh-mcp.sh" push_files "$(cat "$tmp")"
