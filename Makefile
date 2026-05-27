# ============================================================================
# CNN LeNet-5 ASIC Accelerator — Top-Level Makefile
# ============================================================================
#
# Usage:
#   make help              Show all targets
#   make check-env         Verify tools are installed
#   make sim-all           Run all unit + integration RTL sims
#   make sim-unit          Run all unit-level testbenches
#   make sim-top           Run top-level RTL sims (OBI + SPI)
#   make sim-gls RUN=name  Gate-level sims (post-synth, post-PnR)
#   make train             Train + quantize + export hex
#   make flow RUN=name     Run LibreLane physical design flow
#
# Variables:
#   NUM_IMAGES  — test images for top-level sims (default: 3)
#   RUN         — LibreLane run name (required for GLS/flow targets)
#   CORNER      — SDF corner: ss, tt, ff (default: tt)
#   CLK_PERIOD  — clock period in ns (default: 100)
# ============================================================================

SHELL      := /bin/bash
.DEFAULT_GOAL := help

# ---- Paths (all relative to repo root) ----
REPO_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR    := $(REPO_ROOT)/rtl/modules
SIM_DIR    := $(REPO_ROOT)/rtl/sim
MACRO_DIR  := $(REPO_ROOT)/rtl/macros
PYTHON_DIR := $(REPO_ROOT)/python
DATA_DIR   := $(REPO_ROOT)/datos_hex_std
FLOW_DIR   := $(REPO_ROOT)/librelane_flow/cnn_top

# ---- User-configurable variables ----
NUM_IMAGES ?= 3
CORNER     ?= tt
CLK_PERIOD ?= 100
RUN        ?=

# ---- Tools ----
IVERILOG   := iverilog -g2012
VVP        := vvp
PYTHON     := python3

# ---- SRAM macros (shared by most testbenches) ----
SRAM_1024  := $(MACRO_DIR)/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.v
SRAM_2048  := $(MACRO_DIR)/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.v
SRAM_ALL   := $(SRAM_1024) $(SRAM_2048)

# ---- RTL source groups ----
# Core compute path
RTL_COMPUTE := $(RTL_DIR)/mac_unit.v \
               $(RTL_DIR)/post_proc_unit.v \
               $(RTL_DIR)/gap_unit.v \
               $(RTL_DIR)/argmax_unit.v \
               $(RTL_DIR)/compute_core_parallel.v \
               $(RTL_DIR)/compute_top.v

# Data + control
RTL_CONTROL := $(RTL_DIR)/data_bus.v \
               $(RTL_DIR)/line_buffer.v \
               $(RTL_DIR)/conv_layer_ctrl.v \
               $(RTL_DIR)/gap_fc_layer_ctrl.v \
               $(RTL_DIR)/layer_sequencer.v

# Memory
RTL_MEMORY  := $(RTL_DIR)/param_memory.v \
               $(RTL_DIR)/activation_buffer.v

# Full cnn_top (OBI)
RTL_CNN_OBI := $(RTL_DIR)/cnn_top.v \
               $(RTL_DIR)/host_interface.v \
               $(RTL_COMPUTE) $(RTL_CONTROL) $(RTL_MEMORY)

# Full cnn_top (SPI)
RTL_CNN_SPI := $(RTL_DIR)/cnn_top.v \
               $(RTL_DIR)/spi_interface.v \
               $(RTL_COMPUTE) $(RTL_CONTROL) $(RTL_MEMORY)

# ---- Output directory for compiled sims ----
BUILD      := $(SIM_DIR)

# ============================================================================
# PHONY targets
# ============================================================================
.PHONY: help check-env sim-all sim-unit sim-top sim-gls \
        tb-mac tb-postproc tb-gap tb-argmax tb-line-buffer \
        tb-param-mem tb-act-buf tb-data-bus \
        tb-compute-core tb-conv-ctrl tb-gfc-ctrl \
        tb-layer-seq tb-host-if tb-spi-if \
        sim-obi sim-spi \
        gls-postsynth gls-postsynth-obi gls-postpnr gls-postpnr-obi gls-sdf \
        librelane-spi-hardened-5 librelane-obi-hardened-2 librelane-spi-chip-hier-28 \
        librelane-shift-reg \
        train gen-hex clean

