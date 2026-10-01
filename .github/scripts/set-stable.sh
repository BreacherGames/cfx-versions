#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source "$(dirname "$0")/common.sh"
need jq
need date

product="${1:?}"
platform="${2:?}"
version="${3:?}"
file="$(channel_file "$product" "$platform")"
SCRIPTS="$(dirname "$0")"

[[ -f "$file" ]] || { echo "missing $file" >&2; exit 1; }

jq -e --arg v "$version" '.builds[$v] != null' "$file" >/dev/null || {
  echo "unknown build $version in $file (run sync first)" >&2
  exit 1
}

min="$(policy_min_build "$product")"
if [[ -n "$min" ]] && (( 10#$version < min )); then
  echo "refusing stable pin: $version below retention minBuild $min" >&2
  exit 1
fi

if [[ "$product" == legacy ]]; then
  url="$(jq -r --arg v "$version" '.builds[$v].url // empty' "$file")"
  if ! is_master_url "$url"; then
    echo "refusing stable pin: $version is not a master URL" >&2
    exit 1
  fi
fi

tmp="$(mktemp)"
jq --arg v "$version" '
  .stable = $v
  | .builds |= (to_entries | sort_by(.key | tonumber) | from_entries)
' "$file" >"$tmp"
mv "$tmp" "$file"

write_index "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"$SCRIPTS/validate.sh"
echo "stable $product/$platform -> $version"
