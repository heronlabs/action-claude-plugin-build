# Claude Plugin Sync Action

[![CI](https://github.com/heronlabs/action-claude-plugin-build/actions/workflows/continuous-integration.yml/badge.svg)](https://github.com/heronlabs/action-claude-plugin-build/actions/workflows/continuous-integration.yml)

> Write a version into a Claude Code plugin's `plugin.json` and matching `marketplace.json` entry, then commit and push.

Claude Code plugins ship from a git repo's `.claude-plugin/marketplace.json` rather than a central registry, and the `version` there must match the plugin's `plugin.json`. This action receives a version (`X.Y.Z`) — it does not compute one — and keeps both files in lockstep. Version bumps, tags, and releases are handled by [`googleapis/release-please-action`](https://github.com/googleapis/release-please-action) in the CD workflow.

## Usage

This action syncs a version into the plugin files. Versioning and releases are managed by [`googleapis/release-please-action`](https://github.com/googleapis/release-please-action) in the CD workflow — it infers the next version from conventional commits, maintains a release PR, and creates the tag and GitHub Release on merge.

```yaml
name: '[ CD ] | Release Plugin'

on:
  push:
    branches: [main]

permissions:
  contents: write
  pull-requests: write

jobs:
  release-please:
    runs-on: ubuntu-24.04
    outputs:
      release_created: ${{ steps.release.outputs.release_created }}
    steps:
      - uses: googleapis/release-please-action@v5
        id: release
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          release-type: simple
```

### Standalone (version from input)

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: The plugin version to release (X.Y.Z).
        required: true

jobs:
  sync:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - uses: heronlabs/action-claude-plugin-build@v2
        with:
          version: ${{ inputs.version }}
```

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `version` | Version to write into both files (`X.Y.Z`). | Yes | — |
| `plugin-dir` | Directory containing `.claude-plugin/` (set for monorepo sub-directories). | No | `.` |

## Outputs

| Name | Description |
|------|-------------|
| `version` | The synced plugin version. |

## Permissions

```yaml
permissions:
  contents: write
```

## How it works

1. Configure git as `github-actions[bot]`.
2. Validate that `version` is `X.Y.Z`, both `.claude-plugin/*.json` parse, `plugin.json` has a `.name`, and `marketplace.json` has an entry of that name.
3. Write the version into `plugin.json` and the matching `marketplace.json` entry.
4. Commit `[skip ci] sync plugin vX.Y.Z`, rebase onto the branch, and push — skipped if both files are already at the version.

## Notes

- Check out with `fetch-depth: 0` so the rebase before push works.
- The `marketplace.json` entry is matched by `plugin.name`, not index — correct for marketplaces listing several plugins.
- Re-running with the same version is a no-op; nothing is committed.
- The sync commit is prefixed `[skip ci]` so it does not re-trigger CI.
- Pass a PAT to `actions/checkout` (and to ATRB) when a downstream pipeline must react to the pushed commit or tag — pushes made with the default `GITHUB_TOKEN` do not trigger other workflows.

## License

MIT
