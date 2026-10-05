`timescale 1ns / 1ps

// ES8388 control port.
// The board ties CE low, therefore the 7-bit I2C address is 0x10.
// Configuration: slave, 48-kHz family, 256*Fs MCLK, 16-bit I2S,
// ADC from LIN2/RIN2 (board LINE_IN), DAC to headphone/line outputs.
module es8388_init #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire clk,
    input  wire rst_n,
    output wire codec_scl,
    inout  wire codec_sda,
    output reg  init_done,
    output reg  init_ok
);
    localparam [6:0] ES8388_ADDR = 7'h10;
    localparam integer POWERUP_CYCLES = CLK_HZ / 50; // 20 ms
    localparam integer REG_COUNT = 30;

    reg [31:0] wait_cnt;
    reg [5:0]  reg_index;
    reg        i2c_start;
    wire       i2c_busy;
    wire       i2c_done;
    wire       i2c_ack_error;

    reg [7:0] cfg_reg;
    reg [7:0] cfg_data;

    always @(*) begin
        cfg_reg  = 8'h00;
        cfg_data = 8'h00;
        case (reg_index)
            // Slave + power sequencing
            6'd0:  begin cfg_reg=8'h08; cfg_data=8'h00; end
            6'd1:  begin cfg_reg=8'h02; cfg_data=8'hF3; end
            6'd2:  begin cfg_reg=8'h2B; cfg_data=8'h80; end
            6'd3:  begin cfg_reg=8'h00; cfg_data=8'h05; end
            6'd4:  begin cfg_reg=8'h01; cfg_data=8'h40; end

            // ADC / LINE-IN
            6'd5:  begin cfg_reg=8'h03; cfg_data=8'h00; end
            6'd6:  begin cfg_reg=8'h09; cfg_data=8'h00; end
            6'd7:  begin cfg_reg=8'h0A; cfg_data=8'h50; end // LIN2/RIN2 (board LINE_IN)
            6'd8:  begin cfg_reg=8'h0C; cfg_data=8'h0C; end // I2S 16-bit
            6'd9:  begin cfg_reg=8'h0D; cfg_data=8'h02; end // 256*Fs
            6'd10: begin cfg_reg=8'h0F; cfg_data=8'h30; end
            6'd11: begin cfg_reg=8'h10; cfg_data=8'h00; end
            6'd12: begin cfg_reg=8'h11; cfg_data=8'h00; end

            // DAC
            6'd13: begin cfg_reg=8'h04; cfg_data=8'h30; end // enable LOUT1/ROUT1 (PHONE_OUT), disable LOUT2/ROUT2 (speaker)
            6'd14: begin cfg_reg=8'h17; cfg_data=8'h18; end // I2S 16-bit
            6'd15: begin cfg_reg=8'h18; cfg_data=8'h02; end // 256*Fs
            6'd16: begin cfg_reg=8'h1A; cfg_data=8'h00; end
            6'd17: begin cfg_reg=8'h1B; cfg_data=8'h00; end

            // Mixer: DAC L/R routed to outputs
            6'd18: begin cfg_reg=8'h26; cfg_data=8'h00; end
            6'd19: begin cfg_reg=8'h27; cfg_data=8'hB8; end
            6'd20: begin cfg_reg=8'h28; cfg_data=8'h38; end
            6'd21: begin cfg_reg=8'h29; cfg_data=8'h38; end
            6'd22: begin cfg_reg=8'h2A; cfg_data=8'hB8; end

            // Analog output volumes
            6'd23: begin cfg_reg=8'h2E; cfg_data=8'h1E; end
            6'd24: begin cfg_reg=8'h2F; cfg_data=8'h1E; end
            6'd25: begin cfg_reg=8'h30; cfg_data=8'h00; end // LOUT2 minimum volume (-45 dB), speaker path suppressed
            6'd26: begin cfg_reg=8'h31; cfg_data=8'h00; end // ROUT2 minimum volume (-45 dB)

            // Unmute and finish power-up
            6'd27: begin cfg_reg=8'h19; cfg_data=8'h00; end
            6'd28: begin cfg_reg=8'h02; cfg_data=8'h00; end
            6'd29: begin cfg_reg=8'h03; cfg_data=8'h00; end
            default: begin cfg_reg=8'h00; cfg_data=8'h00; end
        endcase
    end

    i2c_master_write #(
        .CLK_HZ(CLK_HZ),
        .I2C_HZ(100_000)
    ) u_i2c (
        .clk(clk),
        .rst_n(rst_n),
        .start(i2c_start),
        .dev_addr(ES8388_ADDR),
        .reg_addr(cfg_reg),
        .reg_data(cfg_data),
        .busy(i2c_busy),
        .done(i2c_done),
        .ack_error(i2c_ack_error),
        .scl(codec_scl),
        .sda(codec_sda)
    );

    localparam [2:0]
        ST_POWERUP = 3'd0,
        ST_ISSUE   = 3'd1,
        ST_WAIT    = 3'd2,
        ST_DONE    = 3'd3;

    reg [2:0] state;
    reg error_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_cnt   <= 32'd0;
            reg_index  <= 6'd0;
            i2c_start  <= 1'b0;
            init_done  <= 1'b0;
            init_ok    <= 1'b0;
            error_seen <= 1'b0;
            state      <= ST_POWERUP;
        end else begin
            i2c_start <= 1'b0;

            case (state)
                ST_POWERUP: begin
                    if (wait_cnt >= POWERUP_CYCLES-1) begin
                        wait_cnt <= 32'd0;
                        state <= ST_ISSUE;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                ST_ISSUE: begin
                    if (!i2c_busy) begin
                        i2c_start <= 1'b1;
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (i2c_done) begin
                        if (i2c_ack_error)
                            error_seen <= 1'b1;

                        if (reg_index == REG_COUNT-1)
                            state <= ST_DONE;
                        else begin
                            reg_index <= reg_index + 1'b1;
                            state <= ST_ISSUE;
                        end
                    end
                end

                ST_DONE: begin
                    init_done <= 1'b1;
                    init_ok   <= ~error_seen;
                end

                default: state <= ST_POWERUP;
            endcase
        end
    end
endmodule
