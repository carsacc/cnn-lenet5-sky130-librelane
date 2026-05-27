# 1. Cargar la tecnología y geometrías (LEFs)
# PDK_ROOT: set via environment, or default to ~/.ciel/sky130A
if {[info exists ::env(PDK_ROOT)]} {
    set PDK_PATH "$::env(PDK_ROOT)/libs.ref/sky130_fd_sc_hd"
} else {
    set PDK_PATH "$::env(HOME)/.ciel/sky130A/libs.ref/sky130_fd_sc_hd"
}
# SRAM path relative to this script's location
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SRAM_PATH "[file dirname $SCRIPT_DIR]/sram"

read_lef  ${PDK_PATH}/techlef/sky130_fd_sc_hd__nom.tlef
read_lef  ${PDK_PATH}/lef/sky130_fd_sc_hd.lef
read_lef  ${SRAM_PATH}/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.lef
read_lef  ${SRAM_PATH}/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.lef

# 2. Cargar temporización (LIBs) - Necesario para link_design
read_liberty ${PDK_PATH}/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty ${SRAM_PATH}/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8_TT_1p8V_25C.lib
read_liberty ${SRAM_PATH}/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8_TT_1p8V_25C.lib

# 3. Cargar el diseño lógico (dummy con instancias de macros)
read_verilog dummy.v

# 4. Construir la base de datos en memoria
link_design dummy

# ---------------------------------------------------------
# A PARTIR DE AQUÍ YA PUEDES JUGAR CON EL FLOORPLAN FÍSICO
# ---------------------------------------------------------

# 5. Inicializar el recuadro del chip (micras)
initialize_floorplan -die_area {0.0 0.0 2200.0 2200.0} \
                     -core_area {210.0 210.0 1990.0 1990.0} \
                     -site unithd

# 5b. Crear la rejilla de tracks de ruteo
make_tracks

# 6. Colocar las macros (nombre de instancia en el dummy.v)
# 4KB (1024w): 701.64 x 673.34 um
place_macro -macro_name u_sram_4kb \
           -location {1200.0 250.0} \
           -orientation MX

# 8KB (2048w): 1110.54 x 723.85 um
place_macro -macro_name u_sram_8kb \
           -location {795.0 1200.0} \
           -orientation R0

# 7. Abrir la interfaz para ver el resultado
gui::show
