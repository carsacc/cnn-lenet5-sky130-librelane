#!/usr/bin/env python3
"""
gen_xyce_tb.py — Generate Xyce SPICE testbench for chip_top_spi
                  SPI write + readback verification

Test: Write 0xDEADBEEF to param_memory addr 0x0000 via SPI,
      then read it back (2 SPI read transactions due to pipeline).

SPI protocol (Mode 0, MSB-first, 56-bit frame):
  [1b R/W][23b address][32b data]
  Address = {5'b0, target[1:0], addr[15:0]}
  target: 00=param, 01=buf_A, 10=buf_B, 11=CSR
"""

VDD = 1.8
TR = 1.0             # rise/fall time (ns)
CLK_PERIOD = 66.67   # Core clock (ns) — 15 MHz
SPI_BIT_TIME = 200.0 # SPI bit period (ns) — 5 MHz

# PDK paths — use PDK_ROOT env var, or auto-detect from ciel
import os
_pdk_default = os.path.expanduser("~/.ciel/sky130A")
PDK_ROOT = os.environ.get("PDK_ROOT", _pdk_default)
PDK_LIB = f"{PDK_ROOT}/libs.tech/ngspice/sky130.lib.spice"
STDCELL = f"{PDK_ROOT}/libs.ref/sky130_fd_sc_hd/spice/sky130_fd_sc_hd.spice"


def frame_bits(rw, addr23, data32):
    """Return 56 bits as list [MSB..LSB] for one SPI frame."""
    val = (rw << 55) | ((addr23 & 0x7FFFFF) << 32) | (data32 & 0xFFFFFFFF)
    return [(val >> (55 - i)) & 1 for i in range(56)]


def gen_pwl_sources():
    """Generate PWL point lists for CS_N, SCLK, MOSI."""

    # SPI Frames
    frames = [
        frame_bits(0, 0x000000, 0xDEADBEEF),  # Write PM[0] = 0xDEADBEEF
        frame_bits(1, 0x000000, 0x00000000),   # Read PM[0] (pipeline cmd)
        frame_bits(1, 0x000000, 0x00000000),   # Read PM[0] (data on MISO)
    ]

    cs_pts  = [(0, VDD)]   # idle HIGH
    sclk_pts = [(0, 0)]    # idle LOW (CPOL=0)
    mosi_pts = [(0, 0)]    # idle LOW

    T_RESET  = 1000.0    # ns
    T_SETTLE = 500.0     # ns after reset, before SPI
    T_GAP    = 1000.0    # ns between frames

    t = T_RESET + T_SETTLE

    for frame in frames:
        # --- CS_N falls (start of frame) ---
        cs_pts.append((t - TR, VDD))
        cs_pts.append((t, 0))
        t += 30  # setup before first bit

        for bit_idx in range(56):
            bit_v = frame[bit_idx] * VDD

            # MOSI: set value (setup before rising edge)
            t_mosi = t
            if len(mosi_pts) == 0 or mosi_pts[-1][1] != bit_v:
                mosi_pts.append((t_mosi - TR, mosi_pts[-1][1]))
                mosi_pts.append((t_mosi, bit_v))
            else:
                # Same value — just extend
                pass

            # SCLK rising edge: 40 ns after MOSI change
            t_rise = t + 40
            sclk_pts.append((t_rise - TR, 0))
            sclk_pts.append((t_rise, VDD))

            # SCLK falling edge: 100 ns high time
            t_fall = t_rise + 100
            sclk_pts.append((t_fall - TR, VDD))
            sclk_pts.append((t_fall, 0))

            t += SPI_BIT_TIME

        # --- CS_N rises (end of frame) ---
        t += 30  # hold after last bit
        cs_pts.append((t - TR, 0))
        cs_pts.append((t, VDD))

        t += T_GAP

    t_end = t + 1000  # 1 us margin

    # Extend to end
    cs_pts.append((t_end, VDD))
    sclk_pts.append((t_end, 0))
    mosi_pts.append((t_end, mosi_pts[-1][1]))

    return cs_pts, sclk_pts, mosi_pts, t_end


def fmt_pwl(pts):
    """Format PWL points as SPICE string with + continuation, ready for PWL()."""
    lines = []
    line = ""
    for i, (t, v) in enumerate(pts):
        pair = f"{t:.1f}n {v:.4f}"
        if i == 0:
            line = "+ " + pair
        elif (i % 6) == 0:
            lines.append(line)
            line = "+ " + pair
        else:
            line += " " + pair
    # Close the parenthesis on the last line
    lines.append(line + ")")
    return "\n".join(lines)


