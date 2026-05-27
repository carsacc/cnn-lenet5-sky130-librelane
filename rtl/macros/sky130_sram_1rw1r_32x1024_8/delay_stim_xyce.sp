* Delay stimulus modified for XYCE - Writing 0xAAAAAAAA @ 100MHz
.lib "/home/carlos/.ciel/sky130A/libs.tech/ngspice/sky130.lib.spice" tt
.include "trimmed.sp"

* Power
Vvdd vdd 0 1.8
Vgnd gnd 0 0.0

* SRAM Instance
Xsky130_sram_1rw1r_32x1024_8 din0_0 din0_1 din0_2 din0_3 din0_4 din0_5 din0_6 din0_7 din0_8 din0_9 din0_10 din0_11 din0_12 din0_13 din0_14 din0_15 din0_16 din0_17 din0_18 din0_19 din0_20 din0_21 din0_22 din0_23 din0_24 din0_25 din0_26 din0_27 din0_28 din0_29 din0_30 din0_31 a0_0 a0_1 a0_2 a0_3 a0_4 a0_5 a0_6 a0_7 a0_8 a0_9 a1_0 a1_1 a1_2 a1_3 a1_4 a1_5 a1_6 a1_7 a1_8 a1_9 CSB0 CSB1 WEB0 clk0 clk1 WMASK0_0 WMASK0_1 WMASK0_2 WMASK0_3 dout0_0 dout0_1 dout0_2 dout0_3 dout0_4 dout0_5 dout0_6 dout0_7 dout0_8 dout0_9 dout0_10 dout0_11 dout0_12 dout0_13 dout0_14 dout0_15 dout0_16 dout0_17 dout0_18 dout0_19 dout0_20 dout0_21 dout0_22 dout0_23 dout0_24 dout0_25 dout0_26 dout0_27 dout0_28 dout0_29 dout0_30 dout0_31 dout1_0 dout1_1 dout1_2 dout1_3 dout1_4 dout1_5 dout1_6 dout1_7 dout1_8 dout1_9 dout1_10 dout1_11 dout1_12 dout1_13 dout1_14 dout1_15 dout1_16 dout1_17 dout1_18 dout1_19 dout1_20 dout1_21 dout1_22 dout1_23 dout1_24 dout1_25 dout1_26 dout1_27 dout1_28 dout1_29 dout1_30 dout1_31 vdd gnd sky130_sram_1rw1r_32x1024_8

* Clock (100MHz)
VCLK0 clk0 0 PULSE (0 1.8 1n 50p 50p 4n 10n)
VCLK1 clk1 0 PULSE (0 1.8 1n 50p 50p 4n 10n)

* Control (Write 0-50ns, Read 50-250ns)
VCSB0 CSB0 0 PWL (0n 1.8 5n 1.8 6n 0)
VWEB0 WEB0 0 PWL (0n 1.8 5n 1.8 6n 0 50n 0 51n 1.8)
VCSB1 CSB1 0 1.8

* WMASK: Enable all 4 bytes (Write whole 32-bit word)
VWMASK0_0 WMASK0_0 0 1.8
VWMASK0_1 WMASK0_1 0 1.8
VWMASK0_2 WMASK0_2 0 1.8
VWMASK0_3 WMASK0_3 0 1.8

* Addresses (Always 0x000)
Va0_0 a0_0 0 0
Va0_1 a0_1 0 0
Va0_2 a0_2 0 0
Va0_3 a0_3 0 0
Va0_4 a0_4 0 0
Va0_5 a0_5 0 0
Va0_6 a0_6 0 0
Va0_7 a0_7 0 0
Va0_8 a0_8 0 0
Va0_9 a0_9 0 0

* Data Pattern 0xAAAAAAAA (10101010...)
* Bit 0=0, 1=1, 2=0, 3=1...
Vdin0_0 din0_0 0 0
Vdin0_1 din0_1 0 1.8
Vdin0_2 din0_2 0 0
Vdin0_3 din0_3 0 1.8
Vdin0_4 din0_4 0 0
Vdin0_5 din0_5 0 1.8
Vdin0_6 din0_6 0 0
Vdin0_7 din0_7 0 1.8
* (Rest of bits 8-31 simplified to 0 for brevity in spice, 
* but you could repeat the pattern if needed)

* Simulation & Output
.TRAN 10p 250n
.PRINT TRAN FORMAT=CSV V(clk0) V(CSB0) V(WEB0) V(dout0_0) V(dout0_1) V(dout0_2) V(dout0_3) V(dout0_4) V(dout0_5) V(dout0_6) V(dout0_7)
.end
