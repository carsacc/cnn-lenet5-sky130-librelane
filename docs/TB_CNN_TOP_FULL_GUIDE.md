# tb_top_spi.sv — Guia del Testbench Completo CNN Top-Level

## Ubicacion

```
rtl/modules/tb_top_spi.sv
```

El testbench carga todos los datos (parametros, imagen y biases ajustados de Conv1), arranca la inferencia y lee el resultado **exclusivamente a traves del bus SPI**. No usa accesos de backdoor a las SRAM. Es el testbench que valida el chip endurecido en el flujo `spi-hardened-5` y el chip integrado `spi-chip-hier-28`.

Las rutas de datos (`$readmemh`) son relativas a `rtl/sim/`. Tanto la compilacion como la ejecucion se hacen desde la raiz del proyecto.

---

## Compilacion y Ejecucion

### Atajo via Makefile

```bash
make sim-spi NUM_IMAGES=3
```

### Lanzamiento directo del script

```bash
bash rtl/sim/sim_cnn_top_spi.sh 3
```

### Invocacion manual

```bash
RTL_DIR=rtl/modules
MACRO_DIR=rtl/macros
SIM_DIR=rtl/sim

iverilog -g2012 -DUSE_SPI_INTERFACE -o ${SIM_DIR}/tb_top_spi.out \
  ${RTL_DIR}/tb_top_spi.sv \
  ${RTL_DIR}/cnn_top.v \
  ${RTL_DIR}/spi_interface.v \
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

cd ${SIM_DIR} && vvp tb_top_spi.out [+plusargs...]
```

> `-DUSE_SPI_INTERFACE` es obligatorio: hace que `cnn_top` instancie `spi_interface` en lugar de `host_interface`.

---

## Plusargs de Configuracion

El testbench SPI se controla con tres plusargs opcionales:

| Plusarg | Default | Descripcion |
|---------|---------|-------------|
| `+NUM_IMAGES=N` | 3 | Numero de imagenes a procesar en Phase B (1-20) |
| `+TIMEOUT=N` | 5000000 | Maximo de polls SPI por inferencia antes de declarar timeout |
| `+DUMP_VCD=0/1` | 0 | 1 = generar `tb_top_spi.vcd` en `rtl/sim/` |

---

## Ejemplos de Uso

```bash
# Test rapido: 3 imagenes (default)
make sim-spi

# Regresion: 20 imagenes
make sim-spi NUM_IMAGES=20

# Debug con VCD
vvp rtl/sim/tb_top_spi.out +NUM_IMAGES=1 +DUMP_VCD=1

# Post-PnR GLS con la netlist SPI (vease apendice de comandos)
make gls-postpnr RUN=spi-hardened-5

# Post-PnR + SDF (CVC64, corner TT)
make gls-sdf RUN=spi-hardened-5 CORNER=tt
```

---

## Protocolo SPI

Todas las transacciones son frames SPI de **56 bits** (Mode 0, CPOL=0, CPHA=0, MSB-first):

```
| cmd (8b) | addr (16b) | data/rsvd (32b) |
```

- `cmd = 0x01` → WRITE, el campo data lleva los 32 bits a escribir.
- `cmd = 0x02` → READ, el campo data se ignora; la respuesta se obtiene en la **siguiente** transaccion (lectura pipelined).
- La primera lectura a una direccion devuelve datos stale o cero — el master descarta esa palabra y conserva la segunda.

El testbench encapsula este protocolo en las tareas `spi_write(addr, data)`, `spi_read_data(addr, out)` y `spi_csr_read(off, out)`.

---

## Fases de Test

### Phase A — SPI Data-Path Sanity Check

Verifica el camino de datos del SPI con cuatro escrituras y lecturas back-to-back:

| Sub-test | Direccion (byte) | Region | Patron |
|----------|------------------|--------|--------|
| A1 | `0x0000` | param_memory | `0xDEADBEEF` |
| A2 | `0x2000` | activation buf A-region | `0xCAFEBABE` |
| A3 | `0x4000` | activation buf B-region | `0x12345678` |
| A4 | `0x6000` | CSR CTRL | `0x00000001` (luego limpia a 0) |

Confirma que el decodificador del `spi_interface`, los muxes de memoria y la lectura pipelined funcionan en las cuatro regiones.

### Phase B — Multi-Image Inference via SPI

Para cada imagen `0..NUM_IMAGES-1`:

1. Reset completo (full reset entre imagenes — no hay back-to-back en este TB).
2. `load_all_data_spi(img_id)`:
   - Escribe los 2048 words de `PARAM_MEM_32x2048.hex` en param_memory.
   - Limpia los 1024 words de la activation buffer.
   - Carga los 196 words de `image_N.hex` en buf_A (4 pixeles por palabra para Conv1).
   - Ajusta los biases de Conv1 sumando `-input_zp * sum(weights)` por canal (compensa que el MAC trata pixeles como unsigned).
3. `run_inference_spi`: CTRL=1 → poll STATUS hasta `done` → lee RESULT → CTRL=0.
4. Compara la clase predicha contra `image_N_label.txt`.

Al final imprime accuracy total y numero de imagenes correctamente clasificadas.

### Resumen

```
========================================
  TOTAL PASS: 6 / 6
  Inference accuracy: 2 / 2 images correct
  ALL TESTS PASSED
========================================
```

---

## Mapa de Memoria SPI (referencia)

El mapa lo decodifica `spi_interface` a partir de `addr[14:13]`. Es identico al del OBI pero accedido en frames SPI de 56 bits:

| Region | Base | Tamanyo | Descripcion |
|--------|------|---------|-------------|
| param_memory | `0x0000` | 8 KB | Pesos, biases, parametros de cuantizacion |
| buf A-region | `0x2000` | 2 KB | Buffer de activaciones (words 0-511) |
| buf B-region | `0x4000` | 2 KB | Buffer de activaciones (words 512-1023) |
| CSR | `0x6000` | 16 B | Registros de control/estado |

**Registros CSR:**

| Offset | Nombre | R/W | Descripcion |
|--------|--------|-----|-------------|
| `0x6000` | CTRL | R/W | Bit 0 = start (escribir 1 para iniciar, 0 para liberar memorias) |
| `0x6004` | STATUS | RO | Bit 0 = done, Bit 1 = computing_valid |
| `0x6008` | RESULT | RO | Bits [3:0] = clase predicha (0-9) |
| `0x600C` | — | RO | Reservado (retorna 0) |

---

## Datos Necesarios

El testbench requiere los siguientes ficheros en `datos_hex_std/` (regenerables con `make train`):

```
datos_hex_std/
  PARAM_MEM_32x2048.hex                # Parametros del modelo (2048 words)
  conv1_weights.hex                    # Necesario para calcular el ajuste de biases
  model_input_zero_point.hex           # input_zp usado en el ajuste de biases
  test_images/
    image_0.hex ... image_19.hex            # 20 imagenes MNIST (196 words cada una)
    image_0_label.txt ... image_19_label.txt # Labels esperados
```

---

## Notas Tecnicas

- **Frecuencia del SPI**: el master genera SCLK a 1 MHz por defecto (parametro `SPI_HALF = 500 ns`). El reloj del nucleo va a 15 MHz (`CLK_PERIOD = 66.67 ns`).
- **Inter-transaction gap**: 2 us entre transacciones para que el slave registre cs_n inactivo (`CS_GAP = 2000`).
- **Lectura pipelined**: la primera lectura a cualquier direccion descarta la palabra anterior del pipeline. El testbench hace dos READs consecutivos y se queda con el segundo.
- **Ajuste de biases Conv1**: igual que en OBI; el TB lo aplica via SPI antes de cada inferencia. Compensa la diferencia entre el modelo Python (`acc = sum((px - input_zp) * w) + bias`) y el hardware (`acc = sum(px * w) + bias_adj`).
- **SRAM VERBOSE=0**: el TB desactiva las trazas debug de las instancias SRAM Sky130 via `defparam`.
- **GLS post-PnR / SDF**: el mismo testbench compila contra la netlist post-PnR cuando se invoca con `-DPOSTSYNTH -DFUNCTIONAL`. Para SDF anotado, los targets `gls-postpnr` y `gls-sdf` del Makefile lo hacen automaticamente.
