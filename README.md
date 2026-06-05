# bump-version

Rewrites a single pinned version string in a file. YAML files are edited by `yq` path expression; all other files match the version-bearing line by a leading key token. The consumer resolves the desired version and passes it in.

## Usage

```yaml
name: Update

on:
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  update:
    name: Update
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      # Resolve the latest version at the call site.
      - name: Get Latest golangci-lint Version
        id: latest
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          version="$(gh release view --repo golangci/golangci-lint --json tagName --jq .tagName)"
          echo "version=${version}" >> "${GITHUB_OUTPUT}"

      - name: Bump golangci-lint in the Makefile
        uses: craigsloggett/bump-version@v1
        with:
          file: Makefile
          key: GOLANGCI_LINT_VERSION
          version: ${{ steps.latest.outputs.version }}
```

For YAML files, `key` is a `yq` path expression and the value is set exactly. For any other file, `key` names a space-separated assignment and the assignment's value is replaced with `version` while surrounding alignment is preserved.

The action edits the file in place and fails if the key matches nothing.

## Inputs

| Input          | Required | Default            | Description                                                                                 |
| -------------- | -------- | ------------------ | ------------------------------------------------------------------------------------------- |
| `file`         | Yes      |                    | Path to the file to edit.                                                                   |
| `key`          | Yes      |                    | A `yq` path expression for YAML files, or the token that begins the version line otherwise. |
| `version`      | Yes      |                    | The new version string to write.                                                            |
| `summary-file` | No       | `changed-files.md` | Filename of the job-scoped changed-files list written under `RUNNER_TEMP`.                  |

## Outputs

| Output    | Description                                                             |
| --------- | ----------------------------------------------------------------------- |
| `changed` | Whether the file was modified. `false` if it already held the version.  |
| `file`    | The path to the file that was edited (passthrough of the `file` input). |

On a change, the action also appends `` - `<file>` `` to `${RUNNER_TEMP}/changed-files.md` (the filename is configurable via `summary-file`). `RUNNER_TEMP` is shared across a job, so several bumps accumulate one Markdown list that a later step can `cat` into `${GITHUB_STEP_SUMMARY}`.
