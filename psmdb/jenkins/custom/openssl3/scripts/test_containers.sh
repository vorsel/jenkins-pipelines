#!/bin/bash
# Level A: every OS from the matrix as a container on this host, 6 at a time.
# usage: test_containers.sh <os-matrix.json> <arch> "<os ids or 'all'>"
# env: T, OUT (see verify_os.sh)
set -uo pipefail
MATRIX=$1 ARCH=$2 LIST=$3
HERE=$(cd "$(dirname "$0")" && pwd)
: "${T:?}" "${OUT:?}"
mkdir -p "$OUT"

jq -r --arg a "$ARCH" --arg l " $LIST " '.[$a] | to_entries[]
    | select($l == " all " or ($l | contains(" " + .value.id + " ")))
    | "\(.key + 1) \(.value.id) \(.value.image)"' "$MATRIX" \
  | xargs -P 6 -L 1 sh -c 'bash "$0/verify_os.sh" container "$2" "$1" "$3"' "$HERE"

cat "$OUT"/*.tsv > "$OUT/results.tsv"
bash "$HERE/summary.sh" "$OUT/results.tsv"
