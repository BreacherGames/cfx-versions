#!/usr/bin/env bash
set -euo pipefail

SCHEMA_VERSION=1
PRODUCTS=(legacy enhanced)
PLATFORMS=(win32 linux)

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }

channel_file() {
  echo "versions/$1/$2.json"
}

channel_key() {
  echo "$1/$2"
}

# Legacy: master branch only (never feature/*).
is_master_url() {
  [[ "${1:-}" == *"/master/"* ]]
}

legacy_artifact_root() {
  case "$1" in
    win32) echo "build_server_windows" ;;
    linux) echo "build_proot_linux" ;;
    *) echo "unknown platform: $1" >&2; return 1 ;;
  esac
}

legacy_artifact_file() {
  case "$1" in
    win32) echo "server.zip" ;;
    linux) echo "fx.tar.xz" ;;
    *) echo "unknown platform: $1" >&2; return 1 ;;
  esac
}

legacy_master_url() {
  local platform="$1" folder="$2"
  printf 'https://runtime.fivem.net/artifacts/fivem/%s/master/%s/%s\n' \
    "$(legacy_artifact_root "$platform")" \
    "$folder" \
    "$(legacy_artifact_file "$platform")"
}

# Parse Cfx master listing HTML on stdin → folder id (e.g. 34629-cb3c120b…).
legacy_master_folder_from_stdin() {
  local folder
  folder="$(sed -n 's/.*is-active[^>]*href="\.\/\([0-9][0-9]*-[a-f0-9]*\)\/.*/\1/p' | head -1)"
  if [[ -z "$folder" ]]; then
    folder="$(grep -oE 'href="\./[0-9]+-[a-f0-9]+/' | grep -oE '[0-9]+-[a-f0-9]+' | sort -t- -k1,1n | tail -1)"
  fi
  [[ -n "$folder" ]] || return 1
  printf '%s\n' "$folder"
}

# Uses CFX_CHANGELOG_<platform> cache file when set by sync.
legacy_changelog_json() {
  local platform="$1"
  local var path
  var="CFX_CHANGELOG_${platform}"
  path="${!var:-}"
  if [[ -n "$path" ]]; then
    if [[ ! -s "$path" ]]; then
      curl -fsSL "https://changelogs-live.fivem.net/api/changelog/versions/${platform}/server" >"$path"
    fi
    cat "$path"
    return 0
  fi
  curl -fsSL "https://changelogs-live.fivem.net/api/changelog/versions/${platform}/server"
}

# No Enhanced API — scrape docs __NEXT_DATA__. Uses CFX_ENHANCED_NEXT when set by sync.
enhanced_next_json() {
  local tmp page
  if [[ -n "${CFX_ENHANCED_NEXT:-}" ]]; then
    if [[ ! -s "$CFX_ENHANCED_NEXT" ]]; then
      tmp="$(mktemp)"
      curl -fsSL "https://docs.fivem.net/docs/server-download/" -o "$tmp"
      awk 'BEGIN{RS="</script>"} /id="__NEXT_DATA__"/{sub(/^.*<script[^>]*>/,""); print; exit}' \
        "$tmp" >"$CFX_ENHANCED_NEXT"
      rm -f "$tmp"
    fi
    cat "$CFX_ENHANCED_NEXT"
    return 0
  fi

  page="$(mktemp)"
  curl -fsSL "https://docs.fivem.net/docs/server-download/" -o "$page"
  awk 'BEGIN{RS="</script>"} /id="__NEXT_DATA__"/{sub(/^.*<script[^>]*>/,""); print; exit}' "$page"
  rm -f "$page"
}

policy_min_build() {
  local product="$1"
  jq -r --arg p "$product" '.retention[$p].minBuild // empty' versions/policy.json
}

write_index() {
  local updatedAt="$1"
  local tmp product platform key file
  tmp="$(mktemp)"

  jq -n \
    --argjson schemaVersion "$SCHEMA_VERSION" \
    --arg updatedAt "$updatedAt" \
    '{ schemaVersion: $schemaVersion, updatedAt: $updatedAt, channels: {} }' >"$tmp"

  for product in "${PRODUCTS[@]}"; do
    for platform in "${PLATFORMS[@]}"; do
      key="$(channel_key "$product" "$platform")"
      file="$(channel_file "$product" "$platform")"
      jq \
        --arg key "$key" \
        --arg path "$file" \
        --argjson meta "$(jq '{latest, stable}' "$file")" \
        '.channels[$key] = ($meta + {path: $path})' \
        "$tmp" >"${tmp}.next"
      mv "${tmp}.next" "$tmp"
    done
  done

  jq -S . "$tmp" >"${tmp}.sorted"
  mv "${tmp}.sorted" versions/index.json
  rm -f "$tmp"
}

# Drop builds below minBuild; always keep latest/stable pins.
prune_retention() {
  local product="$1" platform="$2"
  local file min tmp
  file="$(channel_file "$product" "$platform")"
  min="$(policy_min_build "$product")"
  [[ -n "$min" ]] || return 0

  tmp="$(mktemp)"
  jq \
    --argjson min "$min" \
    '
      . as $root
      | .builds |= (
          with_entries(
            select(
              (.key | test("^[0-9]+$") | not)
              or (.key | tonumber) >= $min
              or .key == $root.latest
              or (.key == $root.stable)
            )
          )
          | to_entries
          | sort_by(.key | tonumber)
          | from_entries
        )
    ' "$file" >"$tmp"
  mv "$tmp" "$file"
}
