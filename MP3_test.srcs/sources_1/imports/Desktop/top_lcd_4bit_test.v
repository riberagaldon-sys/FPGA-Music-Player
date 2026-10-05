`timescale 1ns / 1ps

// ============================================================================
// LCD1602 4-bit mode isolation test
// Purpose: bypass LCD D0~D3 completely and use only D4~D7.
// Expected:
//   LCD 4BIT OK
//   1234567890ABCDEF
//
// Existing XDC can stay unchanged.
// ============================================================================
module top_lcd_4bit_test (
    input  wire sys_clk,

    output wire AUDIO_MCLK,
    output wire AUDIO_BCLK,
    output wire AUDIO_LRCK,
    output wire AUDIO_DAC_DIN,
    input  wire AUDIO_ADC_DOUT,
    output wire AUDIO_CCLK,
    inout  wire AUDIO_CDATA,

    output wire FLASH_CS_N,
    output wire FLASH_SCLK,
    output wire FLASH_MOSI,
    input  wire FLASH_MISO,
    output wire FLASH_HOLD_N,

    output wire SD_CS_N,
    output wire SD_SCLK,
    output wire SD_MOSI,
    input  wire SD_MISO,
    input  wire SD_CD_N,

    output wire [7:0] LCD_D,
    output wire       LCD_RS,
    output wire       LCD_RW,
    output wire       LCD_E,

    output wire LED0,
    output wire LED1
);

    // Keep everything except LCD idle.
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

    reg [21:0] por_cnt = 22'd0;
    reg rst_n = 1'b0;

    always @(posedge sys_clk) begin
        if (!por_cnt[21]) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    wire done;

    lcd1602_4bit_once u_lcd (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .line1  ("LCD 4BIT OK     "),
        .line2  ("1234567890ABCDEF"),
        .lcd_d  (LCD_D),
        .lcd_rs (LCD_RS),
        .lcd_rw (LCD_RW),
        .lcd_e  (LCD_E),
        .done   (done)
    );

    assign LED0 = done;
    assign LED1 = 1'b1;

endmodule


module lcd1602_4bit_once (
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

    // Only D4-D7 are used in 4-bit mode.
    reg [3:0] lcd_nibble;
    assign lcd_d[7:4] = lcd_nibble;
    assign lcd_d[3:0] = 4'b0000;
    assign lcd_rw = 1'b0;

    // 100 us tick @ 100 MHz.
    localparam integer TICK_DIV = 10000;
    reg [13:0] tick_cnt;
    wire tick = (tick_cnt == TICK_DIV-1);

    reg [15:0] wait_ticks;
    reg [5:0] op_idx;
    reg [3:0] state;
    reg [7:0] cur_byte;
    reg       cur_rs;

    localparam S_PWR_WAIT   = 4'd0;
    localparam S_INIT3_1    = 4'd1;
    localparam S_INIT3_2    = 4'd2;
    localparam S_INIT3_3    = 4'd3;
    localparam S_INIT2      = 4'd4;
    localparam S_LOAD_CMD   = 4'd5;
    localparam S_SEND_HI    = 4'd6;
    localparam S_E_HI1      = 4'd7;
    localparam S_SEND_LO    = 4'd8;
    localparam S_E_HI2      = 4'd9;
    localparam S_AFTER_BYTE = 4'd10;
    localparam S_DONE       = 4'd11;

    reg [3:0] init_cmd_idx;

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
                default:get_char = text[7:0];
            endcase
        end
    endfunction

    function [7:0] setup_cmd;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: setup_cmd = 8'h28; // 4-bit, 2-line, 5x8
                4'd1: setup_cmd = 8'h08; // display off
                4'd2: setup_cmd = 8'h01; // clear
                4'd3: setup_cmd = 8'h06; // increment, no shift
                default: setup_cmd = 8'h0C; // display on
            endcase
        end
    endfunction

    task pulse_raw_nibble;
        input [3:0] nib;
        begin
            lcd_rs      <= 1'b0;
            lcd_nibble  <= nib;
            lcd_e       <= 1'b1;
        end
    endtask

    task load_display_byte;
        input [5:0] idx;
        begin
            if (idx == 6'd0) begin
                cur_rs   <= 1'b0;
                cur_byte <= 8'h80;
            end
            else if ((idx >= 6'd1) && (idx <= 6'd16)) begin
                cur_rs   <= 1'b1;
                cur_byte <= get_char(line1, idx-1);
            end
            else if (idx == 6'd17) begin
                cur_rs   <= 1'b0;
                cur_byte <= 8'hC0;
            end
            else begin
                cur_rs   <= 1'b1;
                cur_byte <= get_char(line2, idx-18);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt      <= 14'd0;
            wait_ticks    <= 16'd1000; // 100 ms
            op_idx        <= 6'd0;
            state         <= S_PWR_WAIT;
            cur_byte      <= 8'h00;
            cur_rs        <= 1'b0;
            init_cmd_idx  <= 4'd0;
            lcd_nibble    <= 4'h0;
            lcd_rs        <= 1'b0;
            lcd_e         <= 1'b0;
            done          <= 1'b0;
        end else begin
            if (tick)
                tick_cnt <= 14'd0;
            else
                tick_cnt <= tick_cnt + 1'b1;

            if (tick) begin
                if (wait_ticks != 0) begin
                    wait_ticks <= wait_ticks - 1'b1;
                    lcd_e <= 1'b0;
                end else begin
                    case (state)
                        S_PWR_WAIT: begin
                            // Standard 4-bit recovery sequence starts with 0x3.
                            lcd_rs <= 1'b0;
                            lcd_nibble <= 4'h3;
                            lcd_e <= 1'b1;
                            state <= S_INIT3_1;
                        end

                        S_INIT3_1: begin
                            lcd_e <= 1'b0;
                            wait_ticks <= 16'd50; // 5 ms
                            state <= S_INIT3_2;
                        end

                        S_INIT3_2: begin
                            lcd_rs <= 1'b0;
                            lcd_nibble <= 4'h3;
                            lcd_e <= 1'b1;
                            state <= S_INIT3_3;
                        end

                        S_INIT3_3: begin
                            lcd_e <= 1'b0;
                            wait_ticks <= 16'd2; // 200 us
                            state <= S_INIT2;
                        end

                        S_INIT2: begin
                            // Third 0x3 pulse.
                            lcd_rs <= 1'b0;
                            lcd_nibble <= 4'h3;
                            lcd_e <= 1'b1;
                            state <= S_LOAD_CMD;
                            wait_ticks <= 16'd2;
                        end

                        S_LOAD_CMD: begin
                            // Finish third pulse low first.
                            lcd_e <= 1'b0;

                            // Send 0x2 high nibble to enter 4-bit mode,
                            // then start normal full-byte commands.
                            if (init_cmd_idx == 4'd0) begin
                                lcd_rs <= 1'b0;
                                lcd_nibble <= 4'h2;
                                lcd_e <= 1'b1;
                                init_cmd_idx <= 4'd1;
                                wait_ticks <= 16'd2;
                            end else if (init_cmd_idx <= 4'd5) begin
                                cur_rs <= 1'b0;
                                cur_byte <= setup_cmd(init_cmd_idx-1);
                                state <= S_SEND_HI;
                                init_cmd_idx <= init_cmd_idx + 1'b1;
                            end else begin
                                op_idx <= 6'd0;
                                load_display_byte(6'd0);
                                state <= S_SEND_HI;
                            end
                        end

                        S_SEND_HI: begin
                            lcd_rs <= cur_rs;
                            lcd_nibble <= cur_byte[7:4];
                            lcd_e <= 1'b0;
                            state <= S_E_HI1;
                        end

                        S_E_HI1: begin
                            lcd_e <= 1'b1;
                            state <= S_SEND_LO;
                        end

                        S_SEND_LO: begin
                            lcd_e <= 1'b0;
                            lcd_nibble <= cur_byte[3:0];
                            state <= S_E_HI2;
                        end

                        S_E_HI2: begin
                            lcd_e <= 1'b1;
                            state <= S_AFTER_BYTE;
                        end

                        S_AFTER_BYTE: begin
                            lcd_e <= 1'b0;

                            if (init_cmd_idx <= 4'd6) begin
                                if (init_cmd_idx == 4'd6) begin
                                    // Finished 0x0C.
                                    init_cmd_idx <= 4'd7;
                                    wait_ticks <= 16'd30;
                                    state <= S_LOAD_CMD;
                                end else begin
                                    // Longer delay after clear.
                                    if (cur_byte == 8'h01)
                                        wait_ticks <= 16'd30;
                                    else
                                        wait_ticks <= 16'd2;
                                    state <= S_LOAD_CMD;
                                end
                            end else begin
                                if (op_idx == 6'd33) begin
                                    done <= 1'b1;
                                    state <= S_DONE;
                                end else begin
                                    op_idx <= op_idx + 1'b1;
                                    load_display_byte(op_idx + 1'b1);
                                    wait_ticks <= 16'd1;
                                    state <= S_SEND_HI;
                                end
                            end
                        end

                        default: begin
                            lcd_e <= 1'b0;
                            done <= 1'b1;
                            state <= S_DONE;
                        end
                    endcase
                end
            end
        end
    end

endmodule
