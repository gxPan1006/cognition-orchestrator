# Security Policy

## Reporting a vulnerability

Please **do not open a public GitHub issue** for security problems.

Instead, open a [GitHub Security Advisory](https://github.com/GuoxunPan/cognition-orchestrator/security/advisories/new) on this repository (private). I'll triage as fast as I can and confirm receipt within 7 days.

Include in your report:

- A description of the vulnerability and its impact.
- Reproduction steps or a proof-of-concept.
- The affected commit / version (`git rev-parse HEAD`).
- Whether you'd like to be credited in the fix's release notes.

## Scope

In scope:

- Code in this repository (Elixir orchestrator, Phoenix dashboard, adapters).
- Default configuration shipped in `WORKFLOW.md`.
- The published GitHub Actions workflows.

Out of scope:

- Vulnerabilities in upstream dependencies — please report those to the upstream project. If a dep CVE materially affects Cognition, opening an issue here so we can pin/upgrade is welcome.
- Issues that require physical access to the operator's machine.
- Social-engineering of the operator running an unattended agent.

## Operator responsibility

This orchestrator runs **autonomous coding agents without the usual interactive guardrails** — that's why the boot flag is `--i-understand-that-this-will-be-running-without-the-usual-guardrails`. The operator is expected to:

- Run Cognition only on hardware/accounts they own.
- Scope the Linear API token to a single project where this kind of automation is acceptable.
- Treat any workspace Cognition creates as **trusted only to the level of the most recent agent turn** — review diffs before pushing if your environment requires it.

## Coordinated disclosure

I'm happy to coordinate a disclosure timeline with you. Default: I aim to ship a fix within 30 days of confirmation, and ask reporters to hold public details until the fix is released.
