#!/usr/bin/env bash
# Shared catalog helpers. Source from repo scripts only.
set -euo pipefail

readonly SCHEMA_VERSION=1
readonly PRODUCTS=(legacy enhanced)
readonly PLATFORMS=(win32 linux)
readonly DOCS_URL="https://docs.fivem.net/docs/server-download/"
CFX_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CFX_SCRIPTS_DIR

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing dependency: $1"; }
enter_repo() { cd "$CFX_SCRIPTS_DIR/../.."; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

channel_file() { printf 'versions/%s/%s.json\n' "$1" "$2"; }
channel_key() { printf '%s/%s\n' "$1" "$2"; }

require_channel() {
  case "$1:$2" in
    legacy:win32 | legacy:linux | enhanced:win32 | enhanced:linux) ;;
    *) die "invalid channel: $1/$2 (expected legacy|enhanced × win32|linux)" ;;
  esac
}

each_channel() {
  local product platform
  for product in "${PRODUCTS[@]}"; do
    for platform in "${PLATFORMS[@]}"; do
      "$@" "$product" "$platform"
    done
  done
}

platform_os() {
  case "$1" in
    win32) printf 'windows\n' ;;
    linux) printf 'linux\n' ;;
    *) die "unknown platform: $1" ;;
  esac
}

is_master_url() { [[ "${1:-}" == *"/master/"* ]]; }

# Docs advertise server.7z; the same artifact folder also serves server.zip.
normalize_url() {
  local product="$1" platform="$2" url="$3"
  if [[ "$product" == legacy && "$platform" == win32 && "$url" == */server.7z ]]; then
    printf '%s\n' "${url%.7z}.zip"
    return 0
  fi
  printf '%s\n' "$url"
}

policy_min_build() {
  jq -r --arg p "$1" '.retention[$p].minBuild // empty' versions/policy.json
}

# --- docs SSOT (cached in CFX_DOCS_NEXT when set by sync) --------------------

docs_fetch_next() {
  local out="$1" page
  page="$(mktemp)"
  curl -fsSL --retry 3 --retry-delay 1 "$DOCS_URL" -o "$page" \
    || { rm -f "$page"; die "docs fetch failed: $DOCS_URL"; }
  awk 'BEGIN{RS="</script>"} /id="__NEXT_DATA__"/{sub(/^.*<script[^>]*>/,""); print; exit}' \
    "$page" >"$out"
  rm -f "$page"
  [[ -s "$out" ]] || die "docs next: empty __NEXT_DATA__ from $DOCS_URL"
}

docs_ensure() {
  if [[ -z "${CFX_DOCS_NEXT:-}" ]]; then
    CFX_DOCS_NEXT="$(mktemp)"
    export CFX_DOCS_NEXT
    docs_fetch_next "$CFX_DOCS_NEXT"
    trap 'rm -f "$CFX_DOCS_NEXT"' EXIT
  elif [[ ! -s "$CFX_DOCS_NEXT" ]]; then
    docs_fetch_next "$CFX_DOCS_NEXT"
  fi
}

docs_jq() {
  docs_ensure
  jq "$@" "$CFX_DOCS_NEXT"
}

docs_require_shape() {
  docs_jq -e '.props.pageProps.legacy and .props.pageProps.enhanced' >/dev/null \
    || die "docs next: missing props.pageProps.legacy/enhanced"
}

