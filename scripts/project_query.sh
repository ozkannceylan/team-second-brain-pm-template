#!/usr/bin/env bash
# scripts/project_query.sh
# Unified runtime engine invoked by .github/workflows/board-keeper.yml (and local CLI).
# Reads all field names, option names, thresholds, and label names from project/fields.yml.
#
# Performs in a single GraphQL fetch:
#   1. Guardrails & Blocked-since auto-stamping / clearing + incomplete-blocker prompts
#   2. Human-only 'Done' and 'Assignees' audit (comment + policy-violation label; optional auto_revert)
#   3. 'Learned:' / 'Decision:' comment extraction from Done cards into inbox/issue-N.md PR
#   4. Weekday morning aging & escalation alerts (Blocked >= 3d warn, >= 5d escalate, Doing stale >= 5d)
#   5. Friday 'Week YYYY-WW' digest issue update + embedded poll snapshot (zero commits to main!)
#
# Dependencies: bash, gh (GitHub CLI), jq, yq (mikefarah/yq v4, preinstalled on ubuntu-latest)
# Usage:
#   ./scripts/project_query.sh --mode all|guardrails|aging|learnings|digest|issue-event \
#     --org ORG --repo REPO --project-number 1 [--input-json FILE] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIELDS_FILE="${REPO_ROOT}/project/fields.yml"

MODE="all"
ORG_NAME="${ORG_NAME:-${GITHUB_REPOSITORY_OWNER:-ORG}}"
REPO_NAME="${REPO_NAME:-}"
if [[ -z "${REPO_NAME}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  REPO_NAME="${GITHUB_REPOSITORY##*/}"
fi
REPO_NAME="${REPO_NAME:-REPO}"
PROJECT_NUMBER="${PROJECT_NUMBER:-1}"
INPUT_JSON=""
DRY_RUN="${DRY_RUN:-false}"
TODAY_UTC="${TODAY_UTC:-$(date -u +%Y-%m-%d)}"
CURRENT_HOUR_UTC="${CURRENT_HOUR_UTC:-$(date -u +%H)}"
CURRENT_DOW_UTC="${CURRENT_DOW_UTC:-$(date -u +%u)}"
ISO_WEEK="${ISO_WEEK:-$(date -u +%G-W%V)}"

# Issue-event context (passed by board-keeper.yml when triggered by on: issues)
EVENT_ACTION="${EVENT_ACTION:-}"
EVENT_ACTOR="${EVENT_ACTOR:-}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
EVENT_LABEL="${EVENT_LABEL:-}"
EVENT_ASSIGNEE="${EVENT_ASSIGNEE:-}"

usage() {
  cat <<'EOF'
Usage: ./scripts/project_query.sh [OPTIONS]

Unified Projects v2 guardrail, blocker-timestamp, learning-collector, aging-alert,
and weekly-digest script reading configuration from project/fields.yml.

Options:
  --mode MODE             One of: all, guardrails, aging, learnings, digest, issue-event (default: all)
  --org ORG               GitHub organization login (default: $ORG_NAME)
  --repo REPO             Repository name (default: $REPO_NAME)
  --project-number N      Organization Project v2 number (default: $PROJECT_NUMBER or 1)
  --input-json FILE       Read project items from local JSON fixture instead of live GraphQL
  --dry-run               Log planned mutations/comments without calling write APIs
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --org)
      ORG_NAME="$2"
      shift 2
      ;;
    --repo)
      REPO_NAME="${2##*/}"
      shift 2
      ;;
    --project-number)
      PROJECT_NUMBER="$2"
      shift 2
      ;;
    --input-json)
      INPUT_JSON="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for cmd in yq jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required dependency '${cmd}' is not installed." >&2
    exit 1
  fi
done

if [[ ! -f "${FIELDS_FILE}" ]]; then
  echo "ERROR: Canonical config not found at ${FIELDS_FILE}" >&2
  exit 1
fi

# Load canonical field names, thresholds, and labels from project/fields.yml
STATUS_FIELD_NAME="$(yq -r '.status_field.name' "${FIELDS_FILE}")"
OPT_TODO="$(yq -r '.status_field.options[0].name' "${FIELDS_FILE}")"
OPT_DOING="$(yq -r '.status_field.options[1].name' "${FIELDS_FILE}")"
OPT_BLOCKED="$(yq -r '.status_field.options[2].name' "${FIELDS_FILE}")"
OPT_DONE="$(yq -r '.status_field.options[3].name' "${FIELDS_FILE}")"

FIELD_BLOCKED_SINCE="Blocked since"
FIELD_BLOCKED_REASON="Blocked reason"
FIELD_KNOWLEDGE_LINK="Knowledge link"

AUTO_REVERT_CFG="$(yq -r '.governance.auto_revert' "${FIELDS_FILE}")"
AUTO_REVERT="${AUTO_REVERT:-${AUTO_REVERT_CFG}}"
WARN_DAYS="$(yq -r '.governance.blocked_warn_days' "${FIELDS_FILE}")"
ESCALATE_DAYS="$(yq -r '.governance.blocked_escalate_days' "${FIELDS_FILE}")"
STALE_DAYS="$(yq -r '.governance.doing_stale_days' "${FIELDS_FILE}")"
COOLDOWN_DAYS="$(yq -r '.governance.alert_cooldown_days' "${FIELDS_FILE}")"
ESCALATION_MENTION="$(yq -r '.governance.escalation_mention' "${FIELDS_FILE}")"
INBOX_BRANCH="$(yq -r '.governance.inbox_capture_branch' "${FIELDS_FILE}")"
LEARNED_REGEX="$(yq -r '.governance.learned_comment_regex' "${FIELDS_FILE}")"

