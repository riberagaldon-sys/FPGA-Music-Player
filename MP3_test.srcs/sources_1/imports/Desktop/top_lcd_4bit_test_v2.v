`timescale 1ns / 1ps

// LCD1602 4-bit isolation test V2
// Important fix versus V1:
//   Every D4-D7 nibble is made stable BEFORE LCD_E rises.
// Expected fixed display:
//   LCD 4BIT V2
//   1234567890ABCDEF

module top_lcd_4bit_test_v2 (
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

    // Keep unrelated interfaces idle.
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

    // Local power-on reset ~42 ms @ 100 MHz.
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

    lcd1602_4bit_once_v2 u_lcd (
        .clk    (sys_clk),
        .rst_n  (rst_n),
        .line1  ("LCD 4BIT V2     "),
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


module lcd1602_4bit_once_v2 (
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

    // 4-bit mode: D0-D3 are not used by the LCD controller.
    reg [3:0] lcd_nibble;
    assign lcd_d[7:4] = lcd_nibble;
    assign lcd_d[3:0] = 4'b0000;
    assign lcd_rw = 1'b0;

    // 10 us tick @ 100 MHz.
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
                6'd0: begin cur_rs <= 1'b0; cur_byte <= 8'h28; end // 4-bit, 2-line
                6'd1: begin cur_rs <= 1'b0; cur_byte <= 8'h08; end // display off
                6'd2: begin cur_rs <= 1'b0; cur_byte <= 8'h01; end // clear
                6'd3: begin cur_rs <= 1'b0; cur_byte <= 8'h06; end // increment, no shift
                6'd4: begin cur_rs <= 1'b0; cur_byte <= 8'h0C; end // display on
                6'd5: begin cur_rs <= 1'b0; cur_byte <= 8'h80; end // line 1 address
                6'd22:begin cur_rs <= 1'b0; cur_byte <= 8'hC0; end // line 2 address
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
            tick_cnt    <= 10'd0;
            wait_ticks  <= 16'd10000; // extra 100 ms LCD power-up wait
            state       <= ST_RAW_SETUP;
            raw_idx     <= 3'd0;
            seq_idx     <= 6'd0;
            cur_byte    <= 8'h00;
            cur_rs      <= 1'b0;
            lcd_nibble  <= 4'h0;
            lcd_rs      <= 1'b0;
            lcd_e       <= 1'b0;
            done        <= 1'b0;
        end
        else begin
            if (tick)
                tick_cnt <= 10'd0;
            else
                tick_cnt <= tick_cnt + 1'b1;

            if (tick) begin
                if (wait_ticks != 0) begin
                    wait_ticks <= wait_ticks - 1'b1;
                    lcd_e <= 1'b0;
                end
                else begin
                    case (state)
                        // Raw 0x3,0x3,0x3,0x2 startup nibbles.
                        // Critical: SETUP and E-rise are separate states.
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
                            end
                            else begin
                                wait_ticks <= raw_delay(raw_idx);
                                raw_idx    <= raw_idx + 1'b1;
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
                            end
                            else begin
                                // 2.5 ms after clear, otherwise 50 us.
                                if (seq_idx == 6'd2)
                                    wait_ticks <= 16'd250;
                                else
                                    wait_ticks <= 16'd5;

                                seq_idx <= seq_idx + 1'b1;
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