# ============================================================================
# Help
# ============================================================================
help:
	@echo ""
	@echo "CNN LeNet-5 ASIC — Makefile targets"
	@echo "===================================="
	@echo ""
	@echo "  Environment:"
	@echo "    check-env           Verify required tools are installed"
	@echo ""
	@echo "  Unit testbenches (RTL):"
	@echo "    sim-unit            Run ALL unit testbenches"
	@echo "    tb-mac              mac_unit"
	@echo "    tb-postproc         post_proc_unit"
	@echo "    tb-gap              gap_unit"
	@echo "    tb-argmax           argmax_unit"
	@echo "    tb-line-buffer      line_buffer"
	@echo "    tb-param-mem        param_memory"
	@echo "    tb-act-buf          activation_buffer"
	@echo "    tb-data-bus         data_bus"
	@echo "    tb-compute-core     compute_core_parallel"
	@echo "    tb-conv-ctrl        conv_layer_ctrl"
	@echo "    tb-gfc-ctrl         gap_fc_layer_ctrl"
	@echo "    tb-layer-seq        layer_sequencer"
	@echo "    tb-host-if          host_interface"
	@echo "    tb-spi-if           spi_interface"
	@echo ""
	@echo "  Top-level RTL simulation:"
	@echo "    sim-top             Run OBI + SPI top-level sims"
	@echo "    sim-obi             cnn_top via OBI  (NUM_IMAGES=$(NUM_IMAGES))"
	@echo "    sim-spi             cnn_top via SPI  (NUM_IMAGES=$(NUM_IMAGES))"
	@echo ""
	@echo "  Gate-level simulation (require RUN=<run_name>):"
	@echo "    sim-gls             All GLS: post-synth + post-PnR"
	@echo "    gls-postsynth       Post-synthesis (Icarus, SPI TB)"
	@echo "    gls-postsynth-obi   Post-synthesis (Icarus, OBI TB)"
	@echo "    gls-postpnr         Post-PnR functional (Icarus, SPI TB)"
	@echo "    gls-postpnr-obi     Post-PnR functional (Icarus, OBI TB)"
	@echo "    gls-sdf             Post-PnR + SDF (CVC64, CORNER=$(CORNER))"
	@echo ""
	@echo "  Physical flow (require nix-shell ~/ASIC/tools/librelane):"
	@echo "    librelane-spi-hardened-5     Core SPI hardened (run-tag spi-hardened-5)"
	@echo "    librelane-obi-hardened-2     Core OBI hardened (run-tag obi-hardened-2)"
	@echo "    librelane-spi-chip-hier-28   Chip integrado SPI (depende del core SPI)"
	@echo "    librelane-shift-reg          Flujo de prueba (shift-reg 8 bits, run-tag shift-reg-test)"
	@echo ""
	@echo "  Full regression:"
	@echo "    sim-all             All unit + top-level RTL sims"
	@echo ""
	@echo "  Python / training:"
	@echo "    train               Train, quantize, export hex + golden models"
	@echo "    gen-hex             Generate param memory image from hex files"
	@echo ""
	@echo "  Cleanup:"
	@echo "    clean               Remove compiled simulation outputs"
	@echo ""

