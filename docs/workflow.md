# Team Workflow Guide: Board Rules, Blockers, Stand-up & Cheat Sheet

> **Reading time:** ~5 minutes (or jump straight to the [1-Page Cheat Sheet](#8-one-page-cheat-sheet) at the bottom).

---

## 1. The Four Board Columns (`Status`)

Every card on the board is a **GitHub Issue** (Pull Requests are never added to the board). `Status` has exactly four values defined in [`project/fields.yml`](../project/fields.yml):

| Column | Entry Criteria | Exit Criteria | Who May Move Cards Here |
|---|---|---|---|
| **`Todo`** | Issue opened via form or blank capture; auto-added by built-in workflow. Clear title; `Priority` defaults to `P1`. | Someone starts work (`→ Doing`) or an immediate dependency blocks it (`→ Blocked`). | **Human** (`Sam`/`Alex`) or **AI Agent** |
| **`Doing`** | Work is actively underway today. Card **must** have a human `Assignee` (set by a human) and respect the soft WIP limit (**≤ 2 `Doing` cards per person**). | Paused (`→ Todo`), hit an impediment (`→ Blocked`), or human verified DoD (`→ Done`). | **Human** or **AI Agent** *(only humans assign people)* |
| **`Blocked`** | Progress is stopped by an external dependency, missing decision, or broken upstream system. Must have **`Assignees`** (owner driving the unblock) + **`Blocked reason`**. `board-keeper.yml` stamps **`Blocked since`** automatically. | Blocker resolved (`→ Doing` or `→ Todo`) or work completed (`→ Done`). `board-keeper.yml` clears `Blocked since` automatically. | **Human** or **AI Agent** |
| **`Done`** | Work is finished, verified by a **human**, and **`Knowledge link`** is filled (or a `Learned:` comment is posted on the issue). | Reopened if regression found (`→ Doing`), or auto-archived after 30 days in `Done`. | **HUMAN ONLY** *(never AI agents or auto-close rules)* |

---

## 2. Soft WIP Limits (Why & How)

- **Rule:** Maximum **2 cards in `Doing` per person** (`wip_limit_per_person: 2`). On the `1. Board` view, the `Doing` column limit is set to **`2 × team_size`** (e.g., `10` for a 5-person team; `30` for 15).
- **How it works (no nagging bots):** GitHub Projects v2 column limits are **soft** (F6)—when the count exceeds the limit, the column header badge turns **red** without blocking emergency drags.
- **What to do when over WIP:** Finish or unblock an existing `Doing` card before pulling a new card from `Todo`, or move the paused card back to `Todo`. Over-WIP assignees are spotted in 5 seconds during stand-up on `2. Stand-up Dashboard`.

---

## 3. The Blocked Protocol (Accountability + Automatic Escalation)

No card is allowed to rot silently in `Blocked`:

1. **On entering `Blocked` (takes 20 seconds on mobile/browser):**
   - Drag the card to **`Blocked`** on the board *(or add the label `status:blocked` directly on the issue screen from your phone)*.
   - Ensure **`Assignees`** is set to the human responsible for driving the unblock (a human must set `Assignees`).
   - Fill **`Blocked reason`** on the card (or in the `[Blocker]` issue form): *what* is blocked, *who/what* can unblock it, and *next check step*.
   - **Optional native link (F9):** Link the blocking issue via the GitHub UI (*Relationships → Blocked by*) or `gh issue edit N --add-blocked-by M`.
2. **What automation (`board-keeper.yml`) does automatically:**
   - **Hour 0:** Stamps **`Blocked since` = `YYYY-MM-DD`** if empty. If `Assignees` or `Blocked reason` is missing, posts a gentle prompt comment (max 1 comment per 3 days).
   - **Day 3 (`Blocked since <= @today-3d`):** Posts a weekday morning reminder asking the assignee if the blocker needs scope reduction or re-routing.
   - **Day 5 (`Blocked since <= @today-5d`):** Applies the **`escalated`** label and mentions **`@ORG/maintainers`** on the issue so leadership unblocks or descopes it that day.
3. **Leaving `Blocked`:**
   - Move `Status` back to **`Doing`** (or `Todo` / `Done`). On the next poll, `board-keeper.yml` automatically clears `Blocked since` and removes `status:blocked`.

---

## 4. Definition of Done (DoD) — 100% Doable from Browser or Mobile Phone

Before a **human** moves any card to **`Done`**, check three things (takes < 30 seconds, zero `git` required):

- [ ] **1. Outcome verified by a human:** The fix, task, or decision actually works (AI agents may never move a card to `Done` or close an issue as completed).
- [ ] **2. Knowledge captured or marked `N/A` (pick one path):**
  - **Path A — Mobile/Browser Comment (easiest, 20 sec):** Leave an issue comment starting with **`Learned:`** (or `Decision:` / `Knowledge:`). Within the hour, `board-keeper.yml` extracts your comment into `inbox/issue-<N>.md` inside the consolidated `bot/inbox-capture` PR and sets the card's `Knowledge link` field to `inbox/issue-<N>.md`.
  - **Path B — Link an existing page:** Paste the path (e.g., `knowledge/area-a/retry-backoff-policy.md`) into the card's **`Knowledge link`** field.
  - **Path C — Trivial task with no reusable learning:** Type **`N/A`** in the card's **`Knowledge link`** field.
- [ ] **3. Card moved to `Done` & issue closed:** Drag the card to **`Done`** and close the issue.

### Worked Example Pair: Issue Card `#42` ↔ Curated Knowledge Page

| Side | Content |
|---|---|
| **Example Board Card (`Issue #42`)** | **Title:** `[Bug]: Fix intermittent timeout on service-x webhook retry`<br>**Status:** `Done` · **Assignee:** `@sam` · **Priority:** `P0` · **Area:** `area-a`<br>**Comment by `Sam` (from mobile app):**<br>`Learned: service-x drops bursts when all workers retry at fixed 5s intervals. Always use exponential backoff (base 2s, cap 60s) with ±25% full jitter and only retry HTTP 429/502/503/504.`<br>**`Knowledge link` field:** [`knowledge/area-a/retry-backoff-policy.md`](../knowledge/area-a/retry-backoff-policy.md) |
| **Curated Second Brain Page** | **[`knowledge/area-a/retry-backoff-policy.md`](../knowledge/area-a/retry-backoff-policy.md)**<br>Frontmatter includes `status: "verified"`, `last_verified: "2026-11-01"` (set by human writer `Alex`), and `related_cards: ["https://github.com/ORG/REPO/issues/42"]`. |

---

## 5. The 10-Minute Daily Stand-up Script (Minute by Minute)

Open **one tab** on screen-share or mobile: **`2. Stand-up Dashboard`** ([exact view settings in `project/views.md`](../project/views.md)). Do **not** do a round-robin "what I did yesterday" monologue—walk the board **by exception**:

| Minute | Group on `2. Stand-up Dashboard` | What the Facilitator (`Sam` or `Alex`) Asks |
|---|---|---|
| **0:00 – 3:00**<br>*(3 min)* | **`Blocked`**<br>*(sorted oldest `Blocked since` first)* | 1. Does every `Blocked` card have an **Assignee** and a **`Blocked reason`**? *(If blank, fill live in 10 seconds.)*<br>2. For any card with **`escalated`** (≥ 5d) or ≥ 3d: *"Who needs to pair or make a call right after stand-up to unblock `#N` today?"* |
| **3:00 – 7:00**<br>*(4 min)* | **`Doing`**<br>*(scan by exception)* | Skip cards moving normally! Only stop on:<br>1. Anyone with **> 2 cards in `Doing`** (*"Which one goes back to `Todo` or finishes this morning?"*)<br>2. Any card with an aging/stale check-in comment (> 5 days no update)<br>3. Any card labeled **`agent-drafted`** waiting on a human to assign or review |
| **7:00 – 10:00**<br>*(3 min)* | **`Done` (last 7 days)** & **`3. Needs Attention`** | 1. Quick shout-out on newly `Done` items.<br>2. Check **`3. Needs Attention`**: if any `Done` card has an empty **`Knowledge link`**, the owner types a 1-line `Learned:` comment or sets `Knowledge link = N/A` live before leaving the call. |

---

## 6. Weekly Review (15–20 Minutes on Friday Afternoon)

Every Friday at `16:00 UTC` (or on demand via `Actions → board-keeper → Run workflow`), `board-keeper.yml` updates the **`Week YYYY-WW: Team Board & Knowledge Digest`** issue:

1. **Minutes 0–5 (Digest & Flow Charts):** Open the `Week YYYY-WW` issue and the 2 **Insights** charts (*Status Over Time* and *Active Work by Assignee*). Check whether `Doing` or `Blocked` is ballooning relative to `Done`.
2. **Minutes 5–12 (Second Brain Inbox Merge):** Knowledge writer `Alex` opens the consolidated **`bot/inbox-capture` Pull Request** containing `inbox/issue-<N>.md` notes captured from the week's `Learned:` comments, folds durable rules into `knowledge/<area>/` or `decisions/`, sets `status: verified` and `last_verified: YYYY-MM-DD`, and merges.
3. **Minutes 12–20 (Queue Hygiene):** Glance at `Todo` sorted by `Priority:asc`, close obsolete items as `not planned`, and confirm the top `P0`/`P1` items for Monday have human owners ready.

---

## 7. Keeping the Board Current Without Nagging

- **Let views do the talking:** Never DM teammates asking for status updates. Share `2. Stand-up Dashboard` at stand-up; missing `Blocked reason` or missing `Knowledge link` rows are visible in `3. Needs Attention` (`0` rows = healthy team).
- **3-day comment cooldown:** `board-keeper.yml` embeds `<!-- board-keeper:alert:YYYY-MM-DD -->` in its comments so a card is never pinged more than once every 3 days.
- **15-second mobile escape hatch:** If you are walking between meetings, open a blank issue with a 5-word title or add label `status:blocked`—fill the rest at the next stand-up.

---

## 8. One-Page Cheat Sheet

| I want to... | What to do (Browser or Mobile App — No Git Required) |
|---|---|
| **Add a new task / bug / decision** | `ORG/REPO` → **Issues → New Issue** → pick **Task / Bug / Blocker / Decision** (or **Blank issue**). Auto-lands in `Todo`. |
| **Start working on a card** | Assign yourself (`Assignees`) and move `Status` → **`Doing`** (keep **≤ 2 `Doing` cards** per person). |
| **Mark a card Blocked** | Move `Status` → **`Blocked`** (or add label **`status:blocked`**), keep an **`Assignee`**, and type **`Blocked reason`**. (`Blocked since` stamps automatically.) |
| **Finish a card (`Done` — Human Only)** | 1. Comment **`Learned: <1-2 sentence takeaway>`** on the issue (or set **`Knowledge link` = `N/A`** / doc path).<br>2. Move `Status` → **`Done`** and close the issue. |
| **Review an AI agent's work** | Look for label **`agent-drafted`**. Verify the output yourself—**only humans** may set `Assignees`, move to `Done`, or set `last_verified` on docs. |
| **Run the 10-minute stand-up** | Open **`2. Stand-up Dashboard`**: **0–3m** `Blocked` (oldest first) → **3–7m** `Doing` exceptions (WIP > 2, stale > 5d) → **7–10m** `Done` & `3. Needs Attention` (`0` rows goal). |
