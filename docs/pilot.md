# 2-Week Pilot Plan: Metrics, Measurement, Checklists & Retro

Run this **10-business-day pilot** with your initial 5-person team before rolling out to 15 people or enabling external knowledge-compiler pipelines.

---

## 1. Day-0 Readiness Checklist (Before Day 1 Stand-up)

- [ ] **Repository & Labels:** `ORG/REPO` created from template; `./scripts/sync-labels.sh --repo ORG/REPO` executed (9 labels present).
- [ ] **Board, Fields & Views:** `./scripts/setup-project.sh --org ORG --repo REPO` executed (`Status` + 5 custom fields + 3 saved views created).
- [ ] **Built-In Workflows Toggled:** Auto-add (`is:issue is:open` → `Todo`) **ON**; Item closed → Done **OFF**; PR merged → Done **OFF**; Auto-archive (`status:Done updated:<@today-30d`) **ON**.
- [ ] **Automation Auth Active:** `APP_ID` + `APP_PRIVATE_KEY` (or `PROJECT_PAT`) and repo variables `ORG_NAME` + `PROJECT_NUMBER` set; test-run `board-keeper.yml` via **Actions → Run workflow** succeeds green.
- [ ] **Seed the Active Work:** Each of the 5 team members enters their **1–2 currently active tasks** as issues and moves them to `Doing` (`Assignees` set).
- [ ] **Bookmarks Saved:** Every team member bookmarks `2. Stand-up Dashboard` on desktop and installs/opens the GitHub mobile app.

---

## 2. The 3 Core Success Metrics (+ 2 Guardrail Metrics) & Exact Measurement

| # | Metric | Target | How to Measure Directly from the Board / Digest |
|---|---|---|---|
| **M1 (Core)** | **Board Coverage of Real Work** | **≥ 90%** of real engineering/ops work is on the board | **Friday Retro Spot-Check (3 min):** Each team member names the top 2 things they worked on that week (10 items total across 5 people) and verifies each has a card in `Doing`, `Blocked`, or `Done`. (`>= 9 / 10` = **≥ 90%**). Also backed by PR check: `gh pr list --state merged --search "updated:>=YYYY-MM-DD" --json body` checking `Closes #N`. |
| **M2 (Core)** | **Blocked Card Accountability** | **100%** of `Blocked` cards have `Assignees` + `Blocked since` + `Blocked reason` | **Saved Filter (`3. Needs Attention`):**<br>`status:Blocked (no:assignee OR no:"Blocked since" OR no:"Blocked reason")`<br>**Target count:** **`0` items** at the end of every stand-up, plus reported automatically in the Friday `Week YYYY-WW` digest issue. |
| **M3 (Core)** | **Stand-up Duration (Dashboard Only)** | **≤ 10 minutes** using only `2. Stand-up Dashboard` | **Daily Timer Log:** Facilitator starts a 10-minute timer at the start of stand-up and records elapsed minutes (`MM:SS`) in a 1-line comment on the active `Week YYYY-WW` digest issue (`>= 8 of 10` stand-ups finished in `≤ 10:00`, zero external spreadsheets opened). |
| **M4 (Extra 1)** | **DoD Knowledge Capture Rate** | **100%** of `Done` cards have a `Knowledge link` (path, `inbox/issue-<N>.md`, or `N/A`) | **Saved Filter (`3. Needs Attention`):**<br>`status:Done no:"Knowledge link"`<br>**Target count:** **`0` items** by Friday Weekly Review. |
| **M5 (Extra 2)** | **Unresolved Agent Policy Violations** | **`0`** unreviewed bot `Done` or `Assignees` violations | **Issue Query / Friday Digest:**<br>`is:issue label:policy-violation is:open`<br>**Target count:** **`0` open issues** at Friday review. |

### One-Command CLI Measurement (`scripts/project_query.sh`)
At any point during the pilot, run:
```bash
./scripts/project_query.sh --mode digest --org ORG --repo REPO --project-number 1 --dry-run
```
This prints the exact counts of `Todo`, `Doing`, `Blocked`, `Done`, incomplete blockers (M2), and `Done` cards missing `Knowledge link` (M4).

---

## 3. Daily & End-of-Week Checklists

