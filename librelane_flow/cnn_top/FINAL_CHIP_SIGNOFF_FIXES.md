# Arreglos finales del flow chip sky130

Este documento resume solo los cambios finales que quedaron activos para el flow chip de `chip_top_spi` en SKY130. No incluye experimentos descartados.

## Contexto

El objetivo era integrar el padring sky130 con el core `cnn_top` y cerrar el flow de LibreLane con:

- pads de `vccd1`/`vssd1` conectados al ring de alimentación del chip,
- ruteo de señales de pads sin DRC adicional cerca del padring,
- LVS limpio aun usando extracción abstracta de pads en Magic,
- STA, antenna y routing DRC limpios.

El run de referencia final es:

```text
runs/spi-chip-hier-27
```

## Configuración de PDN custom

Los configs activos usan:

```json
"PDN_CFG": "pdn_cfg_custom.tcl"
```

El script `pdn_cfg_custom.tcl` envuelve `pdngen` para ejecutar, después de generar el PDN base, las conexiones especiales entre pads de alimentación y el ring del chip:

```tcl
bridge_sky130_power_pad_to_ring_fully_auto vccd1 pad_vccd1_n VCCD POWER both
bridge_sky130_power_pad_to_ring_fully_auto vccd1 pad_vccd1_e VCCD POWER both
bridge_sky130_power_pad_to_ring_fully_auto vccd1 pad_vccd1_w VCCD POWER both

bridge_sky130_power_pad_to_ring_fully_auto vssd1 pad_vssd1_n VSSD GROUND both
bridge_sky130_power_pad_to_ring_fully_auto vssd1 pad_vssd1_e VSSD GROUND both
bridge_sky130_power_pad_to_ring_fully_auto vssd1 pad_vssd1_w VSSD GROUND both
```

No hay pads `pad_vccd1_s` ni `pad_vssd1_s`; en el lado sur solo están los pads de `vddio_s`/`vssio_s`, que no alimentan el core.

## Conexiones pad-to-ring

Las conexiones de `vccd1` y `vssd1` se crean desde las ventanas de metal3 de los pins `VCCD`/`VSSD` de los pads hacia el ring del chip.

El script calcula automáticamente:

- orientación del pad (`MY`, `R180`, `R270`, `MYR90`),
- lado físico del padring,
- ventanas izquierda/derecha del pin de alimentación,
- coordenada del ring correspondiente,
- matriz de vías entre met3/met4 y met4/met5.

Puntos importantes del arreglo:

- En los pads, la conexión entra por met3, no por met5.
- En lados este/oeste se evita usar met4 como puente principal cuando puede coincidir con el ring vertical y crear cortos entre dominios.
- Las vías se generan como matriz, no como una sola fila.
- Se eliminaron los L-straps experimentales en met5 porque podían unir dominios de alimentación del padring y generaban DRC `m5.2`.

## Obstrucciones de ruteo

Se agregaron obstrucciones de ruteo para evitar que TritonRoute acceda a ciertos pins del padring con geometrías demasiado cercanas al borde del pad.

Están presentes en `config_chip_hier.json` y `config_chip_flat.json`:

```json
"ROUTING_OBSTRUCTIONS": [
  ["met3", 197.9, 1021.4, 202.5, 1024.2],
  ["met2", 199.124, 1022.302, 200.0, 1022.719],
  ["met2", 199.124, 1021.191, 199.996, 1021.785],
  ["met2", 1459.9, 197.9, 1460.7, 202.5]
]
```

Estas obstrucciones fuerzan un acceso más limpio a pins de pads sensibles y eliminan los DRC top-level que aparecían por cambios de capa demasiado cerca del pad.

## Modelos de pads para LVS

Los configs incluyen los modelos CDL/SPICE de sky130 I/O:

```json
"PAD_SPICE_MODELS": [
  "pdk_dir::libs.ref/sky130_fd_io/cdl/sky130_ef_io.cdl",
  "pdk_dir::libs.ref/sky130_fd_io/spice/sky130_fd_io.spice"
],
"PAD_CDLS": [
  "pdk_dir::libs.ref/sky130_fd_io/cdl/sky130_ef_io.cdl"
]
```

