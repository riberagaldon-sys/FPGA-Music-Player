`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// LCD1602-only slow lyric test for the GX-BIDT board.
//
// Top module: top_lcd_lyrics_slow_test
//
// This diagnostic deliberately does NOT use the SD card, SONG.RAW, the audio
// codec, a lyric ROM, or any external memory file.  It shows eight fixed ASCII
// lyric pages, one page every 10 seconds.  The first line never changes.
//
// Expected display:
//   line 1: LYRIC TEST 10SEC
//   line 2: one fixed lyric page, changing every 10 seconds
// -----------------------------------------------------------------------------
module top_lcd_lyrics_slow_test (
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
    localparam [29:0] PAGE_LAST = 30'd999_999_999; // 10 s at 100 MHz

    wire por_n;
    slowtest_por_reset u_por (
        .clk   (sys_clk),
        .rst_n (por_n)
    );

    // One static page for 10 seconds.  No character-by-character scrolling.
    reg [29:0] page_timer;
    reg [2:0]  page_index;

    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
            page_timer <= 30'd0;
            page_index <= 3'd0;
        end else if (page_timer == PAGE_LAST) begin
            page_timer <= 30'd0;
            page_index <= page_index + 3'd1;
        end else begin
            page_timer <= page_timer + 30'd1;
        end
    end

    wire [127:0] lcd_line1 = "LYRIC TEST 10SEC";
    reg  [127:0] lcd_line2;

    always @* begin
        case (page_index)
            3'd0: lcd_line2 = "We don't talk   ";
            3'd1: lcd_line2 = "anymore, we     ";
            3'd2: lcd_line2 = "don't talk      ";
            3'd3: lcd_line2 = "anymore, like   ";
            3'd4: lcd_line2 = "we used to do   ";
            3'd5: lcd_line2 = "We don't love   ";
            3'd6: lcd_line2 = "anymore         ";
            default: lcd_line2 = "What was all of ";
        endcase
    end

    slowtest_lcd1602_driver #(
        .CLK_HZ (100_000_000)
    ) u_lcd (
        .clk    (sys_clk),
        .rst_n  (por_n),
        .line1  (lcd_line1),
        .line2  (lcd_line2),
        .lcd_d  (LCD_D),
        .lcd_rs (LCD_RS),
        .lcd_rw (LCD_RW),
        .lcd_e  (LCD_E)
    );

    // All unrelated interfaces are held in safe inactive states.
    assign UART_TXD     = 1'b1;

    assign AUDIO_MCLK   = 1'b0;
    assign AUDIO_BCLK   = 1'b0;
    assign AUDIO_LRCK   = 1'b0;
    assign AUDIO_DAC_DIN= 1'b0;
    assign AUDIO_CCLK   = 1'b1;
    assign AUDIO_CDATA  = 1'bz;

    assign FLASH_CS_N   = 1'b1;
    assign FLASH_SCLK   = 1'b0;
    assign FLASH_MOSI   = 1'b1;
    assign FLASH_HOLD_N = 1'b1;

    assign SD_CS_N      = 1'b1;
    assign SD_SCLK      = 1'b0;
    assign SD_MOSI      = 1'b1;

    // LED0 stays on as a test marker. LED1 changes state every page.
    assign LED0 = 1'b1;
    assign LED1 = page_index[0];

    // Keep the complete original top-level pin list, so the existing XDC can
    // be reused without missing-port errors.
    wire unused_inputs;
    assign unused_inputs = UART_RXD ^ AUDIO_ADC_DOUT ^ FLASH_MISO ^
                           SD_MISO ^ SD_CD_N;

endmodule


// About 10.5 ms of power-on reset at 100 MHz.
module slowtest_por_reset (
    input  wire clk,
    output wire rst_n
);
    reg [19:0] reset_counter = 20'd0;

    always @(posedge clk) begin
        if (reset_counter != 20'hFFFFF)
            reset_counter <= reset_counter + 20'd1;
    end

    assign rst_n = (reset_counter == 20'hFFFFF);
endmodule


// -----------------------------------------------------------------------------
// Robust HD44780-compatible LCD1602 driver, 8-bit bus.
//
// Improvements used for this diagnostic:
//   * waits 40 ms after reset;
//   * sends function-set (0x38) three times with datasheet-safe delays;
//   * keeps E high/low for 10 us per phase;
//   * refreshes complete, static 16-character lines only.
//
// RW remains low, so no busy-flag read is required.
// -----------------------------------------------------------------------------
module slowtest_lcd1602_driver #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output reg  [7:0]   lcd_d,
    output reg          lcd_rs,
    output wire         lcd_rw,
    output reg          lcd_e
);
    assign lcd_rw = 1'b0;

    // One controller step every 10 us at the default 100-MHz clock.
    localparam integer TICK_DIV = CLK_HZ / 100_000;

    reg [31:0] div_count;
    wire tick = (div_count == TICK_DIV-1);

    reg [15:0] wait_ticks;
    reg [2:0]  init_index;
    reg [5:0]  operation_index;
    reg [1:0]  pulse_phase;
    reg        initialized;

    function [7:0] get_character;
        input [127:0] line;
        input [4:0] index;
        begin
            case (index)
                5'd0:  get_character = line[127:120];
                5'd1:  get_character = line[119:112];
                5'd2:  get_character = line[111:104];
                5'd3:  get_character = line[103:96];
                5'd4:  get_character = line[95:88];
                5'd5:  get_character = line[87:80];
                5'd6:  get_character = line[79:72];
                5'd7:  get_character = line[71:64];
                5'd8:  get_character = line[63:56];
                5'd9:  get_character = line[55:48];
                5'd10: get_character = line[47:40];
                5'd11: get_character = line[39:32];
                5'd12: get_character = line[31:24];
                5'd13: get_character = line[23:16];
                5'd14: get_character = line[15:8];
                default: get_character = line[7:0];
            endcase
        end
    endfunction

    function [7:0] initialization_command;
        input [2:0] index;
        begin
            case (index)
                3'd0: initialization_command = 8'h38;
                3'd1: initialization_command = 8'h38;
                3'd2: initialization_command = 8'h38;
                3'd3: initialization_command = 8'h08; // display off
                3'd4: initialization_command = 8'h01; // clear display
                3'd5: initialization_command = 8'h06; // entry increment
                default: initialization_command = 8'h0C; // display on
            endcase
        end
    endfunction

    function [15:0] initialization_wait;
        input [2:0] index;
        begin
            case (index)
                3'd0: initialization_wait = 16'd500; // 5 ms
                3'd1: initialization_wait = 16'd20;  // 200 us
                3'd4: initialization_wait = 16'd200; // clear: 2 ms
                default: initialization_wait = 16'd5; // 50 us
            endcase
        end
    endfunction

    task load_display_operation;
        input [5:0] operation;
        begin
            if (operation == 6'd0) begin
                lcd_rs <= 1'b0;
                lcd_d  <= 8'h80;
            end else if (operation <= 6'd16) begin
                lcd_rs <= 1'b1;
                lcd_d  <= get_character(line1, operation - 6'd1);
            end else if (operation == 6'd17) begin
                lcd_rs <= 1'b0;
                lcd_d  <= 8'hC0;
            end else begin
                lcd_rs <= 1'b1;
                lcd_d  <= get_character(line2, operation - 6'd18);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_count       <= 32'd0;
            wait_ticks      <= 16'd4000; // 40-ms LCD power-up delay
            init_index      <= 3'd0;
            operation_index <= 6'd0;
            pulse_phase     <= 2'd0;
            initialized     <= 1'b0;
            lcd_d           <= 8'h00;
            lcd_rs          <= 1'b0;
            lcd_e           <= 1'b0;
        end else begin
            if (tick)
                div_count <= 32'd0;
            else
                div_count <= div_count + 32'd1;

            if (tick) begin
                if (wait_ticks != 16'd0) begin
                    wait_ticks <= wait_ticks - 16'd1;
                    lcd_e <= 1'b0;
                end else if (!initialized) begin
                    case (pulse_phase)
                        2'd0: begin
                            lcd_rs      <= 1'b0;
                            lcd_d       <= initialization_command(init_index);
                            lcd_e       <= 1'b0;
                            pulse_phase <= 2'd1;
                        end
                        2'd1: begin
                            lcd_e       <= 1'b1;
                            pulse_phase <= 2'd2;
                        end
                        default: begin
                            lcd_e       <= 1'b0;
                            pulse_phase <= 2'd0;
                            if (init_index == 3'd6) begin
                                initialized     <= 1'b1;
                                operation_index <= 6'd0;
                                wait_ticks      <= 16'd200;
                            end else begin
                                wait_ticks <= initialization_wait(init_index);
                                init_index <= init_index + 3'd1;
                            end
                        end
                    endcase
                end else begin
                    case (pulse_phase)
                        2'd0: begin
                            load_display_operation(operation_index);
                            lcd_e       <= 1'b0;
                            pulse_phase <= 2'd1;
                        end
                        2'd1: begin
                            lcd_e       <= 1'b1;
                            pulse_phase <= 2'd2;
                        end
                        default: begin
                            lcd_e       <= 1'b0;
                            pulse_phase <= 2'd0;
                            if (operation_index == 6'd33) begin
                                operation_index <= 6'd0;
                                wait_ticks      <= 16'd2000; // 20 ms
                            end else begin
                                operation_index <= operation_index + 6'd1;
                                wait_ticks      <= 16'd5;
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
