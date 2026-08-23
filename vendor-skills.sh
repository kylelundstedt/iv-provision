#!/usr/bin/env bash
# Refresh the vendored ./skills snapshot AND the generated agent/mcp-servers.json
# from ./provisioning/{skills,mcp}.manifest.
#
# Those manifests used to be fetched from kylelundstedt/dotfiles at the commit
# recorded in ./dotfiles-manifest.pin. They now live here (2026-08-18), so a
# fleet VM provisions with no dependency on a personal repository.
#
# The pin is not missed. It was silently wrong: agent/mcp-servers.json was
# committed with `api-motherduck-mcp` (which matches the real exe.dev
# integration) while the pinned manifest still said `motherduck-mcp`, i.e. the
# content had been re-vendored from a newer dotfiles commit without bumping the
# pin. A pin that can disagree with the artifact it supposedly pins buys nothing;
# the manifests being in-tree and reviewed with the snapshot is stronger.
#
# Run occasionally on any machine with node + jq; commit the result.
# provision-iv.sh installs from the committed snapshot with NO network — this
# is the ONLY step that touches upstream/node.
#
# Installs into a throwaway HOME so your real ~/.agents/skills is left untouched.
#
# SCOPE: this script owns ./skills ENTIRELY -- it `rm -rf`s that directory below
# and rebuilds it from the manifest. Never put a hand-written skill there; the
# next run deletes it with no error and nothing in the diff to say why. In-tree
# skills live in ./skills-local, which this script does not touch and
# provision-iv.sh installs alongside the vendored set.
set -euo pipefail
cd "$(dirname "$0")"

command -v npx >/dev/null || { echo "vendor-skills: need node/npx on PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "vendor-skills: need jq on PATH" >&2; exit 1; }

MANIFEST_DIR="provisioning"
for f in skills.manifest mcp.manifest agents-shared.md; do
  [ -f "$MANIFEST_DIR/$f" ] || { echo "vendor-skills: missing $MANIFEST_DIR/$f" >&2; exit 1; }
done

SKILLS_MANIFEST="$(cat "$MANIFEST_DIR/skills.manifest")"
MCP_MANIFEST="$(cat "$MANIFEST_DIR/mcp.manifest")"
manifest_rows() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' <<< "$1"; }

OUT="$(pwd)/skills"
SERVERS_OUT="$(pwd)/agent/mcp-servers.json"

# --- skills: install the manifest's team rows into a throwaway HOME ---------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.agents/skills"

# The loop feeds on fd 9, NOT stdin: npx (and other children) read stdin and
# would silently eat the remaining manifest rows — first observed as
# "vendored 1 skills" when this loop used stdin.
while read -u 9 -r layer method args; do
  [ "$layer" = "team" ] || continue
  case "$method" in
    npx)
      # word-splitting of $args is intentional (repo + optional -s flags)
      # shellcheck disable=SC2086
      npx -y skills add -g -y $args
      ;;
    curl)
      # args = "<name> <url>" — no GitHub repo, fetch the skill file directly
      name="${args%% *}"; url="${args#* }"
      mkdir -p "$HOME/.agents/skills/$name"
      curl -fsSL "$url" -o "$HOME/.agents/skills/$name/SKILL.md"
      ;;
    *) echo "vendor-skills: unknown method '$method' ($args)" >&2; exit 1 ;;
  esac
done 9< <(manifest_rows "$SKILLS_MANIFEST")

# Replace the vendored snapshot with the freshly resolved trees.
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$HOME/.agents/skills/." "$OUT/"

# --- mcp: generate agent/mcp-servers.json from the team rows' vm-urls -------
# Rows whose vm-url is `-` are SKIPPED: the manifest defines `-` as "not
# registered on VMs". Without this filter the row was emitted verbatim as
# {"url": "-"}, which is worse than omitting it — setup-mcp.sh would register a
# server pointing at a literal dash. Hit 2026-07-28 when github-work moved to
# `-` after `github-mcp-work` was detached from auto:all.
manifest_rows "$MCP_MANIFEST" \
  | awk -F'|' '$2 ~ /team/ {gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$3); if ($3 != "-" && $3 != "") print $1"\t"$3}' \
  | jq -Rn 'reduce (inputs | split("\t")) as $r ({}; . + {($r[0]): {type: "http", url: $r[1]}})' \
  > "$SERVERS_OUT"

# --- agents: splice the shared AGENTS.md block (provisioning/agents-shared.md) ---
# The block between the shared markers in agent/AGENTS.md is replaced with the
# pinned file verbatim; team-specific sections outside the markers are kept.
# ENVIRON (not awk -v) so backslashes in the content can't be mangled.
AGENTS_SHARED="$(cat "$MANIFEST_DIR/agents-shared.md")" \
awk '
  /^<!-- >>> shared/ {print; print ENVIRON["AGENTS_SHARED"]; skip=1; next}
  /^<!-- <<< shared/ {skip=0}
  !skip
' agent/AGENTS.md > agent/AGENTS.md.tmp && mv agent/AGENTS.md.tmp agent/AGENTS.md

echo "vendored $(find "$OUT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') skills + $(jq 'length' "$SERVERS_OUT") MCP servers + shared AGENTS block from $MANIFEST_DIR — commit the result"
