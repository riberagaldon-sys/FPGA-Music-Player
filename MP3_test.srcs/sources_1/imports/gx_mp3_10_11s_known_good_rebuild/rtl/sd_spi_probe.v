`timescale 1ns / 1ps

// First SD-card hardware bring-up:
// 80 idle clocks, CMD0, then read R1.
// cmd0_ok=1 means the card entered SPI idle state (R1=0x01).
module sd_spi_probe #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire card_detect_n,
    output reg  sd_cs_n,
    output wire sd_sclk,
    output wire sd_mosi,
    input  wire sd_miso,
    output reg  probe_done,
    output reg  cmd0_ok,
    output reg  [7:0] r1_value
);
    reg        byte_start;
    reg [7:0]  byte_tx;
    wire [7:0] byte_rx;
    wire       byte_busy;
    wire       byte_done;

    spi_byte_master #(
        .CLK_HZ(CLK_HZ),
        .SPI_HZ(400_000)
    ) u_spi (
        .clk(clk),
        .rst_n(rst_n),
        .start(byte_start),
        .tx_data(byte_tx),
        .rx_data(byte_rx),
        .busy(byte_busy),
        .done(byte_done),
        .sclk(sd_sclk),
        .mosi(sd_mosi),
        .miso(sd_miso)
    );

    localparam [3:0]
        ST_WAIT_CARD  = 4'd0,
        ST_IDLE_SEND  = 4'd1,
        ST_IDLE_WAIT  = 4'd2,
        ST_CMD_SEND   = 4'd3,
        ST_CMD_WAIT   = 4'd4,
        ST_RESP_SEND  = 4'd5,
        ST_RESP_WAIT  = 4'd6,
        ST_DONE       = 4'd7;

    reg [3:0] state;
    reg [4:0] count;
    reg [31:0] power_wait;

    function [7:0] cmd0_byte;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: cmd0_byte = 8'h40;
                3'd1: cmd0_byte = 8'h00;
                3'd2: cmd0_byte = 8'h00;
                3'd3: cmd0_byte = 8'h00;
                3'd4: cmd0_byte = 8'h00;
                default: cmd0_byte = 8'h95;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_start <= 1'b0;
            byte_tx    <= 8'hFF;
            sd_cs_n    <= 1'b1;
            probe_done <= 1'b0;
            cmd0_ok    <= 1'b0;
            r1_value   <= 8'hFF;
            state      <= ST_WAIT_CARD;
            count      <= 5'd0;
            power_wait <= 32'd0;
        end else begin
            byte_start <= 1'b0;

            case (state)
                ST_WAIT_CARD: begin
                    sd_cs_n <= 1'b1;
                    if (!card_detect_n) begin
                        if (power_wait >= CLK_HZ/100-1) begin // 10 ms
                            power_wait <= 32'd0;
                            count <= 5'd0;
                            state <= ST_IDLE_SEND;
                        end else
                            power_wait <= power_wait + 1'b1;
                    end else
                        power_wait <= 32'd0;
                end

                ST_IDLE_SEND: begin
                    if (!byte_busy) begin
                        byte_tx <= 8'hFF;
                        byte_start <= 1'b1;
                        state <= ST_IDLE_WAIT;
                    end
                end

                ST_IDLE_WAIT: begin
                    if (byte_done) begin
                        if (count == 5'd9) begin
                            count <= 5'd0;
                            sd_cs_n <= 1'b0;
                            state <= ST_CMD_SEND;
                        end else begin
                            count <= count + 1'b1;
                            state <= ST_IDLE_SEND;
                        end
                    end
                end

                ST_CMD_SEND: begin
                    if (!byte_busy) begin
                        byte_tx <= cmd0_byte(count[2:0]);
                        byte_start <= 1'b1;
                        state <= ST_CMD_WAIT;
                    end
                end

                ST_CMD_WAIT: begin
                    if (byte_done) begin
                        if (count == 5) begin
                            count <= 5'd0;
                            state <= ST_RESP_SEND;
                        end else begin
                            count <= count + 1'b1;
                            state <= ST_CMD_SEND;
                        end
                    end
                end

                ST_RESP_SEND: begin
                    if (!byte_busy) begin
                        byte_tx <= 8'hFF;
                        byte_start <= 1'b1;
                        state <= ST_RESP_WAIT;
                    end
                end

                ST_RESP_WAIT: begin
                    if (byte_done) begin
                        if (byte_rx != 8'hFF) begin
                            r1_value <= byte_rx;
                            cmd0_ok <= (byte_rx == 8'h01);
                            probe_done <= 1'b1;
                            sd_cs_n <= 1'b1;
                            state <= ST_DONE;
                        end else if (count == 5'd15) begin
                            r1_value <= byte_rx;
                            cmd0_ok <= 1'b0;
                            probe_done <= 1'b1;
                            sd_cs_n <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            count <= count + 1'b1;
                            state <= ST_RESP_SEND;
                        end
                    end
                end

                ST_DONE: begin
                    sd_cs_n <= 1'b1;
                end

                default: state <= ST_WAIT_CARD;
            endcase
        end
    end
endmodule
