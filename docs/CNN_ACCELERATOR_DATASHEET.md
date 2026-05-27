# Datasheet Interna — Acelerador CNN LeNet-5 (ASIC Sky130)

**Revision:** 2.0
**Target:** SkyWater 130nm (sky130A PDK)
**Herramientas:** Icarus Verilog (simulacion), Yosys (sintesis), LibreLane (P&R)

---

## 1. Resumen del Sistema

Acelerador de inferencia hardware para redes neuronales convolucionales, optimizado para clasificacion MNIST (digitos 0-9). Implementa una arquitectura LeNet-5 modificada con cuantizacion INT8 y 4 MACs paralelos.

### Especificaciones Generales

| Parametro | Valor |
|-----------|-------|
| Interfaz host | OBI v1.0 slave o SPI slave (compile-time `-DUSE_SPI_INTERFACE`) |
| Precision aritmetica | INT8 (pesos/activaciones), INT32 (acumuladores) |
| MACs paralelos | 4 |
| Param SRAM | 1x `sky130_sram_1rw1r_32x2048_8` (8 KB, OpenRAM) |
| Activation SRAM | 1x `sky130_sram_1rw1r_32x1024_8` (4 KB, OpenRAM, buffer unificado A+B) |
| Total SRAM | 12 KB |
| Reloj objetivo | 15 MHz (66.67 ns) |
| Die | 1700 x 1700 um |
| Ciclos por imagen | ~470,000 |
| Latencia estimada | ~31 ms @ 15 MHz |

### Pipeline de Inferencia

```
Input MNIST (28x28x1, 8-bit)
    |
    v
Conv1 (3x3, 1->8, OC-parallel) + ReLU + MaxPool 2x2 -> 13x13x8
    |
    v
Conv2 (3x3, 8->16, IC-parallel) + ReLU + MaxPool 2x2 -> 5x5x16
    |
    v
Conv3 (3x3, 16->32, IC-parallel) + ReLU -> 3x3x32
    |
    v
Global Average Pooling (3x3 -> 1x1 por canal) -> 1x1x32
    |
    v
Fully Connected (32 -> 10, OC-parallel) + ReLU -> 10 logits
    |
    v
ArgMax -> 4-bit class prediction (0-9)
```

---

## 2. Top-Level: `cnn_top.v`

### 2.1 Interfaz de Puertos

Seleccion de interfaz en tiempo de compilacion (`-DUSE_SPI_INTERFACE`):

```verilog
module cnn_top (
    input  wire        clk,          // Reloj del sistema
    input  wire        reset,        // Reset sincrono activo-alto
`ifdef USE_SPI_INTERFACE
    // SPI Slave Port
    input  wire        spi_sclk,     // SPI clock
    input  wire        spi_cs_n,     // Chip select (activo bajo)
    input  wire        spi_mosi,     // Master Out Slave In
    output wire        spi_miso      // Master In Slave Out
`else
    // OBI Slave Port (default)
    input  wire        obi_req,      // Request del master
    output wire        obi_gnt,      // Grant hacia el master
    input  wire [31:0] obi_addr,     // Direccion (byte-addressed)
    input  wire        obi_we,       // Write enable (1=write)
    input  wire [3:0]  obi_be,       // Byte enables
    input  wire [31:0] obi_wdata,    // Write data
    output wire        obi_rvalid,   // Response valid
    output wire [31:0] obi_rdata     // Read data
`endif
);
```

### 2.2 Mapa de Memoria (visto desde el bus OBI)

| Region | Rango (byte addr) | Bits decodificacion | Tamano | Acceso |
|--------|-------------------|---------------------|--------|--------|
| Param Memory | `0x0000`-`0x1FFF` | `addr[14:13]=00` | 8 KB (2048 words) | R/W cuando idle |
| Activation Buf A-region | `0x2000`-`0x3FFF` | `addr[14:13]=01` | 2 KB (words 0-511) | R/W cuando idle |
| Activation Buf B-region | `0x4000`-`0x5FFF` | `addr[14:13]=10` | 2 KB (words 512-1023) | R/W cuando idle |
| CSR Registers | `0x6000`-`0x600F` | `addr[14:13]=11` | 4 registros | Siempre accesible |

> **Nota:** Buf A y Buf B son regiones del mismo SRAM fisico unificado (1024 words). El host accede a la B-region via target=2, que internamente suma 512 a la direccion.

### 2.3 Registros CSR

| Offset | Nombre | R/W | Bits | Descripcion |
|--------|--------|-----|------|-------------|
| `0x6000` | CTRL | R/W | `[0]` start | `1` = iniciar inferencia / memoria bloqueada para host |
| `0x6004` | STATUS | RO | `[0]` done, `[1]` classification_valid | Estado del acelerador |
| `0x6008` | RESULT | RO | `[3:0]` pred_class | Clase predicha (0-9) |
| `0x600C` | (reservado) | RO | — | Lee `0x00000000` |

### 2.4 Protocolo de Uso (CPU)

```
1. Escribir imagen MNIST empaquetada (196 words, 4 pixels/word) en Activation Buffer A (0x2000+)
2. Escribir parametros del modelo en Param Memory (0x0000+)  [solo primera vez]
3. Escribir CTRL = 1  (0x6000 <- 0x00000001)
   -> Acceso a memorias bloqueado para host (gnt=0), CSR sigue accesible
4. Polling: Leer STATUS (0x6004) hasta que bit[0] (done) = 1
5. Leer RESULT (0x6008) -> bits [3:0] = clase predicha
6. Escribir CTRL = 0  (0x6000 <- 0x00000000)
   -> Memorias desbloqueadas, listo para siguiente imagen
```

### 2.5 Arbitraje de Memoria

El modulo implementa un mux 2:1 por memoria, controlado por la senal `accel_start` (CSR CTRL[0]):

- **`accel_start = 0` (idle):** El host (OBI/SPI) controla las 2 memorias. El layer_sequencer esta detenido.
- **`accel_start = 1` (inferencia):** El layer_sequencer controla las 2 memorias. Accesos del host a memoria reciben stall. CSR sigue respondiendo normalmente.

Polaridad critica: `host_interface.mem_we` (1=write) se invierte a `memory.read_writeb` (1=read) mediante `~mem_we`.

### 2.6 Instancias Internas

| Instancia | Modulo | Funcion |
|-----------|--------|---------|
| `u_host` | `host_interface` o `spi_interface` | Decodificacion interfaz, CSR, arbitraje grant |
| `u_seq` | `layer_sequencer` | FSM global de inferencia |
| `u_param` | `param_memory` | 8 KB — 1x `sky130_sram_1rw1r_32x2048_8` |
| `u_buf` | `activation_buffer` | 4 KB — 1x `sky130_sram_1rw1r_32x1024_8` (A-region 0-511, B-region 512-1023) |

---

## 3. Host Interface: `host_interface.v`

### 3.1 Descripcion

Slave OBI v1.0 con soporte para single outstanding transaction (sin pipelining). Decodifica accesos a 4 regiones de memoria y gestiona 3 registros CSR.

### 3.2 FSM (3 estados)

```
         ┌──────────────────────────────────────┐
         │               S_IDLE                  │
         │  obi_rvalid=0, esperando obi_req     │
         └─────┬───────────────┬────────────────┘
     CSR hit   │               │  Memory hit
               v               v
    ┌──────────────┐   ┌───────────────┐
    │ S_CSR_RESP   │   │ S_MEM_WAIT    │
    │ 1 ciclo resp │   │ hold hasta    │
    │ rvalid=1     │   │ mem_valid=1   │
    └──────┬───────┘   └───────┬───────┘
           │                   │
           └───────┬───────────┘
                   v
              S_IDLE (rvalid=1 durante 1 ciclo)
