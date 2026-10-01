#!/usr/bin/env bash
# Apply every update that Renovate proposes to the working tree, without
# creating branches or PRs. Review the result with `git diff`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Local mode reads only the files that git tracks.
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD":/repo -v "$out":/out -w /repo \
  -e RENOVATE_REPORT_TYPE=file -e RENOVATE_REPORT_PATH=/out/report.json \
  ghcr.io/renovatebot/renovate:44.131.2 renovate --platform=local >/dev/null

PYTHONDONTWRITEBYTECODE=1 python3 .github/renovate/apply-report.py "$out/report.json"
PYTHONDONTWRITEBYTECODE=1 python3 .github/renovate/post-upgrade.py
