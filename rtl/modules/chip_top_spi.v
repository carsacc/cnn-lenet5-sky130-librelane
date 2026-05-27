// chip_top_spi.v — Padring wrapper for cnn_top with SPI interface
// Instantiates 6 GPIO pads + 10 power pads + 4 corners + cnn_top core (SPI mode)
// For standalone chip — no SoC, external MCU communicates via SPI

module chip_top_spi (
`ifdef USE_POWER_PINS
    inout vccd1,
    inout vssd1,
    inout vddio,
    inout vssio,
    inout vdda,
    inout vssa,
`endif
    // GPIO bond pads
    inout pad_clk,
    inout pad_reset,
    inout pad_spi_sclk,
    inout pad_spi_cs_n,
    inout pad_spi_mosi,
    inout pad_spi_miso
);

    // -------------------------------------------------------
    // Internal wires: GPIO pad <-> core
    // -------------------------------------------------------
    wire clk_core, reset_core;
    wire spi_sclk_core, spi_cs_n_core, spi_mosi_core, spi_miso_core;

    // Shared analog buses (connected by pad abutment)
    wire amuxbus_a, amuxbus_b;

    // Power domain wires
`ifdef USE_POWER_PINS
    wire vcchib  = vccd1;
    wire vddio_q = vddio;
    wire vssio_q = vssio;
    wire vswitch = vddio;
`else
    wire vccd1, vssd1, vddio, vssio, vdda, vssa;
    wire vcchib, vddio_q, vssio_q, vswitch;