LBL_STATUS_BLOCKED="$(yq -r '.labels.status_blocked' "${FIELDS_FILE}")"
LBL_ESCALATED="$(yq -r '.labels.escalated' "${FIELDS_FILE}")"
LBL_POLICY_VIOLATION="$(yq -r '.labels.policy_violation' "${FIELDS_FILE}")"
LBL_AGENT_DRAFTED="$(yq -r '.labels.agent_drafted' "${FIELDS_FILE}")"

REPO_FULL="${ORG_NAME}/${REPO_NAME}"

is_bot_actor() {
  local actor="$1"
  if [[ -z "${actor}" || "${actor}" == "null" ]]; then
    return 1
  fi
  local lower_actor
  lower_actor="$(printf '%s' "${actor}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${lower_actor}" == *"[bot]" ]] || [[ "${lower_actor}" == *-bot ]] || [[ "${lower_actor}" == bot-* ]]; then
    return 0
  fi
  local count i pat pat_lower
  count="$(yq '.governance.bot_actor_patterns | length' "${FIELDS_FILE}")"
  for (( i=0; i<count; i++ )); do
    pat="$(yq -r ".governance.bot_actor_patterns[${i}]" "${FIELDS_FILE}")"
    pat_lower="$(printf '%s' "${pat}" | tr '[:upper:]' '[:lower:]')"
    # Treat '[' and ']' literally so "*[bot]" does not become a character class.
    pat_lower="${pat_lower//\[/\\[}"
    pat_lower="${pat_lower//\]/\\]}"
    # shellcheck disable=SC2053
    if [[ "${lower_actor}" == ${pat_lower} ]]; then
      return 0
    fi
  done
  return 1
}

days_between() {
  local start_date="$1"
  local end_date="$2"
  local s_epoch e_epoch
  s_epoch="$(date -u -d "${start_date}" +%s 2>/dev/null || echo 0)"
  e_epoch="$(date -u -d "${end_date}" +%s 2>/dev/null || echo 0)"
  if [[ "${s_epoch}" -eq 0 || "${e_epoch}" -eq 0 ]]; then
    echo 0
    return 0
  fi
  echo $(( (e_epoch - s_epoch) / 86400 ))
}

