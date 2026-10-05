`timescale 1ns / 1ps

// ============================================================================
// LCD1602 write-once isolation test
// Same top-level ports as the current MP3 project so the existing XDC can stay.
//
// Expected:
//   line1: LCD WRITE ONCE
//   line2: 1234567890ABCDEF
//
// Important:
//   - LCD is initialized once.
//   - Two lines are written once.
//   - Then LCD_E is held LOW forever.
//   - No periodic refresh, no display-shift command.
// ============================================================================

module top_lcd_write_once_test (
    input  wire sys_clk,

    // ES8388
    output wire AUDIO_MCLK,
    output wire AUDIO_BCLK,
    output wire AUDIO_LRCK,
    output wire AUDIO_DAC_DIN,
    input  wire AUDIO_ADC_DOUT,
    output wire AUDIO_CCLK,
    inout  wire AUDIO_CDATA,

    // User SPI Flash
    output wire FLASH_CS_N,
    output wire FLASH_SCLK,
    output wire FLASH_MOSI,
    input  wire FLASH_MISO,
    output wire FLASH_HOLD_N,

    // SD
    output wire SD_CS_N,
    output wire SD_SCLK,
    output wire SD_MOSI,
    input  wire SD_MISO,
    input  wire SD_CD_N,

    // LCD1602
    output wire [7:0] LCD_D,
    output wire       LCD_RS,
    output wire       LCD_RW,
    output wire       LCD_E,

    // LEDs
    output wire LED0,
    output wire LED1
);

    // Keep unrelated peripherals idle.
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

    // Local POR: about 42 ms @ 100 MHz
    reg [21:0] por_cnt = 22'd0;
    reg rst_n = 1'b0;
    always @(posedge sys_clk) begin
        if (!por_cnt[21]) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n <= 1'b0;
        end else begin
            rst_n <= 1'b1;
        end
    end

    wire done;

    lcd1602_write_once u_lcd (
        .clk(sys_clk),
        .rst_n(rst_n),
        .line1("LCD WRITE ONCE  "),
        .line2("1234567890ABCDEF"),
        .lcd_d(LCD_D),
        .lcd_rs(LCD_RS),
        .lcd_rw(LCD_RW),
        .lcd_e(LCD_E),
        .done(done)
    );

    assign LED0 = done;
    assign LED1 = 1'b1;

endmodule


module lcd1602_write_once (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output reg  [7:0]   lcd_d,
    output reg          lcd_rs,
    output wire         lcd_rw,
    output reg          lcd_e,
    output reg          done
);

    assign lcd_rw = 1'b0;

    // 100 us tick @ 100 MHz
    localparam integer TICK_DIV = 10000;

    reg [13:0] tick_cnt;
    wire tick = (tick_cnt == TICK_DIV-1);

    reg [15:0] wait_ticks;
    reg [3:0]  init_idx;
    reg [5:0]  op_idx;
    reg [1:0]  phase;
    reg        init_done;

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

    function [7:0] init_cmd;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: init_cmd = 8'h30;
                4'd1: init_cmd = 8'h30;
                4'd2: init_cmd = 8'h30;
                4'd3: init_cmd = 8'h38; // 8-bit, 2-line
                4'd4: init_cmd = 8'h08; // display off
                4'd5: init_cmd = 8'h01; // clear
                4'd6: init_cmd = 8'h06; // increment, NO display shift
                default: init_cmd = 8'h0C; // display on
            endcase
        end
    endfunction

    function [15:0] init_wait_after;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: init_wait_after = 16'd50; // 5 ms
                4'd1: init_wait_after = 16'd10; // 1 ms
                4'd2: init_wait_after = 16'd10;
                4'd3: init_wait_after = 16'd10;
                4'd4: init_wait_after = 16'd10;
                4'd5: init_wait_after = 16'd30; // 3 ms
                4'd6: init_wait_after = 16'd10;
                default: init_wait_after = 16'd10;
            endcase
        end
    endfunction

    task load_op;
        input [5:0] op;
        begin
            if (op == 6'd0) begin
                lcd_rs <= 1'b0;
                lcd_d  <= 8'h80;
            end
            else if ((op >= 6'd1) && (op <= 6'd16)) begin
                lcd_rs <= 1'b1;
                lcd_d  <= get_char(line1, op - 6'd1);
            end
            else if (op == 6'd17) begin
                lcd_rs <= 1'b0;
                lcd_d  <= 8'hC0;
            end
            else begin
                lcd_rs <= 1'b1;
                lcd_d  <= get_char(line2, op - 6'd18);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt   <= 14'd0;
            wait_ticks <= 16'd1000; // 100 ms
            init_idx   <= 4'd0;
            op_idx     <= 6'd0;
            phase      <= 2'd0;
            init_done  <= 1'b0;
            lcd_d      <= 8'h00;
            lcd_rs     <= 1'b0;
            lcd_e      <= 1'b0;
            done       <= 1'b0;
        end
        else begin
            if (tick)
                tick_cnt <= 14'd0;
            else
                tick_cnt <= tick_cnt + 1'b1;

            if (tick) begin
                if (done) begin
                    // Absolutely no more LCD transactions after both lines are written.
                    lcd_e <= 1'b0;
                end
                else if (wait_ticks != 0) begin
                    wait_ticks <= wait_ticks - 1'b1;
                    lcd_e <= 1'b0;
                end
                else if (!init_done) begin
                    case (phase)
                        2'd0: begin
                            lcd_rs <= 1'b0;
                            lcd_d  <= init_cmd(init_idx);
                            lcd_e  <= 1'b0;
                            phase  <= 2'd1;
                        end
                        2'd1: begin
                            lcd_e <= 1'b1;
                            phase <= 2'd2;
                        end
                        default: begin
                            lcd_e <= 1'b0;
                            phase <= 2'd0;
                            if (init_idx == 4'd7) begin
                                init_done  <= 1'b1;
                                op_idx     <= 6'd0;
                                wait_ticks <= 16'd20;
                            end
                            else begin
                                wait_ticks <= init_wait_after(init_idx);
                                init_idx   <= init_idx + 1'b1;
                            end
                        end
                    endcase
                end
                else begin
                    case (phase)
                        2'd0: begin
                            load_op(op_idx);
                            lcd_e <= 1'b0;
                            phase <= 2'd1;
                        end
                        2'd1: begin
                            lcd_e <= 1'b1;
                            phase <= 2'd2;
                        end
                        default: begin
                            lcd_e <= 1'b0;
                            phase <= 2'd0;

                            if (op_idx == 6'd33) begin
                                done <= 1'b1;
                            end
                            else begin
                                op_idx <= op_idx + 1'b1;
                                wait_ticks <= 16'd1;
                            end
                        end
                    endcase
                end
            end
        end
    end

endmodule
