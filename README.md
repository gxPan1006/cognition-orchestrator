# Cognition

Cognition is a Symphony-compatible orchestration service for coding agents. It keeps Symphony's
operator-facing workflow intact: poll Linear, create one isolated workspace per issue, send the
repo-owned `WORKFLOW.md` prompt to an autonomous coding tool, and expose runtime observability.

The first Cognition difference is the coding-tool layer. Symphony's reference implementation was
Codex-first; Cognition supports:

- `codex`: the existing Codex app-server protocol, kept as the default and backward-compatible path.
- `claude`: a Claude Code non-interactive CLI adapter.

The adapter boundary is intentionally small so more coding tools can be added later without
changing the Linear/workspace/workpad flow.

## Running Cognition

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/cognition ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

See [elixir/README.md](elixir/README.md) for configuration, testing, and adapter examples.

## Relationship To Symphony

Cognition was bootstrapped from the Symphony Elixir reference implementation and preserves the
same external lifecycle semantics. The goal is compatibility first, then broader tool support.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
