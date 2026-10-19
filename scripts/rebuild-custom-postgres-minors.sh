#!/usr/bin/env bash
set -euo pipefail
# Rebuild cnpg-postgres-plus floating minor tags so each picks up pgBackRest
# 2.60.0dev (PR #142). Serial: dispatch one minor, wait for its run to finish,
# then the next. Halts on the first failure (trim MINORS and re-run to resume).
# Based on the script from PR #105.
#
# Scope: only the old minors actually in use across the prod GCP cells
# (usc1-cell-1, ase1-cell-1) as of 2026-10-13. The latest minor of each major
# (16.15 / 17.11 / 18.6) already got the fix from the PR #142 merge and is omitted.
#
# NOTE: minors older than the May-2026 CVE-2026-6473 release (e.g. 16.11/16.12)
# CANNOT be rebuilt with current extensions -- pg_stat_monitor references the
# palloc0_mul symbol those bases lack, so the preload smoke test fails. Both
# minors below postdate that fix and build cleanly. If you add an older minor,
# expect it to fail; minor-upgrade those clusters to latest instead.

REPO="xataio/postgres-images"
WORKFLOW="build-custom-image.yml"

MINORS=(
  16.14
  18.4
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

echo "[$(ts)] All ${#MINORS[@]} builds completed successfully."
