#!/usr/bin/env bash
# Sync a Claude Code plugin's version: write VERSION into plugin.json and the
# matching marketplace.json entry, then commit + push.
#
# The plugin's version of record is .claude-plugin/plugin.json. It must be
# mirrored in .claude-plugin/marketplace.json (the entry whose .name matches the
# plugin) so that `/plugin install` resolves a consistent version. This action
# does NOT compute the version — it RECEIVES one (e.g. from the workflow input
# that also drives action-tag-release-build) and applies it to both files in
# lockstep. Tagging and release are a separate, later step.
#
# Env (provided by action.yml):
#   VERSION   X.Y.Z to write           (required)
#   REF_NAME  branch to rebase/push    (required)
set -euo pipefail

: "${VERSION:?VERSION is required (X.Y.Z)}"
: "${REF_NAME:?REF_NAME is required}"

PJ=".claude-plugin/plugin.json"
MJ=".claude-plugin/marketplace.json"

# --- Validate version -----------------------------------------------------
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "FAIL: version '$VERSION' is not X.Y.Z"
  exit 1
fi

# --- Validate files -------------------------------------------------------
[ -f "$PJ" ] || { echo "FAIL: $PJ not found"; exit 1; }
[ -f "$MJ" ] || { echo "FAIL: $MJ not found"; exit 1; }
jq empty "$PJ" 2>/dev/null || { echo "FAIL: $PJ is not valid JSON"; exit 1; }
jq empty "$MJ" 2>/dev/null || { echo "FAIL: $MJ is not valid JSON"; exit 1; }

NAME=$(jq -r '.name // empty' "$PJ")
[ -n "$NAME" ] || { echo "FAIL: $PJ has no .name"; exit 1; }

# The marketplace must carry an entry for THIS plugin (matched by name, not
# index — survives a marketplace that lists more than one plugin).
HAS_ENTRY=$(jq -r --arg n "$NAME" 'any(.plugins[]?; .name == $n)' "$MJ")
[ "$HAS_ENTRY" = "true" ] || { echo "FAIL: no marketplace.json entry named '$NAME'"; exit 1; }

# --- Write both files (jq to a temp, then move — never truncate on a failed jq).
CURRENT=$(jq -r '.version // empty' "$PJ")

tmp=$(mktemp)
jq --arg v "$VERSION" '.version = $v' "$PJ" > "$tmp" && mv "$tmp" "$PJ"
tmp=$(mktemp)
jq --arg n "$NAME" --arg v "$VERSION" \
  '(.plugins[] | select(.name == $n) | .version) = $v' "$MJ" > "$tmp" && mv "$tmp" "$MJ"

echo "Synced $NAME: ${CURRENT:-?} -> $VERSION"

# --- Commit + push --------------------------------------------------------
git add "$PJ" "$MJ"
if git diff --cached --quiet; then
  echo "No version change — already at $VERSION, nothing to commit"
else
  git commit -m "[skip ci] sync plugin v${VERSION}"
  git pull --rebase origin "$REF_NAME"
  git push
  echo "✅ Synced and pushed: $NAME@$VERSION"
fi

echo "version=$VERSION" >> "$GITHUB_OUTPUT"
