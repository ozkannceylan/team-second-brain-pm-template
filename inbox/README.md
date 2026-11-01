# `inbox/` — Zero-Friction Second Brain Drop-Zone

Raw notes land here before a knowledge writer (`Alex`) or the optional nightly compiler folds them into [`knowledge/`](../knowledge/README.md), [`decisions/`](../decisions/README.md), or [`standards/`](../standards/README.md).

## How Notes Arrive in `inbox/` (Two Paths)

1. **Automatic Issue Comment Extraction (Recommended for Mobile & Browser Users):**
   - When finishing an issue card (#N), post a regular issue comment starting with **`Learned:`** (or **`Decision:`** / **`Knowledge:`**), then move the card to `Done`.
   - On its hourly weekday run, [`.github/workflows/board-keeper.yml`](../.github/workflows/board-keeper.yml) automatically extracts the comment into `inbox/issue-<N>.md`, opens/updates the consolidated **`bot/inbox-capture`** pull request, and populates the card's `Knowledge link` field.
2. **Direct Web Editor / Git Drop (Optional):**
   - Click **Add file → Create new file** in this folder (`inbox/YYYY-MM-DD-topic.md`) using [`_templates/inbox-note.md`](../_templates/inbox-note.md). No YAML frontmatter is required in `inbox/`.
