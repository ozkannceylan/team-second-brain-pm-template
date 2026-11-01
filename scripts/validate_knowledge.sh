#!/usr/bin/env bash
# scripts/validate_knowledge.sh
# Validates Second Brain Markdown frontmatter against _meta/schema.yaml and enforces:
#   1. All required frontmatter keys exist and have valid types/enums/date formats.
#   2. Non-human actors (bots/agents matching project/fields.yml bot_actor_patterns)
#      MUST NOT set status: verified or set/modify last_verified.
#   3. Non-human actors MUST NOT modify files with locked: true or inside standards/.
#
# Dependencies: bash, yq (mikefarah/yq v4, preinstalled on ubuntu-latest)
# Usage:
#   ./scripts/validate_knowledge.sh [--all] [--actor LOGIN] [FILE ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEMA_FILE="${REPO_ROOT}/_meta/schema.yaml"
FIELDS_FILE="${REPO_ROOT}/project/fields.yml"

ACTOR="${GITHUB_ACTOR:-human-local}"
SCAN_ALL="false"
BASE_REF=""
FILES=()

usage() {
  cat <<'EOF'
Usage: ./scripts/validate_knowledge.sh [OPTIONS] [FILE ...]

Validates Second Brain Markdown frontmatter against _meta/schema.yaml and
enforces human-only verification and page locks.

Options:
  --all             Validate all curated Markdown pages in knowledge/, decisions/, standards/, docs/decisions/
  --actor LOGIN     Actor login to check against bot rules (default: $GITHUB_ACTOR or 'human-local')
  --schema PATH     Path to schema.yaml (default: _meta/schema.yaml)
  --base REF        Git ref to diff against (e.g. origin/main). With --base, bot rules
                    apply only to files changed since REF and compare against REF's
                    frontmatter (a bot may touch a verified page's body, but may not
                    change status to verified, change last_verified, or edit locked pages).
                    Without --base, bot rules apply to every validated file (strict).
  -h, --help        Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      SCAN_ALL="true"
      shift
      ;;
    --actor)
      ACTOR="$2"
      shift 2
      ;;
    --schema)
      SCHEMA_FILE="$2"
      shift 2
      ;;
    --base)
      BASE_REF="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: 'yq' (v4+) is required. Install via 'brew install yq' or run on ubuntu-latest." >&2
  exit 1
fi

if [[ ! -f "${SCHEMA_FILE}" ]]; then
  echo "ERROR: Schema file not found: ${SCHEMA_FILE}" >&2
  exit 1
fi

is_bot_actor() {
  local check_actor="$1"
  local lower_actor
  lower_actor="$(printf '%s' "${check_actor}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${lower_actor}" == *"[bot]" ]] || [[ "${lower_actor}" == *-bot ]] || [[ "${lower_actor}" == bot-* ]]; then
    return 0
  fi

  if [[ -f "${FIELDS_FILE}" ]]; then
    local pattern_count
    pattern_count="$(yq '.governance.bot_actor_patterns | length' "${FIELDS_FILE}")"
    local i pat pat_lower
    for (( i=0; i<pattern_count; i++ )); do
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
  fi
  return 1
}

collect_default_files() {
  local search_dirs=(
    "${REPO_ROOT}/knowledge"
    "${REPO_ROOT}/decisions"
    "${REPO_ROOT}/standards"
    "${REPO_ROOT}/docs/decisions"
  )
  local dir file base
  for dir in "${search_dirs[@]}"; do
    if [[ -d "${dir}" ]]; then
      while IFS= read -r -d '' file; do
        base="$(basename "${file}")"
        if [[ "${base}" == "README.md" ]]; then
          continue
        fi
        FILES+=("${file}")
      done < <(find "${dir}" -type f -name '*.md' -print0 | sort -z)
    fi
  done
}

if [[ "${SCAN_ALL}" == "true" ]] || [[ "${#FILES[@]}" -eq 0 ]]; then
  collect_default_files
fi

ACTOR_IS_BOT="false"
if is_bot_actor "${ACTOR}"; then
  ACTOR_IS_BOT="true"
fi

echo "==> Validating ${#FILES[@]} knowledge page(s) (actor='${ACTOR}', is_bot=${ACTOR_IS_BOT})..."

REQUIRED_KEYS=()
while IFS= read -r key; do
  [[ -n "${key}" ]] && REQUIRED_KEYS+=("${key}")
