#!/usr/bin/env bash
# Offline test harness for core/sync-plugin-version.sh.
#
# Builds throwaway git repos (a bare "origin" + a working clone), seeds
# .claude-plugin/{plugin,marketplace}.json fixtures, runs the action script from
# inside the clone, and asserts on the written files / pushed refs / stdout.
# The script does real git add/commit/pull --rebase/push against the local bare
# origin. No network, no real GitHub. jq and git are real.
#
# shellcheck disable=SC2015  # `cond && ok || bad` is intentional; ok() always returns 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../core/sync-plugin-version.sh"

pass=0
fail=0
note() { printf '  %s\n' "$*"; }
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && note "$2"; }

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Build a bare origin + working clone seeded with the given plugin/marketplace
# JSON, on the given branch. The JSON is normalised through jq so the committed
# files match what the action writes (a repo it has previously synced); this is
# what lets the no-op test produce a genuinely empty diff. Pushes with -u so the
# action's bare `git push` resolves an upstream, mirroring actions/checkout.
# Usage: build_repo <branch> <plugin_json> <marketplace_json>  -> echoes temp root.
build_repo() {
  local branch="$1" plugin_json="$2" marketplace_json="$3"
  local root origin work
  root="$(mktemp -d)"
  origin="$root/origin.git"
  work="$root/work"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null
  git -C "$work" config user.name  tester
  git -C "$work" config user.email tester@example.com
  git -C "$work" checkout -q -b "$branch"
  mkdir -p "$work/.claude-plugin"
  printf '%s' "$plugin_json"      | jq . >"$work/.claude-plugin/plugin.json"
  printf '%s' "$marketplace_json" | jq . >"$work/.claude-plugin/marketplace.json"
  git_q "$work" add -A
  git_q "$work" commit -m init
  git_q "$work" push -u origin "$branch"
  printf '%s' "$root"
}

# Run the action script inside a working clone with a captured GITHUB_OUTPUT.
# Usage: run_action <work> <version> <ref>
# Exports RUN_OUT (stdout+stderr), RUN_RC (exit code), RUN_GHOUT (output file).
run_action() {
  local work="$1" version="$2" ref="$3"
  RUN_GHOUT="$(mktemp)"
  : >"$RUN_GHOUT"
  RUN_OUT="$(
    cd "$work" &&
    env PATH="$PATH" \
        GITHUB_OUTPUT="$RUN_GHOUT" \
        VERSION="$version" \
        REF_NAME="$ref" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
}

origin_subject() { # <origin> <branch> -> tip commit subject on origin/branch
  local origin="$1" br="$2" tmp; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  git -C "$tmp" log -1 --format='%s' "origin/$br" 2>/dev/null
  rm -rf "$tmp"
}

origin_commit_count() { # <origin> <branch> -> number of commits on origin/branch
  local origin="$1" br="$2" tmp count; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  count="$(git -C "$tmp" rev-list --count "origin/$br" 2>/dev/null)"
  rm -rf "$tmp"
  printf '%s' "${count:-0}"
}

# ---------------------------------------------------------------- tests

test_valid_bump() {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"},{"name":"bar","version":"9.9.9"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.2.3 main

  [ "$RUN_RC" -eq 0 ] && ok "valid bump: exit 0" || bad "valid bump: exit 0" "rc=$RUN_RC out=$RUN_OUT"
  [ "$(jq -r .version "$work/.claude-plugin/plugin.json")" = "1.2.3" ] && ok "valid bump: plugin.json version updated" || bad "valid bump: plugin.json version updated"
  [ "$(jq -r '.plugins[] | select(.name=="foo") | .version' "$work/.claude-plugin/marketplace.json")" = "1.2.3" ] && ok "valid bump: marketplace foo entry updated" || bad "valid bump: marketplace foo entry updated"
  [ "$(jq -r '.plugins[] | select(.name=="bar") | .version' "$work/.claude-plugin/marketplace.json")" = "9.9.9" ] && ok "valid bump: marketplace bar entry untouched" || bad "valid bump: marketplace bar entry untouched"
  [ "$(origin_subject "$origin" main)" = "[skip ci] sync plugin v1.2.3" ] && ok "valid bump: sync commit pushed to origin" || bad "valid bump: sync commit pushed to origin" "$(origin_subject "$origin" main)"
  [ "$(origin_commit_count "$origin" main)" -eq 2 ] && ok "valid bump: origin branch advanced" || bad "valid bump: origin branch advanced" "count=$(origin_commit_count "$origin" main)"
  grep -qF 'version=1.2.3' "$RUN_GHOUT" && ok "valid bump: GITHUB_OUTPUT has version" || bad "valid bump: GITHUB_OUTPUT has version" "$(cat "$RUN_GHOUT")"
  grep -qF 'Synced foo: 1.0.0 -> 1.2.3' <<<"$RUN_OUT" && ok "valid bump: stdout reports the sync" || bad "valid bump: stdout reports the sync" "$RUN_OUT"

  rm -rf "$root"
}

