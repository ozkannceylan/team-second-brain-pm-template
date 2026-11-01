# `_meta/` — Second Brain Schema & Compiler Governance

This directory holds the governance rules and frontmatter schema for the repository's Markdown Second Brain:

- **[`schema.yaml`](schema.yaml):** Machine-readable frontmatter specification enforced by [`scripts/validate_knowledge.sh`](../scripts/validate_knowledge.sh) and [`.github/workflows/validate-knowledge.yml`](../.github/workflows/validate-knowledge.yml).
- **[`AGENTS.md`](AGENTS.md):** Operating rules for any AI assistant or external nightly compiler (`bot/nightly`) interacting with `inbox/`, `knowledge/`, `standards/`, and `decisions/`.
