###############################################################################
# SDC constraints for cnn_top — CNN Accelerator with OBI slave interface
###############################################################################

# Clock definition — 15 MHz (66.67 ns period)
create_clock -name clk -period 66.67 [get_ports {clk}]
set_clock_uncertainty 0.5 [get_clocks {clk}]

# Reset is synchronous — constrain as normal input
set_false_path -from [get_ports {reset}]

# I/O delays — exclude clk from input_delay to avoid STA-0441
set_input_delay  20.0 -clock clk [lsearch -inline -all -not [all_inputs] [get_ports {clk}]]
set_output_delay 20.0 -clock clk [all_outputs]

# Relax global data-path slew to accommodate SRAM macro outputs
# (inherently slow in SS corner, up to ~2.5 ns; does not affect clock tree)
set_max_transition 3.0 -data_path [current_design]
