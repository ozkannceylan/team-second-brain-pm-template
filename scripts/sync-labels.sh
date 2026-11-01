#!/usr/bin/env bash
# scripts/sync-labels.sh
# Idempotently syncs repository labels from .github/labels.yml using gh CLI.
#
# Dependencies: bash, gh (GitHub CLI), yq (mikefarah/yq v4, preinstalled on ubuntu-latest)
# Usage:
#   ./scripts/sync-labels.sh [--repo ORG/REPO] [--labels-file .github/labels.yml] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_SLUG="${GITHUB_REPOSITORY:-}"
LABELS_FILE="${REPO_ROOT}/.github/labels.yml"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: ./scripts/sync-labels.sh [OPTIONS]

Idempotently creates or updates repository labels defined in .github/labels.yml.

Options:
  --repo ORG/REPO       Target repository (defaults to $GITHUB_REPOSITORY or current gh repo)
  --labels-file PATH    Path to labels YAML file (default: .github/labels.yml)
  --dry-run             Print gh label commands without calling the GitHub API
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_SLUG="$2"
      shift 2
      ;;
    --labels-file)
      LABELS_FILE="$2"
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

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: 'yq' (v4+) is required to parse ${LABELS_FILE}. Install via 'brew install yq' or use ubuntu-latest." >&2
  exit 1
fi

if [[ ! -f "${LABELS_FILE}" ]]; then
  echo "ERROR: Labels file not found at ${LABELS_FILE}" >&2
  exit 1
fi

if [[ "${DRY_RUN}" != "true" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' (GitHub CLI) is required when not running with --dry-run." >&2
  exit 1
fi

LABEL_COUNT="$(yq '.labels | length' "${LABELS_FILE}")"
echo "==> Syncing ${LABEL_COUNT} labels from ${LABELS_FILE} (dry_run=${DRY_RUN})..."

REPO_ARGS=()
if [[ -n "${REPO_SLUG}" ]]; then
  REPO_ARGS=(--repo "${REPO_SLUG}")
fi

for (( i=0; i<LABEL_COUNT; i++ )); do
  NAME="$(yq -r ".labels[${i}].name" "${LABELS_FILE}")"
  COLOR="$(yq -r ".labels[${i}].color" "${LABELS_FILE}")"
  DESC="$(yq -r ".labels[${i}].description" "${LABELS_FILE}")"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] gh label create \"${NAME}\" --color \"${COLOR}\" --description \"${DESC}\" --force ${REPO_ARGS[*]:-}"
  else
    gh label create "${NAME}" \
      --color "${COLOR}" \
      --description "${DESC}" \
      --force \
      "${REPO_ARGS[@]}"
    echo "  ✓ Synced label: ${NAME} (#${COLOR})"
  fi
done

echo "==> Label sync complete (${LABEL_COUNT} labels)."
