// Blackbox stubs for sky130_ef_io pad cells used in chip_top
// Physical layout provided by LEF/GDS from the PDK

(* blackbox *)
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
endmodule

(* blackbox *)
module sky130_ef_io__vccd_lvc_pad (
    inout AMUXBUS_A,
    inout AMUXBUS_B,
    inout DRN_LVC1,
    inout DRN_LVC2,
    inout SRC_BDY_LVC1,
    inout SRC_BDY_LVC2,
    inout BDY2_B2B,
    inout VDDIO,
    inout VDDIO_Q,
    inout VDDA,
    inout VCCD,
    inout VCCD_PAD,
    inout VSWITCH,
    inout VCCHIB,
    inout VSSA,
    inout VSSD,
    inout VSSIO_Q,
    inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__vssd_lvc_pad (
    inout AMUXBUS_A,
    inout AMUXBUS_B,
    inout DRN_LVC1,
    inout DRN_LVC2,
    inout SRC_BDY_LVC1,
    inout SRC_BDY_LVC2,
    inout BDY2_B2B,
    inout VDDIO,
    inout VDDIO_Q,
    inout VDDA,
    inout VCCD,
    inout VSWITCH,
    inout VCCHIB,
    inout VSSA,
    inout VSSD,
    inout VSSD_PAD,
    inout VSSIO_Q,
    inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__vddio_lvc_pad (
    inout AMUXBUS_A,
    inout AMUXBUS_B,
    inout DRN_LVC1,
    inout DRN_LVC2,
    inout SRC_BDY_LVC1,
    inout SRC_BDY_LVC2,
    inout BDY2_B2B,
    inout VDDIO,
    inout VDDIO_PAD,
    inout VDDIO_Q,
    inout VDDA,
    inout VCCD,
    inout VSWITCH,
    inout VCCHIB,
    inout VSSA,
    inout VSSD,
    inout VSSIO_Q,
    inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__vssio_lvc_pad (
    inout AMUXBUS_A,
    inout AMUXBUS_B,
    inout DRN_LVC1,
    inout DRN_LVC2,
    inout SRC_BDY_LVC1,
    inout SRC_BDY_LVC2,
    inout BDY2_B2B,
    inout VDDIO,
    inout VDDIO_Q,
    inout VDDA,
    inout VCCD,
    inout VSWITCH,
    inout VCCHIB,
    inout VSSA,
    inout VSSD,
    inout VSSIO_Q,
    inout VSSIO,
    inout VSSIO_PAD
);
endmodule

(* blackbox *)
module sky130_ef_io__corner_pad (
    inout AMUXBUS_A,
    inout AMUXBUS_B,
    inout VDDIO,
    inout VDDIO_Q,
    inout VDDA,
    inout VCCD,
    inout VSWITCH,
    inout VCCHIB,
    inout VSSA,
    inout VSSD,
    inout VSSIO_Q,
    inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__com_bus_slice_1um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__com_bus_slice_5um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__com_bus_slice_10um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule

(* blackbox *)
module sky130_ef_io__com_bus_slice_20um (
    inout AMUXBUS_A, inout AMUXBUS_B,
    inout VDDIO, inout VDDIO_Q, inout VDDA, inout VCCD,
    inout VSWITCH, inout VCCHIB, inout VSSA, inout VSSD,
    inout VSSIO_Q, inout VSSIO
);
endmodule
