#!/bin/bash
# Post-synthesis gate-level simulation (functional, no SDF) using Icarus Verilog
# Usage: ./sim_cnn_top_postsynth.sh [run_name] [num_images] [clk_period_ns]
#   run_name:       LibreLane run directory name (required)
#   num_images:     number of test images (default: 3)
#   clk_period_ns:  clock period in ns (default: 100)
#
# Environment:
#   PDK_ROOT  — path to sky130A root (auto-detected from ciel if unset)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL_DIR="${REPO_ROOT}/rtl/modules"
SIM_DIR="${REPO_ROOT}/rtl/sim"
MACRO_DIR="${REPO_ROOT}/rtl/macros"

# PDK: PDK_ROOT defaults to ~/.ciel; sky130A is the variant used in this repo
PDK_ROOT="${PDK_ROOT:-$HOME/.ciel}"
PDK_DIR="${PDK_ROOT}/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
if [ ! -d "$PDK_DIR" ]; then
    echo "ERROR: sky130A not found under PDK_ROOT=${PDK_ROOT}."
    echo "  Expected: ${PDK_DIR}"
    exit 1
fi

RUN_NAME="${1:?Usage: $0 <run_name> [num_images] [clk_period_ns]}"
NUM_IMAGES="${2:-3}"
CLK_PERIOD="${3:-100}"

RUN_DIR="${REPO_ROOT}/librelane_flow/cnn_top/runs/${RUN_NAME}"
NETLIST="${RUN_DIR}/06-yosys-synthesis/cnn_top.nl.v"

echo "=== Post-Synthesis GLS (functional) with Icarus ==="
echo "  Run:       $RUN_NAME"
echo "  Netlist:   $NETLIST"
echo "  PDK:       $PDK_DIR"
echo "  Images:    $NUM_IMAGES"
echo "  Clock:     ${CLK_PERIOD} ns"
echo ""

if [ ! -f "$NETLIST" ]; then
    echo "ERROR: Netlist not found: $NETLIST"
    exit 1
fi

iverilog -g2012 -DPOSTSYNTH -DFUNCTIONAL -o ${SIM_DIR}/tb_top_spi_postsynth.out \
    ${RTL_DIR}/tb_top_spi.sv \
    ${NETLIST} \
    ${PDK_DIR}/primitives.v \
    ${PDK_DIR}/sky130_fd_sc_hd.v \
    ${MACRO_DIR}/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.v \
    ${MACRO_DIR}/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.v

if [ $? -ne 0 ]; then
    echo "ERROR: Compilation failed"
    exit 1
fi

cd ${SIM_DIR} && vvp tb_top_spi_postsynth.out +NUM_IMAGES=${NUM_IMAGES} +CLK_PERIOD_NS=${CLK_PERIOD}
