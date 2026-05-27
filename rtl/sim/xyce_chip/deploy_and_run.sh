#!/bin/bash
# deploy_and_run.sh — Prepare, upload, and run Xyce SPICE simulation of chip_top_spi
#
# Usage: bash deploy_and_run.sh [--dry-run]
#   --dry-run: prepare files locally but don't upload or run

set -euo pipefail

# ---- Configuration (override via environment) ----
SERVER="${XYCE_SERVER:?Set XYCE_SERVER (e.g. user@host)}"
REMOTE_DIR="${XYCE_REMOTE_DIR:-/tmp/xyce_sim/chip_spi}"
XYCE="${XYCE_BIN:-Xyce}"
NPROCS="${XYCE_NPROCS:-4}"

# ---- Local paths ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FLOW_DIR="${REPO_ROOT}/librelane_flow/cnn_top"
SRAM_DIR="${REPO_ROOT}/rtl/macros"
RUN_NAME="${1:?Usage: $0 <run_name> [--dry-run]}"
shift
CHIP_SPICE="${FLOW_DIR}/runs/${RUN_NAME}/final/spice/chip_top_spi.spice"

WORK="${SCRIPT_DIR}/build"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
CHIP_SPICE="${FLOW_DIR}/runs/${RUN_NAME}/final/spice/chip_top_spi.spice"

echo "=== Xyce Chip SPICE Simulation Setup ==="
echo "  Run:     ${RUN_NAME}"
echo "  Server:  ${SERVER}"
echo "  Cores:   ${NPROCS}"
echo ""

# ---- Step 1: Generate testbench ----
echo "[1/5] Generating Xyce testbench..."
cd "${SCRIPT_DIR}"
python3 gen_xyce_tb.py
echo ""

# ---- Step 2: Extract clean chip netlist (strip black-box stubs) ----
echo "[2/5] Extracting chip netlist (removing black-box stubs)..."
if [ ! -f "${CHIP_SPICE}" ]; then
    echo "ERROR: Chip SPICE not found: ${CHIP_SPICE}"
    exit 1
fi

# The chip_top_spi subcircuit starts at line containing ".subckt chip_top_spi "
# Everything before that are black-box stubs that we replace with real models
START_LINE=$(grep -n "^\.subckt chip_top_spi " "${CHIP_SPICE}" | head -1 | cut -d: -f1)
if [ -z "${START_LINE}" ]; then
    echo "ERROR: Could not find .subckt chip_top_spi in ${CHIP_SPICE}"
    exit 1
fi

echo "  Chip subcircuit starts at line ${START_LINE}"
TOTAL_LINES=$(wc -l < "${CHIP_SPICE}")
echo "  Total lines: ${TOTAL_LINES}, extracting $((TOTAL_LINES - START_LINE + 1)) lines"

tail -n +${START_LINE} "${CHIP_SPICE}" > chip_netlist.spice
echo "  Written: chip_netlist.spice ($(wc -c < chip_netlist.spice | tr -d ' ') bytes)"
echo ""

# ---- Step 3: Prepare SRAM models (remove duplicates between 1024 and 2048) ----
echo "[3/5] Preparing SRAM SPICE models..."
cp "${SRAM_DIR}/sky130_sram_1rw1r_32x2048_8/trimmed.sp" sram_2048_trimmed.sp

# The 1024 SRAM shares base cells with 2048 (openram_dff, dp_cell, sense_amp, etc.)
# Xyce treats duplicate .SUBCKT as errors, so strip shared cells from 1024
# Shared cells: sky130_fd_bd_sram__openram_*  (defined in both files)
SHARED_CELLS=(
    sky130_fd_bd_sram__openram_dff
    sky130_fd_bd_sram__openram_dp_nand2_dec
    sky130_fd_bd_sram__openram_dp_nand3_dec
    sky130_fd_bd_sram__openram_sense_amp
    sky130_fd_bd_sram__openram_write_driver
    sky130_fd_bd_sram__openram_dp_cell
    sky130_fd_bd_sram__openram_dp_cell_dummy
    sky130_fd_bd_sram__openram_dp_cell_replica
)

cp "${SRAM_DIR}/sky130_sram_1rw1r_32x1024_8/trimmed.sp" sram_1024_trimmed.sp

# Build awk pattern to remove duplicate subcircuit blocks
AWK_PATTERN=""
for cell in "${SHARED_CELLS[@]}"; do
    CELL_UPPER=$(echo "$cell" | tr '[:lower:]' '[:upper:]')
    if [ -n "$AWK_PATTERN" ]; then
        AWK_PATTERN="${AWK_PATTERN}|"
    fi
    AWK_PATTERN="${AWK_PATTERN}${cell}|${CELL_UPPER}"
done

# Remove matching .SUBCKT ... .ENDS blocks (case-insensitive subckt name match)
awk -v pat="$AWK_PATTERN" '
BEGIN { skip=0; IGNORECASE=1 }
/^\.subckt / {
    name = $2
    if (match(name, "^(" pat ")$")) {
        skip = 1
        next
    }
}
/^\.ends/ {
    if (skip) { skip = 0; next }
}
{ if (!skip) print }
' sram_1024_trimmed.sp > sram_1024_clean.sp
mv sram_1024_clean.sp sram_1024_trimmed.sp

echo "  sram_2048_trimmed.sp: $(wc -l < sram_2048_trimmed.sp) lines"
echo "  sram_1024_trimmed.sp: $(wc -l < sram_1024_trimmed.sp) lines (shared cells stripped)"
echo ""

# ---- Step 4: Upload to server ----
FILES=(
    chip_spi_tb.cir
    chip_netlist.spice
    pad_models.spice
    sram_1024_trimmed.sp
    sram_2048_trimmed.sp
)

echo "[4/5] Files to upload:"
for f in "${FILES[@]}"; do
    SIZE=$(du -h "$f" | cut -f1)
    echo "  ${f} (${SIZE})"
done
echo ""

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY RUN] Skipping upload and execution."
    echo "Files are ready in: ${SCRIPT_DIR}/"
    exit 0
fi

echo "  Creating remote directory: ${REMOTE_DIR}"
ssh "${SERVER}" "mkdir -p ${REMOTE_DIR}"

echo "  Uploading files..."
rsync -avP "${FILES[@]}" "${SERVER}:${REMOTE_DIR}/"
echo ""

# ---- Step 5: Launch simulation ----
echo "[5/5] Launching Xyce simulation on ${SERVER} with ${NPROCS} cores..."
echo "  Command: mpirun -np ${NPROCS} ${XYCE} chip_spi_tb.cir"
echo ""
echo "  *** Simulation will run in background on server ***"
echo "  *** Output: ${REMOTE_DIR}/chip_spi_tb.cir.prn ***"
echo ""

# Run in background on server with nohup, redirect output to log
ssh "${SERVER}" "cd ${REMOTE_DIR} && nohup mpirun -np ${NPROCS} ${XYCE} chip_spi_tb.cir > xyce_run.log 2>&1 &"

echo "  Simulation launched! Monitor with:"
echo "    ssh ${SERVER} 'tail -f ${REMOTE_DIR}/xyce_run.log'"
echo ""
echo "  Check status:"
echo "    ssh ${SERVER} 'ps aux | grep Xyce | grep -v grep'"
echo ""
echo "  When done, retrieve results:"
echo "    scp ${SERVER}:${REMOTE_DIR}/chip_spi_tb.cir.prn ."
echo ""
echo "=== Done ==="
