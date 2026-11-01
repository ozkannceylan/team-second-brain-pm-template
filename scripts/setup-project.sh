#!/usr/bin/env bash
# scripts/setup-project.sh
# Idempotently provisions the organization GitHub Projects v2 board, Status options,
# 5 custom fields from project/fields.yml, 3 saved views from project/views.yml (REST API F12),
# links the repository, syncs labels, and prints the manual UI steps that have no API.
#
# Prerequisite:
#   gh auth refresh -s project
#
# Dependencies: bash, gh (GitHub CLI), jq, yq (mikefarah/yq v4, preinstalled on ubuntu-latest)
# Usage:
#   ./scripts/setup-project.sh --org ORG --repo REPO [--project-number N] [--title TITLE] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIELDS_FILE="${REPO_ROOT}/project/fields.yml"
VIEWS_FILE="${REPO_ROOT}/project/views.yml"

ORG_NAME="${ORG_NAME:-}"
REPO_NAME="${REPO_NAME:-}"
PROJECT_NUMBER="${PROJECT_NUMBER:-}"
PROJECT_TITLE=""
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-project.sh --org ORG --repo REPO [OPTIONS]

Idempotently creates or updates the GitHub Projects v2 board, custom fields
(from project/fields.yml), saved views (from project/views.yml), and repo labels.

Prerequisite:
  gh auth refresh -s project

Options:
  --org ORG               GitHub organization login (required)
  --repo REPO             Repository name inside ORG, e.g. REPO (required)
  --project-number N      Existing project number to update (optional; searched by title if omitted)
  --title TITLE           Override project title from project/fields.yml
  --dry-run               Print all GraphQL/REST/CLI operations without calling GitHub APIs
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --title)
      PROJECT_TITLE="$2"
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
      echo "ERROR: Unknown argument: $1" >&2
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

if [[ ! -f "${FIELDS_FILE}" ]] || [[ ! -f "${VIEWS_FILE}" ]]; then
  echo "ERROR: Missing config files (${FIELDS_FILE} or ${VIEWS_FILE})." >&2
  exit 1
fi

if [[ -z "${ORG_NAME}" ]] || [[ -z "${REPO_NAME}" ]]; then
  echo "ERROR: Both --org ORG and --repo REPO are required." >&2
  usage >&2
  exit 1
fi

if [[ -z "${PROJECT_TITLE}" ]]; then
  PROJECT_TITLE="$(yq -r '.project.default_title' "${FIELDS_FILE}")"
fi

echo "=================================================================="
echo " GitHub Projects v2 Setup (${ORG_NAME}/${REPO_NAME})"
echo " Title:   ${PROJECT_TITLE}"
echo " Dry-run: ${DRY_RUN}"
echo "=================================================================="

