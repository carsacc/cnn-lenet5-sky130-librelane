// pad_sim_models.v — Simplified behavioral models for sky130_ef_io pads
// For gate-level functional simulation (no power checking)
// These replace the full PDK pad models which require power rails to function.

`timescale 1ns/1ps

// =========================================================================
// GPIO pad — bidirectional I/O
// DM=001 (input): IN = PAD, PAD not driven
// DM=110 (push-pull output): PAD = OUT, IN disabled
// =========================================================================
module sky130_ef_io__gpiov2_pad (
    input  OUT,
    input  OE_N,
    input  HLD_H_N,
    input  ENABLE_H,
    input  ENABLE_INP_H,
    input  ENABLE_VDDA_H,
    input  ENABLE_VSWITCH_H,
    input  ENABLE_VDDIO,
    input  INP_DIS,
    input  IB_MODE_SEL,
    input  VTRIP_SEL,
    input  SLOW,
    input  HLD_OVR,
    input  ANALOG_EN,
    input  ANALOG_SEL,
    input  ANALOG_POL,
    input  [2:0] DM,
    inout  VDDIO,
    inout  VDDIO_Q,
    inout  VDDA,
    inout  VCCD,
    inout  VSWITCH,
    inout  VCCHIB,
    inout  VSSA,
    inout  VSSD,
    inout  VSSIO_Q,
    inout  VSSIO,
    inout  PAD,
    inout  PAD_A_NOESD_H,
    inout  PAD_A_ESD_0_H,
    inout  PAD_A_ESD_1_H,
    inout  AMUXBUS_A,
    inout  AMUXBUS_B,
    output IN,
    output IN_H,
    output TIE_HI_ESD,
    output TIE_LO_ESD
);

    // Output driver: active when OE_N=0 and DM is output-capable
    wire out_en = (OE_N === 1'b0) && (DM != 3'b000) && (DM != 3'b001);
    assign PAD = out_en ? OUT : 1'bz;

    // Input buffer: active when INP_DIS=0 and DM is not 000
    wire inp_en = (INP_DIS === 1'b0) && (DM != 3'b000);
    assign IN   = inp_en ? PAD : 1'b0;
    assign IN_H = IN;

    assign TIE_HI_ESD = 1'b1;
    assign TIE_LO_ESD = 1'b0;

endmodule

// =========================================================================
// Power pads — passive in simulation
// =========================================================================
module sky130_ef_io__vccd_lvc_pad (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout DRN_LVC1, inout DRN_LVC2,
    inout SRC_BDY_LVC1, inout SRC_BDY_LVC2, inout BDY2_B2B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD, inout VCCD_PAD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

module sky130_ef_io__vssd_lvc_pad (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout DRN_LVC1, inout DRN_LVC2,
    inout SRC_BDY_LVC1, inout SRC_BDY_LVC2, inout BDY2_B2B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD, inout VSSD_PAD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

module sky130_ef_io__vddio_lvc_pad (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout DRN_LVC1, inout DRN_LVC2,
    inout SRC_BDY_LVC1, inout SRC_BDY_LVC2, inout BDY2_B2B,
    inout VDDIO, inout VDDIO_PAD, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

module sky130_ef_io__vssio_lvc_pad (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout DRN_LVC1, inout DRN_LVC2,
    inout SRC_BDY_LVC1, inout SRC_BDY_LVC2, inout BDY2_B2B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO, inout VSSIO_PAD
);
endmodule

// =========================================================================
// Corner pads — passive
// =========================================================================
module sky130_ef_io__corner_pad (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

// =========================================================================
// I/O filler cells — passive
// =========================================================================
module sky130_ef_io__com_bus_slice_1um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

module sky130_ef_io__com_bus_slice_5um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

module sky130_ef_io__com_bus_slice_10um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

module sky130_ef_io__com_bus_slice_20um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule
