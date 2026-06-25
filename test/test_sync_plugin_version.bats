#!/usr/bin/env bats
# bats tests for core/sync-plugin-version.sh
#
# Builds throwaway git repos (a bare "origin" + a working clone), seeds
# .claude-plugin/{plugin,marketplace}.json fixtures, runs the action script from
# inside the clone, and asserts on the written files / pushed refs / stdout.
# Uses real git and jq. No network, no real GitHub.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/sync-plugin-version.sh"
}

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Build a bare origin + working clone seeded with the given plugin/marketplace
# JSON, on the given branch.
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
# shellcheck disable=SC2034  # RUN_OUT is used by callers in assertions
run_action() {
  local work="$1" version="$2" ref="$3"
  RUN_GHOUT="$(mktemp)"
  : >"$RUN_GHOUT"
  set +e
  RUN_OUT="$(
    cd "$work" &&
    env PATH="$PATH" \
        GITHUB_OUTPUT="$RUN_GHOUT" \
        VERSION="$version" \
        REF_NAME="$ref" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
  set -e
}

origin_subject() {
  local origin="$1" br="$2" tmp; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  git -C "$tmp" log -1 --format='%s' "origin/$br" 2>/dev/null
  rm -rf "$tmp"
}

origin_commit_count() {
  local origin="$1" br="$2" tmp count; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  count="$(git -C "$tmp" rev-list --count "origin/$br" 2>/dev/null)"
  rm -rf "$tmp"
  printf '%s' "${count:-0}"
}

# ---------------------------------------------------------------- tests

@test "valid bump: updates both JSON files, commits, pushes, sets output" {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"},{"name":"bar","version":"9.9.9"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.2.3 main

  [ "$RUN_RC" -eq 0 ]
  [ "$(jq -r .version "$work/.claude-plugin/plugin.json")" = "1.2.3" ]
  [ "$(jq -r '.plugins[] | select(.name=="foo") | .version' "$work/.claude-plugin/marketplace.json")" = "1.2.3" ]
  [ "$(jq -r '.plugins[] | select(.name=="bar") | .version' "$work/.claude-plugin/marketplace.json")" = "9.9.9" ]
  [ "$(origin_subject "$origin" main)" = "[skip ci] sync plugin v1.2.3" ]
  [ "$(origin_commit_count "$origin" main)" -eq 2 ]
  grep -qF 'version=1.2.3' "$RUN_GHOUT"
  grep -qF 'Synced foo: 1.0.0 -> 1.2.3' <<<"$RUN_OUT"

  rm -rf "$root"
}

@test "invalid version 1.2: exit 1, reports format error" {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.2 main
  [ "$RUN_RC" -eq 1 ]
  grep -qF 'is not X.Y.Z' <<<"$RUN_OUT"

  run_action "$work" v1.2.3 main
  [ "$RUN_RC" -eq 1 ]
  grep -qF 'is not X.Y.Z' <<<"$RUN_OUT"

  [ "$(origin_commit_count "$origin" main)" -eq 1 ]

  rm -rf "$root"
}

@test "missing plugin.json: exit 1, reports not found" {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"}]}')"
  work="$root/work"; origin="$root/origin.git"
  rm -f "$work/.claude-plugin/plugin.json"

  run_action "$work" 1.2.3 main
  [ "$RUN_RC" -eq 1 ]
  grep -qF 'not found' <<<"$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ]

  rm -rf "$root"
}

@test "invalid JSON: exit 1, reports not valid JSON" {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"}]}')"
  work="$root/work"; origin="$root/origin.git"
  printf '{ not json\n' >"$work/.claude-plugin/plugin.json"

  run_action "$work" 1.2.3 main
  [ "$RUN_RC" -eq 1 ]
  grep -qF 'not valid JSON' <<<"$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ]

  rm -rf "$root"
}

@test "no marketplace entry: exit 1, reports missing entry" {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"bar","version":"9.9.9"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.2.3 main
  [ "$RUN_RC" -eq 1 ]
  grep -qF 'no marketplace.json entry' <<<"$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ]

  rm -rf "$root"
}

@test "no-op same version: exit 0, nothing committed" {
  local root work origin
  root="$(build_repo main \
    '{"name":"foo","version":"1.0.0"}' \
    '{"plugins":[{"name":"foo","version":"1.0.0"},{"name":"bar","version":"9.9.9"}]}')"
  work="$root/work"; origin="$root/origin.git"

  run_action "$work" 1.0.0 main
  [ "$RUN_RC" -eq 0 ]
  grep -qF 'No version change' <<<"$RUN_OUT"
  [ "$(origin_commit_count "$origin" main)" -eq 1 ]

  rm -rf "$root"
}
