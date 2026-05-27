import os

word_size = 32
write_size = 8
num_words = 2048
num_rw_ports = 1
num_r_ports = 1
num_w_ports = 0
num_banks = 1

num_threads = 43
num_sim_threads = 43

tech_name = "sky130"
process_corners = ["TT", "SS", "FF"]
supply_voltages = [1.80, 1.60, 1.95]
temperatures = [25, 100, -40]
use_specified_corners = [("TT", 1.80, 25), ("SS", 1.60, 100), ("FF", 1.95, -40)]

check_lvsdrc = False
trim_netlist = True
inline_lvsdrc = False

spice_name = "Xyce"
analytical_delay = False
use_conda = True

output_path = "sky130_sram_1rw1r_32x2048_8"
output_name = "sky130_sram_1rw1r_32x2048_8"
