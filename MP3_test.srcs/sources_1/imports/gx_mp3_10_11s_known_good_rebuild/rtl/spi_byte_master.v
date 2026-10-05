`timescale 1ns / 1ps

module spi_byte_master #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer SPI_HZ = 400_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] tx_data,
    output reg  [7:0] rx_data,
    output reg        busy,
    output reg        done,
    output reg        sclk,
    output reg        mosi,
    input  wire       miso
);
    localparam integer HALF_DIV = CLK_HZ / (SPI_HZ * 2);
    reg [31:0] div_cnt;
    reg [2:0]  bit_count;
    reg [7:0]  tx_shift;
    reg [7:0]  rx_shift;
    wire half_tick = (div_cnt == HALF_DIV-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt   <= 32'd0;
            bit_count <= 3'd0;
            tx_shift  <= 8'hFF;
            rx_shift  <= 8'h00;
            rx_data   <= 8'h00;
            busy      <= 1'b0;
            done      <= 1'b0;
            sclk      <= 1'b0;
            mosi      <= 1'b1;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                sclk <= 1'b0;
                if (start) begin
                    busy      <= 1'b1;
                    bit_count <= 3'd0;
                    tx_shift  <= tx_data;
                    rx_shift  <= 8'd0;
                    mosi      <= tx_data[7];
                    div_cnt   <= 32'd0;
                end
            end else begin
                if (half_tick)
                    div_cnt <= 32'd0;
                else
                    div_cnt <= div_cnt + 1'b1;

                if (half_tick) begin
                    if (!sclk) begin
                        sclk     <= 1'b1;
                        rx_shift <= {rx_shift[6:0], miso};
                    end else begin
                        sclk <= 1'b0;
                        if (bit_count == 3'd7) begin
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            rx_data <= rx_shift;
                            mosi    <= 1'b1;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                            tx_shift  <= {tx_shift[6:0],1'b1};
                            mosi      <= tx_shift[6];
                        end
                    end
                end
            end
        end
    end
endmodule