# VERSION<TAB>URL for pageProps-relative path (e.g. legacy.latest.windows).
docs_first_tsv() {
  local rel="$1"
  docs_jq -r --arg rel "$rel" '
    getpath(["props", "pageProps"] + ($rel | split(".")))
    | if type == "array" then .[0] else empty end
    | select((.downloadURL // "") != "" and (.subtitle // "") != "")
    | [((.subtitle | gsub("[^0-9]"; "")), .downloadURL)]
    | select(.[0] != "")
    | @tsv
  '
}

discover() {
  local product="$1" platform="$2"
  local os rel line version url
  require_channel "$product" "$platform"
  os="$(platform_os "$platform")"

  case "$product" in
    legacy) rel="legacy.latest.$os" ;;
    enhanced) rel="enhanced.$os" ;;
  esac

  line="$(docs_first_tsv "$rel")"
  [[ -n "$line" ]] || die "discover $product/$platform: docs missing ${rel}[0]"

  version="${line%%$'\t'*}"
  url="$(normalize_url "$product" "$platform" "${line#*$'\t'}")"
  [[ "$version" =~ ^[0-9]+$ ]] || die "discover $product/$platform: bad version in docs"

  if [[ "$product" == legacy ]] && ! is_master_url "$url"; then
    die "discover $product/$platform: not a master URL: $url"
  fi
  printf '%s\t%s\n' "$version" "$url"
}

# --- channel mutations (0 = changed, 1 = unchanged) -------------------------

# Sort builds by numeric id. Shared jq filter fragment.
# shellcheck disable=SC2016
readonly JQ_SORT_BUILDS='.builds |= (to_entries | sort_by(.key | tonumber) | from_entries)'

# Keep only latest + stable; legacy must be master; honor minBuild except pins.
# shellcheck disable=SC2016
readonly JQ_PRUNE_PINS='
  . as $root
  | .builds |= with_entries(
      select(
        (.key == $root.latest or .key == $root.stable)
        and (
          ($product != "legacy")
          or ((.value.url // "") | test("/master/"))
        )
        and (
          ((.key | test("^[0-9]+$") | not) or ((.key | tonumber) >= $min))
          or .key == $root.latest
          or .key == $root.stable
        )
      )
    )
'

channel_jq() {
  local file="$1" msg="$2" tmp dir
  shift 2
  [[ -f "$file" ]] || die "missing channel file: $file"
  dir="$(dirname "$file")"
  tmp="$(mktemp "${dir}/.tmp.XXXXXX")"
  jq "$@" "$file" >"$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  printf '%s\n' "$msg"
  return 0
}

# Record docs latest, retarget pin, drop everything else unpinned.
sync_channel() {
  local product="$1" platform="$2" seenAt="$3"
  local file line version url min
  require_channel "$product" "$platform"
  file="$(channel_file "$product" "$platform")"
  line="$(discover "$product" "$platform")"
  version="${line%%$'\t'*}"
  url="${line#*$'\t'}"
  min="$(policy_min_build "$product")"
  [[ "$min" =~ ^[0-9]+$ ]] || die "policy.retention.$product.minBuild invalid"

  channel_jq "$file" "synced $product/$platform -> $version" \
    --argjson schemaVersion "$SCHEMA_VERSION" \
    --argjson min "$min" \
    --arg product "$product" \
    --arg version "$version" \
    --arg url "$url" \
    --arg seenAt "$seenAt" \
    "
      .schemaVersion = \$schemaVersion
      | .latest = \$version
      | .builds[\$version] = (
          (.builds[\$version] // {})
          | .url = \$url
          | if .seenAt then . else .seenAt = \$seenAt end
        )
      | ${JQ_PRUNE_PINS}
      | ${JQ_SORT_BUILDS}
    "
}

set_stable_pin() {
  local product="$1" platform="$2" version="$3"
  local file min url
  require_channel "$product" "$platform"
  file="$(channel_file "$product" "$platform")"
  [[ -f "$file" ]] || die "missing $file"
  [[ "$version" =~ ^[0-9]+$ ]] || die "stable version must be numeric"

  jq -e --arg v "$version" '.builds[$v] != null' "$file" >/dev/null \
    || die "unknown build $version in $file (run sync first)"

  min="$(policy_min_build "$product")"
  [[ "$min" =~ ^[0-9]+$ ]] || die "policy.retention.$product.minBuild invalid"
  if ((10#$version < min)); then
    die "refusing stable pin: $version below retention minBuild $min"
  fi

  if [[ "$product" == legacy ]]; then
    url="$(jq -r --arg v "$version" '.builds[$v].url // empty' "$file")"
    is_master_url "$url" || die "refusing stable pin: $version is not a master URL"
  fi

  channel_jq "$file" "stable $product/$platform -> $version" \
    --argjson min "$min" \
    --arg product "$product" \
    --arg version "$version" \
    "
      .stable = \$version
      | ${JQ_PRUNE_PINS}
      | ${JQ_SORT_BUILDS}
    " || true
}

write_index() {
  local updatedAt="$1"
  local tmp files=() product platform
  for product in "${PRODUCTS[@]}"; do
    for platform in "${PLATFORMS[@]}"; do
      files+=("$(channel_file "$product" "$platform")")
    done
  done

  tmp="$(mktemp versions/.index.XXXXXX)"
  jq -S -n \
    --argjson schemaVersion "$SCHEMA_VERSION" \
    --arg updatedAt "$updatedAt" \
    --slurpfile chans <(
      jq -c '
        {
          key: "\(.product)/\(.platform)",
          value: {
            latest: .latest,
            stable: .stable,
            path: "versions/\(.product)/\(.platform).json"
          }
        }
      ' "${files[@]}"
    ) \
    '{
      schemaVersion: $schemaVersion,
      updatedAt: $updatedAt,
      channels: ($chans | map({(.key): .value}) | add)
    }' >"$tmp"
  mv "$tmp" versions/index.json
}