has_recent_marker() {
  local comments_json="$1"
  local marker_prefix="$2"
  local last_marker_date
  last_marker_date="$(printf '%s' "${comments_json}" | jq -r --arg p "${marker_prefix}" '
    [.[] | .body // "" | capture("<!-- " + $p + ":(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}) -->") | .d] | last // ""
  ')"
  if [[ -z "${last_marker_date}" ]]; then
    return 1
  fi
  local age
  age="$(days_between "${last_marker_date}" "${TODAY_UTC}")"
  if [[ "${age}" -lt "${COOLDOWN_DAYS}" ]]; then
    return 0
  fi
  return 1
}

post_issue_comment() {
  local num="$1"
  local body="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Comment on #${num}: $(printf '%s' "${body}" | head -n 1)"
  else
    gh issue comment "${num}" --repo "${REPO_FULL}" --body "${body}" >/dev/null
    sleep 1
  fi
}

add_issue_label() {
  local num="$1"
  local label="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Add label '${label}' on #${num}"
  else
    gh issue edit "${num}" --repo "${REPO_FULL}" --add-label "${label}" >/dev/null || true
    sleep 1
  fi
}

# ==============================================================================
# Fast Path: Real-Time Issue Event Handler (--mode issue-event)
# ==============================================================================
handle_issue_event() {
  echo "==> Handling issue-event: action='${EVENT_ACTION}' issue='#${ISSUE_NUMBER}' actor='${EVENT_ACTOR}' label='${EVENT_LABEL}'"
  if [[ -z "${ISSUE_NUMBER}" ]]; then
    echo "No ISSUE_NUMBER set; skipping issue-event handler."
    return 0
  fi

  # 1. Mobile shortcut: adding label 'status:blocked' triggers immediate Blocked status & date stamp
  if [[ "${EVENT_ACTION}" == "labeled" && "${EVENT_LABEL}" == "${LBL_STATUS_BLOCKED}" ]]; then
    echo "  -> Label '${LBL_STATUS_BLOCKED}' applied on #${ISSUE_NUMBER}; syncing Blocked status & '${FIELD_BLOCKED_SINCE}'=${TODAY_UTC}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[DRY-RUN] Set #${ISSUE_NUMBER} Status='${OPT_BLOCKED}' and '${FIELD_BLOCKED_SINCE}'='${TODAY_UTC}'"
      return 0
    fi
    # Fall through to poll mode so the single GraphQL helper stamps the card immediately
    MODE="guardrails"
    return 0
  fi

  # 2. Check if actor is a bot violating human-only Assignees or Issue Close rules
  if is_bot_actor "${EVENT_ACTOR}"; then
    if [[ "${EVENT_ACTION}" == "assigned" ]]; then
      echo "  ! POLICY VIOLATION: Bot actor '${EVENT_ACTOR}' assigned '${EVENT_ASSIGNEE}' on #${ISSUE_NUMBER}"
      add_issue_label "${ISSUE_NUMBER}" "${LBL_POLICY_VIOLATION}"
      local msg
      msg="⚠️ **Governance Audit (\`board-keeper\`):** Non-human actor \`@${EVENT_ACTOR}\` assigned \`@${EVENT_ASSIGNEE:-user}\` on #${ISSUE_NUMBER}. Per team rules, **only humans may assign owners** (\`Assignees\`)."
      if [[ "${AUTO_REVERT}" == "true" && -n "${EVENT_ASSIGNEE}" ]]; then
        msg="${msg} Automatically removing bot-added assignee (\`auto_revert: true\`)."
        if [[ "${DRY_RUN}" == "true" ]]; then
          echo "[DRY-RUN] gh issue edit ${ISSUE_NUMBER} --repo ${REPO_FULL} --remove-assignee ${EVENT_ASSIGNEE}"
        else
          gh issue edit "${ISSUE_NUMBER}" --repo "${REPO_FULL}" --remove-assignee "${EVENT_ASSIGNEE}" >/dev/null || true
        fi
      fi
      post_issue_comment "${ISSUE_NUMBER}" "${msg}"
    elif [[ "${EVENT_ACTION}" == "closed" ]]; then
      echo "  ! POLICY VIOLATION: Bot actor '${EVENT_ACTOR}' closed #${ISSUE_NUMBER}"
      add_issue_label "${ISSUE_NUMBER}" "${LBL_POLICY_VIOLATION}"
      local msg
      msg="⚠️ **Governance Audit (\`board-keeper\`):** Non-human actor \`@${EVENT_ACTOR}\` closed #${ISSUE_NUMBER}. Per team rules, **only humans may verify DoD and close issues or move cards to \`${OPT_DONE}\`**."
      if [[ "${AUTO_REVERT}" == "true" ]]; then
        msg="${msg} Automatically reopening issue (\`auto_revert: true\`)."
        if [[ "${DRY_RUN}" == "true" ]]; then
          echo "[DRY-RUN] gh issue reopen ${ISSUE_NUMBER} --repo ${REPO_FULL}"
        else
          gh issue reopen "${ISSUE_NUMBER}" --repo "${REPO_FULL}" >/dev/null || true
        fi
      fi
      post_issue_comment "${ISSUE_NUMBER}" "${msg}"
    fi
  fi
}

if [[ "${MODE}" == "issue-event" ]]; then
  handle_issue_event
  if [[ "${MODE}" == "issue-event" ]]; then
    exit 0
  fi
fi

# ==============================================================================
# Consolidated GraphQL Fetch (or --input-json fixture for offline testability)
# ==============================================================================
fetch_project_data() {
  if [[ -n "${INPUT_JSON}" ]]; then
    if [[ ! -f "${INPUT_JSON}" ]]; then
      echo "ERROR: Input JSON file not found: ${INPUT_JSON}" >&2
      exit 1
    fi
    cat "${INPUT_JSON}"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 'gh' CLI is required when --input-json is not provided." >&2
    exit 1
  fi

  # Single GraphQL query fetching project metadata, field IDs, and items + comments
  # shellcheck disable=SC2016
  gh api graphql \
    -f org="${ORG_NAME}" \
    -F num="${PROJECT_NUMBER}" \
    -f query='
      query($org: String!, $num: Int!) {
        organization(login: $org) {
          projectV2(number: $num) {
            id
            title
            fields(first: 30) {
              nodes {
                ... on ProjectV2Field {
                  id
                  name
                  dataType
                }
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  dataType
                  options {
                    id
                    name
                  }
                }
              }
            }
            items(first: 100) {
              nodes {
                id
                statusField: fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    optionId
                    updatedAt
                    creator {
                      login
                    }
                  }
                }
                priorityField: fieldValueByName(name: "Priority") {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                  }
                }
                areaField: fieldValueByName(name: "Area") {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                  }
                }
                blockedSinceField: fieldValueByName(name: "Blocked since") {
                  ... on ProjectV2ItemFieldDateValue {
                    date
                  }
                }
                blockedReasonField: fieldValueByName(name: "Blocked reason") {
                  ... on ProjectV2ItemFieldTextValue {
                    text
                  }
                }
                knowledgeLinkField: fieldValueByName(name: "Knowledge link") {
                  ... on ProjectV2ItemFieldTextValue {
                    text
                  }
                }
                content {
                  ... on Issue {
                    number
                    title
                    url
                    state
                    updatedAt
                    assignees(first: 10) {
                      nodes {
                        login
                      }
                    }
                    labels(first: 20) {
                      nodes {
                        name
                      }
                    }
                    comments(last: 20) {
                      nodes {
                        author {
                          login
                        }
                        body
                        createdAt
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }'
}

echo "==> Running board-keeper query (mode=${MODE}, org=${ORG_NAME}, repo=${REPO_NAME}, project=#${PROJECT_NUMBER}, dry_run=${DRY_RUN})..."
RAW_JSON="$(fetch_project_data)"

PROJECT_ID="$(printf '%s' "${RAW_JSON}" | jq -r '.data.organization.projectV2.id // empty')"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: Could not read Project #${PROJECT_NUMBER} in org '${ORG_NAME}'. Check APP_ID/APP_PRIVATE_KEY or PROJECT_PAT permissions." >&2
  exit 1
fi

STATUS_FIELD_ID="$(printf '%s' "${RAW_JSON}" | jq -r --arg n "${STATUS_FIELD_NAME}" '.data.organization.projectV2.fields.nodes[] | select(.name == $n) | .id' | head -n 1)"
DOING_OPTION_ID="$(printf '%s' "${RAW_JSON}" | jq -r --arg n "${STATUS_FIELD_NAME}" --arg o "${OPT_DOING}" '.data.organization.projectV2.fields.nodes[] | select(.name == $n) | .options[]? | select(.name == $o) | .id' | head -n 1)"
BLOCKED_OPTION_ID="$(printf '%s' "${RAW_JSON}" | jq -r --arg n "${STATUS_FIELD_NAME}" --arg o "${OPT_BLOCKED}" '.data.organization.projectV2.fields.nodes[] | select(.name == $n) | .options[]? | select(.name == $o) | .id' | head -n 1)"
BLOCKED_SINCE_FIELD_ID="$(printf '%s' "${RAW_JSON}" | jq -r --arg n "${FIELD_BLOCKED_SINCE}" '.data.organization.projectV2.fields.nodes[] | select(.name == $n) | .id' | head -n 1)"
KNOWLEDGE_LINK_FIELD_ID="$(printf '%s' "${RAW_JSON}" | jq -r --arg n "${FIELD_KNOWLEDGE_LINK}" '.data.organization.projectV2.fields.nodes[] | select(.name == $n) | .id' | head -n 1)"

set_date_field() {
  local item_id="$1"
  local field_id="$2"
  local date_val="$3"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Set date field (${field_id}) on item ${item_id} -> '${date_val}'"
  else
    # shellcheck disable=SC2016
    gh api graphql \
      -f projectId="${PROJECT_ID}" \
      -f itemId="${item_id}" \
      -f fieldId="${field_id}" \
      -f dateVal="${date_val}" \
      -f query='mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $dateVal: Date!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: { date: $dateVal }
        }) { projectV2Item { id } }
      }' >/dev/null
    sleep 1
  fi
}

clear_field_value() {
  local item_id="$1"
  local field_id="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Clear field (${field_id}) on item ${item_id}"
  else
    # shellcheck disable=SC2016
    gh api graphql \
      -f projectId="${PROJECT_ID}" \
      -f itemId="${item_id}" \
      -f fieldId="${field_id}" \
      -f query='mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!) {
        clearProjectV2ItemFieldValue(input: {
          projectId: $projectId, itemId: $itemId, fieldId: $fieldId
        }) { projectV2Item { id } }
      }' >/dev/null
    sleep 1
  fi
}

