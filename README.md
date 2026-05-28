# bump-version

Bumps a version.

## Usage

```yaml
name: Bump Version

on: pull_request

permissions:
  contents: read

jobs:
  bump:
    name: Bump
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Bump Version
        uses: craigsloggett/bump-version@v1
```
