# Sync Claude Plugin Version Action

A GitHub Action that writes a given version into a [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) plugin's `.claude-plugin/plugin.json` and the matching `.claude-plugin/marketplace.json` entry, then commits and pushes the change.

The action does **not** compute or bump the version — it **receives** one (`X.Y.Z`) and keeps the two files in lockstep. Tagging and releasing are a separate concern; pair this action with [`action-tag-release-build`](https://github.com/heronlabs/action-tag-release-build) when you also need a tag and a GitHub release.

## How Claude plugins are distributed

Claude Code plugins are **not** submitted to a central registry. A plugin is distributed from a public git repo that contains a `.claude-plugin/marketplace.json`. End users add the marketplace and install:

```text
/plugin marketplace add <owner>/<repo>
/plugin install <plugin-name>@<marketplace-name>
```

For Claude to resolve a consistent version, the `version` in `marketplace.json` must match the one in `plugin.json`. This action keeps them in sync.

## Requirements

### Permissions

```yaml
permissions:
  contents: write
```

The action pushes the sync commit, so the job needs write access to repository contents. Check out with `fetch-depth: 0` so the rebase before push works.

### Repository layout

```text
<plugin-dir>/
└── .claude-plugin/
    ├── plugin.json        # { "name": "...", "version": "X.Y.Z", ... }
    └── marketplace.json   # { "plugins": [ { "name": "...", "version": "X.Y.Z", "source": "./" } ] }
```

`plugin.json` must have a `.name`, and `marketplace.json` must contain an entry whose `.name` matches it. The action fails loudly otherwise.

### Dependencies

- `jq` (pre-installed on GitHub-hosted runners)

### Supported runners

- `ubuntu-24.04` (recommended), `ubuntu-22.04`, `ubuntu-latest`

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `version` | Version to write into both files (`X.Y.Z`) | Yes | — |
| `plugin-dir` | Directory containing `.claude-plugin/` (set for monorepo sub-dirs) | No | `.` |

## Outputs

| Name | Description |
|------|-------------|
| `version` | The synced plugin version (echoes back the input) |

## Usage with `action-tag-release-build`

Pair this action with [`action-tag-release-build`](https://github.com/heronlabs/action-tag-release-build) (ATRB) to bump `package.json`, tag, and release in the same run. ATRB derives its tag from bumping `package.json` by `spec`, so the `version` you give **this** action must equal what that bump produces.

Keep them in lockstep by deriving the next version **once** (read-only — no file is written), feeding it to this action, then letting ATRB do the single real bump. Run this action **first** so ATRB's tag commit is a child of the sync commit, and the tag captures the synced plugin files.

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
          token: ${{ secrets.PAT }}   # PAT so the pushed tag triggers downstream workflows

      - uses: actions/setup-node@v6
        with:
          node-version-file: '.node-version'

      # Compute the NEXT version from package.json + spec — READ ONLY, writes no file.
      - id: next
        run: |
          CURRENT=$(node -p "require('./package.json').version")
          NEXT=$(npx --yes semver -i "${{ inputs.spec }}" "$CURRENT")
          echo "version=$NEXT" >> "$GITHUB_OUTPUT"

      # 1. Sync plugin.json + marketplace.json to NEXT, commit + push.
      - uses: heronlabs/action-claude-plugin-build@v1
        with:
          version: ${{ steps.next.outputs.version }}

      # 2. Bump package.json by the SAME spec, tag, release. The tag's commit is a
      #    child of step 1's sync commit, so the tag captures the plugin sync.
      - uses: heronlabs/action-tag-release-build@v3
        with:
          github-token: ${{ secrets.PAT }}
          spec: ${{ inputs.spec }}
```

**Why the versions can't drift:** the `next` step only *reads* `package.json`; ATRB performs the one real `npm version <spec>` bump. Same `spec` → identical number → the plugin JSONs and `package.json` always agree.

> Pass a PAT to `actions/checkout` (and to ATRB) when a downstream pipeline must react to the pushed commit or tag — a push made with the default `GITHUB_TOKEN` does not trigger other workflows.

### Standalone (version from a workflow input)

Without ATRB, supply the version directly. This action validates `X.Y.Z`, syncs both files, and commits:

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: The plugin version to release (X.Y.Z).
        required: true

# ...
      - uses: heronlabs/action-claude-plugin-build@v1
        with:
          version: ${{ inputs.version }}
```

### Monorepo sub-directory

```yaml
- uses: heronlabs/action-claude-plugin-build@v1
  with:
    version: ${{ inputs.version }}
    plugin-dir: plugins/my-plugin
```

## What a run does

1. **Config git** as `github-actions[bot]`.
2. **Validate** — `version` matches `X.Y.Z`; both `.claude-plugin/*.json` parse; `plugin.json` has a `.name`; `marketplace.json` has an entry of that name.
3. **Write** the version into `plugin.json` and the matching `marketplace.json` entry (selected by name, not index).
4. **Commit & push** — `[skip ci] sync plugin vX.Y.Z`, rebased onto the current branch. If both files are already at the version, the commit is skipped.

## Notes

- **Match by name, not index.** The `marketplace.json` entry is selected by `.name`, so a marketplace listing several plugins is synced correctly.
- **Idempotent.** Re-running with the same version is a no-op — nothing to commit.
- **`[skip ci]`.** The sync commit is prefixed `[skip ci]` so it does not re-trigger CI.

## License

MIT
