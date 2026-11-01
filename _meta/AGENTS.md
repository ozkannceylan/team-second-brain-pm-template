# Second Brain Compiler & Agent Rules (`_meta/AGENTS.md`)

Any AI agent, automation script, or external nightly LLM compiler (`bot/nightly`) operating on this repository must obey these rules:

1. **Human-Only Verification (Enforced by Blocking CI):**
   - **Never** set `status: "verified"` or write/modify `last_verified` in YAML frontmatter.
   - Any page created or updated by a bot must use `status: "draft-bot"` and leave `last_verified: null` (or preserve the human's previous `last_verified` only when appending to the contradictions section if explicitly permitted; otherwise set `status: "draft-bot"`).
   - [`.github/workflows/validate-knowledge.yml`](../.github/workflows/validate-knowledge.yml) fails any PR or push where a non-human actor modifies `last_verified` or sets `status: verified`.
2. **Locked Pages & Standards (`locked: true`):**
   - Pages with `locked: true` in their base frontmatter—and all pages under [`standards/`](../standards/README.md)—may **only** be modified by human owners (`@ORG/maintainers`).
3. **One Consolidated Nightly PR (`bot/nightly`) & Inbox Capture (`bot/inbox-capture`):**
   - [`board-keeper.yml`](../.github/workflows/board-keeper.yml) collects `Learned:` comments from newly `Done` issue cards into `inbox/issue-<N>.md` inside a single branch/PR (`bot/inbox-capture`).
   - If the optional external nightly LLM compiler is enabled, it reads raw notes from `inbox/`, updates curated drafts on branch `bot/nightly` (never force-pushing over human commits), and moves processed inbox notes verbatim to `_archive/inbox/YYYY-MM/`.
4. **Never Silently Drop Contradictions:**
   - When an inbox note contradicts an existing `verified` page, append the discrepancy with source issue link and date under `## Contradictions and open questions` at the bottom of the page for human resolution within the 7-day SLA.
5. **Derived Freshness Only:**
   - The 30-day freshness lifecycle (Fresh 0–30d, Overdue 31–60d, Stale 61–90d, Archive candidate 91d+) is computed at static-site build time from `last_verified`. Bots never commit freshness-state edits to git.