# ============================================================================
# Environment check
# ============================================================================
check-env:
	@echo "Checking environment..."
	@ok=1; \
	for tool in iverilog vvp python3; do \
		if command -v $$tool >/dev/null 2>&1; then \
			printf "  %-20s OK (%s)\n" "$$tool" "$$(command -v $$tool)"; \
		else \
			printf "  %-20s MISSING\n" "$$tool"; ok=0; \
		fi; \
	done; \
	for tool in cvc64; do \
		if command -v $$tool >/dev/null 2>&1; then \
			printf "  %-20s OK (%s)\n" "$$tool" "$$(command -v $$tool)"; \
		else \
			printf "  %-20s not found (optional, needed for SDF sims)\n" "$$tool"; \
		fi; \
	done; \
	pdk_root="$${PDK_ROOT:-$$HOME/.ciel}"; \
	if [ -d "$$pdk_root/sky130A/libs.ref" ]; then \
		printf "  %-20s %s\n" "PDK_ROOT" "$$pdk_root"; \
	else \
		printf "  %-20s %s (sky130A not found, needed for GLS)\n" "PDK_ROOT" "$$pdk_root"; \
	fi; \
	if [ -f "$(SRAM_1024)" ] && [ -f "$(SRAM_2048)" ]; then \
		printf "  %-20s OK\n" "SRAM macros"; \
	else \
		printf "  %-20s MISSING (check rtl/macros/)\n" "SRAM macros"; ok=0; \
	fi; \
	if [ -d "$(DATA_DIR)" ]; then \
		printf "  %-20s OK\n" "datos_hex_std"; \
	else \
		printf "  %-20s MISSING\n" "datos_hex_std"; ok=0; \
	fi; \
	echo ""; \
	if [ "$$ok" -eq 1 ]; then echo "Environment OK."; else echo "Some tools missing."; exit 1; fi

# ============================================================================
# Generic compile-and-run rules
#   run_tb:     runs vvp from repo root (for unit TBs and tb_layer_sequencer)
#   run_tb_sim: runs vvp from rtl/sim/  (for tb_top_obi, tb_top_spi — hex paths use ../../)
# ============================================================================
define run_tb
	@echo "=== $(1) ==="
	@$(IVERILOG) -o $(BUILD)/$(1).out $(2) && \
	 cd $(REPO_ROOT) && $(VVP) $(BUILD)/$(1).out +REPO_ROOT=$(REPO_ROOT) $(3) && \
	 echo "" || { echo "FAIL: $(1)"; exit 1; }
endef

define run_tb_sim
	@echo "=== $(1) ==="
	@$(IVERILOG) -o $(BUILD)/$(1).out $(2) && \
	 cd $(SIM_DIR) && $(VVP) $(BUILD)/$(1).out +REPO_ROOT=$(REPO_ROOT) $(3) && \
	 echo "" || { echo "FAIL: $(1)"; exit 1; }
endef

# ============================================================================
# Unit Testbenches
# ============================================================================

tb-mac:
	$(call run_tb,tb_mac_unit, \
		$(RTL_DIR)/tb_mac_unit.sv $(RTL_DIR)/mac_unit.v)

tb-postproc:
	$(call run_tb,tb_post_proc_unit, \
		$(RTL_DIR)/tb_post_proc_unit.sv $(RTL_DIR)/post_proc_unit.v)

tb-gap:
	$(call run_tb,tb_gap_unit, \
		$(RTL_DIR)/tb_gap_unit.sv $(RTL_DIR)/gap_unit.v)

tb-argmax:
	$(call run_tb,tb_argmax_unit, \
		$(RTL_DIR)/tb_argmax_unit.sv $(RTL_DIR)/argmax_unit.v)

tb-line-buffer:
	$(call run_tb,tb_line_buffer, \
		$(RTL_DIR)/tb_line_buffer.sv $(RTL_DIR)/line_buffer.v)

tb-param-mem:
	$(call run_tb,tb_param_memory, \
		$(RTL_DIR)/tb_param_memory.sv $(RTL_DIR)/param_memory.v $(SRAM_2048))

tb-act-buf:
	$(call run_tb,tb_activation_buffer, \
		$(RTL_DIR)/tb_activation_buffer.sv $(RTL_DIR)/activation_buffer.v $(SRAM_1024))

