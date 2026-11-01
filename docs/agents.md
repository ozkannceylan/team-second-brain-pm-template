# AI Agent Integration Guide: Identity, Least Privilege, MCP & Guardrails

This document defines how coding and project-management AI agents (via the **GitHub MCP Server** or REST/GraphQL API) collaborate safely on `ORG/REPO` and the organization's **GitHub Projects v2** board.

---

## 1. Golden Rule of Bot Identity: Never Share a Human PAT

Every AI agent and automation job **must** authenticate with its own distinct identity—either:
1. **A dedicated bot machine account** (e.g., `@ORG-agent-bot`) with a scoped Fine-Grained Personal Access Token (PAT), **or**
2. **An organization GitHub App** (e.g., `ORG-board-keeper[bot]`) minting short-lived (1-hour) installation tokens via `actions/create-github-app-token@v1`.

> **Why this is non-negotiable:** `.github/workflows/board-keeper.yml` and `.github/workflows/validate-knowledge.yml` inspect `github.actor` (on issue/PR events) and GraphQL `fieldValueByName(name: "Status").creator.login` (on project board polls) against `governance.bot_actor_patterns` in [`project/fields.yml`](../project/fields.yml). If an engineer gives their personal PAT to an agent, GitHub records the engineer's username on every action, blinding all human-only guardrails.

---

## 2. Exact Token Permissions

### 2.1 AI Agent Token (`@ORG-agent-bot` Fine-Grained PAT for MCP Server)

Create the Fine-Grained PAT from the dedicated `@ORG-agent-bot` account (**Settings → Developer settings → Personal access tokens → Fine-grained tokens**):

| Scope Level | Permission Name | Access Level | Why / Security Boundary |
|---|---|---|---|
| **Resource owner** | Organization | `ORG` | Scopes token to the team organization only. |
| **Repository access** | Only select repositories | `ORG/REPO` | Prevents lateral access to unrelated org repositories. |
| **Repository permission** | **Issues** | **Read and write** | Allows creating cards, commenting, and adding labels (`agent-drafted`). |
| **Repository permission** | **Metadata** | **Read-only** | Mandatory base scope for repository API access. |
| **Repository permission** | **Contents** | **No access** *(or Read-only)* | **Blocks agents from pushing commits or editing `knowledge/` directly.** |
| **Repository permission** | **Pull requests** | **No access** | **Blocks agents from approving or merging pull requests.** |
| **Repository permission** | **Administration** | **No access** | **Blocks agents from deleting issues or modifying branch rules.** |
| **Organization permission** | **Projects** | **Read and write** | Required because `GITHUB_TOKEN` cannot access Projects v2 (F2). |

### 2.2 GitHub Actions Automation Identity (`board-keeper.yml`)

For `.github/workflows/board-keeper.yml`, register an internal **GitHub App** owned by `ORG` (recommended so tokens never expire when a team member leaves) or provide a fallback `PROJECT_PAT` secret:
- **GitHub App permissions:** Repository `Issues: Read & write`, `Contents: Read & write` (to push `inbox/issue-<N>.md` to branch `bot/inbox-capture`), `Pull requests: Read & write` (to open/update the `bot/inbox-capture` PR), `Metadata: Read-only`; Organization `Projects: Read & write`.
- **Secrets & Variables (defined in [`project/fields.yml`](../project/fields.yml)):**
  - Repository Secrets: `APP_ID` and `APP_PRIVATE_KEY` (primary), or `PROJECT_PAT` (fallback).
  - Repository Variables: `ORG_NAME` (`ORG`) and `PROJECT_NUMBER` (e.g., `1`).

---

## 3. GitHub MCP Server Configuration (`github/github-mcp-server`)

By default, `github/github-mcp-server` enables `context,repos,issues,pull_requests,users` and **does not enable `projects` or `labels`** (F14).

Use `--toolsets context,issues,projects,labels` so the agent can read/write Issues, Labels, and Projects v2 fields **without** exposing `repos` (file write/push) or `pull_requests` (merge/approve) tools:

### 3.1 Standard Task & Board Agent Config (`mcp.json`)

```json
{
  "mcpServers": {
    "github-team-pm": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_PERSONAL_ACCESS_TOKEN",
        "-e",
        "GITHUB_TOOLSETS=context,issues,projects,labels",
        "ghcr.io/github/github-mcp-server"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${AGENT_BOT_FINE_GRAINED_PAT}"
      }
    }
  }
}
```

### 3.2 Read-Only Research / Stand-Up Prep Agent Config

Passing `--read-only` (or `GITHUB_READ_ONLY=1`) overrides all toolsets and strips every write tool at the server level (F14):

```json
{
  "mcpServers": {
    "github-team-pm-readonly": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_PERSONAL_ACCESS_TOKEN",
        "ghcr.io/github/github-mcp-server",
        "--read-only",
        "--toolsets",
        "context,repos,issues,projects"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${AGENT_BOT_FINE_GRAINED_PAT}"
      }
    }
  }
}
```

---

## 4. What Agents May and May Not Do (and How Each Is Enforced)