set_text_field() {
  local item_id="$1"
  local field_id="$2"
  local text_val="$3"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Set text field (${field_id}) on item ${item_id} -> '${text_val}'"
  else
    # shellcheck disable=SC2016
    gh api graphql \
      -f projectId="${PROJECT_ID}" \
      -f itemId="${item_id}" \
      -f fieldId="${field_id}" \
      -f textVal="${text_val}" \
      -f query='mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $textVal: String!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: { text: $textVal }
        }) { projectV2Item { id } }
      }' >/dev/null
    sleep 1
  fi
}

set_single_select_field() {
  local item_id="$1"
  local field_id="$2"
  local option_id="$3"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Set single-select field (${field_id}) on item ${item_id} -> option '${option_id}'"
  else
    # shellcheck disable=SC2016
    gh api graphql \
      -f projectId="${PROJECT_ID}" \
      -f itemId="${item_id}" \
      -f fieldId="${field_id}" \
      -f optionId="${option_id}" \
      -f query='mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: { singleSelectOptionId: $optionId }
        }) { projectV2Item { id } }
      }' >/dev/null
    sleep 1
  fi
}

# ==============================================================================
# Single-Pass Item Processing (Guardrails, Blocked-since, Learnings, Aging)
# ==============================================================================
ITEMS_COUNT="$(printf '%s' "${RAW_JSON}" | jq '.data.organization.projectV2.items.nodes | length')"
echo "==> Scanning ${ITEMS_COUNT} board item(s)..."

COUNT_TODO=0
COUNT_DOING=0
COUNT_BLOCKED=0
COUNT_DONE=0
COUNT_INCOMPLETE_BLOCKERS=0
COUNT_MISSING_KNOWLEDGE=0
COUNT_VIOLATIONS=0

DIGEST_DONE_ROWS=""
DIGEST_DOING_ROWS=""
DIGEST_BLOCKED_ROWS=""
DIGEST_ATTENTION_ROWS=""
SNAPSHOT_PAIRS=()
CAPTURED_NOTES=()

RUN_GUARDRAILS="false"
RUN_LEARNED="false"
RUN_AGING="false"
RUN_DIGEST="false"

case "${MODE}" in
  all)
    RUN_GUARDRAILS="true"
    RUN_LEARNED="true"
    if [[ "${CURRENT_HOUR_UTC}" == "08" || "${FORCE_AGING:-false}" == "true" ]]; then
      RUN_AGING="true"
    fi
    if [[ ( "${CURRENT_DOW_UTC}" == "5" && "${CURRENT_HOUR_UTC}" == "16" ) || "${FORCE_DIGEST:-false}" == "true" ]]; then
      RUN_DIGEST="true"
    fi
    ;;
  guardrails) RUN_GUARDRAILS="true" ;;
  learnings)  RUN_LEARNED="true" ;;
  aging)      RUN_AGING="true" ;;
  digest)     RUN_DIGEST="true" ;;
  *)
    echo "ERROR: Unsupported --mode '${MODE}'" >&2
    exit 1
    ;;
esac

