#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

need curl
need jq

product="${1:?usage: $0 <legacy|enhanced> <win32|linux>}"
platform="${2:?usage: $0 <legacy|enhanced> <win32|linux>}"
require_channel "$product" "$platform"
discover "$product" "$platform"