def main():
    cs_pts, sclk_pts, mosi_pts, t_end = gen_pwl_sources()

    print(f"PWL points: CS_N={len(cs_pts)}, SCLK={len(sclk_pts)}, MOSI={len(mosi_pts)}")
    print(f"Simulation time: {t_end/1e3:.1f} us")

    cir = f"""\
* chip_spi_tb.cir — Xyce testbench: chip_top_spi SPI write/readback
* Write 0xDEADBEEF to param_memory addr 0, read back via SPI
* Core clock: 15 MHz | SPI clock: 5 MHz | Sim time: {t_end/1e3:.1f} us
*
* Run: mpirun -np ${{NPROCS}} Xyce chip_spi_tb.cir

* ============================================================
* Models — PDK transistor models (TT corner)
* ============================================================
.LIB "{PDK_LIB}" tt

* ============================================================
* Standard cell transistor-level subcircuits
* ============================================================
.INCLUDE "{STDCELL}"

* ============================================================
* Diode model for antenna cells (sky130_fd_sc_hd__diode_2)
* Simplified from sky130 PDK — the original uses parameterized
* expressions that Xyce cannot resolve. These diodes are reverse-
* biased during normal digital operation; only basic IV and cap
* parameters matter for convergence.
* ============================================================
.MODEL sky130_fd_pr__diode_pw2nd_05v5 D
+ IS=2.75e-15 N=1.2928 RS=981 BV=11.7 IBV=0.00106
+ CJO=1.3459e-15 VJ=0.729 M=0.44 EG=1.05 XTI=2.0

* ============================================================
* SRAM macro transistor-level models (OpenRAM)
* ============================================================
.INCLUDE "sram_2048_trimmed.sp"
.INCLUDE "sram_1024_trimmed.sp"

* ============================================================
* Behavioral pad models
* ============================================================
.INCLUDE "pad_models.spice"

* ============================================================
* Chip netlist (gate-level from Magic extraction, stubs stripped)
* ============================================================
.INCLUDE "chip_netlist.spice"

* ============================================================
* Power Supplies (1.8 V)
* ============================================================
Vvdd vdd 0 {VDD}
Vgnd gnd 0 0

* ============================================================
* DUT — chip_top_spi
* Ports: pad_clk pad_reset pad_spi_cs_n pad_spi_miso pad_spi_mosi
*        pad_spi_sclk vccd1 vddio vssd1 vssio
*        vccd1_uq0 vccd1_uq1 vccd1_uq9
*        vssd1_uq0 vssd1_uq1 vssd1_uq2
*        vssio_uq0 vddio_uq0
* ============================================================
Xdut pad_clk pad_reset pad_spi_cs_n pad_spi_miso pad_spi_mosi pad_spi_sclk
+ vdd vdd gnd gnd vdd vdd vdd gnd gnd gnd gnd vdd
+ chip_top_spi

* ============================================================
* Core Clock — 15 MHz, 1.8V, starts at t=10ns
* ============================================================
Vclk pad_clk 0 PULSE(0 {VDD} 10n {TR}n {TR}n {CLK_PERIOD/2 - TR:.2f}n {CLK_PERIOD:.2f}n)

* ============================================================
* Reset — active HIGH for 1 us, then released
* ============================================================
Vrst pad_reset 0 PWL(0 {VDD} 1000n {VDD} {1000+TR:.0f}n 0 {t_end:.0f}n 0)

* ============================================================
* SPI CS_N
* ============================================================
Vcsn pad_spi_cs_n 0 PWL(
{fmt_pwl(cs_pts)}

* ============================================================
* SPI SCLK
* ============================================================
Vsclk pad_spi_sclk 0 PWL(
{fmt_pwl(sclk_pts)}

* ============================================================
* SPI MOSI
* ============================================================
Vmosi pad_spi_mosi 0 PWL(
{fmt_pwl(mosi_pts)}

* ============================================================
* MISO load (output pad drives this)
* ============================================================
Cmiso pad_spi_miso 0 1p

* ============================================================
* Simulation Control
* ============================================================
.TRAN 50p {t_end:.0f}n

* Solver options for large digital circuit
.OPTIONS TIMEINT METHOD=GEAR ERROPTION=1
.OPTIONS NONLIN MAXSTEP=200 SEARCHMETHOD=2
.OPTIONS DEVICE VOLTLIM=0

* ============================================================
* Output — CSV with SPI signals
* ============================================================
.PRINT TRAN V(pad_clk) V(pad_reset) V(pad_spi_cs_n) V(pad_spi_sclk) V(pad_spi_mosi) V(pad_spi_miso)

.END
"""

    with open("chip_spi_tb.cir", "w") as f:
        f.write(cir)

    print("Written: chip_spi_tb.cir")


if __name__ == "__main__":
    main()
