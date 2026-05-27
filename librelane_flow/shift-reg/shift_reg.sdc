###############################################################################
# SDC para shift_reg — caso de prueba minimo para flujo LibreLane + SDF
###############################################################################

# Reloj a 100 MHz (periodo 10 ns). Holgado para un diseno de 8 FFs.
create_clock -name clk -period 10.0 [get_ports {clk}]
set_clock_uncertainty 0.25 [get_clocks {clk}]

# Reset sincrono. No es un camino critico, se excluye del analisis.
set_false_path -from [get_ports {reset}]

# Margenes de entrada/salida holgados (2 ns sobre periodo 10 ns)
set_input_delay  2.0 -clock clk [get_ports {en d_in}]
set_output_delay 2.0 -clock clk [get_ports {q_out[*]}]