| Capability | Allowed? | Enforcement Layer | Exact Technical Mechanism |
|---|---|---|---|
| **Create issues / cards** | ✅ **May** | Permission + Convention | `Issues: Write` scope; agent must apply label **`agent-drafted`**. |
| **Update `Status` among `Todo`, `Doing`, `Blocked`** | ✅ **May** | Permission | `Projects: Write` scope via `projects` MCP toolset. |
| **Set `Priority`, `Area`, `Blocked reason`, `Knowledge link`** | ✅ **May** | Permission | `Projects: Write` scope via `projects` MCP toolset. |
| **Comment on issues & append weekly narrative summary** | ✅ **May** | Permission | `Issues: Write` scope. |
| **Assign people (`Assignees`)** | ❌ **May NOT** | **Real-Time Automation Audit (+ Optional Revert)** | `board-keeper.yml` triggers on `issues: [assigned]`. If `github.actor` matches a bot pattern, it posts a warning comment, applies label **`policy-violation`**, and logs to the weekly digest. Setting `auto_revert: true` in `project/fields.yml` removes the bot-added assignee immediately. |
| **Move `Status` to `Done` or close an issue as completed** | ❌ **May NOT** | **Workflow Config + Poll & Event Audit (+ Optional Revert)** | 1. Built-in *"Item closed → Done"* and *"PR merged → Done"* are **OFF**.<br>2. `on: issues: [closed]` checks `github.actor` instantly.<br>3. Hourly `board-keeper.yml` poll checks `fieldValueByName(name: "Status").creator.login` and the digest issue snapshot. Bot `Done` transitions get a warning comment + **`policy-violation`** label (or revert to `Doing` if `auto_revert: true`). |
| **Set `last_verified` or `status: verified` on knowledge pages** | ❌ **May NOT** | **Permission + Blocking CI** | 1. Agent PAT has no `Contents: Write`.<br>2. For bots with repo write access (e.g., nightly compiler), `.github/workflows/validate-knowledge.yml` runs `scripts/validate_knowledge.sh` and **fails the PR** if a non-human actor sets `status: verified` or changes `last_verified`. |
| **Modify `locked: true` pages (`standards/`, `decisions/`)** | ❌ **May NOT** | **Permission + Blocking CI + CODEOWNERS** | `validate-knowledge.yml` blocks non-human edits to any file with `locked: true` or under `standards/` on all plans (Free & Team); `.github/CODEOWNERS.example` enforces review on Team. |
| **Push to `main`, approve PRs, or merge PRs** | ❌ **May NOT** | **Permission** | Agent PAT lacks `Contents: Write` and `Pull requests: Write`; `repos` and `pull_requests` MCP toolsets are omitted. |
| **Delete issues, project fields, or project views** | ❌ **May NOT** | **Permission** | Deleting issues requires repo `Administration`; MCP toolset does not expose field/view deletion tools. |

---

## 5. Why "Issue Intents" Are NOT a Security Control (Verified Fact F15)

GitHub introduced *Agent automation controls in GitHub Issues* (`issue-intents` / `copilot_issue_intents`, public preview 2026-07-23, F15), where an agent attaches confidence levels and rationale so low/medium-confidence mutations are held for human review.

**Do not rely on `issue-intents` to enforce human-only rules (`Assignees`, `Done`, `last_verified`):**
1. **Explicit vendor warning:** GitHub's official changelog states plainly: *"Approvals are a workflow convenience, not a security control… an agent with permission to change issues can directly apply changes."*
2. **Public preview status:** It is a Copilot-specific public preview feature, violating our core stability rule.
3. **Our defense-in-depth:** We enforce boundaries via **token scope omission** (no `Contents: Write`), **blocking CI** (`validate-knowledge.yml`), and **independent server-side actor auditing** (`board-keeper.yml` checking `github.actor` and `Status.creator.login`).

---

## 6. Labelling `agent-drafted` & Reviewing Agent Output in 30 Seconds

1. **Every issue created by an agent** must include the **`agent-drafted`** label and a 1-line footer (`_Drafted by @ORG-agent-bot — requires human assignment and DoD verification._`).
2. **During daily stand-up (or triage):**
   - A human (`Sam` or `Alex`) scans new `agent-drafted` cards in `Todo` or `Doing`.
   - To accept the card: the human assigns an owner (`Assignees`), confirms `Priority`/`Area`, and removes `agent-drafted` (or leaves it for provenance).
   - To reject noise: the human closes the issue as **Close as not planned** (takes 2 taps on mobile; because *"Item closed → Done"* is OFF, rejected cards never pollute `Done`).

---

## 7. Weekly Agent Narrative Summary Format

Every Friday at `16:00 UTC`, `board-keeper.yml` creates or updates the deterministic **`Week YYYY-WW: Team Board & Knowledge Digest`** issue with exact counts and tables. An AI agent may then post **one comment** on that digest issue using this exact structure:

```markdown
### 🤖 Agent Weekly Narrative Summary (`Week YYYY-WW`)
_Label: `agent-drafted` · Source: deterministic tables in issue body above_

1. **Throughput & Flow Highlights (≤ 3 bullets):**
   - Completed **N** cards in `area-a` / `area-b`; summarize the top 1–2 user-facing or operational outcomes (#issue links).
2. **Blocker & WIP Risks (≤ 3 bullets):**
   - Call out any card in `Blocked` ≥ 3 days (#issue, owner, blocker reason) or any assignee currently over the soft WIP limit (> 2 `Doing` cards).
3. **Second Brain & Knowledge Gaps (≤ 2 bullets):**
   - List `Done` cards whose `Learned:` notes are queued in `bot/inbox-capture`, plus any `Done` card still missing `Knowledge link`.
4. **Suggested Focus for Monday Stand-up (≤ 2 bullets):**
   - Recommend which unblock or review action should happen first on Monday morning *(recommendation only — humans assign and approve)*.
```