done < <(yq -r '.required_fields[]' "${SCHEMA_FILE}")

CHANGED_FILES=""
if [[ -n "${BASE_REF}" ]]; then
  CHANGED_FILES="$(git -C "${REPO_ROOT}" diff --name-only "${BASE_REF}...HEAD" -- '*.md')"
fi

ERRORS=0
TMP_FM="$(mktemp)"
TMP_BASE_FM="$(mktemp)"
trap 'rm -f "${TMP_FM}" "${TMP_BASE_FM}"' EXIT

# Prints "status|last_verified|locked" of a file at BASE_REF ("new|null|false" if absent).
base_frontmatter() {
  local rel="$1"
  if ! git -C "${REPO_ROOT}" show "${BASE_REF}:${rel}" 2>/dev/null \
      | awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { exit } in_fm { print }' > "${TMP_BASE_FM}" \
      || [[ ! -s "${TMP_BASE_FM}" ]]; then
    echo "new|null|false"
    return 0
  fi
  printf '%s|%s|%s\n' \
    "$(yq -r '.status // ""' "${TMP_BASE_FM}")" \
    "$(yq -r '.last_verified // "null"' "${TMP_BASE_FM}")" \
    "$(yq -r '.locked // false' "${TMP_BASE_FM}")"
}

