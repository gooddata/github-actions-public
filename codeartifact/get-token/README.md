# Code artifact get auth token

This action authenticates with aws code artifact and get the token.
Then the token will be injected into environment variable `CODEARTIFACT_AUTH_TOKEN`.

Note: This action only works on `infra1-runners-arc`.

## Inputs

*None*

## Outputs

*None*

## Example usage

```
name: Run gradle check

on:
  pull_request:

jobs:
  check:
    runs-on:
      group: infra1-runners-arc
      labels: runners-small
    steps:
      - uses: actions/checkout@v3

      - uses: gooddata/github-actions/codeartifact/get-token@master

      - name: Setup Gradle
        uses: gradle/actions/setup-gradle@v3

      - name: Check
        run: ./gradlew -I src/init.d/init.gradle.kts check --scan
```