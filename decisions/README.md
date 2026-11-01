# `decisions/` — Team Architecture Decision Records (ADRs)

When the team resolves a `[Decision]` issue card on the GitHub Projects v2 board ([`.github/ISSUE_TEMPLATE/decision.yml`](../.github/ISSUE_TEMPLATE/decision.yml)), the durable decision is recorded here using [`_templates/adr.md`](../_templates/adr.md).

## How Decision Cards Turn Into ADRs

1. **On the Board (`Sam` or `Alex`):** Open a **Decision** issue (`type:decision`, `needs-second-brain`), discuss options, and comment `Decision: <summary of chosen option and consequences>` before moving the card to `Done`.
2. **Automatic Capture:** [`board-keeper.yml`](../.github/workflows/board-keeper.yml) extracts the `Decision:` comment into `inbox/issue-<N>.md` inside the `bot/inbox-capture` PR.
3. **Curated ADR (`Alex`):** Copy [`_templates/adr.md`](../_templates/adr.md) to `decisions/NNNN-short-title.md`, link the issue in `related_cards`, set `status: "verified"` and `last_verified: "YYYY-MM-DD"`, and update the board card's `Knowledge link` field to `decisions/NNNN-short-title.md`.

*(Note: The architecture decisions for this template repository itself live in [`docs/decisions/`](../docs/decisions/0001-brainstorming.md).)*
