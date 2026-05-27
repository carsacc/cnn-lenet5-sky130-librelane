# tb_top_obi.sv — Guia del Testbench Completo CNN Top-Level

## Ubicacion

```
rtl/modules/tb_top_obi.sv
```

Todas las rutas de datos (`$readmemh`) son relativas a `rtl/sim/`. Tanto la compilacion como la ejecucion deben hacerse desde ese directorio.

---

## Compilacion y Ejecucion

### Compilacion y ejecucion (desde la raiz del proyecto)

```bash
bash rtl/sim/sim_cnn_top.sh
```

O manualmente:

```bash
RTL_DIR=rtl/modules
MACRO_DIR=rtl/macros
SIM_DIR=rtl/sim

iverilog -g2012 -o ${SIM_DIR}/tb_top_obi.out \
  ${RTL_DIR}/tb_top_obi.sv \
  ${RTL_DIR}/cnn_top.v \
  ${RTL_DIR}/host_interface.v \
  ${RTL_DIR}/layer_sequencer.v \
  ${RTL_DIR}/param_memory.v \
  ${RTL_DIR}/activation_buffer.v \
  ${RTL_DIR}/conv_layer_ctrl.v \
  ${RTL_DIR}/gap_fc_layer_ctrl.v \
  ${RTL_DIR}/compute_top.v \
  ${RTL_DIR}/compute_core_parallel.v \
  ${RTL_DIR}/data_bus.v \
  ${RTL_DIR}/mac_unit.v \
  ${RTL_DIR}/post_proc_unit.v \
  ${RTL_DIR}/gap_unit.v \
  ${RTL_DIR}/argmax_unit.v \
  ${RTL_DIR}/line_buffer.v \
  ${MACRO_DIR}/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.v \
  ${MACRO_DIR}/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.v

cd ${SIM_DIR} && vvp tb_top_obi.out [+plusargs...]
```

---

## Plusargs de Configuracion

Todos los parametros son opcionales y se pasan en tiempo de ejecucion (sin recompilar):

| Plusarg | Default | Descripcion |
|---------|---------|-------------|
| `+NUM_IMAGES=N` | 10 | Numero de imagenes a testear en Phase E (1-20) |
| `+SHUFFLE=0/1` | 1 | 1 = orden aleatorio (Fisher-Yates), 0 = secuencial 0..N-1 |
| `+SEED=N` | aleatorio | Semilla para el shuffle (reproducibilidad) |
| `+TIMEOUT=N` | 2000000 | Maximo de polls OBI por inferencia antes de declarar timeout |
| `+STOP_ON_FAIL=0/1` | 0 | 1 = abortar simulacion al primer fallo |
| `+DUMP_VCD=0/1` | 0 | 1 = generar `tb_top_obi.vcd` en `rtl/sim/` |
| `+CLK_PERIOD_NS=N` | 10 | Periodo de reloj en ns (10 = 100 MHz, 5 = 200 MHz) |
| `+FREQ_SWEEP=0/1` | 0 | 1 = activar Phase F (barrido de frecuencias) |
| `+FREQ_MIN_NS=N` | 4 | Periodo minimo del barrido (4 ns = 250 MHz) |
| `+FREQ_MAX_NS=N` | 20 | Periodo maximo del barrido (20 ns = 50 MHz) |
| `+FREQ_STEP_NS=N` | 2 | Decremento del periodo en cada paso del barrido |

---

## Ejemplos de Uso

```bash
# Test rapido: 3 imagenes secuenciales, 100 MHz
vvp tb_top_obi.out +NUM_IMAGES=3 +SHUFFLE=0

# Regresion completa: 20 imagenes en orden aleatorio reproducible
vvp tb_top_obi.out +NUM_IMAGES=20 +SHUFFLE=1 +SEED=42

# Reloj personalizado: 200 MHz
vvp tb_top_obi.out +NUM_IMAGES=5 +CLK_PERIOD_NS=5

# Barrido de frecuencias: 50 MHz a 250 MHz en pasos de 4 ns
vvp tb_top_obi.out +NUM_IMAGES=1 +FREQ_SWEEP=1 \
  +FREQ_MIN_NS=4 +FREQ_MAX_NS=20 +FREQ_STEP_NS=4

# Debug: 1 imagen, parar al primer fallo, generar VCD
vvp tb_top_obi.out +NUM_IMAGES=1 +STOP_ON_FAIL=1 +DUMP_VCD=1

# Post-sintesis con netlist (compilar con el netlist en vez del RTL):
# iverilog -g2012 -o tb_top_obi_gl.out \
#   ../modules/tb_top_obi.sv netlist/cnn_top_synth.v ...
# vvp tb_top_obi_gl.out +FREQ_SWEEP=1 +FREQ_MIN_NS=8
```