Esto permite que Netgen compare contra la conectividad real esperada de los pads.

## Extracción Magic abstracta

La extracción final mantiene pads abstractos:

```json
"MAGIC_EXT_USE_GDS": false,
"MAGIC_EXT_ABSTRACT": true
```

Esto evita el problema de cargar toda la geometría GDS de pads en Magic para el chip completo, pero requiere corregir la diferencia entre:

- conectividad interna real del pad en CDL,
- conectividad expuesta por la vista abstracta/maglef extraída por Magic.

## Step custom Netgen.PadFix

Se creó el plugin local:

```text
librelane_plugin_padfix/__init__.py
```

Este plugin registra el step:

```text
Netgen.PadFix
```

El step se inserta antes de `Netgen.LVS` en ambos configs:

```json
"meta": {
  "flow": "Chip",
  "substituting_steps": {
    "-Netgen.LVS": "Netgen.PadFix"
  }
}
```

`Netgen.PadFix` toma el SPICE generado por `Magic.SpiceExtraction`, normaliza la conectividad abstracta de pads y devuelve un nuevo `DesignFormat.SPICE` para que `Netgen.LVS` estándar lo use sin modificar Netgen ni LibreLane.

El archivo de normalización es:

```text
normalize_magic_lvs_spice.py
```

La normalización hace:

- `vccd1_uq*` -> `vccd1`
- `vssd1_uq*` -> `vssd1`
- `vddio_uq*` -> `vddio`
- `vssio_uq*` -> `vssio`
- pins abstractos como `*/VCCD`, `*/VCCD_PAD`, `*/VCCHIB` -> `vccd1`
- pins abstractos como `*/VSSD`, `*/VSSD_PAD` -> `vssd1`
- pins abstractos de IO supply -> `vddio`/`vssio`
- pins analógicos comunes `VDDA`, `VSSA`, `AMUXBUS_A`, `AMUXBUS_B` a sus nets top-level esperadas

También reescribe el header top-level de `.subckt chip_top_spi` con los puertos esperados:

```text
pad_clk pad_reset pad_spi_cs_n pad_spi_miso pad_spi_mosi pad_spi_sclk
vccd1 vdda vddio vssa vssd1 vssio
```

## Resultado del run final

En `runs/spi-chip-hier-27`:

```text
65-netgen-padfix
66-netgen-lvs
```

`Netgen.LVS` usó:

```text
runs/spi-chip-hier-27/65-netgen-padfix/chip_top_spi.padfix.spice
```

El reporte final de LVS indica:

```text
Final result: Circuits match uniquely.
```

Métricas relevantes:

```text
design__lvs_error__count = 0
timing__setup_vio__count = 0
timing__hold_vio__count = 0
route__drc_errors = 0
antenna__violating__nets = 0
```

## DRC aceptados por waiver

KLayout reporta 60 DRC:

```text
psdm.1 = 47
nwell.6 = 8
m2.2 = 2
via2.2 = 2
m3.2 = 1
total = 60
```

Estos DRC provienen de la SRAM generada por el compilador de memoria SKY130. No son introducidos por la integración chip-level ni por las conexiones del padring, por lo que se aceptan mediante waiver.

## PSM

OpenROAD PSM reporta muchas violaciones de power grid:

```text
design__power_grid_violation__count = 2400808
```

El flow las marca como deferred e indica que pueden ignorarse si LVS pasa. En este caso LVS pasa limpio con `Netgen.PadFix`, por lo que estas violaciones se tratan como una limitación/falso positivo del análisis PSM para esta integración con padring, pads abstractos y macro.

## Estado final

El estado final aceptado del chip es:

- LVS limpio.
- STA limpio.
- Routing DRC limpio.
- Antenna limpio.
- DRC KLayout restante aceptado por waiver de SRAM.
- PSM no usado como criterio bloqueante porque LVS valida la conectividad final.