validate_file() {
  local file="$1"
  local base
  base="$(basename "${file}")"

  # Skip folder README index files or raw inbox notes
  if [[ "${base}" == "README.md" ]] || [[ "${file}" == *"inbox/"* ]]; then
    return 0
  fi

  if [[ ! -f "${file}" ]]; then
    echo "  ✗ [${file}] File does not exist" >&2
    ERRORS=$((ERRORS + 1))
    return 0
  fi

  local first_line
  first_line="$(head -n 1 "${file}")"
  if [[ "${first_line}" != "---" ]]; then
    echo "  ✗ [${file}] Missing opening YAML frontmatter delimiter ('---' on line 1)" >&2
    ERRORS=$((ERRORS + 1))
    return 0
  fi

  awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { exit } in_fm { print }' "${file}" > "${TMP_FM}"

  if [[ ! -s "${TMP_FM}" ]]; then
    echo "  ✗ [${file}] Empty or unclosed YAML frontmatter block" >&2
    ERRORS=$((ERRORS + 1))
    return 0
  fi

  if ! yq '.' "${TMP_FM}" >/dev/null 2>&1; then
    echo "  ✗ [${file}] Malformed YAML in frontmatter" >&2
    ERRORS=$((ERRORS + 1))
    return 0
  fi

  local req_key has_key
  for req_key in "${REQUIRED_KEYS[@]}"; do
    has_key="$(yq "has(\"${req_key}\")" "${TMP_FM}")"
    if [[ "${has_key}" != "true" ]]; then
      echo "  ✗ [${file}] Missing required frontmatter field: '${req_key}'" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done

  local title domain doc_type owner status last_verified locked publish
  title="$(yq -r '.title // ""' "${TMP_FM}")"
  domain="$(yq -r '.domain // ""' "${TMP_FM}")"
  doc_type="$(yq -r '.type // ""' "${TMP_FM}")"
  owner="$(yq -r '.owner // ""' "${TMP_FM}")"
  status="$(yq -r '.status // ""' "${TMP_FM}")"
  last_verified="$(yq -r '.last_verified // "null"' "${TMP_FM}")"
  locked="$(yq -r '.locked' "${TMP_FM}")"
  publish="$(yq -r '.publish' "${TMP_FM}")"

  if [[ -z "${title}" ]]; then
    echo "  ✗ [${file}] 'title' must be a non-empty string" >&2
    ERRORS=$((ERRORS + 1))
  fi

  if [[ -z "${domain}" ]]; then
    echo "  ✗ [${file}] 'domain' must be a non-empty string" >&2
    ERRORS=$((ERRORS + 1))
  fi

  case "${doc_type}" in
    runbook|guide|reference|standard|adr) ;;
    *)
      echo "  ✗ [${file}] Invalid 'type': '${doc_type}' (expected: runbook|guide|reference|standard|adr)" >&2
      ERRORS=$((ERRORS + 1))
      ;;
  esac

  if [[ ! "${owner}" =~ ^@[A-Za-z0-9_/-]+$ ]]; then
    echo "  ✗ [${file}] Invalid 'owner': '${owner}' (expected GitHub handle/team starting with '@', e.g. @ORG/maintainers)" >&2
    ERRORS=$((ERRORS + 1))
  fi

  case "${status}" in
    draft-bot|verified|deprecated) ;;
    *)
      echo "  ✗ [${file}] Invalid 'status': '${status}' (expected: draft-bot|verified|deprecated)" >&2
      ERRORS=$((ERRORS + 1))
      ;;
  esac

  if [[ "${status}" == "verified" ]]; then
    if [[ ! "${last_verified}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "  ✗ [${file}] When status is 'verified', 'last_verified' must be YYYY-MM-DD (got '${last_verified}')" >&2
      ERRORS=$((ERRORS + 1))
    fi
  else
    if [[ "${last_verified}" != "null" ]] && [[ ! "${last_verified}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "  ✗ [${file}] 'last_verified' must be YYYY-MM-DD or null (got '${last_verified}')" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if [[ "${locked}" != "true" && "${locked}" != "false" ]]; then
    echo "  ✗ [${file}] 'locked' must be boolean true or false (got '${locked}')" >&2
    ERRORS=$((ERRORS + 1))
  fi

  if [[ "${publish}" != "true" && "${publish}" != "false" ]]; then
    echo "  ✗ [${file}] 'publish' must be boolean true or false (got '${publish}')" >&2
    ERRORS=$((ERRORS + 1))
  fi

  # Enforce non-human actor rules when actor is a bot/agent
  if [[ "${ACTOR_IS_BOT}" == "true" ]]; then
    local rel="${file#"${REPO_ROOT}"/}"
    if [[ -z "${BASE_REF}" ]]; then
      # Strict mode (no base): a bot-authored file must not carry verification or locks.
      if [[ "${status}" == "verified" ]]; then
        echo "  ✗ [${file}] POLICY VIOLATION: Non-human actor '${ACTOR}' cannot set or touch a page with 'status: verified'" >&2
        ERRORS=$((ERRORS + 1))
      fi
      if [[ "${last_verified}" != "null" ]]; then
        echo "  ✗ [${file}] POLICY VIOLATION: Non-human actor '${ACTOR}' cannot set 'last_verified' ('${last_verified}'); only humans may verify pages" >&2
        ERRORS=$((ERRORS + 1))
      fi
      if [[ "${locked}" == "true" ]] || [[ "${file}" == *"/standards/"* ]]; then
        echo "  ✗ [${file}] POLICY VIOLATION: Non-human actor '${ACTOR}' cannot modify locked page ('locked: true' or inside standards/)" >&2
        ERRORS=$((ERRORS + 1))
      fi
    elif grep -qxF "${rel}" <<<"${CHANGED_FILES}"; then
      local base_status base_lv base_locked
      IFS='|' read -r base_status base_lv base_locked < <(base_frontmatter "${rel}")
      if [[ "${status}" == "verified" && "${base_status}" != "verified" ]]; then
        echo "  ✗ [${file}] POLICY VIOLATION: Non-human actor '${ACTOR}' changed status to 'verified'; only humans may verify pages" >&2
        ERRORS=$((ERRORS + 1))
      fi
      if [[ "${last_verified}" != "${base_lv}" ]]; then
        echo "  ✗ [${file}] POLICY VIOLATION: Non-human actor '${ACTOR}' changed 'last_verified' ('${base_lv}' -> '${last_verified}')" >&2
        ERRORS=$((ERRORS + 1))
      fi
      if [[ "${base_locked}" == "true" ]] || [[ "${rel}" == standards/* ]]; then
        echo "  ✗ [${file}] POLICY VIOLATION: Non-human actor '${ACTOR}' cannot modify locked page ('locked: true' at base or inside standards/)" >&2
        ERRORS=$((ERRORS + 1))
      fi
    fi
  fi

  echo "  ✓ Validated: ${file#"${REPO_ROOT}"/}"
}

for f in "${FILES[@]}"; do
  validate_file "${f}"
done

if [[ "${ERRORS}" -gt 0 ]]; then
  echo "==> FAILED: ${ERRORS} validation error(s) detected." >&2
  exit 1
fi

echo "==> SUCCESS: All ${#FILES[@]} knowledge page(s) passed schema and governance checks."
