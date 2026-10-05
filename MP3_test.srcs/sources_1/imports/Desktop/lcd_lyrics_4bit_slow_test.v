`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// LCD1602 4-bit slow lyric test for GX-BIDT / XC7A200T
//
// Top module: top_lcd_lyrics_4bit_slow_test
//
// This source deliberately does not read the SD card and does not play audio.
// It restores the previously verified LCD1602 V2 method:
//   * LCD_D[7:4] carry D7..D4 nibbles
//   * LCD_D[3:0] remain 0
//   * startup nibbles are 3, 3, 3, 2
//   * every nibble is stable before LCD_E rises
//
// Two lyric lines remain visible for 20 seconds.  On each page the complete
// display is written exactly once; there is no continuous LCD refresh.
// ============================================================================
module top_lcd_lyrics_4bit_slow_test (
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

    // Preserve the power-on reset used by the verified 4-bit V2 test.
    reg [21:0] por_cnt = 22'd0;
    reg        rst_n   = 1'b0;

    always @(posedge sys_clk) begin
        if (!por_cnt[21]) begin
            por_cnt <= por_cnt + 22'd1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // 20 seconds at 100 MHz.  Four pages repeat after 80 seconds.
    localparam [30:0] PAGE_LAST = 31'd1999999999;
    reg [30:0] page_timer;
    reg [1:0]  page_index;

    // When a page changes, reset only the LCD writer for 20 ms.  It then uses
    // the same full V2 initialization and writes the new page exactly once.
    reg [20:0] lcd_restart_count;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            page_timer        <= 31'd0;
            page_index        <= 2'd0;
            lcd_restart_count <= 21'd0;
        end else begin
            if (lcd_restart_count != 21'd0)
                lcd_restart_count <= lcd_restart_count - 21'd1;

            if (page_timer == PAGE_LAST) begin
                page_timer        <= 31'd0;
                page_index        <= page_index + 2'd1;
                lcd_restart_count <= 21'd1999999;
            end else begin
                page_timer <= page_timer + 31'd1;
            end
        end
    end

    reg [127:0] lyric_line1;
    reg [127:0] lyric_line2;

    always @* begin
        case (page_index)
            2'd0: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore, we     ";
            end
            2'd1: begin
                lyric_line1 = "don't talk      ";
                lyric_line2 = "anymore, like   ";
            end
            2'd2: begin
                lyric_line1 = "we used to do   ";
                lyric_line2 = "We don't love   ";
            end
            default: begin
                lyric_line1 = "anymore         ";
                lyric_line2 = "What was all of ";
            end
        endcase
    end

    wire lcd_rst_n = rst_n && (lcd_restart_count == 21'd0);
    wire lcd_done;

    lyric4_lcd1602_once u_lcd (
        .clk    (sys_clk),
        .rst_n  (lcd_rst_n),
        .line1  (lyric_line1),
        .line2  (lyric_line2),
        .lcd_d  (LCD_D),
        .lcd_rs (LCD_RS),
        .lcd_rw (LCD_RW),
        .lcd_e  (LCD_E),
        .done   (lcd_done)
    );

    // Hold every unrelated interface inactive.
    assign UART_TXD      = 1'b1;

    assign AUDIO_MCLK    = 1'b0;
    assign AUDIO_BCLK    = 1'b0;
    assign AUDIO_LRCK    = 1'b0;
    assign AUDIO_DAC_DIN = 1'b0;
    assign AUDIO_CCLK    = 1'b1;
    assign AUDIO_CDATA   = 1'bz;

    assign FLASH_CS_N    = 1'b1;
    assign FLASH_SCLK    = 1'b0;
    assign FLASH_MOSI    = 1'b0;
    assign FLASH_HOLD_N  = 1'b1;

    assign SD_CS_N       = 1'b1;
    assign SD_SCLK       = 1'b0;
    assign SD_MOSI       = 1'b0;

    // LED0 lights after the current page has been written.
    // LED1 identifies alternating 20-second pages.
    assign LED0 = lcd_done;
    assign LED1 = page_index[0];

    wire unused_inputs;
    assign unused_inputs = UART_RXD ^ AUDIO_ADC_DOUT ^ FLASH_MISO ^
                           SD_MISO ^ SD_CD_N;

endmodule


// ============================================================================
// Previously verified LCD1602 4-bit V2 one-shot writer.
// ============================================================================
module lyric4_lcd1602_once (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output wire [7:0]   lcd_d,
    output reg          lcd_rs,
    output wire         lcd_rw,
    output reg          lcd_e,
    output reg          done
);

    reg [3:0] lcd_nibble;
    assign lcd_d[7:4] = lcd_nibble;
    assign lcd_d[3:0] = 4'b0000;
    assign lcd_rw      = 1'b0;

    // 10-us state-machine tick at 100 MHz.
    localparam integer TICK_DIV = 1000;
    reg [9:0] tick_cnt;
    wire tick = (tick_cnt == TICK_DIV-1);

    reg [15:0] wait_ticks;

    localparam ST_RAW_SETUP = 4'd0;
    localparam ST_RAW_E_HI  = 4'd1;
    localparam ST_RAW_E_LO  = 4'd2;
    localparam ST_BYTE_LOAD = 4'd3;
    localparam ST_HI_SETUP  = 4'd4;
    localparam ST_HI_E_HI   = 4'd5;
    localparam ST_HI_E_LO   = 4'd6;
    localparam ST_LO_SETUP  = 4'd7;
    localparam ST_LO_E_HI   = 4'd8;
    localparam ST_LO_E_LO   = 4'd9;
    localparam ST_DONE      = 4'd10;

    reg [3:0] state;
    reg [2:0] raw_idx;
    reg [5:0] seq_idx;
    reg [7:0] cur_byte;
    reg       cur_rs;

    function [3:0] raw_init_nibble;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: raw_init_nibble = 4'h3;
                3'd1: raw_init_nibble = 4'h3;
                3'd2: raw_init_nibble = 4'h3;
                default: raw_init_nibble = 4'h2;
            endcase
        end
    endfunction

    function [15:0] raw_delay;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: raw_delay = 16'd500; // 5 ms
                3'd1: raw_delay = 16'd20;  // 200 us
                3'd2: raw_delay = 16'd20;  // 200 us
                default: raw_delay = 16'd20;
            endcase
        end
    endfunction

    function [7:0] get_char;
        input [127:0] text;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  get_char = text[127:120];
                5'd1:  get_char = text[119:112];
                5'd2:  get_char = text[111:104];
                5'd3:  get_char = text[103:96];
                5'd4:  get_char = text[95:88];
                5'd5:  get_char = text[87:80];
                5'd6:  get_char = text[79:72];
                5'd7:  get_char = text[71:64];
                5'd8:  get_char = text[63:56];
                5'd9:  get_char = text[55:48];
                5'd10: get_char = text[47:40];
                5'd11: get_char = text[39:32];
                5'd12: get_char = text[31:24];
                5'd13: get_char = text[23:16];
                5'd14: get_char = text[15:8];
                default: get_char = text[7:0];
            endcase
        end
    endfunction

    task load_sequence_byte;
        input [5:0] idx;
        begin
            case (idx)
                6'd0: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'h28;
                end
                6'd1: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'h08;
                end
                6'd2: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'h01;
                end
                6'd3: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'h06;
                end
                6'd4: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'h0C;
                end
                6'd5: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'h80;
                end
                6'd22: begin
                    cur_rs   <= 1'b0;
                    cur_byte <= 8'hC0;
                end
                default: begin
                    cur_rs <= 1'b1;
                    if ((idx >= 6'd6) && (idx <= 6'd21))
                        cur_byte <= get_char(line1, idx - 6'd6);
                    else
                        cur_byte <= get_char(line2, idx - 6'd23);
                end
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt   <= 10'd0;
            wait_ticks <= 16'd10000; // 100-ms LCD power-up wait
            state      <= ST_RAW_SETUP;
            raw_idx    <= 3'd0;
            seq_idx    <= 6'd0;
            cur_byte   <= 8'h00;
            cur_rs     <= 1'b0;
            lcd_nibble <= 4'h0;
            lcd_rs     <= 1'b0;
            lcd_e      <= 1'b0;
            done       <= 1'b0;
        end else begin
            if (tick)
                tick_cnt <= 10'd0;
            else
                tick_cnt <= tick_cnt + 10'd1;

            if (tick) begin
                if (wait_ticks != 16'd0) begin
                    wait_ticks <= wait_ticks - 16'd1;
                    lcd_e      <= 1'b0;
                end else begin
                    case (state)
                        ST_RAW_SETUP: begin
                            lcd_rs     <= 1'b0;
                            lcd_nibble <= raw_init_nibble(raw_idx);
                            lcd_e      <= 1'b0;
                            state      <= ST_RAW_E_HI;
                        end

                        ST_RAW_E_HI: begin
                            lcd_e <= 1'b1;
                            state <= ST_RAW_E_LO;
                        end

                        ST_RAW_E_LO: begin
                            lcd_e <= 1'b0;
                            if (raw_idx == 3'd3) begin
                                seq_idx    <= 6'd0;
                                wait_ticks <= 16'd20;
                                state      <= ST_BYTE_LOAD;
                            end else begin
                                wait_ticks <= raw_delay(raw_idx);
                                raw_idx    <= raw_idx + 3'd1;
                                state      <= ST_RAW_SETUP;
                            end
                        end

                        ST_BYTE_LOAD: begin
                            load_sequence_byte(seq_idx);
                            state <= ST_HI_SETUP;
                        end

                        ST_HI_SETUP: begin
                            lcd_rs     <= cur_rs;
                            lcd_nibble <= cur_byte[7:4];
                            lcd_e      <= 1'b0;
                            state      <= ST_HI_E_HI;
                        end

                        ST_HI_E_HI: begin
                            lcd_e <= 1'b1;
                            state <= ST_HI_E_LO;
                        end

                        ST_HI_E_LO: begin
                            lcd_e <= 1'b0;
                            state <= ST_LO_SETUP;
                        end

                        ST_LO_SETUP: begin
                            lcd_rs     <= cur_rs;
                            lcd_nibble <= cur_byte[3:0];
                            lcd_e      <= 1'b0;
                            state      <= ST_LO_E_HI;
                        end

                        ST_LO_E_HI: begin
                            lcd_e <= 1'b1;
                            state <= ST_LO_E_LO;
                        end

                        ST_LO_E_LO: begin
                            lcd_e <= 1'b0;
                            if (seq_idx == 6'd38) begin
                                done  <= 1'b1;
                                state <= ST_DONE;
                            end else begin
                                if (seq_idx == 6'd2)
                                    wait_ticks <= 16'd250;
                                else
                                    wait_ticks <= 16'd5;

                                seq_idx <= seq_idx + 6'd1;
                                state   <= ST_BYTE_LOAD;
                            end
                        end

                        default: begin
                            lcd_e <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_DONE;
                        end
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
