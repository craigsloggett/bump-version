# composite-action-template

A GitHub repository template for creating a new Composite Action.

> Composite actions allow you to collect a series of workflow job steps into a single action which you can then run as a single job step in multiple workflows.

## Usage

```yaml
name: Lint

on: pull_request

permissions:
  contents: read

jobs:
  my-job:
    name: My Job
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Use Composite Action
        uses: craigsloggett-lab/my-composite-action@v1
```

### Inputs

| Input            | Required? | Default                    | Description                                        |
| ---------------- | --------- | -------------------------- | -------------------------------------------------- |
| `my-input`       | `false`   | `The default description.` | This is my input, there is no other input like it. |

### Outputs

| Output      | Description                                |
| ----------- | ------------------------------------------ |
| `my-output` | The output this composite action produces. |
