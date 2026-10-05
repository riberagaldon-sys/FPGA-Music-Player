`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// LCD1602 complete 4-bit lyric preview for GX-BIDT / XC7A200T
//
// Top module: top_lcd_full_lyrics_4bit_preview
//
// This source previews the complete supplied LRC without SD-card or audio playback.
// It restores the previously verified LCD1602 V2 method:
//   * LCD_D[7:4] carry D7..D4 nibbles
//   * LCD_D[3:0] remain 0
//   * startup nibbles are 3, 3, 3, 2
//   * every nibble is stable before LCD_E rises
//
// The 66 lyric entries become 176 word-aligned rows and 88 two-line pages.
// Every page remains visible for 10 seconds.  The display is written only once
// per page; there is no continuous LCD refresh and no external memory file.
// ============================================================================
module top_lcd_full_lyrics_4bit_preview (
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

    // 10 seconds at 100 MHz.  All 88 pages repeat after 14 min 40 s.
    localparam [29:0] PAGE_LAST = 30'd999999999;
    localparam [6:0]  LAST_PAGE = 7'd87;
    reg [29:0] page_timer;
    reg [6:0]  page_index;

    // Reset only the LCD writer when the page changes.  The verified V2 writer
    // then initializes the controller and writes the new two-line page once.
    reg [20:0] lcd_restart_count;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            page_timer        <= 30'd0;
            page_index        <= 7'd0;
            lcd_restart_count <= 21'd0;
        end else begin
            if (lcd_restart_count != 21'd0)
                lcd_restart_count <= lcd_restart_count - 21'd1;

            if (page_timer == PAGE_LAST) begin
                page_timer <= 30'd0;
                if (page_index == LAST_PAGE)
                    page_index <= 7'd0;
                else
                    page_index <= page_index + 7'd1;
                lcd_restart_count <= 21'd1999999;
            end else begin
                page_timer <= page_timer + 30'd1;
            end
        end
    end

    reg [127:0] lyric_line1;
    reg [127:0] lyric_line2;

    always @* begin
        case (page_index)
            7'd0: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore, we     ";
            end
            7'd1: begin
                lyric_line1 = "don't talk      ";
                lyric_line2 = "anymore         ";
            end
            7'd2: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore, like we";
            end
            7'd3: begin
                lyric_line1 = "used to do      ";
                lyric_line2 = "We don't love   ";
            end
            7'd4: begin
                lyric_line1 = "anymore         ";
                lyric_line2 = "What was all of ";
            end
            7'd5: begin
                lyric_line1 = "it for?         ";
                lyric_line2 = "Oh, we don't    ";
            end
            7'd6: begin
                lyric_line1 = "talk anymore,   ";
                lyric_line2 = "like we used to ";
            end
            7'd7: begin
                lyric_line1 = "do              ";
                lyric_line2 = "I just heard you";
            end
            7'd8: begin
                lyric_line1 = "found the one   ";
                lyric_line2 = "you've been     ";
            end
            7'd9: begin
                lyric_line1 = "looking         ";
                lyric_line2 = "You've been     ";
            end
            7'd10: begin
                lyric_line1 = "looking for     ";
                lyric_line2 = "I wish I would  ";
            end
            7'd11: begin
                lyric_line1 = "have known that ";
                lyric_line2 = "wasn't me       ";
            end
            7'd12: begin
                lyric_line1 = "Cause even after";
                lyric_line2 = "all this time I ";
            end
            7'd13: begin
                lyric_line1 = "still wonder    ";
                lyric_line2 = "Why I can't move";
            end
            7'd14: begin
                lyric_line1 = "on              ";
                lyric_line2 = "Just the way you";
            end
            7'd15: begin
                lyric_line1 = "did so easily   ";
                lyric_line2 = "Don't wanna know";
            end
            7'd16: begin
                lyric_line1 = "what kind of    ";
                lyric_line2 = "dress you're    ";
            end
            7'd17: begin
                lyric_line1 = "wearing tonight ";
                lyric_line2 = "If he's holding ";
            end
            7'd18: begin
                lyric_line1 = "onto you so     ";
                lyric_line2 = "tight           ";
            end
            7'd19: begin
                lyric_line1 = "The way I did   ";
                lyric_line2 = "before          ";
            end
            7'd20: begin
                lyric_line1 = "I overdosed     ";
                lyric_line2 = "Should've known ";
            end
            7'd21: begin
                lyric_line1 = "your love was a ";
                lyric_line2 = "game            ";
            end
            7'd22: begin
                lyric_line1 = "Now I can't get ";
                lyric_line2 = "you out of my   ";
            end
            7'd23: begin
                lyric_line1 = "brain           ";
                lyric_line2 = "Oh, it's such a ";
            end
            7'd24: begin
                lyric_line1 = "shame           ";
                lyric_line2 = "We don't talk   ";
            end
            7'd25: begin
                lyric_line1 = "anymore, we     ";
                lyric_line2 = "don't talk      ";
            end
            7'd26: begin
                lyric_line1 = "anymore         ";
                lyric_line2 = "We don't talk   ";
            end
            7'd27: begin
                lyric_line1 = "anymore, like we";
                lyric_line2 = "used to do      ";
            end
            7'd28: begin
                lyric_line1 = "We don't love   ";
                lyric_line2 = "anymore         ";
            end
            7'd29: begin
                lyric_line1 = "What was all of ";
                lyric_line2 = "it for?         ";
            end
            7'd30: begin
                lyric_line1 = "Oh, we don't    ";
                lyric_line2 = "talk anymore,   ";
            end
            7'd31: begin
                lyric_line1 = "like we used to ";
                lyric_line2 = "do              ";
            end
            7'd32: begin
                lyric_line1 = "Who knows how to";
                lyric_line2 = "love you like me";
            end
            7'd33: begin
                lyric_line1 = "There must be a ";
                lyric_line2 = "good reason that";
            end
            7'd34: begin
                lyric_line1 = "you're gone     ";
                lyric_line2 = "Every now and   ";
            end
            7'd35: begin
                lyric_line1 = "then I think you";
                lyric_line2 = "Might want me to";
            end
            7'd36: begin
                lyric_line1 = "come show up at ";
                lyric_line2 = "your door       ";
            end
            7'd37: begin
                lyric_line1 = "But I'm just too";
                lyric_line2 = "afraid that I'll";
            end
            7'd38: begin
                lyric_line1 = "be wrong        ";
                lyric_line2 = "Don't wanna know";
            end
            7'd39: begin
                lyric_line1 = "If you're       ";
                lyric_line2 = "looking into her";
            end
            7'd40: begin
                lyric_line1 = "eyes            ";
                lyric_line2 = "If she's holding";
            end
            7'd41: begin
                lyric_line1 = "onto you so     ";
                lyric_line2 = "tight the way I ";
            end
            7'd42: begin
                lyric_line1 = "did before      ";
                lyric_line2 = "I overdosed     ";
            end
            7'd43: begin
                lyric_line1 = "Should've known ";
                lyric_line2 = "your love was a ";
            end
            7'd44: begin
                lyric_line1 = "game            ";
                lyric_line2 = "Now I can't get ";
            end
            7'd45: begin
                lyric_line1 = "you out of my   ";
                lyric_line2 = "brain           ";
            end
            7'd46: begin
                lyric_line1 = "Oh, it's such a ";
                lyric_line2 = "shame           ";
            end
            7'd47: begin
                lyric_line1 = "That we don't   ";
                lyric_line2 = "talk anymore (We";
            end
            7'd48: begin
                lyric_line1 = "don't, we don't)";
                lyric_line2 = "We don't talk   ";
            end
            7'd49: begin
                lyric_line1 = "anymore (We     ";
                lyric_line2 = "don't, we don't)";
            end
            7'd50: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore, like we";
            end
            7'd51: begin
                lyric_line1 = "used to do      ";
                lyric_line2 = "We don't love   ";
            end
            7'd52: begin
                lyric_line1 = "anymore (We     ";
                lyric_line2 = "don't, we don't)";
            end
            7'd53: begin
                lyric_line1 = "What was all of ";
                lyric_line2 = "it for? (We     ";
            end
            7'd54: begin
                lyric_line1 = "don't, we don't)";
                lyric_line2 = "Oh, we don't    ";
            end
            7'd55: begin
                lyric_line1 = "talk anymore,   ";
                lyric_line2 = "like we used to ";
            end
            7'd56: begin
                lyric_line1 = "do              ";
                lyric_line2 = "Like we used to ";
            end
            7'd57: begin
                lyric_line1 = "do              ";
                lyric_line2 = "Don't wanna know";
            end
            7'd58: begin
                lyric_line1 = "kind of dress   ";
                lyric_line2 = "you're wearing  ";
            end
            7'd59: begin
                lyric_line1 = "tonight         ";
                lyric_line2 = "If he's giving  ";
            end
            7'd60: begin
                lyric_line1 = "it to you just  ";
                lyric_line2 = "right           ";
            end
            7'd61: begin
                lyric_line1 = "The way I did   ";
                lyric_line2 = "before          ";
            end
            7'd62: begin
                lyric_line1 = "I overdosed     ";
                lyric_line2 = "Should've known ";
            end
            7'd63: begin
                lyric_line1 = "your love was a ";
                lyric_line2 = "game            ";
            end
            7'd64: begin
                lyric_line1 = "Now I can't get ";
                lyric_line2 = "you out of my   ";
            end
            7'd65: begin
                lyric_line1 = "brain           ";
                lyric_line2 = "Oh, it's such a ";
            end
            7'd66: begin
                lyric_line1 = "shame           ";
                lyric_line2 = "That we don't   ";
            end
            7'd67: begin
                lyric_line1 = "talk anymore (We";
                lyric_line2 = "don't, we don't)";
            end
            7'd68: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore (We     ";
            end
            7'd69: begin
                lyric_line1 = "don't, we don't)";
                lyric_line2 = "We don't talk   ";
            end
            7'd70: begin
                lyric_line1 = "anymore, like we";
                lyric_line2 = "used to do      ";
            end
            7'd71: begin
                lyric_line1 = "We don't love   ";
                lyric_line2 = "anymore (We     ";
            end
            7'd72: begin
                lyric_line1 = "don't, we don't)";
                lyric_line2 = "What was all of ";
            end
            7'd73: begin
                lyric_line1 = "it for? (We     ";
                lyric_line2 = "don't, we don't)";
            end
            7'd74: begin
                lyric_line1 = "Oh, we don't    ";
                lyric_line2 = "talk anymore,   ";
            end
            7'd75: begin
                lyric_line1 = "like we used to ";
                lyric_line2 = "do              ";
            end
            7'd76: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore         ";
            end
            7'd77: begin
                lyric_line1 = "What kind of    ";
                lyric_line2 = "dress you're    ";
            end
            7'd78: begin
                lyric_line1 = "wearing tonight ";
                lyric_line2 = "(Oh)            ";
            end
            7'd79: begin
                lyric_line1 = "If he's holding ";
                lyric_line2 = "onto you so     ";
            end
            7'd80: begin
                lyric_line1 = "tight (Oh)      ";
                lyric_line2 = "The way I did   ";
            end
            7'd81: begin
                lyric_line1 = "before          ";
                lyric_line2 = "We don't talk   ";
            end
            7'd82: begin
                lyric_line1 = "anymore (I      ";
                lyric_line2 = "overdosed)      ";
            end
            7'd83: begin
                lyric_line1 = "Should've known ";
                lyric_line2 = "your love was a ";
            end
            7'd84: begin
                lyric_line1 = "game (Oh)       ";
                lyric_line2 = "Now I can't get ";
            end
            7'd85: begin
                lyric_line1 = "you out of my   ";
                lyric_line2 = "brain (Woah)    ";
            end
            7'd86: begin
                lyric_line1 = "Oh, it's such a ";
                lyric_line2 = "shame           ";
            end
            7'd87: begin
                lyric_line1 = "We don't talk   ";
                lyric_line2 = "anymore         ";
            end
            default: begin
                lyric_line1 = "LYRIC PAGE ERROR";
                lyric_line2 = "RESET FPGA      ";
            end
        endcase
    end

    wire lcd_rst_n = rst_n && (lcd_restart_count == 21'd0);
    wire lcd_done;

    fulllyric4_lcd1602_once u_lcd (
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
    // LED1 identifies alternating 10-second pages.
    assign LED0 = lcd_done;
    assign LED1 = page_index[0];

    wire unused_inputs;
    assign unused_inputs = UART_RXD ^ AUDIO_ADC_DOUT ^ FLASH_MISO ^
                           SD_MISO ^ SD_CD_N;

endmodule


// ============================================================================
// Previously verified LCD1602 4-bit V2 one-shot writer.
// ============================================================================
module fulllyric4_lcd1602_once (
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