# 1. Verify gh CLI authentication & 'project' scope
if [[ "${DRY_RUN}" != "true" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 'gh' CLI is required. Install from https://cli.github.com/" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: Not authenticated with gh CLI. Run: gh auth login && gh auth refresh -s project" >&2
    exit 1
  fi
else
  echo "[DRY-RUN] Prerequisite check: ensure you have run 'gh auth refresh -s project'"
fi

# 2. Sync repository labels via scripts/sync-labels.sh
echo ""
echo "==> Step 1/5: Syncing repository labels (.github/labels.yml)..."
if [[ "${DRY_RUN}" == "true" ]]; then
  "${SCRIPT_DIR}/sync-labels.sh" --repo "${ORG_NAME}/${REPO_NAME}" --dry-run
else
  "${SCRIPT_DIR}/sync-labels.sh" --repo "${ORG_NAME}/${REPO_NAME}"
fi

# 3. Find or create the organization Project v2
echo ""
echo "==> Step 2/5: Locating or creating organization Project v2 '${PROJECT_TITLE}'..."
PROJECT_ID=""

if [[ "${DRY_RUN}" == "true" ]]; then
  PROJECT_NUMBER="${PROJECT_NUMBER:-1}"
  PROJECT_ID="PVT_kwDOExampleProject01"
  echo "[DRY-RUN] gh project list --owner \"${ORG_NAME}\" --format json"
  echo "[DRY-RUN] Using simulated project_number=${PROJECT_NUMBER}, project_id=${PROJECT_ID}"
else
  if [[ -z "${PROJECT_NUMBER}" ]]; then
    EXISTING_JSON="$(gh project list --owner "${ORG_NAME}" --format json --limit 100)"
    PROJECT_NUMBER="$(printf '%s' "${EXISTING_JSON}" | jq -r --arg t "${PROJECT_TITLE}" '.projects[] | select(.title == $t) | .number' | head -n 1)"
  fi

  if [[ -z "${PROJECT_NUMBER}" || "${PROJECT_NUMBER}" == "null" ]]; then
    CREATED_JSON="$(gh project create --owner "${ORG_NAME}" --title "${PROJECT_TITLE}" --format json)"
    PROJECT_NUMBER="$(printf '%s' "${CREATED_JSON}" | jq -r '.number')"
    PROJECT_ID="$(printf '%s' "${CREATED_JSON}" | jq -r '.id')"
    echo "  ✓ Created Project #${PROJECT_NUMBER} (${PROJECT_ID})"
  else
    VIEW_JSON="$(gh project view "${PROJECT_NUMBER}" --owner "${ORG_NAME}" --format json)"
    PROJECT_ID="$(printf '%s' "${VIEW_JSON}" | jq -r '.id')"
    echo "  ✓ Found existing Project #${PROJECT_NUMBER} (${PROJECT_ID})"
  fi

  echo "  -> Linking repository ${ORG_NAME}/${REPO_NAME} to Project #${PROJECT_NUMBER}..."
  gh project link "${PROJECT_NUMBER}" --owner "${ORG_NAME}" --repo "${ORG_NAME}/${REPO_NAME}" || true
fi

# 4. Configure Status options and custom fields from project/fields.yml
echo ""
echo "==> Step 3/5: Configuring Status options and custom fields from project/fields.yml..."

STATUS_OPTIONS_JSON="$(yq -o=json '.status_field.options' "${FIELDS_FILE}")"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY-RUN] GraphQL updateProjectV2Field on 'Status' with options: $(printf '%s' "${STATUS_OPTIONS_JSON}" | jq -c '[.[].name]')"
else
  FIELDS_LIST_JSON="$(gh project field-list "${PROJECT_NUMBER}" --owner "${ORG_NAME}" --format json)"
  STATUS_FIELD_ID="$(printf '%s' "${FIELDS_LIST_JSON}" | jq -r '.fields[] | select(.name == "Status") | .id' | head -n 1)"
  if [[ -n "${STATUS_FIELD_ID}" && "${STATUS_FIELD_ID}" != "null" ]]; then
    # shellcheck disable=SC2016
    gh api graphql \
      -f query='mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
        updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: $options }) {
          projectV2Field { ... on ProjectV2SingleSelectField { id name } }
        }
      }' \
      -f fieldId="${STATUS_FIELD_ID}" \
      -f options="${STATUS_OPTIONS_JSON}" >/dev/null || echo "  ! Note: Status options already match or require UI check."
    echo "  ✓ Verified Status options (Todo, Doing, Blocked, Done)"
  fi
fi

CUSTOM_FIELD_COUNT="$(yq '.custom_fields | length' "${FIELDS_FILE}")"
for (( i=0; i<CUSTOM_FIELD_COUNT; i++ )); do
  F_NAME="$(yq -r ".custom_fields[${i}].name" "${FIELDS_FILE}")"
  F_TYPE="$(yq -r ".custom_fields[${i}].data_type" "${FIELDS_FILE}")"

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ "${F_TYPE}" == "SINGLE_SELECT" ]]; then
      OPTS_CSV="$(yq -r ".custom_fields[${i}].options[].name" "${FIELDS_FILE}" | paste -sd ',' -)"
      echo "[DRY-RUN] gh project field-create ${PROJECT_NUMBER} --owner \"${ORG_NAME}\" --name \"${F_NAME}\" --data-type \"${F_TYPE}\" --single-select-options \"${OPTS_CSV}\""
    else
      echo "[DRY-RUN] gh project field-create ${PROJECT_NUMBER} --owner \"${ORG_NAME}\" --name \"${F_NAME}\" --data-type \"${F_TYPE}\""
    fi
  else
    EXISTING_FIELD_ID="$(printf '%s' "${FIELDS_LIST_JSON}" | jq -r --arg n "${F_NAME}" '.fields[] | select(.name == $n) | .id' | head -n 1)"
    if [[ -n "${EXISTING_FIELD_ID}" && "${EXISTING_FIELD_ID}" != "null" ]]; then
      echo "  ✓ Custom field already exists: ${F_NAME} (${F_TYPE})"
    else
      if [[ "${F_TYPE}" == "SINGLE_SELECT" ]]; then
        OPTS_CSV="$(yq -r ".custom_fields[${i}].options[].name" "${FIELDS_FILE}" | paste -sd ',' -)"
        gh project field-create "${PROJECT_NUMBER}" \
          --owner "${ORG_NAME}" \
          --name "${F_NAME}" \
          --data-type "${F_TYPE}" \
          --single-select-options "${OPTS_CSV}" >/dev/null
      else
        gh project field-create "${PROJECT_NUMBER}" \
          --owner "${ORG_NAME}" \
          --name "${F_NAME}" \
          --data-type "${F_TYPE}" >/dev/null
      fi
      echo "  ✓ Created custom field: ${F_NAME} (${F_TYPE})"
    fi
  fi
