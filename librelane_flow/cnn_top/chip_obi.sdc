###############################################################################
# SDC constraints for chip_top — Padring wrapper for cnn_top
###############################################################################

# Clock — 15 MHz (66.67 ns period)
# Define on the pad cell output pin so CTS can build the clock tree
create_clock -name clk -period 66.67 [get_pins pad_clk_inst/IN]
set_clock_uncertainty 0.5 [get_clocks {clk}]

# Reset — synchronous but treat as false path for setup
set_false_path -from [get_ports {pad_reset}]

# Input delays on signal pads
set_input_delay  20.0 -clock clk [get_ports {pad_obi_req pad_obi_we pad_obi_be0 pad_obi_be1}]

# Output delays on signal pads
set_output_delay 20.0 -clock clk [get_ports {pad_obi_gnt pad_obi_rvalid}]

# Relax data-path slew to accommodate SRAM macro outputs
set_max_transition 3.0 -data_path [current_design]