tb-data-bus:
	$(call run_tb,tb_data_bus, \
		$(RTL_DIR)/tb_data_bus.sv $(RTL_DIR)/data_bus.v)

tb-compute-core:
	$(call run_tb,tb_compute_core_parallel, \
		$(RTL_DIR)/tb_compute_core_parallel.sv \
		$(RTL_DIR)/compute_core_parallel.v \
		$(RTL_DIR)/mac_unit.v $(RTL_DIR)/post_proc_unit.v)

tb-conv-ctrl:
	$(call run_tb,tb_conv_layer_ctrl, \
		$(RTL_DIR)/tb_conv_layer_ctrl.sv \
		$(RTL_DIR)/conv_layer_ctrl.v \
		$(RTL_DIR)/data_bus.v $(RTL_DIR)/compute_top.v $(RTL_DIR)/line_buffer.v \
		$(RTL_DIR)/activation_buffer.v $(RTL_DIR)/param_memory.v \
		$(RTL_DIR)/compute_core_parallel.v $(RTL_DIR)/mac_unit.v \
		$(RTL_DIR)/post_proc_unit.v $(RTL_DIR)/gap_unit.v $(RTL_DIR)/argmax_unit.v \
		$(SRAM_ALL))

tb-gfc-ctrl:
	$(call run_tb,tb_gap_fc_layer_ctrl, \
		$(RTL_DIR)/tb_gap_fc_layer_ctrl.sv \
		$(RTL_DIR)/gap_fc_layer_ctrl.v \
		$(RTL_DIR)/data_bus.v $(RTL_DIR)/compute_top.v \
		$(RTL_DIR)/activation_buffer.v $(RTL_DIR)/param_memory.v \
		$(RTL_DIR)/compute_core_parallel.v $(RTL_DIR)/mac_unit.v \
		$(RTL_DIR)/post_proc_unit.v $(RTL_DIR)/gap_unit.v $(RTL_DIR)/argmax_unit.v \
		$(SRAM_ALL))

tb-layer-seq:
	$(call run_tb,tb_layer_sequencer, \
		$(RTL_DIR)/tb_layer_sequencer.sv \
		$(RTL_DIR)/layer_sequencer.v \
		$(RTL_DIR)/data_bus.v $(RTL_DIR)/compute_top.v $(RTL_DIR)/line_buffer.v \
		$(RTL_DIR)/conv_layer_ctrl.v $(RTL_DIR)/gap_fc_layer_ctrl.v \
		$(RTL_DIR)/activation_buffer.v $(RTL_DIR)/param_memory.v \
		$(RTL_DIR)/compute_core_parallel.v $(RTL_DIR)/mac_unit.v \
		$(RTL_DIR)/post_proc_unit.v $(RTL_DIR)/gap_unit.v $(RTL_DIR)/argmax_unit.v \
		$(SRAM_ALL))

tb-host-if:
	$(call run_tb,tb_host_interface, \
		$(RTL_DIR)/tb_host_interface.sv \
		$(RTL_DIR)/host_interface.v \
		$(RTL_DIR)/param_memory.v $(RTL_DIR)/activation_buffer.v \
		$(SRAM_ALL))

tb-spi-if:
	$(call run_tb,tb_spi_interface, \
		$(RTL_DIR)/tb_spi_interface.sv \
		$(RTL_DIR)/spi_interface.v \
		$(RTL_DIR)/param_memory.v $(RTL_DIR)/activation_buffer.v \
		$(SRAM_ALL))

# ---- Aggregate unit target ----
sim-unit: tb-mac tb-postproc tb-gap tb-argmax tb-line-buffer \
          tb-param-mem tb-act-buf tb-data-bus \
          tb-compute-core tb-conv-ctrl tb-gfc-ctrl \
          tb-layer-seq tb-host-if tb-spi-if
	@echo "============================================"
	@echo "All unit testbenches PASSED"
	@echo "============================================"