for (( idx=0; idx<ITEMS_COUNT; idx++ )); do
  ITEM_JSON="$(printf '%s' "${RAW_JSON}" | jq -c ".data.organization.projectV2.items.nodes[${idx}]")"
  ITEM_ID="$(printf '%s' "${ITEM_JSON}" | jq -r '.id')"
  ISSUE_NUM="$(printf '%s' "${ITEM_JSON}" | jq -r '.content.number // empty')"
  if [[ -z "${ISSUE_NUM}" ]]; then
    continue
  fi

  TITLE="$(printf '%s' "${ITEM_JSON}" | jq -r '.content.title // ""')"
  ISSUE_URL="$(printf '%s' "${ITEM_JSON}" | jq -r '.content.url // ""')"
  UPDATED_AT="$(printf '%s' "${ITEM_JSON}" | jq -r '.content.updatedAt // ""' | cut -c1-10)"
  STATUS="$(printf '%s' "${ITEM_JSON}" | jq -r '.statusField.name // "Todo"')"
  STATUS_CREATOR="$(printf '%s' "${ITEM_JSON}" | jq -r '.statusField.creator.login // ""')"
  PRIORITY="$(printf '%s' "${ITEM_JSON}" | jq -r '.priorityField.name // "P1"')"
  AREA="$(printf '%s' "${ITEM_JSON}" | jq -r '.areaField.name // "area-a"')"
  BLOCKED_SINCE="$(printf '%s' "${ITEM_JSON}" | jq -r '.blockedSinceField.date // ""')"
  BLOCKED_REASON="$(printf '%s' "${ITEM_JSON}" | jq -r '.blockedReasonField.text // ""')"
  KNOWLEDGE_LINK="$(printf '%s' "${ITEM_JSON}" | jq -r '.knowledgeLinkField.text // ""')"
  ASSIGNEES_CSV="$(printf '%s' "${ITEM_JSON}" | jq -r '[.content.assignees.nodes[]?.login | "@" + .] | join(", ")')"
  LABELS_JSON="$(printf '%s' "${ITEM_JSON}" | jq -c '[.content.labels.nodes[]?.name]')"
  COMMENTS_JSON="$(printf '%s' "${ITEM_JSON}" | jq -c '.content.comments.nodes // []')"

  SNAPSHOT_PAIRS+=("\"${ISSUE_NUM}\":\"${STATUS}\"")

  # Check if label 'status:blocked' is present while card is not yet in Blocked
  HAS_BLOCKED_LABEL="$(printf '%s' "${LABELS_JSON}" | jq --arg l "${LBL_STATUS_BLOCKED}" 'index($l) != null')"
  if [[ "${RUN_GUARDRAILS}" == "true" && "${HAS_BLOCKED_LABEL}" == "true" && "${STATUS}" != "${OPT_BLOCKED}" && "${STATUS}" != "${OPT_DONE}" ]]; then
    echo "  -> #${ISSUE_NUM} has label '${LBL_STATUS_BLOCKED}'; moving Status to '${OPT_BLOCKED}'"
    if [[ -n "${STATUS_FIELD_ID}" && -n "${BLOCKED_OPTION_ID}" ]]; then
      set_single_select_field "${ITEM_ID}" "${STATUS_FIELD_ID}" "${BLOCKED_OPTION_ID}"
      STATUS="${OPT_BLOCKED}"
    fi
  fi

  # 1. Blocked-since stamping & clearing + incomplete blocker check
  if [[ "${STATUS}" == "${OPT_BLOCKED}" ]]; then
    COUNT_BLOCKED=$((COUNT_BLOCKED + 1))
    if [[ "${RUN_GUARDRAILS}" == "true" && -z "${BLOCKED_SINCE}" ]]; then
      echo "  -> #${ISSUE_NUM} is Blocked with empty '${FIELD_BLOCKED_SINCE}'; stamping ${TODAY_UTC}"
      if [[ -n "${BLOCKED_SINCE_FIELD_ID}" ]]; then
        set_date_field "${ITEM_ID}" "${BLOCKED_SINCE_FIELD_ID}" "${TODAY_UTC}"
      fi
      BLOCKED_SINCE="${TODAY_UTC}"
    fi

    if [[ -z "${ASSIGNEES_CSV}" || -z "${BLOCKED_REASON}" ]]; then
      COUNT_INCOMPLETE_BLOCKERS=$((COUNT_INCOMPLETE_BLOCKERS + 1))
      DIGEST_ATTENTION_ROWS="${DIGEST_ATTENTION_ROWS}| #${ISSUE_NUM} ${TITLE} | \`${OPT_BLOCKED}\` | ${ASSIGNEES_CSV:-_unassigned_} | Missing owner or \`Blocked reason\` |\n"
      if [[ "${RUN_GUARDRAILS}" == "true" ]] && ! has_recent_marker "${COMMENTS_JSON}" "board-keeper:incomplete-blocker"; then
        PROMPT_BODY="⚠️ **Blocker Hygiene Check (\`board-keeper\`):** Card #${ISSUE_NUM} is in **\`${OPT_BLOCKED}\`** (since \`${BLOCKED_SINCE:-${TODAY_UTC}}\`), but is missing a human **Assignee** or **\`${FIELD_BLOCKED_REASON}\`**. Please assign the person driving the unblock and fill \`${FIELD_BLOCKED_REASON}\` before stand-up.
