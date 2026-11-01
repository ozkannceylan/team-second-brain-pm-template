# Project Views & Insights Dashboard Specification

This document defines the **3 saved Project views** (provisioned from [`project/views.yml`](views.yml) by [`scripts/setup-project.sh`](../scripts/setup-project.sh)) and the **2 Insights charts** configured in the GitHub Projects v2 UI.

---

## 1. The 3 Saved Views (`project/views.yml`)

All filter queries below use **Generally Available (GA)** GitHub Projects v2 filter syntax, including boolean `AND` / `OR` parentheses, `no:FIELD`, and relative `@today` dates (verified fact F11).

| View Name | Layout | Exact Filter Syntax | Group / Column By | Sort | Visible Fields | Question Answered in Stand-up |
|---|---|---|---|---|---|---|
| **`1. Board`** | **Board** | `is:issue` | Column by: `Status` (`Todo`, `Doing`, `Blocked`, `Done`) | `Priority:asc` | `Title`, `Assignees`, `Priority`, `Area`, `Blocked since`, `Blocked reason`, `Knowledge link` | *"Where does my card sit, and is the `Doing` column over our soft WIP limit (`2 × team_size`)?"* |
| **`2. Stand-up Dashboard`** | **Table** | `status:Blocked,Doing OR (status:Done updated:>@today-7d)` | Group by: `Status` | `Blocked since:asc`, then `Priority:asc` | `Title`, `Status`, `Assignees`, `Priority`, `Blocked since`, `Blocked reason`, `Knowledge link`, `Area` | **Primary 10-minute stand-up tab:**<br>• **0–3m (`Blocked`):** What is blocked, since when, and who owns unblocking?<br>• **3–7m (`Doing`):** Who is over WIP (>2) or stuck?<br>• **7–10m (`Done`):** What finished in the last 7 days and was knowledge captured? |
| **`3. Needs Attention`** | **Table** | `(status:Blocked (no:assignee OR no:"Blocked since" OR no:"Blocked reason")) OR (status:Doing no:assignee) OR (status:Done no:"Knowledge link")` | Group by: `Status` | `Priority:asc` | `Title`, `Status`, `Assignees`, `Blocked since`, `Blocked reason`, `Knowledge link` | *"Which cards violate our pilot rules right now?"* (**Goal: `0` rows** at the end of every stand-up.) |

### Optional Sub-Team Filter at 15 People
When the team grows from 5 to ~15 people, append `AND area:area-a` (or click the `Area` pill in the table header) to slice `2. Stand-up Dashboard` by sub-team without creating extra views.

---

## 2. Insights Charts (Click-by-Click Setup)

GitHub Projects v2 **Insights** (current + historical charts) is included on **all plans (Free and Team, public and private, F7)**. Because GitHub has no public API to create Insights charts, create these **2 charts** once by hand (takes 2 minutes):

> **Important (F7):** Insights ignores archived items. Keep the built-in **Auto-archive** filter set to `status:Done updated:<@today-30d` so Insights always has a full 30-day window of completed cards.

### Chart 1: `Status Over Time` (Flow & Bottleneck Detector)
Answers: *"Is work flowing smoothly to `Done`, or is `Doing` / `Blocked` piling up over the 2-week pilot?"*

1. In the top-right of your Project, click **Insights** (graph icon).
2. Click **+ New chart** (left sidebar) and rename it **`Status Over Time`**.
3. Click **Configure** (top-right of chart):
   - **Layout:** `Stacked area` (or `Stacked column`)
   - **X-axis:** `Time` → **Period:** `Last 30 days` (or `Last 2 weeks` during the pilot)
   - **Group by:** `Status`
   - **Y-axis:** `Count of items`
   - **Filter:** `is:issue`
4. Click **Save changes**.

### Chart 2: `Active Work by Assignee` (Soft WIP & Load Check)
Answers: *"Who is overloaded (> 2 `Doing` cards) or carrying multiple `Blocked` cards right now?"*

1. In **Insights**, click **+ New chart** and rename it **`Active Work by Assignee`**.
2. Click **Configure**:
   - **Layout:** `Stacked bar` (horizontal) or `Stacked column`
   - **Filter:** `status:Doing,Blocked`
   - **X-axis:** `Assignees`
   - **Group by:** `Status`
   - **Y-axis:** `Count of items`
3. Click **Save changes**. *(Anyone whose `Doing` bar exceeds `2` is over the soft WIP limit.)*
