#!/usr/bin/env bash
set -euo pipefail

REPO="xataio/postgres-images"
WORKFLOW="build-custom-image.yml"

MINORS=(
  14.22
  15.17
  16.13
  17.5  17.6  17.7 17.8 17.9
  18.0  18.1  18.2 18.3
)

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

for minor in "${MINORS[@]}"; do
  echo "[$(ts)] === Dispatching build for ${minor} ==="
  before=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" \
                       --event workflow_dispatch --limit 1 \
                       --json databaseId --jq '.[0].databaseId // "0"')

  gh workflow run "$WORKFLOW" \
    --repo "$REPO" \
    --ref main \
    -f cnpg_base=minimal \
    -f custom_cnpg_base="ghcr.io/cloudnative-pg/postgresql:${minor}-minimal-bookworm" \
    -f target_folder=docker/custom-postgres \
    -f only_version="${minor}"

  # Wait for the new run to appear (id != before)
  run_id="$before"
  for _ in $(seq 1 30); do
    sleep 2
    run_id=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" \
                         --event workflow_dispatch --limit 1 \
                         --json databaseId --jq '.[0].databaseId // "0"')
    [[ "$run_id" != "$before" ]] && break
  done
  if [[ "$run_id" == "$before" ]]; then
    echo "[$(ts)] FAILED to detect new run for ${minor}" >&2
    exit 1
  fi

  echo "[$(ts)] Run ${run_id} started for ${minor}; waiting for completion..."
  if ! gh run watch "$run_id" --repo "$REPO" --exit-status >/dev/null; then
    echo "[$(ts)] !!! Run ${run_id} for ${minor} FAILED. Halting." >&2
    exit 1
  fi
  echo "[$(ts)] === ${minor} done (run ${run_id}) ==="
done

echo "[$(ts)] All 18 builds completed successfully."
