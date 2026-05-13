# Cognition Orchestrator

> Self-hosted orchestration service that turns a Linear backlog into autonomous coding-agent runs — drives Codex CLI and Claude Code in isolated per-issue workspaces, with a Phoenix LiveView dashboard for live observability.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Built with Elixir](https://img.shields.io/badge/Elixir-1.19-purple)](https://elixir-lang.org/)
[![CI](https://github.com/GuoxunPan/cognition-orchestrator/actions/workflows/make-all.yml/badge.svg)](https://github.com/GuoxunPan/cognition-orchestrator/actions/workflows/make-all.yml)

> ⚠️ **Not affiliated with Cognition AI (Devin).** This project is a community fork of OpenAI's [Symphony](#relationship-to-symphony) reference implementation, focused on multi-tool, self-hosted agent orchestration.

---

## What is it?

Cognition Orchestrator is a long-running daemon that:

- **Polls Linear** on a fixed cadence for tickets that match your active-state filter.
- **Provisions an isolated workspace** per issue (git worktree, dedicated runtime dir).
- **Launches an autonomous coding agent** inside that workspace — **Codex CLI** or **Claude Code CLI** — with a per-repo `WORKFLOW.md` prompt that you version-control.
- **Keeps the agent working** on the ticket until the issue leaves an active state.
- **Exposes a Phoenix LiveView dashboard** for live token usage, agent status, and historical session transcripts (both Claude and Codex).
- **Multi-project control plane**: a single Cognition instance can supervise multiple project runtimes via tmux + dashboard.

You write the workflow contract once (in `WORKFLOW.md`); Cognition makes sure agents follow it across runs, retries, and reboots.

## Why this exists

If you've tried to run autonomous coding agents against a real backlog, you've probably hit the same operational problems:

- The agent loses context across restarts.
- One bad turn corrupts the only workspace.
- There's no single source of truth for "what state is each ticket in".
- Switching between Codex and Claude Code means rewriting glue.

Cognition Orchestrator solves these as a **scheduler + workspace manager + observability layer** — not as another agent. Bring your own model; orchestration stays the same.

## Quickstart

```bash
git clone https://github.com/GuoxunPan/cognition-orchestrator.git
cd cognition-orchestrator/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build

# Edit WORKFLOW.md: set tracker.project_slug to your Linear project slug,
# and export LINEAR_API_KEY before running.
export LINEAR_API_KEY="lin_api_..."
mise exec -- ./bin/cognition ./WORKFLOW.md \
  --port 4000 \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Open `http://localhost:4000` for the live dashboard.

CLI flags:

| Flag | Purpose |
|---|---|
| `--port <n>` | Start the Phoenix observability dashboard on port `<n>`. |
| `--logs-root <dir>` | Override the default `./log` directory for run logs. |
| `--language <name>` | Force the workpad/Linear-facing output language (`中文`, `日本語`, etc.). Code, commits, PR titles stay in English. |
| `--control-plane` | Boot in multi-project supervisor mode (manage many Cognition runtimes from one dashboard). |

See [`elixir/README.md`](elixir/README.md) for the full configuration reference and adapter details.

## Supported coding tools

| Tool | Status | Adapter |
|---|---|---|
| **Codex CLI** (`codex app-server`) | Default, fully supported | [`coding_tool/codex_adapter.ex`](elixir/lib/cognition/coding_tool/codex_adapter.ex) |
| **Claude Code CLI** (`claude --print --output-format stream-json`) | Supported | [`coding_tool/claude_cli.ex`](elixir/lib/cognition/coding_tool/claude_cli.ex) |

The adapter boundary is intentionally small — new tools can be slotted in without touching the Linear/workspace/scheduling layer.

## How it works

```
┌──────────────┐    poll     ┌─────────────────┐   spawn   ┌──────────────────┐
│   Linear     │ ◀────────── │   Orchestrator  │ ────────▶ │  Coding tool     │
│   tickets    │   updates   │   (Cognition)   │   prompt  │  in workspace    │
└──────────────┘             └────────┬────────┘           └──────────────────┘
                                      │
                                      ▼ Phoenix LiveView
                              ┌──────────────────┐
                              │   Dashboard      │
                              │ tokens / status  │
                              │ session history  │
                              └──────────────────┘
```

The full normative spec — including state machine, retry semantics, and workspace isolation contract — lives in [`SPEC.md`](SPEC.md).

## Relationship to Symphony

Cognition Orchestrator was bootstrapped from OpenAI's [Symphony](https://github.com/openai/symphony) Elixir reference implementation and preserves the same external lifecycle semantics (workpad comment shape, workspace isolation, retry/backoff, observability hooks).

The first **Cognition-specific** difference is the coding-tool adapter layer — Symphony was Codex-first; Cognition supports Codex and Claude Code under one orchestrator.

## Roadmap (community-driven)

- Additional coding-tool adapters (Aider, OpenHands, Cursor agent, custom CLIs).
- Pluggable trackers beyond Linear (Jira, GitHub Issues, Plane).
- Dashboard hardening: auth, multi-user views, exportable run history.
- Cost/token quota enforcement per project.

Open an issue if you'd like to propose / claim a roadmap item.

## Contributing

Pull requests welcome. Please:

1. Run `make -C elixir all` locally; CI requires it green (test + coverage 100% + dialyzer + credo strict).
2. Follow the [PR template](.github/pull_request_template.md).
3. For new adapters, ship the adapter + tests in the same PR.

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## Security

For security issues, please **do not** open a public GitHub issue. See [SECURITY.md](SECURITY.md) for the disclosure process.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