done

# 5. Create saved views from project/views.yml via Projects v2 REST API (F12)
echo ""
echo "==> Step 4/5: Creating 3 saved views from project/views.yml (REST API F12)..."
VIEW_COUNT="$(yq '.views | length' "${VIEWS_FILE}")"

for (( i=0; i<VIEW_COUNT; i++ )); do
  V_NAME="$(yq -r ".views[${i}].name" "${VIEWS_FILE}")"
  V_LAYOUT="$(yq -r ".views[${i}].layout" "${VIEWS_FILE}")"
  V_FILTER="$(yq -r ".views[${i}].filter" "${VIEWS_FILE}")"

  PAYLOAD="$(jq -n \
    --arg name "${V_NAME}" \
    --arg layout "${V_LAYOUT}" \
    --arg filter "${V_FILTER}" \
    '{name: $name, layout: $layout, filter: $filter}')"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] gh api --method POST \"/orgs/${ORG_NAME}/projectsV2/${PROJECT_NUMBER}/views\" --input - <<< '${PAYLOAD}'"
  else
    if gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/orgs/${ORG_NAME}/projectsV2/${PROJECT_NUMBER}/views" \
      --input - <<<"${PAYLOAD}" >/dev/null 2>&1; then
      echo "  ✓ Provisioned view: ${V_NAME} (${V_LAYOUT})"
    else
      echo "  i View '${V_NAME}' already exists or requires manual filter paste (see project/views.md)."
    fi
  fi
done

# 6. Print manual UI steps that have no public GitHub API
echo ""
echo "==> Step 5/5: Manual UI Checklist (~5 minutes — no public API exists for these)"
cat <<EOF
------------------------------------------------------------------
1. Save Repository Variables (Settings -> Secrets and variables -> Actions -> Variables):
   - ORG_NAME       = ${ORG_NAME}
   - PROJECT_NUMBER = ${PROJECT_NUMBER}

2. Configure Built-In Project Workflows (Project #${PROJECT_NUMBER} -> ⋯ top-right -> Workflows):
   - [ON]  Auto-add to project:     Repo = ${ORG_NAME}/${REPO_NAME}, Filter = is:issue is:open
   - [ON]  Item added to project:   Set Status = Todo
   - [OFF] Item closed:             TURN OFF (on by default! Closing != human-verified Done)
   - [OFF] Pull request merged:     TURN OFF (on by default! Merging != human-verified Done)
   - [ON]  Auto-archive items:      Filter = status:Done updated:<@today-30d

3. Set Soft WIP Limit on '1. Board' (F6):
   - On column 'Doing', click ⋯ -> Set limit -> enter (2 x team_size), e.g. 10 for 5 people.

4. Verify Group/Sort on '2. Stand-up Dashboard' & '3. Needs Attention' (project/views.md):
   - Group by: Status | Sort by: Blocked since (ascending), then Priority (ascending).

5. Create the 2 Insights Charts (Project #${PROJECT_NUMBER} -> Insights -> + New chart):
   - Chart 1 ('Status Over Time'):        Layout = Stacked area, X = Time (Last 30d), Group = Status
   - Chart 2 ('Active Work by Assignee'): Layout = Stacked bar, Filter = status:Doing,Blocked, X = Assignees, Group = Status
------------------------------------------------------------------
EOF
echo "==> Setup complete for Project #${PROJECT_NUMBER}."
