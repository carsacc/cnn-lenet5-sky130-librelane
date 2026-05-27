###############################################################################
# SDC constraints for chip_top_spi — Padring wrapper for cnn_top (SPI mode)
###############################################################################

# Core clock — 15 MHz (66.67 ns period)
# Define on the pad cell output pin so CTS can build the clock tree
create_clock -name clk -period 66.67 [get_pins pad_clk_inst/IN]
set_clock_uncertainty 0.5 [get_clocks {clk}]

# SPI clock — ~2 MHz max (clk/8), enters through GPIO pad
# Sampled as data by 2-FF synchronizer, but declared for STA methodology
create_clock -name spi_clk -period 500 [get_pins pad_spi_sclk_inst/IN]

# Core and SPI clock domains are completely asynchronous
set_clock_groups -asynchronous -group {clk} -group {spi_clk}

# Reset — synchronous but treat as false path for setup
set_false_path -from [get_ports {pad_reset}]

# SPI data signals constrained to spi_clk domain
set_input_delay  100.0 -clock spi_clk [get_ports {pad_spi_cs_n pad_spi_mosi}]
set_output_delay 100.0 -clock spi_clk [get_ports {pad_spi_miso}]

# Relax data-path slew to accommodate SRAM macro outputs
set_max_transition 3.0 -data_path [current_design]
