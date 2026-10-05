`timescale 1ns / 1ps
`default_nettype none

// SD-card Stage 1 top level.
//
// This build intentionally performs no QSPI Flash access and produces no
// audio.  It proves the SD electrical interface, SPI initialization and a
// complete 512-byte sector read before SD streaming is connected to ES8388.
module top_mp3_player (
    input  wire       sys_clk,
    input  wire       UART_RXD,
    output wire       UART_TXD,

    output wire       AUDIO_MCLK,
    output wire       AUDIO_BCLK,
    output wire       AUDIO_LRCK,
    output wire       AUDIO_DAC_DIN,
    input  wire       AUDIO_ADC_DOUT,
    output wire       AUDIO_CCLK,
    inout  wire       AUDIO_CDATA,

    output wire       FLASH_CS_N,
    output wire       FLASH_SCLK,
    output wire       FLASH_MOSI,
    input  wire       FLASH_MISO,
    output wire       FLASH_HOLD_N,

    output wire       SD_CS_N,
    output wire       SD_SCLK,
    output wire       SD_MOSI,
    input  wire       SD_MISO,
    input  wire       SD_CD_N,

    output wire [7:0] LCD_D,
    output wire       LCD_RS,
    output wire       LCD_RW,
    output wire       LCD_E,

    output wire       LED0,
    output wire       LED1
);
    wire rst_n;
    por_reset #(.POR_BITS(22)) u_por (
        .clk(sys_clk),
        .rst_n(rst_n)
    );

    // Keep every unused subsystem inactive during the SD-only diagnostic.
    assign UART_TXD      = 1'b1;
    assign AUDIO_MCLK    = 1'b0;
    assign AUDIO_BCLK    = 1'b0;
    assign AUDIO_LRCK    = 1'b0;
    assign AUDIO_DAC_DIN = 1'b0;
    assign AUDIO_CCLK    = 1'b1;
    assign AUDIO_CDATA   = 1'bz;
    assign FLASH_CS_N    = 1'b1;
    assign FLASH_SCLK    = 1'b0;
    assign FLASH_MOSI    = 1'b1;
    assign FLASH_HOLD_N  = 1'b1;

    wire       card_present;
    wire       init_done;
    wire       init_ok;
    wire       read_done;
    wire       read_ok;
    wire       card_sdhc;
    wire [7:0] error_code;

    sd_spi_sector0_test #(
        .CLK_HZ(100_000_000),
        .SPI_HZ(400_000)
    ) u_sd_test (
        .clk(sys_clk),
        .rst_n(rst_n),
        // The GX-BIDT SD_CD_N signal stays high on some board revisions even
        // with a card inserted.  Force "present" and let CMD0/CMD8 verify the
        // card electrically instead of blocking on the mechanical detect pin.
        .card_detect_n(1'b0),
        .sd_cs_n(SD_CS_N),
        .sd_sclk(SD_SCLK),
        .sd_mosi(SD_MOSI),
        .sd_miso(SD_MISO),
        .card_present(card_present),
        .init_done(init_done),
        .init_ok(init_ok),
        .read_done(read_done),
        .read_ok(read_ok),
        .card_sdhc(card_sdhc),
        .error_code(error_code)
    );

    reg [127:0] lcd_line1;
    reg [127:0] lcd_line2;

    always @* begin
        lcd_line1 = "SD CARD TEST    ";
        lcd_line2 = "INITIALIZING... ";

        if (!card_present) begin
            lcd_line2 = "INSERT SD CARD  ";
        end else if (error_code != 8'h00) begin
            lcd_line1 = "SD TEST ERROR   ";
            case (error_code)
                8'h01: lcd_line2 = "CMD0 FAILED     ";
                8'h02: lcd_line2 = "CMD8 FAILED     ";
                8'h03: lcd_line2 = "ACMD41 TIMEOUT  ";
                8'h04: lcd_line2 = "CMD58 FAILED    ";
                8'h05: lcd_line2 = "CMD16 FAILED    ";
                8'h06: lcd_line2 = "CMD17 FAILED    ";
                8'h07: lcd_line2 = "DATA TIMEOUT    ";
                default: lcd_line2 = "BAD BOOT SIGN   ";
            endcase
        end else if (read_ok) begin
            lcd_line1 = "SD CARD READY   ";
            lcd_line2 = card_sdhc ? "SDHC SECTOR0 OK " :
                                   "SDSC SECTOR0 OK ";
        end else if (init_ok && !read_done) begin
            lcd_line2 = "READING SECTOR0 ";
        end else if (init_done && !init_ok) begin
            lcd_line2 = "SD INIT FAILED  ";
        end
    end

    lcd1602_driver #(.CLK_HZ(100_000_000)) u_lcd (
        .clk(sys_clk),
        .rst_n(rst_n),
        .line1(lcd_line1),
        .line2(lcd_line2),
        .lcd_d(LCD_D),
        .lcd_rs(LCD_RS),
        .lcd_rw(LCD_RW),
        .lcd_e(LCD_E)
    );

    // LED0: card initialized. LED1: sector 0 read and signature accepted.
    assign LED0 = init_ok;
    assign LED1 = read_ok;

    // Inputs retained for compatibility with the existing project/XDC.
    wire unused_inputs = UART_RXD ^ AUDIO_ADC_DOUT ^ FLASH_MISO;
endmodule

`default_nettype wire
