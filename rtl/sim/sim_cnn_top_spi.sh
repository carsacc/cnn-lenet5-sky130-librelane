#!/bin/bash
# RTL simulation of cnn_top (SPI interface) using Icarus Verilog
# Usage: bash rtl/sim/sim_cnn_top_spi.sh [NUM_IMAGES]
#   NUM_IMAGES defaults to 3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RTL_DIR="${REPO_ROOT}/rtl/modules"
SIM_DIR="${REPO_ROOT}/rtl/sim"
MACRO_DIR="${REPO_ROOT}/rtl/macros"

NUM_IMAGES=${1:-3}

echo "Compiling tb_top_spi (SPI interface)..."

iverilog -g2012 -DUSE_SPI_INTERFACE -o ${SIM_DIR}/tb_top_spi.out \
    ${RTL_DIR}/tb_top_spi.sv \
    ${RTL_DIR}/cnn_top.v \
    ${RTL_DIR}/spi_interface.v \
    ${RTL_DIR}/layer_sequencer.v \
    ${RTL_DIR}/param_memory.v \
    ${RTL_DIR}/activation_buffer.v \
    ${RTL_DIR}/conv_layer_ctrl.v \
    ${RTL_DIR}/gap_fc_layer_ctrl.v \
    ${RTL_DIR}/compute_top.v \
    ${RTL_DIR}/compute_core_parallel.v \
    ${RTL_DIR}/data_bus.v \
    ${RTL_DIR}/mac_unit.v \
    ${RTL_DIR}/post_proc_unit.v \
    ${RTL_DIR}/gap_unit.v \
    ${RTL_DIR}/argmax_unit.v \
    ${RTL_DIR}/line_buffer.v \
    ${MACRO_DIR}/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.v \
    ${MACRO_DIR}/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.v

if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

echo "Running simulation with ${NUM_IMAGES} images..."
echo "(All data loaded via SPI — this will take several minutes)"
cd ${SIM_DIR} && vvp tb_top_spi.out +NUM_IMAGES=${NUM_IMAGES}
