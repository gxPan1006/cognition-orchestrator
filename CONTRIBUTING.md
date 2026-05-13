# Contributing to Cognition Orchestrator

Thanks for your interest. This project is small but real — please follow the workflow below so your change can land cleanly.

## Ground rules

- **Apache 2.0 only.** All contributions are accepted under the [Apache 2.0 license](LICENSE). By opening a PR you confirm you have the right to submit your changes under this license.
- **No proprietary credentials in commits.** API keys, tokens, and personal paths must come from environment variables or local-only config. The `.gitignore` already covers `.env*`, `.secrets`, `.credentials`.
- **Be respectful.** Code reviews are about the code, not the person.

## Before you start

For non-trivial changes (new adapter, tracker, dashboard view, anything > ~100 lines), open an issue first to discuss scope and design. Drive-by typo fixes / one-line bug fixes can skip this.

## Development setup

```bash
git clone https://github.com/<your-fork>/cognition-orchestrator.git
cd cognition-orchestrator/elixir
mise trust
mise install
mise exec -- mix setup
```

Run the full CI gate locally before pushing:

```bash
make -C elixir all
```

This runs, in order:

| Step | What it checks |
|---|---|
| `mix build` | escript builds |
| `mix format --check-formatted` | code is `mix format`-clean |
| `mix lint` | `specs.check` (every public function has `@spec`) + `credo --strict` (no refactoring/design findings) |
| `mix test --cover` | 269+ tests pass and coverage threshold is met (operational/IO modules are listed in `ignore_modules`) |
| `mix dialyzer` | type analysis with 0 errors |

All five must pass for your PR to be mergeable.

## PR conventions

Use the [PR template](.github/pull_request_template.md). Specifically:

- **Title**: imperative mood, ≤ 70 chars. Example: `Add Aider coding-tool adapter`.
- **TL;DR**: 1 sentence, ≤ 120 chars. The reader should understand the change from the title + TL;DR alone.
- **Test Plan**: at minimum `make -C elixir all`; add any additional checks the change warrants (manual repro for UI changes, etc.).

## Adding a new coding-tool adapter

The adapter contract lives in `Cognition.CodingTool.Adapter`. To add a tool:

1. Implement the adapter module under `lib/cognition/coding_tool/<your_tool>.ex`.
2. Register it in `Cognition.CodingTool` (the dispatcher).
3. Add a `Cognition.Config.Schema.<YourTool>` schema if the tool needs config keys.
4. Write tests under `test/cognition/<your_tool>_adapter_test.exs` that drive the adapter against fixtures (no live API calls).
5. Document the `coding_tool.kind` value and any new config keys in `elixir/README.md`.

Aim for the same shape as `claude_cli.ex` — the bar is "operator can swap tools by changing one config block".

## Reporting bugs

Open an issue with:

- Cognition version (`git rev-parse HEAD`).
- Elixir + Erlang versions (`elixir --version`).
- A minimal `WORKFLOW.md` that reproduces.
- The relevant log snippet (`./log/...`) — redact secrets.

## Reporting security issues

**Don't open a public issue.** See [SECURITY.md](SECURITY.md).

## Where decisions live

- Normative spec: [`SPEC.md`](SPEC.md).
- Operational notes: [`elixir/AGENTS.md`](elixir/AGENTS.md).
- Logging conventions: [`elixir/docs/logging.md`](elixir/docs/logging.md).
- Token accounting: [`elixir/docs/token_accounting.md`](elixir/docs/token_accounting.md).
