#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

enter_repo
need jq
need date

product="${1:?usage: $0 <legacy|enhanced> <win32|linux> <version>}"
platform="${2:?usage: $0 <legacy|enhanced> <win32|linux> <version>}"
version="${3:?usage: $0 <legacy|enhanced> <win32|linux> <version>}"

set_stable_pin "$product" "$platform" "$version"
write_index "$(iso_now)"
"$CFX_SCRIPTS_DIR/validate.sh"
echo "stable $product/$platform -> $version"