```

### 3.3 Logica de Grant

```verilog
obi_gnt = obi_req && (state == S_IDLE) && (req_is_csr || !csr_ctrl_start);
```

- CSR: siempre concedido (si FSM en IDLE)
- Memoria: solo si `csr_ctrl_start=0` (acelerador idle)

### 3.4 Senales hacia Memorias

| Senal | Ancho | Descripcion |
|-------|-------|-------------|
| `mem_addr` | 11-bit | Direccion word (`obi_addr[12:2]`) |
| `mem_wdata` | 32-bit | Dato a escribir |
| `mem_wmask` | 4-bit | Byte mask (param_memory: siempre `1111`; buffers: usa `obi_be`) |
| `mem_we` | 1-bit | Write enable (1=write, 0=read) |
| `mem_request` | 1-bit | Pulso de solicitud |
| `mem_target` | 2-bit | `00`=param, `01`=bufA, `10`=bufB |
| `mem_rdata` | 32-bit | Respuesta de lectura (muxed externamente) |
| `mem_valid` | 1-bit | Respuesta valida |

---

## 4. Layer Sequencer: `layer_sequencer.v`

### 4.1 Descripcion

FSM global de 14 estados que encadena la ejecucion de las 6 capas del CNN. Configura parametros por capa, gestiona el ping-pong de buffers, e instancia internamente todos los modulos de compute y control.

### 4.2 Secuencia de Ejecucion

| Estado | Operacion | Buffer Lectura | Buffer Escritura |
|--------|-----------|---------------|-----------------|
| Conv1+Pool1 | OC-parallel, pool=1 | A (imagen input) | B |
| Conv2+Pool2 | IC-parallel, pool=1 | B | A |
| Conv3 | IC-parallel, pool=0 | A | B |
| GAP+FC+ArgMax | GAP→FC→ArgMax | B | B (nunca simultaneo) |

### 4.3 Instancias Internas

| Instancia | Modulo | Funcion |
|-----------|--------|---------|
| `u_conv_ctrl` | `conv_layer_ctrl` | FSM de capa convolucional |
| `u_gfc_ctrl` | `gap_fc_layer_ctrl` | FSM de GAP+FC+ArgMax |
| `u_data_bus` | `data_bus` | Registros de datos y formateo |
| `u_compute_top` | `compute_top` | Ruta de computo (4 MACs + post-proc + GAP + ArgMax) |
| `u_line_buf` | `line_buffer` | Cache de 3 filas para ventana 3x3 |

### 4.4 Mux de Controlador Activo (`active_ctrl`)

```
active_ctrl = 0 -> conv_layer_ctrl controla data_bus/compute_top/memorias
active_ctrl = 1 -> gap_fc_layer_ctrl controla data_bus/compute_top/memorias
```

Todas las senales de control (pixel_load, weight_load, bias_load, core_req, etc.) pasan por este mux.

### 4.5 Configuracion por Capa

| Parametro | Conv1 | Conv2 | Conv3 |
|-----------|-------|-------|-------|
| Modo | OC-parallel | IC-parallel | IC-parallel |
| IC-groups | 1 | 2 | 4 |
| OC-steps | 2 | 16 | 32 |
| Out size | 26x26 | 11x11 | 3x3 |
| In width | 28 | 13 | 5 |
| Words/row | 28 | 26 | 20 |
| Pool | Si (2x2) | Si (2x2) | No |
| ReLU | Si | Si | Si |
| Shift | 30 | 30 | 30 |

### 4.6 Correccion Input Zero-Point (Conv1)

El hardware MAC trata los pixeles como unsigned (`{1'b0, pixel}`), pero el modelo Python resta `input_zp=17` antes de multiplicar. Para compensar:

```
bias_adj = bias_original - input_zp * sum(kernel_weights_for_channel)
```

Esta correccion debe aplicarse via software (escritura a param_memory) antes de iniciar la inferencia.

---

## 5. Convolution Layer Controller: `conv_layer_ctrl.v`

### 5.1 Descripcion

FSM de 16 estados que orquesta una capa de convolucion completa. Maneja los loops anidados OC/fila/columna/kernel/IC, la precarga de configuracion, el llenado del line_buffer, y la escritura de resultados.

### 5.2 FSM

```
IDLE -> FRAME_START -> LOAD_SHIFT -> CFG_READ <-> CFG_WAIT (N params)
    -> FILL_READ <-> FILL_WAIT (3 filas o 1 fila)
    -> WEIGHT_READ -> WEIGHT_WAIT -> LOAD_COMPUTE -> CORE_REQ
    -> PROCESS_OUT -> WAIT_VALID -> WRITE_RESULT -> WRITE_WAIT
    -> (siguiente pixel o DONE)
```

### 5.3 Loops Anidados (desde exterior a interior)

1. **oc_step** (0 .. num_oc_steps-1): Canal de salida
2. **out_row** (0 .. out_height-1): Fila de salida
3. **out_col** (0 .. out_width-1): Columna de salida
4. **kpos** (0..8) x **ic_grp** (0..num_ic_groups-1): Kernel 3x3 x grupos IC

### 5.4 Precarga de Configuracion

**Modo OC-parallel** (cfg_cnt_max=10):
```
cnt 0-3: 4 bias (una por lane)
cnt 4-7: 4 multipliers (uno por lane)
cnt 8:   1 zero-point word (4 ZP empaquetados)
cnt 9:   (shift ya cargado en LOAD_SHIFT)
```

**Modo IC-parallel** (cfg_cnt_max=3):
```
cnt 0: 1 bias (solo lane 0, hw fuerza 0 en lanes 1-3)
cnt 1: 1 multiplier (solo lane 0, hw replica)
cnt 2: 1 zero-point word (byte extraido segun oc_step[1:0])
```

### 5.5 Line Buffer Fill

- **Llenado inicial**: 3 filas completas (fill_row 0→1→2)
- **Row advance**: 1 fila nueva (fill_row=2, fill_single_row=1) con `lb_row_advance=1`
- La fila leida del activation buffer se escribe palabra por palabra al line buffer

### 5.6 Direccionamiento de Escritura

```
OC-parallel: wr_addr = wr_base + wr_count * num_oc_steps + oc_step
IC-parallel: wr_addr = wr_base + wr_count * (num_oc_steps >> 2) + (oc_step >> 2)
```

`wr_count` se incrementa en cada write-back exitoso (valid_out=1), se resetea al cambiar oc_step.

### 5.7 Timing Critico: WAIT_VALID

El `post_proc_unit` registra su salida: `valid` aparece 1 ciclo despues de `request`. Sin el estado `WAIT_VALID`, el FSM leeria `valid=0` (stale) y saltaria el write-back.

```
PROCESS_OUT:  ct_core_process_out = 1   (pulso)
WAIT_VALID:   espera 1 ciclo             (valid se propaga)
WRITE_RESULT: lee ct_valid_out           (ahora es valido)
```

---

## 6. GAP+FC+ArgMax Controller: `gap_fc_layer_ctrl.v`

### 6.1 Descripcion

FSM de 28 estados que ejecuta las 3 ultimas etapas: Global Average Pooling, Fully Connected, y ArgMax. Todas operan sobre el mismo activation buffer (nunca leen y escriben simultaneamente).

### 6.2 Fases

#### 6.2.1 GAP (Estados 1-7, compute_mode=1)

Procesa 32 canales de Conv3 output (3x3 cada uno). Para cada canal:
1. Lee 9 valores espaciales del activation buffer
2. Alimenta secuencialmente al `gap_unit` (que acumula y divide por 9)
3. Escribe el resultado promediado (1 byte) al activation buffer

**Direccionamiento de lectura:**
```
addr = gap_rd_base + spatial_pos * 8 + (gap_oc >> 2)
byte_sel = gap_oc[1:0]
```

#### 6.2.2 FC (Estados 8-21, compute_mode=0)

3 grupos OC (4+4+2 neuronas) x 32 inputs. Usa modo OC-parallel del compute_core.
1. Carga shift (una vez)
2. Por grupo: carga 9 params (4 bias + 4 mult + 1 zp)
3. Loop de 32 inputs: lee pixel GAP + peso, pulsa core_req
4. process_out -> escribe 1 word (4 logits empaquetados) al activation buffer

**Direccionamiento de pesos:**
```
weight_addr = fc_weight_base + fc_oc_group * 32 + fc_input
```

#### 6.2.3 ArgMax (Estados 22-26, compute_mode=2)

Lee 10 logits del FC output, los alimenta al `argmax_unit`, espera `classification_done`.

**Direccionamiento de logits:**
```
addr = fc_wr_base + (arg_logit >> 2)
byte_sel = arg_logit[1:0]
```

---

## 7. Compute Top: `compute_top.v`

### 7.1 Descripcion

Wrapper que instancia los 3 bloques de computo (compute_core_parallel, gap_unit, argmax_unit) y multiplexa sus salidas segun `compute_mode`.

### 7.2 Modos de Operacion

| compute_mode | Unidad activa | Entradas | Salida |
|-------------|---------------|----------|--------|
| `2'd0` | compute_core_parallel | pixel_word, weights_word, bias/mult/shift/zp | data_out_32b (4 bytes), valid_out |
| `2'd1` | gap_unit | pixel_word[7:0] | data_out_32b[7:0], valid_out |
| `2'd2` | argmax_unit | pixel_word[7:0] | pred_class[3:0], classification_done |

### 7.3 Interfaz

```verilog
// Control
input  compute_mode [1:0]       // 0=Conv/FC, 1=GAP, 2=ArgMax
input  is_parallel_ic           // 0=OC-parallel, 1=IC-parallel
input  core_req                 // Pulso MAC
input  core_acc_clear           // Precargar bias en acumulador
input  core_process_out         // Solicitar post-procesado
input  core_frame_start         // Reset contadores pool
input  core_relu_en             // Habilitar ReLU
input  core_pool_en             // Habilitar MaxPool 2x2
input  core_img_width [5:0]     // Ancho de imagen (para pool)
input  gap_req                  // Pulso GAP
input  argmax_req               // Pulso ArgMax

// Datos
input  weights_word [31:0]      // 4 pesos empaquetados
input  pixel_word [31:0]        // 4 pixeles o 1 pixel broadcast
input  bias_0..3 [31:0]         // Bias por lane
input  mult_0..3 [31:0]         // Multiplicador requantizacion
input  shift_amt [7:0]          // Shift amount
input  zp_0..3 [7:0]            // Zero-points

// Salidas
output data_out_32b [31:0]      // Resultado (4 bytes empaquetados)
output valid_out                // Resultado valido
output pred_class [3:0]         // Clase predicha (solo ArgMax)
output classification_done      // ArgMax terminado
```

---

## 8. Compute Core Parallel: `compute_core_parallel.v`

### 8.1 Descripcion

Nucleo de computo con 4 MACs y 4 post-procesadores en paralelo. Soporta dos modos de paralelismo que comparten el mismo hardware con muxes de configuracion.

### 8.2 Arquitectura

```
            pixel_word [31:0]           weights_word [31:0]
                 |                            |
    ┌────────────┼────────────┐    ┌──────────┼──────────┐
    |  OC: broadcast [7:0]    |    |  byte 0  byte 1 ... |
    |  IC: byte 0,1,2,3       |    |  byte 0  byte 1 ... |
    └──┬─────┬─────┬─────┬────┘    └──┬─────┬─────┬────┬─┘
       |     |     |     |            |     |     |    |
    ┌──v──┐ ┌v──┐ ┌v──┐ ┌v──┐     ┌──v──┐ ┌v──┐ ┌v──┐ ┌v──┐
    │MAC 0│ │ 1 │ │ 2 │ │ 3 │     │     │ │   │ │   │ │   │
    └──┬──┘ └┬──┘ └┬──┘ └┬──┘     └─────┘ └───┘ └───┘ └───┘
       |     |     |     |
       v     v     v     v
    ┌─────────────────────────┐
    │    sum_tree (IC mode)   │  acc[0]+acc[1]+acc[2]+acc[3]
    │    o passthrough (OC)   │
    └──┬─────┬─────┬─────┬───┘
       |     |     |     |
    ┌──v──┐ ┌v──┐ ┌v──┐ ┌v──┐
    │PP  0│ │ 1 │ │ 2 │ │ 3 │    Post-Proc (requant+ReLU+pool)
    └──┬──┘ └┬──┘ └┬──┘ └┬──┘
       |     |     |     |
       v     v     v     v
    data_out_word = {pp3, pp2, pp1, pp0}  (32 bits)
```

### 8.3 Modo OC-Parallel (`is_parallel_ic=0`)

- **Uso:** Conv1 (4 OC por paso), FC (4 neuronas por grupo)
- Pixel broadcast: `pixel_word[7:0]` replicado a los 4 MACs
- Cada MAC tiene bias/mult/zp independientes
- Salida: 4 bytes = 4 canales de salida simultaneos
- `data_out_word = {oc3, oc2, oc1, oc0}`

### 8.4 Modo IC-Parallel (`is_parallel_ic=1`)

- **Uso:** Conv2 (4 IC por paso), Conv3 (4 IC por paso)
- Cada MAC recibe un pixel diferente: `pixel_word[8*i +: 8]`
- Sum tree combina los 4 acumuladores: `acc[0] + acc[1] + acc[2] + acc[3]`
- Solo lane 0 porta el bias (hw fuerza `bias=0` en lanes 1-3)
- Todos los post-proc reciben `mult_0`, `zp_0` (hw fuerza uniformidad)
- Salida: `data_out_word[7:0]` es el unico byte valido

### 8.5 Sum Tree

```verilog
// Combinacional
sum_tree_reg = is_parallel_ic ? (mac_acc[0] + mac_acc[1] + mac_acc[2] + mac_acc[3])
                              : mac_acc[0];  // passthrough en OC mode
```

En modo IC: cada post_proc recibe `sum_tree_out` en lugar de su propio `mac_acc[i]`. Los 4 post_proc producen resultados identicos (solo byte 0 se usa).

---

## 9. MAC Unit: `mac_unit.v`

### 9.1 Descripcion

Multiply-Accumulate con acumulador de 32 bits, reset sincrono, y precarga de bias.

### 9.2 Interfaz

| Puerto | Dir | Ancho | Descripcion |
|--------|-----|-------|-------------|
| `clk` | in | 1 | Reloj |
| `reset` | in | 1 | Reset sincrono activo-alto |
| `valid_in` | in | 1 | Dato de entrada valido |
| `acc_clear` | in | 1 | Precargar bias (no poner a cero) |
| `bias_in` | in | 32 signed | Bias de precarga |
| `pixel_in` | in | 8 signed | Pixel de entrada |
| `weight_in` | in | 8 signed | Peso |
| `acc_out` | out | 32 signed | Acumulador (registrado) |
| `valid_out` | out | 1 | Salida valida |

### 9.3 Comportamiento

```
if (valid_in && acc_clear):
    acc_reg = bias_in + pixel_in * weight_in     // Precarga bias

if (valid_in && !acc_clear):
    acc_reg = acc_reg + pixel_in * weight_in     // Acumular

if (!valid_in):
    acc_reg = acc_reg  (hold, valid_out = 0)
```

- Latencia: 1 ciclo (resultado disponible en `acc_out` el ciclo siguiente a `valid_in=1`)
- Multiplicacion: `$signed(pixel_in) * $signed(weight_in)` -> 16 bits, sign-extended a 32

---

## 10. Post-Processing Unit: `post_proc_unit.v`

### 10.1 Descripcion

Unidad de post-procesamiento que aplica requantizacion, ReLU, y opcionalmente max-pooling 2x2. La requantizacion es combinacional; el pooling usa registros internos con contadores espaciales.

### 10.2 Pipeline de Requantizacion (combinacional)

```
data_in [32-bit signed, acumulador MAC]
    |
    v
full_mult = data_in * multiplier          [64-bit signed]
    |
    v
scaled_data = full_mult >>> shift_amt     [64-bit, arithmetic shift right]
    |
    v
with_zp = scaled_data[31:0] + offset_zp  [32-bit]
    |
    v
Saturacion: clamp a [-128, +127]          [8-bit signed]
    |
    v
ReLU: if (relu_en && resultado < 0) resultado = 0
    |
    v
post_requant [8-bit signed]
```

### 10.3 Max-Pooling 2x2 (registrado)

Cuando `pool_en=1`, el post_proc mantiene contadores `col_cnt` y `row_cnt` para rastrear la posicion espacial. La logica de pooling 2x2:

```
Posicion (row,col) en la ventana 2x2:

  (even_row, even_col): temp_max = post_requant
  (even_row, odd_col):  line_buffer[col>>1] = max(post_requant, temp_max)
  (odd_row,  even_col): temp_max = max(post_requant, line_buffer[col>>1])
  (odd_row,  odd_col):  output = max(post_requant, temp_max), valid=1
```

Solo emite `valid=1` en la posicion (odd_row, odd_col) de cada ventana 2x2.

### 10.4 Senal `frame_start`

Resetea `col_cnt`, `row_cnt`, `temp_max` sin afectar el reset global. Necesario cuando las dimensiones de salida son impares (ej. Conv2: 11x11), ya que los contadores de pooling no se alinean naturalmente entre canales consecutivos.

### 10.5 Sin Pooling (`pool_en=0`)

Output directo: `data_out = post_requant`, `valid = 1` en el mismo ciclo que `request`.

---

## 11. GAP Unit: `gap_unit.v`

### 11.1 Descripcion

Calcula el promedio global sobre una ventana 3x3 (9 valores) usando una aproximacion en punto fijo para la division por 9.

### 11.2 Algoritmo

```
accumulator += data_in  (9 veces, controlado por request)

Al 9no request (count == 8):
    sum = accumulator + data_in
    avg = (sum * 0x1C72) >> 16    // 0x1C72 = round(65536/9)
    data_out = avg[23:16]          // Truncar a 8 bits
    valid = 1
    Reset: count=0, accumulator=0
```

### 11.3 Precision

- Acumulador: 16 bits signed (suficiente para 9 valores de 8 bits: max = 9*127 = 1143)
- Constante INV_9: `0x1C72` (Q16 fixed-point, 1/9 * 65536 = 7282.17 -> 7282)
- Producto: 32 bits signed
- Resultado: bits [23:16] del producto (desplazamiento implicito de 16)

---

## 12. ArgMax Unit: `argmax_unit.v`

### 12.1 Descripcion

Compara secuencialmente 10 logits (INT8 signed) y produce el indice de la clase con mayor valor.

### 12.2 Comportamiento

```
Para cada request (count 0..9):
    if (count == 0 || data_in > current_max):
        current_max = data_in
        best_idx = count

Cuando count == 9 (10mo logit):
    argmax_idx = indice final
    max_value = valor maximo
    done = 1
    Reset interno para siguiente imagen
```

### 12.3 Interfaz

| Puerto | Dir | Ancho | Descripcion |
|--------|-----|-------|-------------|
| `request` | in | 1 | Nuevo logit disponible |
| `data_in` | in | 8 signed | Valor del logit |
| `done` | out | 1 | Todas las clases procesadas |
| `argmax_idx` | out | 4 | Indice de la clase ganadora |
| `max_value` | out | 8 signed | Valor maximo |

---

## 13. Data Bus: `data_bus.v`

### 13.1 Descripcion

Bloque puramente de datos (registros + muxes), sin FSM ni handshake. Actua como intermediario entre la memoria (param/activation) y el compute_top, formateando datos segun el modo de paralelismo.

### 13.2 Canales

| Canal | Registros | Load | Funcion |
|-------|-----------|------|---------|
| Pixel | 1x 32-bit | `pixel_load` | SRAM word -> formato pixel (OC: byte select + zero-extend, IC: passthrough) |
| Weight | 1x 32-bit | `weight_load` | SRAM word -> 4 pesos empaquetados |
| Bias | 4x 32-bit | `bias_load` + `lane_sel` | Un bias por lane (carga selectiva) |
| Mult | 4x 32-bit | `mult_load` + `lane_sel` | Un multiplier por lane |
| Shift | 1x 8-bit | `shift_load` | Shift amount (global) |
| ZP | 4x 8-bit | `zp_load` | 4 zero-points de 1 word empaquetado |
| Result | combinacional | — | compute_top output -> formato para write-back |

### 13.3 Pixel Formatting

```verilog
// OC mode: byte seleccionado, zero-extended a 32 bits
pixel_word = {24'b0, pixel_reg[byte_sel*8 +: 8]}

// IC mode: word completo (4 pixeles IC, uno por MAC)
pixel_word = pixel_reg
```

### 13.4 Result Formatting

```verilog
// OC mode: word completo, wmask=1111
result_dout = result_din
result_wmask = 4'b1111

// IC mode: byte replicado a todas las posiciones, wmask selecciona byte destino
result_dout = {4{result_din[7:0]}}
result_wmask = (4'b0001 << result_byte_pos)
```

---

## 14. Line Buffer: `line_buffer.v`

### 14.1 Descripcion

Cache circular de 3 filas para la ventana deslizante 3x3 de la convolucion. Cada fila almacena hasta 28 words de 32 bits. Lectura combinacional (zero-latency), escritura sincrona.

### 14.2 Operacion

```
row_base = 0 inicialmente

Mapeo logico -> fisico:
    physical_row = (row_base + logical_row) mod 3

row_advance:
    row_base = (row_base + 1) mod 3
    // La fila logica "top" (0) se descarta
    // La fila logica "bot" (2) queda libre para escribir la nueva fila
```

### 14.3 Parametros

| Parametro | Valor | Descripcion |
|-----------|-------|-------------|
| `MAX_WORDS_PER_ROW` | 28 | Maximo ancho (Conv1 input: 28) |
| Almacenamiento total | 3 x 28 x 32 = 2688 bits | ~336 bytes |

### 14.4 Interfaz de Lectura

Combinacional: el dato esta disponible inmediatamente despues de cambiar `rd_row`/`rd_addr`. No hay latencia de lectura.

### 14.5 Interfaz de Escritura

Sincrona: el dato se escribe en el flanco positivo del reloj cuando `wr_en=1`.

---

## 15. Memorias SRAM

### 15.1 Param Memory: `param_memory.v`

Almacen de solo lectura (desde el punto de vista del acelerador) para pesos, bias, multipliers y zero-points. Escribible por el host via OBI/SPI.

| Parametro | Valor |
|-----------|-------|
| SRAM macro | `sky130_sram_1rw1r_32x2048_8` (1 instancia) |
| Tamano | 8 KB (2048 words x 32 bits) |
| Direccionamiento | 11-bit word address |
| Write mask | Fijo `4'b1111` (siempre word completo) |
| Handshake lectura | 3 posedges (delay 0→1→2→valid) |
| Handshake escritura | 2 posedges (delay 0→1→valid) |

### 15.2 Activation Buffer: `activation_buffer.v`

Buffer unificado para feature maps. Las regiones A (words 0-511) y B (words 512-1023) alternan roles de lectura/escritura por capa (ping-pong logico).

| Parametro | Valor |
|-----------|-------|
| SRAM macro | `sky130_sram_1rw1r_32x1024_8` (1 instancia) |
| Tamano | 4 KB (1024 words x 32 bits) |
| Direccionamiento | 10-bit word address (SRAM_ADDR_WIDTH=10) |
| Write mask | Configurable (puerto `wmask[3:0]`) |
| A-region | words 0-511 |
| B-region | words 512-1023 |

### 15.3 SRAM Macros OpenRAM

Macros generadas con OpenRAM para el PDK SkyWater 130nm. Caracterizadas en 3 corners PVT (TT/FF/SS).

| Macro | Tamano | Words | Puertos |
|-------|--------|-------|---------|
| `sky130_sram_1rw1r_32x2048_8` | 8 KB | 2048 x 32 bits | 1 RW + 1 R |
| `sky130_sram_1rw1r_32x1024_8` | 4 KB | 1024 x 32 bits | 1 RW + 1 R |

Ambas macros comparten la misma interfaz:
- Active-low signals: `csb0` (chip select), `web0` (write enable)
- Write granularity: 8 bits (byte-level via `wmask0`)
- Puerto R secundario: no utilizado (`csb1=1` permanente)

---

## 16. Mapa de Memoria de Parametros

Direcciones word-based (11-bit, 0x000-0x7FF):

| Seccion | Rango | Words | Contenido |
|---------|-------|-------|-----------|
| Global Config | 0x000-0x001 | 2 | Input scale, ZP, shift |
| Conv1 Weights | 0x002-0x013 | 18 | 9 kernel pos x 2 OC-groups (4 OC/word) |
| Conv1 Bias | 0x014-0x01B | 8 | 1 bias por OC (32-bit cada) |
| Conv1 Mult | 0x01C-0x023 | 8 | 1 multiplier por OC (32-bit cada) |
| Conv1 ZP | 0x024-0x025 | 2 | 4 ZP por word (empaquetados) |
| Conv2 Weights | 0x026-0x145 | 288 | 16 OC x 18 words (9 kpos x 2 IC-groups) |
| Conv2 Bias | 0x146-0x155 | 16 | 1 por OC |
| Conv2 Mult | 0x156-0x165 | 16 | 1 por OC |
| Conv2 ZP | 0x166-0x169 | 4 | 4 por word |
| Conv3 Weights | 0x16A-0x5E9 | 1152 | 32 OC x 36 words (9 kpos x 4 IC-groups) |
| Conv3 Bias | 0x5EA-0x609 | 32 | 1 por OC |
| Conv3 Mult | 0x60A-0x629 | 32 | 1 por OC |
| Conv3 ZP | 0x62A-0x631 | 8 | 4 por word |
| FC Weights | 0x632-0x691 | 96 | 3 OC-groups x 32 words |
| FC Bias | 0x692-0x69B | 10 | 1 por neurona |
| FC Mult | 0x69C-0x6A5 | 10 | 1 por neurona |
| FC ZP | 0x6A6-0x6A8 | 3 | 4 por word |
| **Total** | | **1705** | **83.2% de 2048** |

---

## 17. Layout de Activaciones en Buffers

Buffer unificado: 4 KB (1024 words x 32 bits). A-region = words 0-511, B-region = words 512-1023.

| Capa | Datos | Formato | Words | Region (base) |
|------|-------|---------|-------|---------------|
| Conv1 in | 28x28x1 | 4 pixels/word (packed) | 196 | A (0) |
| Pool1 out | 13x13x8 | 4 OC/word, 2 groups | 338 | B (512) |
| Pool2 out | 5x5x16 | 4 OC/word, 4 groups | 100 | A (0) |
| Conv3 out | 3x3x32 | 4 OC/word, 8 groups | 72 | B (512) |
| GAP out | 1x1x32 | 1 valor/word | 32 | B (584) |
| FC out | 1x1x10 | 4 logits/word, 3 words | 3 | B (616) |

---

## 18. Cuantizacion

### 18.1 Esquema

Cuantizacion asimetrica INT8 con parametros por capa:

```
float_value = (int8_value - zero_point) * scale
```

En hardware, la requantizacion del acumulador INT32 al INT8 de salida:

```
output = clamp(round(accumulator * multiplier >> shift) + zero_point, -128, 127)
output = max(output, 0)  // ReLU
```

### 18.2 Parametros por Capa

| Parametro | Tipo | Tamano | Granularidad |
|-----------|------|--------|-------------|
| Bias | INT32 signed | 32 bits | Por canal de salida |
| Multiplier | INT32 signed | 32 bits | Por canal de salida |
| Shift | UINT8 | 8 bits | Global (=30 para todas las capas) |
| Zero-Point | UINT8 | 8 bits | Por canal de salida |

---

## 19. Verificacion

### 19.1 Testbenches por Modulo

| Testbench | Checks | Estado |
|-----------|--------|--------|
| `tb_mac_unit.sv` | Reset, acumulacion, precarga bias | PASS |
| `tb_post_proc_unit.sv` | Requant, ReLU, pool 2x2, frame_start | PASS |
| `tb_gap_unit.sv` | 50 vectores aleatorios | PASS (50/50) |
| `tb_argmax_unit.sv` | 20 secuencias | PASS (20/20) |
| `tb_compute_core_parallel.sv` | OC-parallel (20), IC-parallel (10) | PASS (30/30) |
| `tb_activation_buffer.sv` | Byte writes, full word, cross-bank, latency, streaming | PASS (26/26) |
| `tb_data_bus.sv` | Pixel OC/IC, weight, bias/mult/shift/zp, result OC/IC, reset | PASS (47/47) |
| `tb_line_buffer.sv` | Fill, read, advance, circular wrap | PASS (92/92) |
| `tb_conv_layer_ctrl.sv` | OC-parallel no pool, IC-parallel no pool, OC+pool, IC+pool | PASS (104/104) |
| `tb_gap_fc_layer_ctrl.sv` | GAP identity, GAP varying, FC, full GAP+FC+ArgMax | PASS (149/149) |
| `tb_layer_sequencer.sv` | Smoke (zero weights), image_0 (label=7), image_1 (label=2) | PASS (6/6) |
| `tb_host_interface.sv` | PM/BufA/BufB R/W, byte mask, CSRs, stall, back-to-back | PASS (21/21) |
| `tb_top_obi.sv` | Host readback, back-to-back, reset, CSR corners, multi-image, freq sweep | PASS (76/76) |
| `tb_top_spi.sv` | SPI load + multi-image inference | PASS |
| `tb_chip_spi.sv` | Chip-level GLS via SPI + padring | PASS |

### 19.2 Inferencia End-to-End Verificada

| Imagen | Label Esperado | Resultado HW | Ciclos |
|--------|---------------|-------------|--------|
| image_0 | 7 | 7 | ~470K |
| image_1 | 2 | 2 | ~470K |

### 19.3 Comandos de Simulacion

```bash
# RTL completo (OBI, 3 imagenes)
bash rtl/sim/sim_cnn_top.sh

# RTL completo (SPI)
bash rtl/sim/sim_cnn_top_spi.sh 3

# Post-sintesis gate-level
bash rtl/sim/sim_cnn_top_postsynth.sh

# Post-PnR gate-level
bash rtl/sim/sim_cnn_top_postpnr.sh

# Chip-level GLS (SPI + padring)
bash rtl/sim/sim_chip_top_gl.sh
```

---

## 20. Jerarquia de Archivos RTL

```
cnn_top.v                              Top-level (OBI/SPI + arbitraje de memoria)
├── host_interface.v / spi_interface.v  Decodificacion interfaz + CSRs
├── layer_sequencer.v                   FSM global de inferencia (14 estados)
│   ├── conv_layer_ctrl.v               FSM capa convolucional (16 estados)
│   ├── gap_fc_layer_ctrl.v             FSM GAP + FC + ArgMax (28 estados)
│   ├── data_bus.v                      Registros de datos + formateo
│   ├── compute_top.v                   Wrapper de computo
│   │   ├── compute_core_parallel.v     4 MACs + 4 post-proc
│   │   │   ├── mac_unit.v             Multiply-Accumulate (INT8x8→INT32)
│   │   │   └── post_proc_unit.v       Requant + ReLU + MaxPool 2x2
│   │   ├── gap_unit.v                 Global Average Pooling (div-by-9)
│   │   └── argmax_unit.v             Clasificador final (10 clases)
│   └── line_buffer.v                   Cache circular 3 filas
├── param_memory.v                      8 KB — 1x sky130_sram_1rw1r_32x2048_8
└── activation_buffer.v                 4 KB — 1x sky130_sram_1rw1r_32x1024_8 (unificado)
```

Chip wrappers (padring + IO pads): `chip_top_spi.v`, `chip_top_spi_flat.v`, `chip_top.v`

Total SRAM macros: 2 (1x param 2048 words + 1x buffer 1024 words)

---

## 21. Consideraciones de Diseno

### 21.1 Tradeoffs de Rendimiento

- **Sequential execution**: Cada operacion MAC toma ~5 ciclos (weight read + wait + load + compute + next). Un diseno pipelined podria alcanzar 1 MAC/ciclo.
- **4 MACs paralelos**: Factor 4x sobre 1 MAC en modo OC-parallel. En IC-parallel, los 4 MACs computan partial sums que se suman.
- **Sin prefetch**: Las lecturas de peso y pixel son secuenciales (read -> wait -> use). Un buffer de prefetch podria ocultar la latencia de SRAM.

### 21.2 Limitaciones

- **Single outstanding OBI**: No hay pipelining en el bus host. Un acceso a memoria bloquea el bus hasta completar.
- **No hay DMA**: La CPU debe escribir imagen pixel por pixel via OBI. Para un despliegue real, un controlador DMA seria beneficioso.
- **Tamano fijo de modelo**: Los parametros de red estan hardcoded en el layer_sequencer. Cambiar la arquitectura requiere modificar el RTL.
- **Sin soporte de batch**: Procesa 1 imagen a la vez.

### 21.3 Area

- Core die (`cnn_top`): 1700 x 1700 um = 2.89 mm^2
- Chip die (`chip_top_spi`): 2500 x 2500 um = 6.25 mm^2 (con padring sky130 IO)
- 2 SRAM macros (dominante): sky130_sram_1rw1r_32x2048_8 + sky130_sram_1rw1r_32x1024_8
- Flujo completo RTL2GDSII ejecutado con LibreLane

## 22. Limitaciones del Toolchain Open-Source

Este proyecto se ha implementado exclusivamente con herramientas open-source. A continuacion se documentan las limitaciones encontradas respecto a un flujo comercial equivalente (Synopsys/Cadence/Siemens), asi como el progreso reciente del ecosistema open-source en cerrar estos gaps. El ecosistema se mueve rapidamente — la informacion aqui refleja el estado a abril 2026.

### 22.1 Simulacion y Verificacion

| Limitacion | Estado open-source (abril 2026) | Equivalente comercial |
|---|---|---|
| **Code coverage limitado** | Icarus Verilog no tiene coverage nativo, pero [Covered](https://github.com/chiphackers/covered) puede generar line, toggle, FSM, combinational y memory coverage via VPI o analizando VCD/FST post-simulacion. Verilator soporta line, toggle y branch coverage nativo (`--coverage`), pero solo para simulacion RTL behavioral (2-state, no soporta GLS). No hay herramienta open-source que ofrezca coverage en simulacion gate-level. | VCS, Xcelium, Questa: coverage integrado en RTL y GLS |
| **Functional coverage emergente** | Icarus y CVC64 no soportan `covergroup`/`coverpoint`. Verilator tiene soporte inicial de covergroups (parsing + elaboracion basica, en desarrollo activo por Antmicro/CHIPS Alliance). Aun no es funcional para uso en produccion. | VCS/Questa: covergroups nativos con merge y reporting |
| **SVA parcial** | Icarus no soporta SVA. Verilator soporta `assert property` basico y control de assertions en runtime, pero no soporta `sequence`, operador `##` (delay), ni `$past`. SymbiYosys permite verificacion formal con assertions SVA (bounded model checking). | VCS/Questa: SVA completo en simulacion + coverage de assertions |
| **UVM en progreso** | Icarus no soporta UVM. Verilator logro elaborar UVM 2017-1.0 upstream sin patches (oct 2025, Antmicro/CHIPS Alliance): clases parametrizadas, constrained randomization con structs, soporte de interfaces genericas. Aun no es equivalente a comerciales para testbenches complejos, pero el progreso es significativo. | VCS/Questa/Xcelium: UVM 2020 nativo |
| **Soporte SV incompleto en Icarus** | Icarus tiene bugs conocidos con `logic signed` en bloques con nombre (zero-extension en vez de sign-extension), soporte limitado de `interface`/`modport`, y no implementa muchas construcciones de SV-2012. Requiere workarounds (ej: usar `integer` en vez de `logic signed [7:0]`). | Simuladores comerciales: soporte SV-2017 completo |
| **SDF extremadamente lento** | CVC64 es el unico simulador open-source con soporte SDF real, pero es ordenes de magnitud mas lento que VCS/Xcelium. Para este diseno (~12K celdas), una inferencia de ~470K ciclos tarda horas con SDF vs minutos en un simulador comercial. Esto hace practicamente inviable la verificacion funcional post-PnR con timing para mas de 1-2 vectores de test. Proyectos emergentes como VHE (GPU-accelerated GLS) buscan cerrar este gap pero aun no estan maduros. | VCS/Xcelium: GLS con SDF en minutos para disenos de este tamano |
| **Sin X-propagation inteligente** | Los simuladores open-source propagan X de forma pesimista. Los comerciales ofrecen modos Xprop configurables y deteccion de X en flip-flops, critico para verificar inicializacion post-reset. | VCS: Xprop, Questa: Xprop |
| **CVC64 sin mantenimiento activo** | CVC64 (unico simulador open-source con soporte SDF) no tiene actividad de desarrollo reciente. Bugs reportados quedan sin corregir. | N/A |
| **Verificacion formal disponible** | [SymbiYosys](https://github.com/YosysHQ/sby) permite bounded model checking, verificacion de safety properties y generacion de testbenches desde cover statements. Usa Yosys + solvers SAT/SMT (Boolector, ABC). No sustituye un entorno de verificacion formal completo pero es funcional para verificacion de modulos individuales. | JasperGold, VC Formal: formal completo |

### 22.2 Sintesis

| Limitacion | Estado open-source (abril 2026) | Equivalente comercial |
|---|---|---|
| **Optimizacion en mejora continua** | Yosys ha anadido recientemente `opt_balance_tree` (convierte cadenas en arboles para mejorar timing), `opt_hier` (optimizacion jerarquica), paralelizacion de `opt_merge`, e integracion mejorada con ABC9 para technology mapping. La brecha con herramientas comerciales se reduce, pero `compile_ultra`-level datapath optimization y retiming avanzado siguen ausentes. | DC: compile_ultra, Genus: opt avanzado |
| **Sin Power-Aware synthesis** | No hay soporte nativo para UPF/CPF (power domains, isolation cells, retention). Para un diseno single-domain como este no es limitante. | DC/Genus: UPF nativo |

### 22.3 STA y Timing

| Limitacion | Estado open-source (abril 2026) | Equivalente comercial |
|---|---|---|
| **Sin AOCV/POCV** | OpenSTA soporta OCV basico (derate global) pero no Advanced OCV ni Parametric OCV, que modelan la variabilidad estadisticamente por celda y profundidad de path. Esto puede resultar en margins de timing innecesariamente pesimistas (over-design). | PrimeTime: AOCV, POCV, SOCV |
| **Sin signal integrity (SI)** | No hay analisis de crosstalk ni noise en OpenSTA. Para sky130 a 15 MHz probablemente no es critico, pero en nodos mas avanzados o frecuencias altas seria un gap significativo. | PrimeTime SI, Tempus SI |

### 22.4 Physical Design

| Limitacion | Estado open-source (abril 2026) | Equivalente comercial |
|---|---|---|
| **IR Drop solo estatico** | OpenROAD (modulo PSM/PDNSim) calcula IR drop estatico. No hay analisis dinamico (transient current during switching). Para este diseno a 15 MHz con power grid robusto es suficiente. | Voltus/RedHawk: IR drop dinamico |
| **Sin analisis EM** | No hay analisis de electromigration en el flujo open-source. | Voltus/RedHawk: EM completo |
| **Extraccion parasita calibrada** | OpenRCX (extractor de OpenROAD) usa un enfoque basado en calibracion: genera tablas RC a partir de un extractor de referencia. Para sky130A, la calibracion disponible fue generada contra Calibre, lo cual proporciona precision razonable. No obstante, no modela todos los efectos fisicos que StarRC/QRC cubren en nodos avanzados (FinFET, coupling detallado). | StarRC, QRC: extraccion golden signoff |
| **Potencia dinamica emergente** | OpenROAD soporta SAIF (Switching Activity Interchange Format) para estimacion de potencia con actividad de conmutacion. Un flujo reciente (2025) permite generar SAIF desde Verilator y alimentar OpenSTA para power estimation post-sintesis. No es equivalente a PrimePower (que usa VCD gate-level), pero es un avance significativo sobre la estimacion puramente estadistica. | PrimePower, Voltus: potencia dinamica con VCD/FSDB |
| **Sin DFT** | No hay soporte de Design-for-Test (scan chain insertion, ATPG) en el flujo actual. [Difetto](https://github.com/donn/difetto) es un proyecto WIP basado en LibreLane que implementa tres flujos: DifettoPNR (insercion de scan chains durante PnR), DifettoATPG (generacion de vectores de test) y DifettoTest (verificacion de integridad). Usa OpenROAD, Quaigh, cocotb y plugins de Yosys. En desarrollo activo pero aun no listo para produccion. | Tessent, DFT Compiler, Modus: DFT/ATPG completo |
| **Clock gating no habilitado** | El soporte existe a multiples niveles: Yosys tiene el comando nativo `clockgate` que reemplaza flip-flops con enable por celdas ICG (seleccion automatica desde liberty). El plugin [Lighter](https://github.com/AUCOHL/Lighter) de AUCOHL ofrece clock gating automatico con mapping para sky130 (`sky130_fd_sc_hd__dlclkp`). OpenROAD tiene el modulo `cgt` (Antmicro, 2025) que realiza clock gating automatico post-sintesis usando BFS + ABC + SAT, con 8-15% de ahorro demostrado en Ibex/sky130. Este diseno no utiliza clock gating; habilitarlo reduciria la potencia dinamica especialmente en los registros de MACs, post-processing y FSMs durante estados idle. | DC/Genus: clock gating automatico integrado en sintesis |

### 22.5 Verificacion Fisica

| Limitacion | Estado open-source (abril 2026) | Equivalente comercial |
|---|---|---|
| **DRC con cobertura parcial** | KLayout DRC usa un rule deck propio para sky130 (no puede parsear SVRF de Calibre, el formato es propietario). La implementacion cubre las reglas principales pero el propio proyecto reconoce que no ha sido exhaustivamente testeado contra todos los casos posibles. Magic DRC complementa con reglas adicionales. El uso de ambos en paralelo mitiga el riesgo. | Calibre, ICV: golden DRC con rule decks del foundry |
| **LVS funcional** | Netgen realiza LVS comparando netlist extraido vs esquematico. Funciona correctamente para este diseno. En casos complejos (parasitic devices, soft connections, mixed-signal) puede ser menos robusto. | Calibre LVS, ICV LVS |

### 22.6 Impacto Practico en Este Proyecto

A pesar de estas limitaciones, el flujo open-source ha sido suficiente para llevar este diseno desde RTL hasta GDSII con signoff razonable:

- **Verificacion funcional**: cubierta por testbenches exhaustivos a nivel de modulo e integracion, GLS post-synth y post-PnR funcional (sin SDF), y STA en 9 corners PVT.
- **Timing signoff**: OpenSTA con 9 corners PVT (3 process x 3 voltage/temp) proporciona confianza razonable. Las violaciones de slew en corner SS son conocidas y mitigadas.
- **Verificacion fisica**: KLayout DRC + Netgen LVS pasan limpio.
- **Sin DFT**: el diseno no incluye scan chains ni vectores ATPG. Esto seria necesario para un test de produccion real pero no es requisito para un prototipo academico. Difetto (basado en LibreLane) esta en desarrollo activo para cubrir este gap.
- **Sin clock gating**: las herramientas lo soportan (Yosys `clockgate`, Lighter, OpenROAD `cgt`), pero no se habilito en este diseno. Es una optimizacion de potencia pendiente que podria implementarse sin cambios en el RTL.
- **El gap mas critico**: la imposibilidad practica de hacer GLS con SDF de forma eficiente. La verificacion de timing depende enteramente de STA estatico, sin una segunda fuente de verdad (simulacion con delays reales). En un flujo comercial, la GLS con SDF confirmaria que el diseno funciona correctamente con los delays reales del layout.

### 22.7 Perspectiva

El ecosistema open-source de EDA ha avanzado enormemente en los ultimos anos. Proyectos como Verilator (UVM, covergroups), Difetto (DFT), SymbiYosys (formal), y las mejoras continuas de Yosys y OpenROAD estan cerrando gaps que hace pocos anos eran impensables. La principal area donde el gap sigue siendo grande es la simulacion gate-level con timing (SDF) — un problema fundamentalmente ligado al rendimiento de los simuladores event-driven open-source.
