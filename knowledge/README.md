# `knowledge/` — Curated Team Second Brain

This directory contains verified operational guides, runbooks, and domain knowledge organized by subsystem (`area-a/`, `area-b/`, etc.).

## Governance & Freshness Summary

- **Schema:** Every page in `knowledge/<domain>/*.md` (excluding folder `README.md` index files) is validated against [`_meta/schema.yaml`](../_meta/schema.yaml) by [`.github/workflows/validate-knowledge.yml`](../.github/workflows/validate-knowledge.yml).
- **Human-Only Verification:** Only humans (`Alex` / `@ORG/maintainers`) may set `status: "verified"` or update `last_verified: "YYYY-MM-DD"`.
- **Bidirectional Card Linking:** Pages list source issues in `related_cards: [...]`, and board cards point back via the **`Knowledge link`** project field.
- **30-Day Freshness Window (Derived at Build Time):**
  - **Days 0–30:** Fresh
  - **Days 31–60:** Overdue for review
  - **Days 61–90:** Stale warning banner
  - **Day 91+:** Archive candidate (requires human owner confirmation)

## Domains

- **[`area-a/`](area-a/README.md)** — Subsystem A operational guides (includes worked example [`retry-backoff-policy.md`](area-a/retry-backoff-policy.md) linked to Card `#42`).
