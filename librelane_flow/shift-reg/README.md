# mult/ — Caso de prueba mínimo para flujo SDF

Diseño de juguete (`shift_reg`, 8 FFs en cadena) para probar la cadena
LibreLane → netlist post-síntesis → SDF post-PnR → simulación con
anotación SDF en Icarus y CVC.

## Ficheros

- `shift_reg.v` — DUT. Registro de desplazamiento de 8 bits con reset
  síncrono y enable de avance. Sin macros, sin jerarquía interna.
- `tb_shift_reg.sv` — Testbench autocomprobado. Tres tests
  (shift de 16 patrones, hold con `en=0`, reset síncrono). Anotación SDF
  guarda con `\`ifdef SDF` y plusarg `+SDF_FILE=...`.
- `shift_reg.sdc` — Reloj a 100 MHz (periodo 10 ns), uncertainty
  0.25 ns. `false_path` sobre `reset`. Margenes de I/O 2 ns.
- `config.json` — Configuración LibreLane mínima. Die 80×80 µm,
  density 30 %, sin macros, KLayout como streamout primario.

## Flujo

### 1. Síntesis + PnR + signoff con LibreLane (genera netlist y SDF)

```bash
nix-shell ~/ASIC/tools/librelane
librelane librelane_flow/mult/config.json
```

Salidas relevantes en `runs/<RUN>/`.
- `06-yosys-synthesis/shift_reg.nl.v` — netlist post-síntesis.
- `final/pnl/shift_reg.pnl.v` — netlist post-PnR.
- `final/sdf/shift_reg__nom_tt_025C_1v80.sdf` — SDF por corner.

### 2. Simulación RTL (referencia funcional)

```bash
cd librelane_flow/mult
iverilog -g2012 -o sim_rtl.out shift_reg.v tb_shift_reg.sv
vvp sim_rtl.out
```

Debe emitir `ALL TESTS PASSED`.

### 3. Simulación GLS post-PnR + SDF con Icarus

```bash
RUN=<nombre del run>
PDK=$HOME/.ciel/sky130A/libs.ref/sky130_fd_sc_hd/verilog

iverilog -g2012 -DSDF -DFUNCTIONAL -o sim_sdf.out \
    runs/$RUN/final/pnl/shift_reg.pnl.v \
    $PDK/primitives.v \
    $PDK/sky130_fd_sc_hd.v \
    tb_shift_reg.sv

vvp sim_sdf.out +SDF_FILE=runs/$RUN/final/sdf/shift_reg__nom_tt_025C_1v80.sdf
```

### 4. Simulación GLS post-PnR + SDF con CVC

Mismo binario de Verilog que en Icarus, distinta invocación:

```bash
cvc64 \
    runs/$RUN/final/pnl/shift_reg.pnl.v \
    $PDK/primitives.v \
    $PDK/sky130_fd_sc_hd.v \
    tb_shift_reg.sv \
    +define+SDF +define+FUNCTIONAL \
    +sdf_verbose \
    +SDF_FILE=runs/$RUN/final/sdf/shift_reg__nom_tt_025C_1v80.sdf
```

## Notas

- El testbench instancia el DUT como `u_dut`, así que la anotación
  SDF apunta a esa instancia (`$sdf_annotate(<file>, u_dut)`).
- El periodo de 10 ns deja margen de sobra para los retardos del
  corner SS, así que las tres pruebas deberían pasar con SDF.
- Si se quiere probar el corner peor (SS), cambiar el nombre del
  fichero SDF a `shift_reg__max_ss_100C_1v60.sdf`.