test_invalid_version_rejected() {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.2 main
  [ "$RUN_RC" -eq 1 ] && ok "invalid version 1.2: exit 1" || bad "invalid version 1.2: exit 1" "rc=$RUN_RC out=$RUN_OUT"
  grep -qF 'is not X.Y.Z' <<<"$RUN_OUT" && ok "invalid version 1.2: reports format error" || bad "invalid version 1.2: reports format error" "$RUN_OUT"

  run_action "$work" v1.2.3 main
  [ "$RUN_RC" -eq 1 ] && ok "invalid version v1.2.3: exit 1" || bad "invalid version v1.2.3: exit 1" "rc=$RUN_RC out=$RUN_OUT"
  grep -qF 'is not X.Y.Z' <<<"$RUN_OUT" && ok "invalid version v1.2.3: reports format error" || bad "invalid version v1.2.3: reports format error" "$RUN_OUT"

  [ "$(origin_commit_count "$origin" main)" -eq 1 ] && ok "invalid version: origin NOT advanced" || bad "invalid version: origin NOT advanced" "count=$(origin_commit_count "$origin" main)"

  rm -rf "$root"
}

test_missing_plugin_json() {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"}]}')"
  work="$root/work"; origin="$root/origin.git"
  rm -f "$work/.claude-plugin/plugin.json"

  run_action "$work" 1.2.3 main
  [ "$RUN_RC" -eq 1 ] && ok "missing plugin.json: exit 1" || bad "missing plugin.json: exit 1" "rc=$RUN_RC out=$RUN_OUT"
  grep -qF 'not found' <<<"$RUN_OUT" && ok "missing plugin.json: reports not found" || bad "missing plugin.json: reports not found" "$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ] && ok "missing plugin.json: origin NOT advanced" || bad "missing plugin.json: origin NOT advanced"

  rm -rf "$root"
}

test_invalid_json() {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"}]}')"
  work="$root/work"; origin="$root/origin.git"
  printf '{ not json\n' >"$work/.claude-plugin/plugin.json"

  run_action "$work" 1.2.3 main
  [ "$RUN_RC" -eq 1 ] && ok "invalid JSON: exit 1" || bad "invalid JSON: exit 1" "rc=$RUN_RC out=$RUN_OUT"
  grep -qF 'not valid JSON' <<<"$RUN_OUT" && ok "invalid JSON: reports not valid JSON" || bad "invalid JSON: reports not valid JSON" "$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ] && ok "invalid JSON: origin NOT advanced" || bad "invalid JSON: origin NOT advanced"

  rm -rf "$root"
}

test_no_marketplace_entry() {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"bar","version":"9.9.9"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.2.3 main
  [ "$RUN_RC" -eq 1 ] && ok "no marketplace entry: exit 1" || bad "no marketplace entry: exit 1" "rc=$RUN_RC out=$RUN_OUT"
  grep -qF 'no marketplace.json entry' <<<"$RUN_OUT" && ok "no marketplace entry: reports missing entry" || bad "no marketplace entry: reports missing entry" "$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ] && ok "no marketplace entry: origin NOT advanced" || bad "no marketplace entry: origin NOT advanced"

  rm -rf "$root"
}

test_noop_same_version() {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"},{"name":"bar","version":"9.9.9"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.0.0 main
  [ "$RUN_RC" -eq 0 ] && ok "no-op: exit 0" || bad "no-op: exit 0" "rc=$RUN_RC out=$RUN_OUT"
  grep -qF 'No version change' <<<"$RUN_OUT" && ok "no-op: reports nothing to commit" || bad "no-op: reports nothing to commit" "$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ] && ok "no-op: origin NOT advanced" || bad "no-op: origin NOT advanced" "count=$(origin_commit_count "$origin" main)"

  rm -rf "$root"
}

# ---------------------------------------------------------------- run

test_valid_bump
test_invalid_version_rejected
test_missing_plugin_json
test_invalid_json
test_no_marketplace_entry
test_noop_same_version

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
