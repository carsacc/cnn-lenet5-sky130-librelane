#!/usr/bin/env bash
# drc_klayout.sh — Run KLayout DRC as LibreLane does, on a standalone GDS
# Usage: bash drc_klayout.sh <gds_file> [topcell] [report_name]

set -euo pipefail

GDS="${1:?Usage: $0 <gds_file> [topcell] [report_name]}"
TOPCELL="${2:-${GDS%.gds}}"
REPORT="${3:-drc}"

PDK_VERSION="8afc8346a57fe1ab7934ba5a6056ea8b43078e71"
PDK_ROOT="$HOME/.ciel/ciel/sky130/versions/$PDK_VERSION"
DRC_SCRIPT="$PDK_ROOT/sky130A/libs.tech/klayout/drc/sky130A_mr.drc"
NPROC=$(nproc)

echo "=== KLayout DRC ==="
echo "  GDS:      $GDS"
echo "  TopCell:  $TOPCELL"
echo "  Report:   ${REPORT}.lyrdb / ${REPORT}.json"
echo "  Threads:  $NPROC"

mkdir -p "$(dirname "$REPORT")"

klayout -b -zz \
  -r "$DRC_SCRIPT" \
  -rd input="$GDS" \
  -rd topcell="$TOPCELL" \
  -rd report="${REPORT}.lyrdb" \
  -rd feol=true \
  -rd beol=true \
  -rd floating_metal=false \
  -rd offgrid=true \
  -rd seal=true \
  -rd threads="$NPROC"

echo ""
echo "DRC done. Report: ${REPORT}.lyrdb"

# Optional: convert to JSON (requires librelane env, uncomment if available)
# python3 /path/to/librelane/scripts/klayout/xml_drc_report_to_json.py \
#   --xml-file="${REPORT}.lyrdb" \
#   --json-file="${REPORT}.json" \
#   --metric=klayout__drc_error__count 2>/dev/null || true
