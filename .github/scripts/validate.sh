#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

enter_repo
need jq

errors=0
err() { echo "error: $*" >&2; errors=$((errors + 1)); }
want() {
  local file="$1" msg="$2"
  shift 2
  jq -e "$@" "$file" >/dev/null 2>&1 || err "$msg"
}

[[ -f versions/policy.json && -f versions/index.json ]] \
  || die "missing versions/policy.json or versions/index.json"

want versions/policy.json "policy schemaVersion" \
  --argjson v "$SCHEMA_VERSION" '.schemaVersion == $v'
want versions/policy.json "policy keys" \
  'keys == ["retention", "schemaVersion"]'
want versions/policy.json "policy.retention keys" \
  '(.retention | keys) == ["enhanced", "legacy"]'

for product in "${PRODUCTS[@]}"; do
  min="$(policy_min_build "$product")"
  [[ "$min" =~ ^[0-9]+$ ]] || err "policy.retention.$product.minBuild invalid"
  want versions/policy.json "policy.retention.$product keys" \
    --arg p "$product" '(.retention[$p] | keys) == ["minBuild"]'
done

want versions/index.json "index schemaVersion" \
  --argjson v "$SCHEMA_VERSION" '.schemaVersion == $v'
want versions/index.json "index keys" \
  'keys == ["channels", "schemaVersion", "updatedAt"]'
want versions/index.json "index.updatedAt" \
  '.updatedAt | test("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")'

validate_channel() {
  local product="$1" platform="$2"
  local key file min latest stable

  key="$(channel_key "$product" "$platform")"
  file="$(channel_file "$product" "$platform")"
  min="$(policy_min_build "$product")"
  [[ -f "$file" ]] || { err "missing $file"; return 0; }

  want "$file" "$file shape" \
    --argjson v "$SCHEMA_VERSION" --arg product "$product" --arg platform "$platform" '
      .schemaVersion == $v
      and .product == $product
      and .platform == $platform
      and (.latest | test("^[0-9]+$"))
      and (.stable == null or (.stable | test("^[0-9]+$")))
      and (.builds | type == "object" and length > 0)
      and keys == ["builds", "latest", "platform", "product", "schemaVersion", "stable"]
    '

  latest="$(jq -r '.latest' "$file")"
  stable="$(jq -r '.stable | if . == null then "" else tostring end' "$file")"

  jq -e --arg v "$latest" '.builds[$v] != null' "$file" >/dev/null \
    || err "$file latest $latest missing from builds"
  if [[ -n "$stable" ]]; then
    jq -e --arg v "$stable" '.builds[$v] != null' "$file" >/dev/null \
      || err "$file stable $stable missing from builds"
  fi

  # Pins-only catalog: every build key must be latest and/or stable.
  want "$file" "$file unpinned builds" \
    --arg latest "$latest" --arg stable "$stable" '
      .builds
      | keys
      | map(select(. != $latest and . != $stable))
      | length == 0
    '

  while IFS=$'\t' read -r id url seen extra || [[ -n "${id:-}" ]]; do
    id="${id%$'\r'}"
    url="${url%$'\r'}"
    seen="${seen%$'\r'}"
    extra="${extra%$'\r'}"
    [[ -z "$id" ]] && continue
    [[ "$id" =~ ^[0-9]+$ ]] || err "$file build id not numeric: $id"
    [[ "$extra" == "0" ]] || err "$file build $id unexpected keys"
    [[ "$url" == https://* ]] || err "$file build $id url must be https"
    [[ "$seen" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || err "$file build $id seenAt invalid"
    if [[ "$product" == legacy ]] && ! is_master_url "$url"; then
      err "$file build $id not a master URL"
    fi
    if ((10#$id < min)) && [[ "$id" != "$latest" && "$id" != "$stable" ]]; then
      err "$file build $id below retention minBuild $min"
    fi
  done < <(jq -r '
    .builds
    | to_entries[]
    | [
        .key,
        (.value.url // ""),
        (.value.seenAt // ""),
        ((.value | keys - ["url", "seenAt"] | length) | tostring)
      ]
    | @tsv
  ' "$file")

  jq -e --arg k "$key" '.channels[$k] != null' versions/index.json >/dev/null \
    || { err "index missing $key"; return 0; }

  want versions/index.json "index $key" \
    --arg k "$key" --arg latest "$latest" --arg path "$file" --arg stable "$stable" '
      .channels[$k].latest == $latest
      and .channels[$k].path == $path
      and (.channels[$k] | keys) == ["latest", "path", "stable"]
      and (
        if $stable == "" then .channels[$k].stable == null
        else .channels[$k].stable == $stable end
      )
    '
}

each_channel validate_channel

while IFS= read -r key || [[ -n "${key:-}" ]]; do
  key="${key%$'\r'}"
  [[ -z "$key" ]] && continue
  known=0
  for product in "${PRODUCTS[@]}"; do
    for platform in "${PLATFORMS[@]}"; do
      [[ "$key" == "$(channel_key "$product" "$platform")" ]] && known=1
    done
  done
  [[ "$known" -eq 1 ]] || err "index unknown channel $key"
done < <(jq -r '.channels | keys[]' versions/index.json)

[[ "$errors" -eq 0 ]] || die "validate failed ($errors)"
echo "validate ok"
