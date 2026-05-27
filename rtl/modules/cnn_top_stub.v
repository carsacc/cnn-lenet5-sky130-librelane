// cnn_top.v — Top-Level CNN Accelerator
// Interface selection:
//   default        → OBI Slave  (host_interface.v)  — for SoC integration
//   -DUSE_SPI_INTERFACE → SPI Slave  (spi_interface.v)  — for standalone chip
//
// Memory arbitration: accel_start=1 → sequencer owns memories,
//                     accel_start=0 → host/SPI owns memories

module cnn_top (
    input  wire        clk,
    input  wire        reset,
    // SPI Slave Port
    input  wire        spi_sclk,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    output wire        spi_miso
);
endmodule
