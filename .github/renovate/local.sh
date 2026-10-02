#!/usr/bin/env bash
# Apply every update that Renovate proposes to the working tree, without
# creating branches or PRs. Review the result with `git diff`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# The github-releases lookups need a token, and xatautils is a private
# repository. Use GITHUB_TOKEN, as the Makefile does, or else the gh login.
token="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
if [ -z "$token" ]; then
  echo "warning: no GITHUB_TOKEN and no gh login, so xatautils cannot be checked" >&2
fi

# Local mode reads only the files that git tracks.
docker run --rm -e GITHUB_COM_TOKEN="$token" --user "$(id -u):$(id -g)" \
  -v "$PWD":/repo -v "$out":/out -w /repo \
  -e RENOVATE_REPORT_TYPE=file -e RENOVATE_REPORT_PATH=/out/report.json \
  ghcr.io/renovatebot/renovate:44.131.2 renovate --platform=local >/dev/null

PYTHONDONTWRITEBYTECODE=1 python3 .github/renovate/apply-report.py "$out/report.json"
PYTHONDONTWRITEBYTECODE=1 python3 .github/renovate/post-upgrade.py