`endif

    // -------------------------------------------------------
    // INPUT GPIO pads (5): clk, reset, spi_sclk, spi_cs_n, spi_mosi
    // -------------------------------------------------------
    `define GPIO_INPUT_ACTIVE \
        .OUT      (1'b0       ), \
        .OE_N     (1'b1       ), \
        .DM       (3'b001     ), \
        .INP_DIS  (1'b0       ), \
        .IB_MODE_SEL(1'b0     ), \
        .VTRIP_SEL(1'b0       ), \
        .SLOW     (1'b0       ), \
        .HLD_OVR  (1'b0       ), \
        .ANALOG_EN(1'b0       ), \
        .ANALOG_SEL(1'b0      ), \
        .ANALOG_POL(1'b0      ), \
        .HLD_H_N  (1'b1       ), \
        .ENABLE_H (1'b1       ), \
        .ENABLE_INP_H(1'b1    ), \
        .ENABLE_VDDA_H(1'b1   ), \
        .ENABLE_VSWITCH_H(1'b0), \
        .ENABLE_VDDIO(1'b1    )

    `define GPIO_OUTPUT_ACTIVE(sig) \
        .OUT      (sig        ), \
        .OE_N     (1'b0       ), \
        .DM       (3'b110     ), \
        .INP_DIS  (1'b1       ), \
        .IB_MODE_SEL(1'b0     ), \
        .VTRIP_SEL(1'b0       ), \
        .SLOW     (1'b0       ), \
        .HLD_OVR  (1'b0       ), \
        .ANALOG_EN(1'b0       ), \
        .ANALOG_SEL(1'b0      ), \
        .ANALOG_POL(1'b0      ), \
        .HLD_H_N  (1'b1       ), \
        .ENABLE_H (1'b1       ), \
        .ENABLE_INP_H(1'b0    ), \
        .ENABLE_VDDA_H(1'b1   ), \
        .ENABLE_VSWITCH_H(1'b0), \
        .ENABLE_VDDIO(1'b1    )

    `define GPIO_POWER_CONN \
        .AMUXBUS_A(amuxbus_a  ), \
        .AMUXBUS_B(amuxbus_b  ), \
        .VDDIO    (vddio      ), \
        .VDDIO_Q  (vddio_q   ), \
        .VDDA     (vdda       ), \
        .VCCD     (vccd1      ), \
        .VSWITCH  (vswitch    ), \
        .VCCHIB   (vcchib     ), \
        .VSSA     (vssa       ), \
        .VSSD     (vssd1      ), \
        .VSSIO_Q  (vssio_q   ), \
        .VSSIO    (vssio      )

    `define POWER_PAD_CONN \
        .AMUXBUS_A    (amuxbus_a), \
        .AMUXBUS_B    (amuxbus_b), \
        .VDDIO        (vddio     ), \
        .VDDIO_Q      (vddio_q  ), \
        .VDDA         (vdda      ), \
        .VCCD         (vccd1     ), \
        .VSWITCH      (vswitch   ), \
        .VCCHIB       (vcchib    ), \
        .VSSA         (vssa      ), \
        .VSSD         (vssd1     ), \
        .VSSIO_Q      (vssio_q  ), \
        .VSSIO        (vssio     )

    // --- Input pads ---
    (* blackbox *)
    sky130_ef_io__gpiov2_pad pad_clk_inst (
        .PAD(pad_clk), .IN(clk_core), .IN_H(),
        .PAD_A_NOESD_H(), .PAD_A_ESD_0_H(), .PAD_A_ESD_1_H(),
        .TIE_HI_ESD(), .TIE_LO_ESD(),
        `GPIO_INPUT_ACTIVE,
        `GPIO_POWER_CONN
    );

    (* blackbox *)
    sky130_ef_io__gpiov2_pad pad_reset_inst (
        .PAD(pad_reset), .IN(reset_core), .IN_H(),
        .PAD_A_NOESD_H(), .PAD_A_ESD_0_H(), .PAD_A_ESD_1_H(),
        .TIE_HI_ESD(), .TIE_LO_ESD(),
        `GPIO_INPUT_ACTIVE,
        `GPIO_POWER_CONN
    );

    (* blackbox *)
    sky130_ef_io__gpiov2_pad pad_spi_sclk_inst (
        .PAD(pad_spi_sclk), .IN(spi_sclk_core), .IN_H(),
        .PAD_A_NOESD_H(), .PAD_A_ESD_0_H(), .PAD_A_ESD_1_H(),
        .TIE_HI_ESD(), .TIE_LO_ESD(),
        `GPIO_INPUT_ACTIVE,
        `GPIO_POWER_CONN
    );

    (* blackbox *)
    sky130_ef_io__gpiov2_pad pad_spi_cs_n_inst (
        .PAD(pad_spi_cs_n), .IN(spi_cs_n_core), .IN_H(),
        .PAD_A_NOESD_H(), .PAD_A_ESD_0_H(), .PAD_A_ESD_1_H(),
        .TIE_HI_ESD(), .TIE_LO_ESD(),
        `GPIO_INPUT_ACTIVE,
        `GPIO_POWER_CONN
    );

    (* blackbox *)
    sky130_ef_io__gpiov2_pad pad_spi_mosi_inst (
        .PAD(pad_spi_mosi), .IN(spi_mosi_core), .IN_H(),
        .PAD_A_NOESD_H(), .PAD_A_ESD_0_H(), .PAD_A_ESD_1_H(),
        .TIE_HI_ESD(), .TIE_LO_ESD(),
        `GPIO_INPUT_ACTIVE,
        `GPIO_POWER_CONN
    );

    // --- Output pad ---
    (* blackbox *)
    sky130_ef_io__gpiov2_pad pad_spi_miso_inst (
        .PAD(pad_spi_miso), .IN(), .IN_H(),
        .PAD_A_NOESD_H(), .PAD_A_ESD_0_H(), .PAD_A_ESD_1_H(),
        .TIE_HI_ESD(), .TIE_LO_ESD(),
        `GPIO_OUTPUT_ACTIVE(spi_miso_core),
        `GPIO_POWER_CONN
    );

    // -------------------------------------------------------
    // POWER PADS (10): 3x vccd, 3x vssd, 2x vddio, 2x vssio
    // -------------------------------------------------------
    sky130_ef_io__vccd_lvc_pad pad_vccd1_w  ( `POWER_PAD_CONN, .VCCD_PAD(vccd1)  );
    sky130_ef_io__vccd_lvc_pad pad_vccd1_e  ( `POWER_PAD_CONN, .VCCD_PAD(vccd1)  );
    sky130_ef_io__vccd_lvc_pad pad_vccd1_n  ( `POWER_PAD_CONN, .VCCD_PAD(vccd1)  );
    sky130_ef_io__vssd_lvc_pad pad_vssd1_w  ( `POWER_PAD_CONN, .VSSD_PAD(vssd1)  );
    sky130_ef_io__vssd_lvc_pad pad_vssd1_e  ( `POWER_PAD_CONN, .VSSD_PAD(vssd1)  );
    sky130_ef_io__vssd_lvc_pad pad_vssd1_n  ( `POWER_PAD_CONN, .VSSD_PAD(vssd1)  );
    sky130_ef_io__vddio_lvc_pad pad_vddio_s ( `POWER_PAD_CONN, .VDDIO_PAD(vddio) );
    sky130_ef_io__vddio_lvc_pad pad_vddio_n ( `POWER_PAD_CONN, .VDDIO_PAD(vddio) );
    sky130_ef_io__vssio_lvc_pad pad_vssio_s ( `POWER_PAD_CONN, .VSSIO_PAD(vssio) );
    sky130_ef_io__vssio_lvc_pad pad_vssio_n ( `POWER_PAD_CONN, .VSSIO_PAD(vssio) );

    // -------------------------------------------------------
    // CORNER PADS (4)
    // -------------------------------------------------------
    sky130_ef_io__corner_pad corner_sw ( `GPIO_POWER_CONN );
    sky130_ef_io__corner_pad corner_se ( `GPIO_POWER_CONN );
    sky130_ef_io__corner_pad corner_ne ( `GPIO_POWER_CONN );
    sky130_ef_io__corner_pad corner_nw ( `GPIO_POWER_CONN );

    // -------------------------------------------------------
    // CORE: cnn_top (SPI mode via USE_SPI_INTERFACE define)
    // -------------------------------------------------------
    (* blackbox *)
    cnn_top u_core (
        .clk       (clk_core       ),
        .reset     (reset_core     ),
        .spi_sclk  (spi_sclk_core  ),
        .spi_cs_n  (spi_cs_n_core  ),
        .spi_mosi  (spi_mosi_core  ),
        .spi_miso  (spi_miso_core  )
    );

endmodule