---

## Fases de Test

El testbench ejecuta 6 fases secuencialmente (A-F) y al final imprime un resumen (G):

### Phase A — Host Data Readback

Verifica que la CPU host puede leer datos internos via OBI tras una inferencia completa (image_0, label esperado = 7):

- **FC logits**: lee 3 words desde buf_B (addrs 104-106, OBI 0x41A0-0x41A8), compara los 10 bytes contra `logits_image_0.hex` con tolerancia +-2 LSB
- **GAP values**: lee 32 words desde buf_B (addrs 72-103, OBI 0x4120-0x419C), compara byte 0 de cada word contra `golden/gap_image_0.hex` con tolerancia +-2 LSB
- **Conv3 spot-check**: lee 8 words desde el inicio de buf_B, verifica que no son todos cero

> La tolerancia +-2 LSB existe porque el hardware usa truncamiento en la division del GAP, mientras que el modelo Python usa round-half-to-even. Ambos producen la misma clasificacion final.

### Phase B — Back-to-Back Inference

Ejecuta 3 inferencias consecutivas (image_0, image_1, image_2) **sin hacer reset** entre ellas. Solo se hace reset antes de la primera. Verifica que la FSM del layer_sequencer vuelve a IDLE limpiamente y no hay contaminacion de estado entre inferencias.

### Phase C — Reset Mid-Inference

1. Inicia inferencia con image_0
2. Espera ~1000 ciclos (mitad de Conv1)
3. Aserta `reset` durante 5 ciclos
4. Verifica CSRs en estado por defecto (STATUS=0, RESULT=0)
5. Recarga datos, hace reset limpio, ejecuta inferencia completa
6. Verifica resultado correcto (label=7)

### Phase D — CSR Corner Cases

Pruebas del protocolo OBI y registros CSR:

| Sub-test | Descripcion |
|----------|-------------|
| D1 | Escritura al registro STATUS (read-only) — debe quedar inalterado |
| D2 | Escritura al registro RESULT (read-only) — debe quedar inalterado |
| D3 | Lectura de direccion CSR reservada (0x600C) — debe retornar 0 |
| D4 | 3 lecturas CSR consecutivas back-to-back — todas deben ser validas |
| D5 | Escritura a CTRL con byte-enable=0001 — solo byte 0 debe afectarse |
| D6 | Integridad de param_memory tras inferencia — snapshot de 6 words antes y despues |

### Phase E — Multi-Image Inference Loop

Para cada imagen en el conjunto (opcionalmente shuffled):

1. Carga parametros + imagen via backdoor
2. Ajusta biases de Conv1 (compensacion input_zp)
3. Reset → CTRL=1 → poll STATUS → lee RESULT
4. Compara contra label esperado (`image_N_label.txt`)
5. Registra ciclos por inferencia (min/avg/max)

Al final reporta accuracy (%) y estadisticas de ciclos.

### Phase F — Frequency Sweep (opcional)

Solo se ejecuta con `+FREQ_SWEEP=1`. Ejecuta image_0 a frecuencias decrecientes:

1. Empieza en `FREQ_MAX_NS` (frecuencia baja, segura)
2. Decrementa el periodo en `FREQ_STEP_NS` por cada paso
3. Para cada frecuencia: carga datos, reset, infiere, verifica result=7
4. Reporta ultima frecuencia que pasa y primera que falla

