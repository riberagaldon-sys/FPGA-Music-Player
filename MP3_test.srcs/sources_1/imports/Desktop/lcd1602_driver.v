`timescale 1ns / 1ps

// ============================================================================
// Drop-in replacement for the original lcd1602_driver.v
//
// Verified direction from the standalone V2 test:
//   - use LCD1602 in 4-bit mode
//   - only LCD_D[7:4] carry data
//   - LCD_D[3:0] are held at 0 and ignored by the LCD controller
//   - every nibble is stable before LCD_E rises
//
// Interface is IDENTICAL to the original driver, so:
//   - top_mp3_player.v does not need to change
//   - XDC does not need to change
//   - audio/Flash logic does not need to change
//
// It periodically rewrites the two display lines so changing status text in
// top_mp3_player.v still updates normally.
// ============================================================================

module lcd1602_driver #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output wire [7:0]   lcd_d,
    output reg          lcd_rs,
    output wire         lcd_rw,
    output reg          lcd_e
);

    // 4-bit mode: only D4-D7 are used.
    reg [3:0] lcd_nibble;
    assign lcd_d[7:4] = lcd_nibble;
    assign lcd_d[3:0] = 4'b0000;
    assign lcd_rw      = 1'b0;

    // 10 us timing tick.
    localparam integer TICK_DIV = CLK_HZ / 100_000;
    reg [31:0] tick_cnt;
    wire tick = (tick_cnt == TICK_DIV-1);

    reg [15:0] wait_ticks;

    localparam ST_RAW_SETUP = 4'd0;
    localparam ST_RAW_E_HI  = 4'd1;
    localparam ST_RAW_E_LO  = 4'd2;
    localparam ST_LOAD_BYTE = 4'd3;
    localparam ST_HI_SETUP  = 4'd4;
    localparam ST_HI_E_HI   = 4'd5;
    localparam ST_HI_E_LO   = 4'd6;
    localparam ST_LO_SETUP  = 4'd7;
    localparam ST_LO_E_HI   = 4'd8;
    localparam ST_LO_E_LO   = 4'd9;

    reg [3:0] state;

    // Startup raw nibbles: 3,3,3,2.
    reg [2:0] raw_idx;

    // init_mode=1: normal full-byte initialization commands.
    // init_mode=0: normal line refresh.
    reg       init_mode;
    reg [2:0] init_idx;
    reg [5:0] op_idx;

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

    function [15:0] raw_delay_after;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: raw_delay_after = 16'd500; // 5 ms
                3'd1: raw_delay_after = 16'd20;  // 200 us
                3'd2: raw_delay_after = 16'd20;  // 200 us
                default: raw_delay_after = 16'd20;
            endcase
        end
    endfunction

    function [7:0] init_cmd;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: init_cmd = 8'h28; // 4-bit, 2 lines, 5x8
                3'd1: init_cmd = 8'h08; // display off
                3'd2: init_cmd = 8'h01; // clear display
                3'd3: init_cmd = 8'h06; // increment, display shift OFF
                default: init_cmd = 8'h0C; // display on, cursor off
            endcase
        end
    endfunction

    function [7:0] line_char;
        input [127:0] text;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  line_char = text[127:120];
                5'd1:  line_char = text[119:112];
                5'd2:  line_char = text[111:104];
                5'd3:  line_char = text[103:96];
                5'd4:  line_char = text[95:88];
                5'd5:  line_char = text[87:80];
                5'd6:  line_char = text[79:72];
                5'd7:  line_char = text[71:64];
                5'd8:  line_char = text[63:56];
                5'd9:  line_char = text[55:48];
                5'd10: line_char = text[47:40];
                5'd11: line_char = text[39:32];
                5'd12: line_char = text[31:24];
                5'd13: line_char = text[23:16];
                5'd14: line_char = text[15:8];
                default: line_char = text[7:0];
            endcase
        end
    endfunction

    task load_refresh_byte;
        input [5:0] idx;
        begin
            if (idx == 6'd0) begin
                cur_rs   <= 1'b0;
                cur_byte <= 8'h80;
            end
            else if ((idx >= 6'd1) && (idx <= 6'd16)) begin
                cur_rs   <= 1'b1;
                cur_byte <= line_char(line1, idx - 6'd1);
            end
            else if (idx == 6'd17) begin
                cur_rs   <= 1'b0;
                cur_byte <= 8'hC0;
            end
            else begin
                cur_rs   <= 1'b1;
                cur_byte <= line_char(line2, idx - 6'd18);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt    <= 32'd0;
            wait_ticks  <= 16'd10000; // 100 ms LCD power-up wait
            state       <= ST_RAW_SETUP;
            raw_idx     <= 3'd0;
            init_mode   <= 1'b1;
            init_idx    <= 3'd0;
            op_idx      <= 6'd0;
            cur_byte    <= 8'h00;
            cur_rs      <= 1'b0;
            lcd_nibble  <= 4'h0;
            lcd_rs      <= 1'b0;
            lcd_e       <= 1'b0;
        end
        else begin
            if (tick)
                tick_cnt <= 32'd0;
            else
                tick_cnt <= tick_cnt + 1'b1;

            if (tick) begin
                if (wait_ticks != 0) begin
                    wait_ticks <= wait_ticks - 1'b1;
                    lcd_e <= 1'b0;
                end
                else begin
                    case (state)

                        // ----------------------------------------------------
                        // Standard HD44780 4-bit entry: 3,3,3,2.
                        // Each nibble is set up one tick BEFORE E rises.
                        // ----------------------------------------------------
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
                                init_mode  <= 1'b1;
                                init_idx   <= 3'd0;
                                wait_ticks <= 16'd20;
                                state      <= ST_LOAD_BYTE;
                            end
                            else begin
                                wait_ticks <= raw_delay_after(raw_idx);
                                raw_idx    <= raw_idx + 1'b1;
                                state      <= ST_RAW_SETUP;
                            end
                        end

                        // ----------------------------------------------------
                        // Load either one initialization command or one
                        // display-refresh byte.
                        // ----------------------------------------------------
                        ST_LOAD_BYTE: begin
                            if (init_mode) begin
                                cur_rs   <= 1'b0;
                                cur_byte <= init_cmd(init_idx);
                            end
                            else begin
                                load_refresh_byte(op_idx);
                            end
                            state <= ST_HI_SETUP;
                        end

                        // ----------------------------------------------------
                        // Send HIGH nibble.
                        // ----------------------------------------------------
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

                        // ----------------------------------------------------
                        // Send LOW nibble.
                        // ----------------------------------------------------
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

                            if (init_mode) begin
                                if (init_idx == 3'd4) begin
                                    // Initialization complete.
                                    init_mode  <= 1'b0;
                                    op_idx     <= 6'd0;
                                    wait_ticks <= 16'd20;
                                    state      <= ST_LOAD_BYTE;
                                end
                                else begin
                                    // Clear command needs >1.5 ms.
                                    if (init_idx == 3'd2)
                                        wait_ticks <= 16'd250; // 2.5 ms
                                    else
                                        wait_ticks <= 16'd5;   // 50 us

                                    init_idx <= init_idx + 1'b1;
                                    state    <= ST_LOAD_BYTE;
                                end
                            end
                            else begin
                                if (op_idx == 6'd33) begin
                                    // Full two-line refresh completed.
                                    // Wait 100 ms, then rewrite from DDRAM 0x80.
                                    op_idx     <= 6'd0;
                                    wait_ticks <= 16'd10000;
                                    state      <= ST_LOAD_BYTE;
                                end
                                else begin
                                    op_idx     <= op_idx + 1'b1;
                                    wait_ticks <= 16'd5; // 50 us
                                    state      <= ST_LOAD_BYTE;
                                end
                            end
                        end

                        default: begin
                            lcd_e <= 1'b0;
                            state <= ST_RAW_SETUP;
                        end
                    endcase
                end
            end
        end
    end

endmodule