<!-- board-keeper:incomplete-blocker:${TODAY_UTC} -->"
        post_issue_comment "${ISSUE_NUM}" "${PROMPT_BODY}"
      fi
    fi
    DIGEST_BLOCKED_ROWS="${DIGEST_BLOCKED_ROWS}| #${ISSUE_NUM} ${TITLE} | ${ASSIGNEES_CSV:-_unassigned_} | \`${BLOCKED_SINCE:-${TODAY_UTC}}\` | ${BLOCKED_REASON:-_missing_} |\n"
  else
    # Clear Blocked since when leaving Blocked
    if [[ "${RUN_GUARDRAILS}" == "true" && -n "${BLOCKED_SINCE}" ]]; then
      echo "  -> #${ISSUE_NUM} left Blocked (now '${STATUS}'); clearing '${FIELD_BLOCKED_SINCE}'"
      if [[ -n "${BLOCKED_SINCE_FIELD_ID}" ]]; then
        clear_field_value "${ITEM_ID}" "${BLOCKED_SINCE_FIELD_ID}"
      fi
      BLOCKED_SINCE=""
    fi
  fi

  # 2. Count & audit Doing / Todo / Done
  if [[ "${STATUS}" == "${OPT_TODO}" ]]; then
    COUNT_TODO=$((COUNT_TODO + 1))
  elif [[ "${STATUS}" == "${OPT_DOING}" ]]; then
    COUNT_DOING=$((COUNT_DOING + 1))
    DIGEST_DOING_ROWS="${DIGEST_DOING_ROWS}| #${ISSUE_NUM} ${TITLE} | ${ASSIGNEES_CSV:-_unassigned_} | \`${PRIORITY}\` | \`${AREA}\` |\n"
    if [[ -z "${ASSIGNEES_CSV}" ]]; then
      DIGEST_ATTENTION_ROWS="${DIGEST_ATTENTION_ROWS}| #${ISSUE_NUM} ${TITLE} | \`${OPT_DOING}\` | _unassigned_ | In \`Doing\` without a human Assignee |\n"
    fi
  elif [[ "${STATUS}" == "${OPT_DONE}" ]]; then
    COUNT_DONE=$((COUNT_DONE + 1))

    # 2a. Audit human-only Done transition
    if [[ "${RUN_GUARDRAILS}" == "true" ]] && is_bot_actor "${STATUS_CREATOR}"; then
      COUNT_VIOLATIONS=$((COUNT_VIOLATIONS + 1))
      echo "  ! POLICY VIOLATION: Card #${ISSUE_NUM} moved to '${OPT_DONE}' by bot actor '${STATUS_CREATOR}'"
      add_issue_label "${ISSUE_NUM}" "${LBL_POLICY_VIOLATION}"
      DIGEST_ATTENTION_ROWS="${DIGEST_ATTENTION_ROWS}| #${ISSUE_NUM} ${TITLE} | \`${OPT_DONE}\` | \`@${STATUS_CREATOR}\` | Bot moved card to \`Done\` (\`${LBL_POLICY_VIOLATION}\`) |\n"
      if ! has_recent_marker "${COMMENTS_JSON}" "board-keeper:done-violation"; then
        VIOLATION_MSG="⚠️ **Governance Audit (\`board-keeper\`):** Card #${ISSUE_NUM} was moved to **\`${OPT_DONE}\`** by non-human actor \`@${STATUS_CREATOR}\`. Per team rules, **only humans may move cards to \`${OPT_DONE}\`** after verifying Definition of Done.
<!-- board-keeper:done-violation:${TODAY_UTC} -->"
        if [[ "${AUTO_REVERT}" == "true" && -n "${STATUS_FIELD_ID}" && -n "${DOING_OPTION_ID}" ]]; then
          VIOLATION_MSG="${VIOLATION_MSG}