**Nota importante**: los resultados del frequency sweep son **informativos** y no afectan al veredicto final PASS/FAIL. Para RTL behavioral (zero-delay), todas las frecuencias razonables pasan. Este test cobra sentido con netlists post-sintesis con SDF back-annotation.

> En el modelo behavioral, a periodos muy cortos (< 6 ns) el delay fijo `#1` del testbench ocupa una fraccion significativa del periodo de reloj, lo cual puede causar fallos artificiales.

### Phase G — Summary

Ejemplo de salida:

```
================================================================
COMPREHENSIVE TEST SUMMARY
================================================================

Phase A — Host Readback:        PASS (44/44 checks)
Phase B — Back-to-Back:         PASS (3/3 inferences)
Phase C — Reset Mid-Inference:  PASS (3/3 checks)
Phase D — CSR Corner Cases:     PASS (6/6 checks)
Phase E — Multi-Image (N=20):   PASS 20/20 (100.0% accuracy)
Phase F — Freq Sweep:           SKIPPED

FINAL: 76 PASS, 0 FAIL out of 76 total checks

ALL TESTS PASSED
================================================================
```

---

## Mapa de Memoria OBI (referencia)

| Region | Base OBI | Tamanyo | Descripcion |
|--------|----------|---------|-------------|
| param_memory | 0x0000 | 8 KB | Pesos, biases, parametros de cuantizacion |
| buf A-region | 0x2000 | 2 KB | Buffer de activaciones (words 0-511) |
| buf B-region | 0x4000 | 2 KB | Buffer de activaciones (words 512-1023) |
| CSR | 0x6000 | 16 B | Registros de control/estado |

**Registros CSR:**

| Offset | Nombre | R/W | Descripcion |
|--------|--------|-----|-------------|
| 0x6000 | CTRL | R/W | Bit 0 = start (CPU escribe 1 para iniciar, 0 para liberar memorias) |
| 0x6004 | STATUS | RO | Bit 0 = done, Bit 1 = computing_valid |
| 0x6008 | RESULT | RO | Bits [3:0] = clase predicha (0-9) |
| 0x600C | — | RO | Reservado (retorna 0) |

**Direcciones de datos internos en buf_B (tras inferencia):**

| Dato | Word addr | OBI addr | Formato |
|------|-----------|----------|---------|
| Conv3 output | 0-71 | 0x4000-0x411C | 4 bytes/word empaquetados por canal |
| GAP output | 72-103 | 0x4120-0x419C | 1 byte/word (byte 0), 32 canales |
| FC logits | 104-106 | 0x41A0-0x41A8 | 4 bytes/word, 10 clases en 3 words |

---

## Datos Necesarios

El testbench requiere los siguientes ficheros en `datos_hex_std/` (relativo a la raiz del proyecto, accedido como `../../datos_hex_std/` desde `rtl/sim/`):

```
datos_hex_std/
  PARAM_MEM_32x2048.hex          # Parametros del modelo (2048 words)
  logits_image_0.hex             # Golden logits image_0 (10 bytes)
  golden/
    gap_image_0.hex              # Golden GAP image_0 (32 bytes)
  test_images/
    image_0.hex ... image_19.hex       # 20 imagenes MNIST (784 bytes cada una)
    image_0_label.txt ... image_19_label.txt  # Labels esperados (1 digito hex)
```

---

## Notas Tecnicas

- **SRAM VERBOSE=0**: el testbench desactiva las trazas debug de las instancias SRAM Sky130 via `defparam`, eliminando millones de lineas de output
- **Tolerancia +-2 LSB**: la comparacion de logits y GAP contra golden acepta diferencias de hasta 2 unidades para compensar diferencias de redondeo HW vs Python
- **Fisher-Yates shuffle**: implementado con `$urandom` para aleatorizar el orden de imagenes; reproducible con `+SEED=N`
- **Ajuste de biases Conv1**: compensa la diferencia entre input_zp=17 (sustraido en Python) y el MAC del hardware que trata pixeles como unsigned. Se aplica automaticamente antes de cada inferencia
- **Reloj configurable**: usa `real half_period` con `always #(half_period)`, permitiendo cambiar la frecuencia en runtime sin recompilar
