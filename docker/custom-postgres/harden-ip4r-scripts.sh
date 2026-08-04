#!/bin/bash
# Pin unqualified polymorphic pg_catalog builtins in ip4r's scripts to
# pg_catalog. Idempotent; fails if any remain. Usage: <script> <extension_dir>
set -euo pipefail

EXTDIR="${1:?usage: harden-ip4r-scripts.sh <extension_dir>}"

FUNCS="unnest|format|array_to_string|array_agg|array_append|array_prepend|array_cat|array_remove|array_replace|array_length|array_lower|array_upper|array_ndims|array_dims|cardinality"

shopt -s nullglob
files=("$EXTDIR"/ip4r--*.sql)
if [ ${#files[@]} -eq 0 ]; then
  echo "harden-ip4r: no ip4r scripts found in $EXTDIR" >&2
  exit 1
fi

for f in "${files[@]}"; do
  # \1 = preceding char (not an identifier char or dot, so already-qualified and
  # substring matches are left alone); \2 = name, original case preserved.
  sed -i -E "s/([^A-Za-z0-9_.])(${FUNCS})[[:space:]]*\(/\1pg_catalog.\2(/gI" "$f"
done

echo "harden-ip4r: qualified polymorphic builtins in ${#files[@]} ip4r script(s)"

residual=$(
  grep -nEi "(^|[^A-Za-z0-9_.\"])(${FUNCS})[[:space:]]*\(" "${files[@]}" 2>/dev/null \
    | grep -vEi "pg_catalog\.(${FUNCS})" \
    | grep -vE "^[^:]+:[0-9]+:[[:space:]]*--" \
    || true
)
if [ -n "$residual" ]; then
  echo "harden-ip4r: ERROR - unqualified polymorphic call(s) remain:" >&2
  echo "$residual" >&2
  exit 1
fi
echo "harden-ip4r: OK - no unqualified polymorphic builtin calls remain"
