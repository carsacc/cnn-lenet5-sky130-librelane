#!/bin/bash
# Post-PnR gate-level simulation with SDF back-annotation using CVC64.
# Replica el flujo que sirvio para shift_reg, ahora sobre cnn_top.
#
# Usage: ./sim_cnn_top_sdf.sh <run_name> [corner] [num_images] [clk_period_ns] [dump_vcd] [mode]
#   run_name:       LibreLane run directory (required). Si el nombre
#                   contiene "spi" usa tb_top_spi.sv, si no tb_top_obi.sv.
#   corner:         tt (default), ss, ff
#   num_images:     numero de imagenes MNIST (default: 1)
#   clk_period_ns:  periodo de reloj (default: 100)
#   dump_vcd:       0=off (default), 1=FST dump
#   mode:           interp (default) o compiled

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

# CVC 7.00b no soporta +=>/-=> de los modelos sky130. Usamos la copia local
# rtl/sim/pdk_patched/ con esos operadores reemplazados. NUNCA tocamos el
# PDK original.
PDK_PATCHED="${SIM_DIR}/pdk_patched"
if [ -f "${PDK_PATCHED}/sky130_fd_sc_hd.v" ]; then
    PDK_MODELS_DIR="${PDK_PATCHED}"
else
    echo "WARNING: ${PDK_PATCHED} no encontrado; usando PDK original."
    PDK_MODELS_DIR="${PDK_DIR}"
fi

RUN_NAME="${1:?Usage: $0 <run_name> [corner] [num_images] [clk_period_ns] [dump_vcd] [mode]}"
CORNER="${2:-tt}"
NUM_IMAGES="${3:-1}"
CLK_PERIOD="${4:-100}"
DUMP_VCD="${5:-0}"
MODE="${6:-interp}"

RUN_DIR="${REPO_ROOT}/librelane_flow/cnn_top/runs/${RUN_NAME}"
NETLIST="${RUN_DIR}/final/pnl/cnn_top.pnl.v"
SDF_BASE="${RUN_DIR}/final/sdf"

# Detectar interfaz a partir del nombre del run.
# Para SPI usamos el TB en SystemVerilog ).
if [[ "$RUN_NAME" == *spi* ]]; then
    TB_FILE="${RTL_DIR}/tb_top_spi.sv"
    IFACE_DEFINE="+define+USE_SPI_INTERFACE"
    TB_TOP="tb_top_spi"
else
    TB_FILE="${RTL_DIR}/tb_top_obi.sv"
    IFACE_DEFINE=""
    TB_TOP="tb_top_obi"
fi

case "$CORNER" in
    ss) SDF_FILE="${SDF_BASE}/max_ss_100C_1v60/cnn_top__max_ss_100C_1v60.sdf"
        DELAY_FLAG="+maxdelays" ;;
    tt) SDF_FILE="${SDF_BASE}/nom_tt_025C_1v80/cnn_top__nom_tt_025C_1v80.sdf"
        DELAY_FLAG="+typdelays" ;;
    ff) SDF_FILE="${SDF_BASE}/max_ff_n40C_1v95/cnn_top__max_ff_n40C_1v95.sdf"
        DELAY_FLAG="+maxdelays" ;;
    custom) SDF_FILE="${SIM_DIR}/cnn_top__nom_tt_025C_1v80.sdf"
        DELAY_FLAG="+maxdelays" ;;
    *)  echo "Unknown corner: $CORNER (use ss, tt, or ff)"; exit 1 ;;
esac

SDF_LOG="${SIM_DIR}/sdf_${CORNER}.log"
EXECUTABLE="${SIM_DIR}/cnn_top_sdf_${CORNER}"

if [ "$DUMP_VCD" -eq 1 ]; then
    FST_FLAGS="+dump2fst +fst+parallel2=on"
else
    FST_FLAGS=""
fi

# Defines exactamente como funcionaron para shift_reg.
#   POSTSYNTH    -> habilita guards de jerarquia en el TB para netlist plana.
#   FUNCTIONAL   -> simulacion funcional, modelos del PDK sin specify.
#   USE_POWER_PINS -> los modelos exponen VPWR/VGND/VPB/VNB; el TB conecta
#                    vccd1/vssd1 dentro de los `ifdef USE_POWER_PINS.
SRC_FLAGS="\
    +define+POSTSYNTH +define+FUNCTIONAL +define+USE_POWER_PINS \
    +define+UNIT_DELAY=#0 \
    ${IFACE_DEFINE} \
    ${DELAY_FLAG} \
    +sdf_annotate ${SDF_FILE}+${TB_TOP}.u_dut \
    +sdf_log_file ${SDF_LOG} \
    +show_canceled_e \
    ${TB_FILE} \
    ${NETLIST} \
    ${PDK_MODELS_DIR}/primitives.v \
    -v ${PDK_MODELS_DIR}/sky130_fd_sc_hd.v \
    -v ${MACRO_DIR}/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.v \
    -v ${MACRO_DIR}/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.v"

RUN_FLAGS="+NUM_IMAGES=${NUM_IMAGES} +CLK_PERIOD_NS=${CLK_PERIOD} +DUMP_VCD=${DUMP_VCD} ${FST_FLAGS}"

echo "=== SDF Simulation with CVC64 ==="
echo "  Run:       $RUN_NAME"
echo "  Interfaz:  $TB_TOP  ($([[ -z "$IFACE_DEFINE" ]] && echo OBI || echo SPI))"
echo "  Corner:    $CORNER"
echo "  Delays:    $DELAY_FLAG"
echo "  Netlist:   $NETLIST"
echo "  SDF:       $SDF_FILE"
echo "  SDF log:   $SDF_LOG"
echo "  PDK uso:   $PDK_MODELS_DIR"
echo "  Images:    $NUM_IMAGES"
echo "  Clock:     ${CLK_PERIOD} ns"
echo "  Dump:      ${DUMP_VCD} (0=off, 1=FST)"
echo "  Mode:      $MODE"
echo ""

if [ ! -f "$NETLIST" ]; then
    echo "ERROR: Netlist not found: $NETLIST"
    exit 1
fi
if [ ! -f "$SDF_FILE" ]; then
    echo "ERROR: SDF not found: $SDF_FILE"
    exit 1
fi

cd ${SIM_DIR}

if [ "$MODE" = "compiled" ]; then
    echo "--- Compiling (this may take a while) ---"
    cvc64 -sv -Ogate +mipdopt +large +sdf_noerrors +notimingchecks +remove_gate_0delays \
        -o ${EXECUTABLE} \
        ${SRC_FLAGS} \
        ${RUN_FLAGS}

    if [ $? -ne 0 ]; then
        echo "ERROR: Compilation failed"
        exit 1
    fi

    echo "--- Running compiled simulation ---"
    ${EXECUTABLE} ${RUN_FLAGS}
else
    echo "--- Running interpreted simulation ---"
    cvc64 +interp -sv \
        ${SRC_FLAGS} \
        ${RUN_FLAGS}
fi
