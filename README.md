# Claude Plugin Sync Action

[![CI](https://github.com/heronlabs/action-claude-plugin-build/actions/workflows/ci.yml/badge.svg)](https://github.com/heronlabs/action-claude-plugin-build/actions/workflows/ci.yml)

> Write a version into a Claude Code plugin's `plugin.json` and matching `marketplace.json` entry, then commit and push.

Claude Code plugins ship from a git repo's `.claude-plugin/marketplace.json` rather than a central registry, and the `version` there must match the plugin's `plugin.json`. This action receives a version (`X.Y.Z`) — it does not compute one — and keeps both files in lockstep. Pair it with [`action-tag-release-build`](https://github.com/heronlabs/action-tag-release-build) when you also need a version bump, tag, and release.

## Usage

Pair with [`action-tag-release-build`](https://github.com/heronlabs/action-tag-release-build) (ATRB) so the plugin JSONs and `package.json` always agree: derive the next version once (read-only), sync the plugin files to it, then let ATRB perform the single real bump, tag, and release. Run this action first so ATRB's tag commit is a child of the sync commit.

```yaml
name: '[ CD ] | Publish Plugin'

on:
  workflow_dispatch:
    inputs:
      spec:
        description: The SEMVER specification.
        required: true
        type: choice
        default: patch
        options:
          - major
          - minor
          - patch

permissions:
  contents: write

jobs:
  publish:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
          token: ${{ secrets.PAT }}

      - uses: actions/setup-node@v6
        with:
          node-version-file: '.node-version'

      - id: next
        run: |
          CURRENT=$(node -p "require('./package.json').version")
          NEXT=$(npx --yes semver -i "${{ inputs.spec }}" "$CURRENT")
          echo "version=$NEXT" >> "$GITHUB_OUTPUT"

      - uses: heronlabs/action-claude-plugin-build@v2
        with:
          version: ${{ steps.next.outputs.version }}

      - uses: heronlabs/action-tag-release-build@v4
        with:
          github-token: ${{ secrets.PAT }}
          spec: ${{ inputs.spec }}
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
