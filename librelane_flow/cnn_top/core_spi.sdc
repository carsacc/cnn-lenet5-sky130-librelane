###############################################################################
# SDC constraints for cnn_top — CNN Accelerator with SPI slave interface
###############################################################################

# Core clock — 15 MHz (66.67 ns period)
create_clock -name clk -period 66.67 [get_ports {clk}]
set_clock_uncertainty 0.5 [get_clocks {clk}]

# SPI clock — ~2 MHz max (clk/8), received from external master
create_clock -name spi_clk -period 500 [get_ports {spi_sclk}]

# Domains are fully asynchronous (2-FF synchronizers in spi_interface.v)
set_clock_groups -asynchronous -group {clk} -group {spi_clk}

# Reset — synchronous to clk, but treat as false path
set_false_path -from [get_ports {reset}]

# SPI data I/O constrained to spi_clk domain
set_input_delay  100.0 -clock spi_clk [get_ports {spi_cs_n spi_mosi}]
set_output_delay 100.0 -clock spi_clk [get_ports {spi_miso}]

# Relax global data-path slew to accommodate SRAM macro outputs
set_max_transition 3.0 -data_path [current_design]
