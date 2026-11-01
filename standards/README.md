# `standards/` — Locked Team Engineering Standards

Files in `standards/` define cross-cutting team conventions that require maintainer sign-off before changing.

## Protection Rules (`locked: true`)

1. Every standard page in `standards/` sets `locked: true` and `type: "standard"` in its YAML frontmatter (using [`_templates/page.md`](../_templates/page.md)).
2. **Enforced on GitHub Free and Team:** [`.github/workflows/validate-knowledge.yml`](../.github/workflows/validate-knowledge.yml) runs [`scripts/validate_knowledge.sh`](../scripts/validate_knowledge.sh) and blocks any non-human actor (`*[bot]` or agent account) from modifying files in `standards/` or any page with `locked: true`.
3. **Additional Team Plan Enforcement (F13):** Copying [`.github/CODEOWNERS.example`](../.github/CODEOWNERS.example) to `.github/CODEOWNERS` requires `@ORG/maintainers` review on all pull requests touching `/standards/`.
