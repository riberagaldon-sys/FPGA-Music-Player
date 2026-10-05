`timescale 1ns / 1ps

// ES8388 slave-mode I2S interface.
// MCLK = 12.288 MHz, BCLK = MCLK/4 = 3.072 MHz, LRCK = 48 kHz.
// 32-bit slot per channel; 16 payload bits, standard one-bit I2S delay.
module i2s_audio_if(
    input  wire        mclk,
    input  wire        rst_n,

    input  wire [15:0] tx_left,
    input  wire [15:0] tx_right,

    input  wire        adc_data,
    output reg         dac_data,
    output reg         bclk,
    output reg         lrclk,

    output reg  [15:0] rx_left,
    output reg  [15:0] rx_right,
    output reg         rx_valid,
    output reg         frame_tick
);
    reg [1:0] mclk_div;
    reg [5:0] bit_pos;

    reg [15:0] tx_latched_l;
    reg [15:0] tx_latched_r;
    reg [15:0] rx_shift_l;
    reg [15:0] rx_shift_r;

    function tx_bit;
        input [5:0] pos;
        input [15:0] l;
        input [15:0] r;
        integer bi;
        begin
            tx_bit = 1'b0;
            if ((pos >= 1) && (pos <= 16)) begin
                bi = 16 - pos;
                tx_bit = l[bi];
            end
            else if ((pos >= 33) && (pos <= 48)) begin
                bi = 48 - pos;
                tx_bit = r[bi];
            end
        end
    endfunction

    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            mclk_div     <= 2'd0;
            bit_pos      <= 6'd0;
            bclk         <= 1'b0;
            lrclk        <= 1'b0;
            dac_data     <= 1'b0;
            tx_latched_l <= 16'd0;
            tx_latched_r <= 16'd0;
            rx_shift_l   <= 16'd0;
            rx_shift_r   <= 16'd0;
            rx_left      <= 16'd0;
            rx_right     <= 16'd0;
            rx_valid     <= 1'b0;
            frame_tick   <= 1'b0;
        end else begin
            rx_valid   <= 1'b0;
            frame_tick <= 1'b0;
            mclk_div   <= mclk_div + 1'b1;

            // Rising edge of BCLK.
            if (mclk_div == 2'd1) begin
                bclk <= 1'b1;

                if ((bit_pos >= 1) && (bit_pos <= 16))
                    rx_shift_l <= {rx_shift_l[14:0], adc_data};
                else if ((bit_pos >= 33) && (bit_pos <= 48))
                    rx_shift_r <= {rx_shift_r[14:0], adc_data};

                if (bit_pos == 6'd63) begin
                    bit_pos      <= 6'd0;
                    rx_left      <= rx_shift_l;
                    rx_right     <= rx_shift_r;
                    rx_valid     <= 1'b1;
                    frame_tick   <= 1'b1;
                    tx_latched_l <= tx_left;
                    tx_latched_r <= tx_right;
                end else begin
                    bit_pos <= bit_pos + 1'b1;
                end
            end

            // Falling edge of BCLK: change output data for next rising edge.
            if (mclk_div == 2'd3) begin
                bclk     <= 1'b0;
                lrclk    <= (bit_pos >= 6'd32);
                dac_data <= tx_bit(bit_pos, tx_latched_l, tx_latched_r);
            end
        end
    end
endmodule