Automatically reverting Status back to **\`${OPT_DOING}\`** (\`auto_revert: true\`)."
          set_single_select_field "${ITEM_ID}" "${STATUS_FIELD_ID}" "${DOING_OPTION_ID}"
        fi
        post_issue_comment "${ISSUE_NUM}" "${VIOLATION_MSG}"
      fi
    fi

    # 2b. Extract 'Learned:' / 'Decision:' comments into inbox/issue-N.md when Knowledge link is empty
    if [[ "${RUN_LEARNED}" == "true" && ( -z "${KNOWLEDGE_LINK}" || "${KNOWLEDGE_LINK}" == "inbox" ) ]]; then
      LEARNED_ENTRY="$(printf '%s' "${COMMENTS_JSON}" | jq -r --arg re "${LEARNED_REGEX}" '
        [.[] | select((.body // "") | test($re; "m"))] | last // empty |
        if . != null then "\(.author.login // "team")|\(.createdAt // "")|\(.body)" else "" end
      ')"
      if [[ -n "${LEARNED_ENTRY}" ]]; then
        L_AUTHOR="${LEARNED_ENTRY%%|*}"
        REST="${LEARNED_ENTRY#*|}"
        L_DATE="${REST%%|*}"
        L_BODY="${REST#*|}"
        INBOX_REL_PATH="inbox/issue-${ISSUE_NUM}.md"
        INBOX_ABS_PATH="${REPO_ROOT}/${INBOX_REL_PATH}"

        echo "  -> Extracting 'Learned:' comment from #${ISSUE_NUM} (by @${L_AUTHOR}) -> ${INBOX_REL_PATH}"
        NOTE_CONTENT="# Inbox Note: Issue #${ISSUE_NUM} — ${TITLE}

- **Date:** ${L_DATE:0:10}
- **Author:** @${L_AUTHOR}
- **Related Card:** ${ISSUE_URL:-https://github.com/${REPO_FULL}/issues/${ISSUE_NUM}}
- **Area:** \`${AREA}\`

## Captured Learning / Decision

${L_BODY}
"
        if [[ "${DRY_RUN}" == "true" ]]; then
          echo "[DRY-RUN] Write ${INBOX_REL_PATH} and set #${ISSUE_NUM} '${FIELD_KNOWLEDGE_LINK}'='${INBOX_REL_PATH}'"
        else
          mkdir -p "$(dirname "${INBOX_ABS_PATH}")"
          printf '%s' "${NOTE_CONTENT}" > "${INBOX_ABS_PATH}"
          if [[ -n "${KNOWLEDGE_LINK_FIELD_ID}" ]]; then
            set_text_field "${ITEM_ID}" "${KNOWLEDGE_LINK_FIELD_ID}" "${INBOX_REL_PATH}"
          fi
        fi
        KNOWLEDGE_LINK="${INBOX_REL_PATH}"
        CAPTURED_NOTES+=("${INBOX_REL_PATH}")
      fi
    fi

    if [[ -z "${KNOWLEDGE_LINK}" ]]; then
      COUNT_MISSING_KNOWLEDGE=$((COUNT_MISSING_KNOWLEDGE + 1))
      DIGEST_ATTENTION_ROWS="${DIGEST_ATTENTION_ROWS}| #${ISSUE_NUM} ${TITLE} | \`${OPT_DONE}\` | ${ASSIGNEES_CSV:-_unassigned_} | Missing \`Knowledge link\` or \`Learned:\` comment |\n"
    fi
    DIGEST_DONE_ROWS="${DIGEST_DONE_ROWS}| #${ISSUE_NUM} ${TITLE} | ${ASSIGNEES_CSV:-_unassigned_} | \`${KNOWLEDGE_LINK:-_missing_}\` |\n"
  fi

  # 3. Morning Aging & Stale Alerts (--mode aging or 08:00 UTC window)
  if [[ "${RUN_AGING}" == "true" ]]; then
    if [[ "${STATUS}" == "${OPT_BLOCKED}" && -n "${BLOCKED_SINCE}" ]]; then
      BLOCKED_AGE="$(days_between "${BLOCKED_SINCE}" "${TODAY_UTC}")"
      if [[ "${BLOCKED_AGE}" -ge "${ESCALATE_DAYS}" ]]; then
        echo "  -> #${ISSUE_NUM} Blocked for ${BLOCKED_AGE}d (>= ${ESCALATE_DAYS}d); escalating"
        add_issue_label "${ISSUE_NUM}" "${LBL_ESCALATED}"
        if ! has_recent_marker "${COMMENTS_JSON}" "board-keeper:alert"; then
          ESC_BODY="🚨 **Blocker Escalation (\`board-keeper\`):** #${ISSUE_NUM} has been **\`${OPT_BLOCKED}\`** for **${BLOCKED_AGE} days** (since \`${BLOCKED_SINCE}\`).
- **Owner:** ${ASSIGNEES_CSV:-_unassigned_}
- **Reason:** ${BLOCKED_REASON:-_not specified_}
- **Escalation:** Looping in ${ESCALATION_MENTION} to help unblock, descope, or reassign today.
<!-- board-keeper:alert:${TODAY_UTC} -->"
          post_issue_comment "${ISSUE_NUM}" "${ESC_BODY}"
        fi
      elif [[ "${BLOCKED_AGE}" -ge "${WARN_DAYS}" ]]; then
        echo "  -> #${ISSUE_NUM} Blocked for ${BLOCKED_AGE}d (>= ${WARN_DAYS}d); posting check-in"
        if ! has_recent_marker "${COMMENTS_JSON}" "board-keeper:alert"; then
          WARN_BODY="⏳ **Blocker Check-in (\`board-keeper\`):** #${ISSUE_NUM} has been **\`${OPT_BLOCKED}\`** for **${BLOCKED_AGE} days** (since \`${BLOCKED_SINCE}\`). ${ASSIGNEES_CSV:-Team}: do we have what we need to unblock this before Day ${ESCALATE_DAYS} escalation?
<!-- board-keeper:alert:${TODAY_UTC} -->"
          post_issue_comment "${ISSUE_NUM}" "${WARN_BODY}"
        fi
      fi
    elif [[ "${STATUS}" == "${OPT_DOING}" && -n "${UPDATED_AT}" ]]; then
      DOING_AGE="$(days_between "${UPDATED_AT}" "${TODAY_UTC}")"
      if [[ "${DOING_AGE}" -ge "${STALE_DAYS}" ]]; then
        echo "  -> #${ISSUE_NUM} in Doing with no update for ${DOING_AGE}d (>= ${STALE_DAYS}d)"
        if ! has_recent_marker "${COMMENTS_JSON}" "board-keeper:alert"; then
          STALE_BODY="👋 **Stale \`${OPT_DOING}\` Check-in (\`board-keeper\`):** #${ISSUE_NUM} has had no issue update for **${DOING_AGE} days**. Is it still actively in progress, blocked, or ready to return to \`${OPT_TODO}\`?
<!-- board-keeper:alert:${TODAY_UTC} -->"
          post_issue_comment "${ISSUE_NUM}" "${STALE_BODY}"
        fi
      fi
    fi
  fi
done

# ==============================================================================
# Sync Extracted 'Learned:' Notes to Single Consolidated PR (bot/inbox-capture)
# Uses GitHub REST API via gh api (zero local git commands required!)
# ==============================================================================
if [[ "${#CAPTURED_NOTES[@]}" -gt 0 ]]; then
  echo "==> ${#CAPTURED_NOTES[@]} note(s) captured for branch '${INBOX_BRANCH}': ${CAPTURED_NOTES[*]}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Upload ${CAPTURED_NOTES[*]} to branch '${INBOX_BRANCH}' via Contents API and create/update PR to main"
  else
    DEFAULT_BRANCH="$(gh api "/repos/${REPO_FULL}" --jq '.default_branch')"
    BASE_SHA="$(gh api "/repos/${REPO_FULL}/git/ref/heads/${DEFAULT_BRANCH}" --jq '.object.sha')"

    # Create branch ref if it does not exist yet
    if ! gh api "/repos/${REPO_FULL}/git/ref/heads/${INBOX_BRANCH}" >/dev/null 2>&1; then
      gh api --method POST "/repos/${REPO_FULL}/git/refs" \
        -f ref="refs/heads/${INBOX_BRANCH}" \
        -f sha="${BASE_SHA}" >/dev/null
    fi

    for rel_path in "${CAPTURED_NOTES[@]}"; do
      CONTENT_B64="$(base64 -w 0 < "${REPO_ROOT}/${rel_path}" 2>/dev/null || base64 < "${REPO_ROOT}/${rel_path}" | tr -d '\n')"
      EXISTING_FILE_SHA="$(gh api "/repos/${REPO_FULL}/contents/${rel_path}?ref=${INBOX_BRANCH}" --jq '.sha' 2>/dev/null || echo "")"
      if [[ -n "${EXISTING_FILE_SHA}" ]]; then
        gh api --method PUT "/repos/${REPO_FULL}/contents/${rel_path}" \
          -f message="docs(inbox): capture learning from ${rel_path}" \
          -f content="${CONTENT_B64}" \
          -f branch="${INBOX_BRANCH}" \
          -f sha="${EXISTING_FILE_SHA}" >/dev/null
      else
        gh api --method PUT "/repos/${REPO_FULL}/contents/${rel_path}" \
          -f message="docs(inbox): capture learning from ${rel_path}" \
          -f content="${CONTENT_B64}" \
          -f branch="${INBOX_BRANCH}" >/dev/null
      fi
    done

    EXISTING_PR_NUM="$(gh pr list --repo "${REPO_FULL}" --head "${INBOX_BRANCH}" --state open --json number --jq '.[0].number // empty')"
    if [[ -z "${EXISTING_PR_NUM}" ]]; then
      gh pr create --repo "${REPO_FULL}" \
        --head "${INBOX_BRANCH}" \
        --base "${DEFAULT_BRANCH}" \
        --title "🧠 Second Brain Inbox Capture (${TODAY_UTC})" \
        --body "Automated collection of \`Learned:\` / \`Decision:\` comments from newly \`Done\` board cards. Knowledge writer (\`Alex\`): fold into \`knowledge/\` or \`decisions/\` and merge." >/dev/null
    fi
  fi
fi

# ==============================================================================
# Weekly Digest Issue & Embedded Poll State Snapshot (Zero commits to main!)
# ==============================================================================
SNAPSHOT_JSON="{$(IFS=,; echo "${SNAPSHOT_PAIRS[*]:-}")}"
DIGEST_TITLE="Week ${ISO_WEEK}: Team Board & Knowledge Digest"

DIGEST_BODY="$(cat <<EOF
# 📊 ${DIGEST_TITLE}

_Updated automatically by \`board-keeper.yml\` on \`${TODAY_UTC}\` (0 LLM tokens used; AI agents labeled \`${LBL_AGENT_DRAFTED}\` may append a narrative comment below)._

## 1. Pilot & Board Health Scorecard
| Metric | Current Value | Target |
|---|---|---|
| **Cards in \`${OPT_TODO}\` / \`${OPT_DOING}\` / \`${OPT_BLOCKED}\` / \`${OPT_DONE}\`** | \`${COUNT_TODO}\` / \`${COUNT_DOING}\` / \`${COUNT_BLOCKED}\` / \`${COUNT_DONE}\` | \`${OPT_DOING}\` <= 2 per person |
| **M2: Incomplete \`${OPT_BLOCKED}\` cards (missing Assignee or Reason)** | **\`${COUNT_INCOMPLETE_BLOCKERS}\`** | \`0\` |
| **M4: \`${OPT_DONE}\` cards missing \`${FIELD_KNOWLEDGE_LINK}\`** | **\`${COUNT_MISSING_KNOWLEDGE}\`** | \`0\` |
| **M5: Bot policy violations detected** | **\`${COUNT_VIOLATIONS}\`** | \`0\` |

## 2. Current Blockers (\`${OPT_BLOCKED}\`)
| Card | Assignee | Blocked Since | Blocked Reason |
|---|---|---|---|
$(printf '%b' "${DIGEST_BLOCKED_ROWS:-"| _None_ | - | - | - |\n"}")

## 3. Work in Progress (\`${OPT_DOING}\`)
| Card | Assignee | Priority | Area |
|---|---|---|---|
$(printf '%b' "${DIGEST_DOING_ROWS:-"| _None_ | - | - | - |\n"}")

## 4. Completed (\`${OPT_DONE}\`) & Second Brain Links
| Card | Assignee | Knowledge Link |
|---|---|---|---|
$(printf '%b' "${DIGEST_DONE_ROWS:-"| _None_ | - | - | - |\n"}")

## 5. Needs Attention (Hygiene & Governance Exceptions)
| Card | Status | Actor / Assignee | Issue |
|---|---|---|---|
$(printf '%b' "${DIGEST_ATTENTION_ROWS:-"| _None — 0 exceptions!_ | - | - | - |\n"}")

<!-- board-keeper:snapshot:${SNAPSHOT_JSON} -->
EOF
)"

if [[ "${RUN_DIGEST}" == "true" || "${COUNT_VIOLATIONS}" -gt 0 ]]; then
  echo "==> Updating weekly digest issue '${DIGEST_TITLE}' (with embedded poll snapshot)..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Create or update issue '${DIGEST_TITLE}':"
    echo "  Summary: Todo=${COUNT_TODO}, Doing=${COUNT_DOING}, Blocked=${COUNT_BLOCKED} (incomplete=${COUNT_INCOMPLETE_BLOCKERS}), Done=${COUNT_DONE} (missing_knowledge=${COUNT_MISSING_KNOWLEDGE}), violations=${COUNT_VIOLATIONS}"
  else
    EXISTING_DIGEST_NUM="$(gh issue list --repo "${REPO_FULL}" --state open --search "\"${DIGEST_TITLE}\" in:title" --json number --jq '.[0].number // empty')"
    if [[ -n "${EXISTING_DIGEST_NUM}" ]]; then
      gh issue edit "${EXISTING_DIGEST_NUM}" --repo "${REPO_FULL}" --body "${DIGEST_BODY}" >/dev/null
      echo "  ✓ Updated digest issue #${EXISTING_DIGEST_NUM}"
    else
      NEW_URL="$(gh issue create --repo "${REPO_FULL}" --title "${DIGEST_TITLE}" --body "${DIGEST_BODY}")"
      echo "  ✓ Created digest issue: ${NEW_URL}"
    fi
  fi
else
  echo "==> Summary: Todo=${COUNT_TODO}, Doing=${COUNT_DOING}, Blocked=${COUNT_BLOCKED} (incomplete=${COUNT_INCOMPLETE_BLOCKERS}), Done=${COUNT_DONE} (missing_knowledge=${COUNT_MISSING_KNOWLEDGE}), violations=${COUNT_VIOLATIONS}"
fi
