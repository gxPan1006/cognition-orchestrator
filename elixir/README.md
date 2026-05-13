# Cognition Elixir

This directory contains the Elixir/OTP implementation of Cognition, a Symphony-compatible coding
agent orchestrator with pluggable coding-tool adapters.

## How It Works

1. Polls Linear for candidate work.
2. Creates a workspace per issue.
3. Launches the configured coding tool inside the workspace.
4. Sends the rendered `WORKFLOW.md` prompt.
5. Keeps the tool working on the issue until the issue leaves an active state.

The visible workflow is intentionally the same as Symphony: Linear cards, one persistent workpad
comment, isolated workspaces, retry/backoff, and the optional Phoenix observability dashboard.

## Run

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/cognition ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Optional flags:

- `--logs-root` writes logs under a different directory, defaulting to `./log`.
- `--port` starts the Phoenix observability service.
- `--language` declares the language used for all Linear-facing output the agent
  produces (workpad comment, status notes, blocker briefs). Example:
  `--language 中文` or `--language Japanese`. Code, commit messages, PR titles,
  branch names, and shell output stay in their natural English form. When the
  flag is omitted no language preamble is added and the agent uses its default
  voice. The value is also exposed to `WORKFLOW.md` as `{{ language }}`.

## Workflow Configuration

Codex remains the default and the old `codex:` block is still accepted:

```yaml
coding_tool:
  kind: codex
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
```

Claude Code can be selected with:

```yaml
coding_tool:
  kind: claude
claude:
  command: claude --print --verbose --output-format stream-json --permission-mode bypassPermissions
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
```

All other workflow sections keep Symphony's shape: `tracker`, `polling`, `workspace`, `worker`,
`agent`, `hooks`, `observability`, and `server`.

## Project Layout

- `lib/`: application code and adapters.
- `test/`: ExUnit coverage for runtime behavior.
- `WORKFLOW.md`: in-repo workflow contract used by local runs.
- `../.codex/`: repository-local skills and setup helpers.

## Testing

```bash
make all
```

Run the live external end-to-end test only when you want Cognition to create disposable Linear
resources and launch a real coding-tool session:

```bash
export LINEAR_API_KEY=...
make e2e
```

The local suite includes adapter tests for Codex app-server compatibility and Claude CLI execution.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