### Daily Stand-up Checklist (10 Minutes Max)
- [ ] **0:00–3:00 (`Blocked`):** Review `Blocked` group on `2. Stand-up Dashboard` (oldest `Blocked since` first). Fill any missing `Assignees` or `Blocked reason` live so M2 = 100%.
- [ ] **3:00–7:00 (`Doing` Exceptions):** Address anyone with **> 2 `Doing` cards**, any card stale **> 5 days**, or any `agent-drafted` card needing a human owner.
- [ ] **7:00–10:00 (`Done` & `3. Needs Attention`):** Verify `3. Needs Attention` has **`0` rows** (any `Done` card missing `Knowledge link` gets a `Learned:` comment or `N/A` live). Log stand-up duration (`≤ 10m`).

### Friday Weekly Review Checklist (15–20 Minutes, Day 5 & Day 10)
- [ ] Open the auto-generated **`Week YYYY-WW: Team Board & Knowledge Digest`** issue.
- [ ] Run the 3-minute **M1 Board Coverage spot-check** (2 items per person = 10 items; record `%` in the digest issue).
- [ ] Knowledge writer (`Alex`) reviews and merges the **`bot/inbox-capture` PR** into `knowledge/` / `decisions/`, setting `status: verified` and `last_verified: YYYY-MM-DD`.
- [ ] Check the 2 **Insights** charts (*Status Over Time*, *Active Work by Assignee*) for WIP creep.

---

## 4. Go / Adjust / Stop Decision Table (Day 10)

| Outcome at Day 10 | Criteria | Action |
|---|---|---|
| 🟢 **GO**<br>*(Scale to 15 people)* | • **M1 ≥ 90%** work on board<br>• **M2 = 100%** blocker accountability (`0` unowned/undated blockers)<br>• **M3 ≤ 10 min** stand-up on ≥ 8/10 days<br>• **M4 = 100%** `Done` cards have `Knowledge link` / `N/A` | Lock in the workflow as the team standard, onboard the remaining sub-teams using the `Area` field (`area-a`, `area-b`, `ops`), and optionally connect the external nightly knowledge compiler. |
| 🟡 **ADJUST**<br>*(Tune & run 1 more week)* | • **M1 = 75–89%** (some ad-hoc tasks skipped)<br>• **M2 = 80–99%** (1–2 blockers missed a reason until prompted)<br>• **M3 = 10–14 min** (people gave status monologues instead of walking exceptions) | Keep the board, fix the specific friction point (e.g., remind mobile users to use **Blank issue** for 15-sec capture; enforce strict exception-only reading in stand-up; switch `board-keeper.yml` cron from hourly to `*/30`), and re-check on Day 15. |
| 🔴 **STOP / REDESIGN** | • **M1 < 75%** (shadow tracking persists)<br>• **M2 < 80%** (blockers sit unowned for > 3 days)<br>• **M3 > 15 min** consistently or team refuses to update cards | Pause automation, run the Day-10 retro below to identify whether issue creation or stand-up facilitation failed, and strip down to `1. Board` + blank issues only before retrying. |

---

## 5. Pilot Retrospective Template (Copy into `Week YYYY-WW` Digest on Day 10)

```markdown
## 🏁 2-Week Pilot Retrospective (`YYYY-MM-DD`)

### 1. Final Scorecard
- **M1 Board Coverage:** `__/10` spot-checked tasks on board (`__%`, target ≥ 90%)
- **M2 Blocker Accountability:** `__` unowned/undated blockers in `3. Needs Attention` (target `0`)
- **M3 Stand-up Duration:** Average `__m __s` across 10 days (`__/10` days ≤ 10m)
- **M4 DoD Knowledge Capture:** `__` `Done` cards missing `Knowledge link` (target `0`)
- **M5 Agent Safety:** `__` open `policy-violation` issues (target `0`)
- **Decision:** `[ ] GO  |  [ ] ADJUST  |  [ ] STOP`

### 2. Friction Check (1 minute per question)
1. **Mobile/Browser Filing (< 1 min):** Did any form field feel slow or unnecessary on a phone?
2. **Stand-up Signal:** Which view column or filter saved the most time? What wasted time?
3. **Second Brain Loop (`Learned:` → `inbox/`):** How many `Learned:` comments turned into reusable notes?
4. **Agent Help vs. Noise:** Were `agent-drafted` cards and weekly summaries useful, or did they create triage overhead?

### 3. Concrete Config Changes for Next Month (max 3)
- [ ] Change 1 (owner: `@...` — e.g., adjust `project/fields.yml` threshold or form input):
- [ ] Change 2 (owner: `@...`):
```
