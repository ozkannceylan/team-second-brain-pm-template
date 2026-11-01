# Optional & Experimental Features (Quarantined from Core Template)

> **Warning:** The core template uses **zero public-preview features** so it runs reliably on GitHub Free and Team from Day 0. Everything below is **strictly optional** and should only be enabled if your team specifically needs it.

---

## 1. Multi-Repo Auto-Add Actions Workflow (GitHub Free > 1 Repo)

GitHub Free allows **1 built-in auto-add workflow** per project (F4; GitHub Team allows 5). If your organization stays on GitHub Free and splits issues across multiple repositories (`ORG/service-x`, `ORG/service-y`), save this workflow in the extra repositories as `.github/workflows/auto-add.yml`:

```yaml
name: Auto-Add Issues to Org Project (Multi-Repo Optional)

on:
  issues:
    types: [opened, transferred]

permissions:
  issues: read

jobs:
  add-to-project:
    runs-on: ubuntu-latest
    env:
      HAS_APP_CREDENTIALS: ${{ secrets.APP_ID != '' && secrets.APP_PRIVATE_KEY != '' && 'true' || 'false' }}
    steps:
      - name: Mint GitHub App token (or fall back to PROJECT_PAT)
        id: app-token
        if: ${{ env.HAS_APP_CREDENTIALS == 'true' }}
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}

      - name: Add issue to Projects v2 board
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token || secrets.PROJECT_PAT }}
          PROJECT_URL: https://github.com/orgs/${{ vars.ORG_NAME || github.repository_owner }}/projects/${{ vars.PROJECT_NUMBER || '1' }}
          ISSUE_URL: ${{ github.event.issue.html_url }}
        run: |
          gh project item-add "${PROJECT_URL##*/}" \
            --owner "${ORG_NAME:-${GITHUB_REPOSITORY_OWNER}}" \
            --url "$ISSUE_URL"
```

---

## 2. Optional `Target date` Field & Deadline Filter

The core template omits `Target date` to keep card triage under 5 custom fields. If your team tracks external regulatory or launch deadlines:
1. Add to `custom_fields` in [`project/fields.yml`](../../project/fields.yml):
   ```yaml
   - name: "Target date"
     data_type: "DATE"
     description: "Optional external deadline (YYYY-MM-DD)."
   ```
2. Re-run `./scripts/setup-project.sh --org ORG --repo REPO`.
3. Add a filter to `3. Needs Attention`: `OR (status:Todo,Doing,Blocked "Target date":<=@today+3d)`.

---

## 3. Static-Site (Quartz 5) 30-Day Freshness Banner Snippet

When publishing `knowledge/`, `standards/`, and `decisions/` (`publish: true`) to an external read-only static site (e.g., Quartz 5), derive freshness banners **at build time** from `last_verified` (never commit freshness status changes back to git):

```javascript
// Build-time helper for Quartz 5 custom banner component
export function computeFreshnessState(lastVerifiedIsoDate, todayIsoDate = new Date().toISOString().slice(0, 10)) {
  const msPerDay = 86400000;
  const ageDays = Math.floor((Date.parse(todayIsoDate) - Date.parse(lastVerifiedIsoDate)) / msPerDay);
  if (ageDays <= 30) return { state: "fresh", ageDays, showBanner: false };
  if (ageDays <= 60) return { state: "overdue", ageDays, showBanner: true, label: `Review overdue (${ageDays}d since human verification)` };
  if (ageDays <= 90) return { state: "stale", ageDays, showBanner: true, label: `Stale page (${ageDays}d unverified) — verify before relying on commands` };
  return { state: "archive-candidate", ageDays, showBanner: true, label: `Archive candidate (${ageDays}d unverified) — awaiting human owner confirmation` };
}
```

---

## 4. Public-Preview GitHub Features (Do Not Use as Core Dependencies)

| Feature | Status (as of `2026-11-01`) | How to Experiment Safely |
|---|---|---|
| **Issue Artifacts (`gh issue artifact`, F16)** | Public Preview (`2026-10-28`) | Attach long agent investigation logs or HTML trace reports via `gh issue artifact create <issue-number> --file report.md` instead of pasting 500-line comments. Keep `Learned:` comments in regular issue comments so `board-keeper.yml` can always extract them. |
| **Agent Automation Controls / Issue Intents (`copilot_issue_intents`, F15)** | Public Preview (`2026-07-23`) | Opt-in via `--toolsets context,issues,projects,labels,copilot_issue_intents` if using Copilot agents to queue low-confidence edits for review in the UI. **Never disable `board-keeper.yml` actor audits**, as GitHub states issue intents are *"a workflow convenience, not a security control"*. |
| **Multi-Select Project Fields (F17)** | Public Preview (`2026-07-23`) | If a single card spans both `area-a` and `area-b`, you can convert `Area` from `SINGLE_SELECT` to `MULTI_SELECT` in the Project UI once multi-select exits preview. |
| **Organization Issue Fields & Issue Types (F8, F10)** | GA (`2025-04-09`) / Org-Admin Opt-in | Organization admins can define org-wide Issue Types (`Task`, `Bug`, `Blocker`, `Decision`) and up to 25 Org Issue Fields (`Priority`, `Target date`). Keep `.github/labels.yml` (`type:*`) active so repositories work even without org-level configuration. |