# ============================================================================
# Top-Level RTL Simulation
# ============================================================================

sim-obi:
	$(call run_tb_sim,tb_top_obi, \
		$(RTL_DIR)/tb_top_obi.sv $(RTL_CNN_OBI) $(SRAM_ALL), \
		+NUM_IMAGES=$(NUM_IMAGES))

sim-spi:
	$(call run_tb_sim,tb_top_spi, \
		-DUSE_SPI_INTERFACE $(RTL_DIR)/tb_top_spi.sv $(RTL_CNN_SPI) $(SRAM_ALL), \
		+NUM_IMAGES=$(NUM_IMAGES))

sim-top: sim-obi sim-spi

# ---- Full regression ----
sim-all: sim-unit sim-top
	@echo "============================================"
	@echo "Full RTL regression PASSED"
	@echo "============================================"

# ============================================================================
# Gate-Level Simulation (require RUN=<name>)
# ============================================================================

_check-run:
	@if [ -z "$(RUN)" ]; then \
		echo "ERROR: RUN variable required. Usage: make <target> RUN=<run_name>"; \
		exit 1; \
	fi

gls-postsynth: _check-run
	bash $(SIM_DIR)/sim_cnn_top_postsynth.sh $(RUN) $(NUM_IMAGES) $(CLK_PERIOD)

gls-postsynth-obi: _check-run
	bash $(SIM_DIR)/sim_cnn_top_postsynth_obi.sh $(RUN) $(NUM_IMAGES) $(CLK_PERIOD)

gls-postpnr: _check-run
	bash $(SIM_DIR)/sim_cnn_top_postpnr.sh $(RUN) $(NUM_IMAGES) $(CLK_PERIOD)

gls-postpnr-obi: _check-run
	bash $(SIM_DIR)/sim_cnn_top_postpnr_obi.sh $(RUN) $(NUM_IMAGES) $(CLK_PERIOD)

gls-sdf: _check-run
	bash $(SIM_DIR)/sim_cnn_top_sdf.sh $(RUN) $(CORNER) $(NUM_IMAGES) $(CLK_PERIOD)

sim-gls: gls-postsynth gls-postpnr

# ============================================================================
# LibreLane — physical flow with reproducible run tags
# ============================================================================
# Estos targets deben ejecutarse DENTRO de nix-shell. El `--run-tag` es
# obligatorio para que el flujo chip-hier encuentre el core endurecido
# (config_chip_hier.json referencia runs/spi-hardened-5/final/...).

librelane-spi-hardened-5:
	librelane $(FLOW_DIR)/config_core_spi.json --run-tag spi-hardened-5

librelane-obi-hardened-2:
	librelane $(FLOW_DIR)/config_core_obi.json --run-tag obi-hardened-2

librelane-spi-chip-hier-28: librelane-spi-hardened-5
	librelane $(FLOW_DIR)/config_chip_hier.json --run-tag spi-chip-hier-28

librelane-shift-reg:
	librelane $(REPO_ROOT)/librelane_flow/shift-reg/config.json --run-tag shift-reg-test

# ============================================================================
# Python — Training & Hex Generation
# ============================================================================

train:
	@echo "=== Training, quantization, and hex export ==="
	$(PYTHON) $(PYTHON_DIR)/train_cnn_mnist_std.py \
		--epochs 10 --export-model --export-images 20 \
		--run-inference --inference-num-images 10 --inference-export-logits

gen-hex:
	@echo "=== Generating param memory image ==="
	$(PYTHON) $(PYTHON_DIR)/script_param_mem_gen.py

# ============================================================================
# Cleanup
# ============================================================================

clean:
	@echo "Cleaning compiled simulation outputs..."
	rm -f $(BUILD)/*.out $(BUILD)/*.vcd $(BUILD)/*.fst
	@echo "Done."
