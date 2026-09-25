#!/usr/bin/env bash
# ==============================================================================
# Run HolmesGPT investigation against opentelemetry-platform-on-eks
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
ALERT_FILE="${1:-${SCRIPT_DIR}/sample-alertmanager-alert.json}"

echo "=== HolmesGPT Adopt Baseline Investigation ==="
echo "Config: ${CONFIG_FILE}"
echo "Alert:  ${ALERT_FILE}"

if ! command -v uv >/dev/null 2>&1; then
  echo "Error: uv is required. Install from https://astral.sh/uv" >&2
  exit 1
fi

uv tool run --from holmesgpt holmes investigate alertmanager \
  --config "${CONFIG_FILE}" \
  --alertmanager-file "${ALERT_FILE}" \
  --destination cli
