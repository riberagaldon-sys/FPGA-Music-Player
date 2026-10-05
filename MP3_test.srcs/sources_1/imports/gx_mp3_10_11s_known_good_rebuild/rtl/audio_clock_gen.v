`timescale 1ns / 1ps

// 100 MHz -> 12.288 MHz, for 48 kHz * 256 audio MCLK.
// MMCM:
//   Fin  = 100 MHz
//   D    = 5
//   M    = 48
//   VCO  = 960 MHz
//   O0   = 78.125
//   Fout = 12.288 MHz exactly
module audio_clock_gen(
    input  wire clk_100m,
    input  wire rst_n,
    output wire mclk_12m288,
    output wire locked
);
    wire clkfb_raw;
    wire clkfb_buf;
    wire mclk_raw;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(48.000),
        .CLKIN1_PERIOD(10.000),
        .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(78.125),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk_100m),
        .RST(~rst_n),
        .PWRDWN(1'b0),
        .CLKFBIN(clkfb_buf),
        .CLKFBOUT(clkfb_raw),
        .CLKOUT0(mclk_raw),
        .LOCKED(locked)
    );

    BUFG u_bufg_fb (
        .I(clkfb_raw),
        .O(clkfb_buf)
    );

    BUFG u_bufg_mclk (
        .I(mclk_raw),
        .O(mclk_12m288)
    );
endmodule
