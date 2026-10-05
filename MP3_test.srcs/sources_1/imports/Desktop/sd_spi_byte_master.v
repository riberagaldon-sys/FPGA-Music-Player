`timescale 1ns / 1ps
`default_nettype none

// SPI mode-0 byte master with the two clock rates required by SD cards:
// <=400 kHz during card initialization and 12.5 MHz for sector streaming.
module sd_spi_byte_master #(
    parameter integer CLK_HZ      = 100_000_000,
    parameter integer INIT_SPI_HZ = 400_000,
    parameter integer DATA_SPI_HZ = 12_500_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       fast_mode,
    input  wire       start,
    input  wire [7:0] tx_data,
    output reg  [7:0] rx_data,
    output reg        busy,
    output reg        done,
    output reg        sclk,
    output reg        mosi,
    input  wire       miso
);
    localparam integer INIT_HALF_DIV = CLK_HZ / (INIT_SPI_HZ * 2);
    localparam integer DATA_HALF_DIV = CLK_HZ / (DATA_SPI_HZ * 2);

    wire [31:0] selected_half_div = fast_mode ? DATA_HALF_DIV :
                                                 INIT_HALF_DIV;
    reg  [31:0] divider_count;
    reg  [2:0]  bit_count;
    reg  [7:0]  tx_shift;
    reg  [7:0]  rx_shift;

    wire half_tick = (divider_count >= selected_half_div-1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider_count <= 32'd0;
            bit_count     <= 3'd0;
            tx_shift      <= 8'hFF;
            rx_shift      <= 8'h00;
            rx_data       <= 8'h00;
            busy          <= 1'b0;
            done          <= 1'b0;
            sclk          <= 1'b0;
            mosi          <= 1'b1;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                sclk <= 1'b0;
                if (start) begin
                    divider_count <= 32'd0;
                    bit_count     <= 3'd0;
                    tx_shift      <= tx_data;
                    rx_shift      <= 8'h00;
                    busy          <= 1'b1;
                    mosi          <= tx_data[7];
                end
            end else if (half_tick) begin
                divider_count <= 32'd0;
                if (!sclk) begin
                    // Rising edge: SD and FPGA both use SPI mode 0.
                    sclk     <= 1'b1;
                    rx_shift <= {rx_shift[6:0], miso};
                end else begin
                    // Falling edge: prepare MOSI for the next rising edge.
                    sclk <= 1'b0;
                    if (bit_count == 3'd7) begin
                        rx_data <= rx_shift;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        mosi    <= 1'b1;
                    end else begin
                        bit_count <= bit_count + 1'b1;
                        tx_shift  <= {tx_shift[6:0], 1'b1};
                        mosi      <= tx_shift[6];
                    end
                end
            end else begin
                divider_count <= divider_count + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
