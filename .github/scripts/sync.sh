#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

enter_repo
need curl
need jq
need date

changed=0
note() { changed=1; }

now="$(iso_now)"
CFX_DOCS_NEXT="$(mktemp)"
export CFX_DOCS_NEXT
trap 'rm -f "$CFX_DOCS_NEXT"' EXIT

docs_require_shape

sync_one() {
  sync_channel "$1" "$2" "$now" && note || true
}

each_channel sync_one

if [[ "$changed" -eq 1 ]]; then
  write_index "$now"
fi

"$CFX_SCRIPTS_DIR/validate.sh"

if [[ "$changed" -eq 1 ]]; then
  echo "catalog changed"
else
  echo "catalog unchanged"
fi
