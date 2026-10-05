`timescale 1ns / 1ps
`default_nettype none

// Dual-clock stereo PCM FIFO with a write-domain fill-level estimate.
// Gray-coded pointers are synchronized between domains; storage infers BRAM.
module async_stereo_fifo_level #(
    parameter integer AW = 12
)(
    input  wire          wr_clk,
    input  wire          wr_rst_n,
    input  wire          wr_clear,
    input  wire          wr_en,
    input  wire [15:0]   wr_l,
    input  wire [15:0]   wr_r,
    output wire          wr_full,
    output wire [AW:0]   wr_level,

    input  wire          rd_clk,
    input  wire          rd_rst_n,
    input  wire          rd_clear,
    input  wire          rd_pop,
    output reg  [15:0]   rd_l,
    output reg  [15:0]   rd_r,
    output wire          rd_empty
);
    localparam integer DEPTH = (1 << AW);
    (* ram_style = "block" *) reg [31:0] memory [0:DEPTH-1];

    reg [AW:0] write_binary;
    reg [AW:0] write_gray;
    reg [AW:0] read_binary;
    reg [AW:0] read_gray;
    reg [AW:0] read_gray_sync1;
    reg [AW:0] read_gray_sync2;
    reg [AW:0] write_gray_sync1;
    reg [AW:0] write_gray_sync2;
    reg        read_have_data;

    wire [AW:0] write_binary_next = write_binary + 1'b1;
    wire [AW:0] write_gray_next =
        (write_binary_next >> 1) ^ write_binary_next;
    wire [AW:0] read_binary_next = read_binary + 1'b1;
    wire [AW:0] read_gray_next =
        (read_binary_next >> 1) ^ read_binary_next;

    function [AW:0] gray_to_binary;
        input [AW:0] gray_value;
        integer bit_number;
        begin
            gray_to_binary[AW] = gray_value[AW];
            for (bit_number=AW-1; bit_number>=0; bit_number=bit_number-1)
                gray_to_binary[bit_number] =
                    gray_to_binary[bit_number+1] ^ gray_value[bit_number];
        end
    endfunction

    wire [AW:0] read_binary_sync = gray_to_binary(read_gray_sync2);
    assign wr_level = write_binary - read_binary_sync;

    assign wr_full = (write_gray_next ==
        {~read_gray_sync2[AW:AW-1], read_gray_sync2[AW-2:0]});

    wire memory_empty = (read_gray == write_gray_sync2);
    assign rd_empty = ~read_have_data;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            write_binary   <= {(AW+1){1'b0}};
            write_gray     <= {(AW+1){1'b0}};
            read_gray_sync1<= {(AW+1){1'b0}};
            read_gray_sync2<= {(AW+1){1'b0}};
        end else begin
            read_gray_sync1 <= read_gray;
            read_gray_sync2 <= read_gray_sync1;

            if (wr_clear) begin
                write_binary <= {(AW+1){1'b0}};
                write_gray   <= {(AW+1){1'b0}};
            end else if (wr_en && !wr_full) begin
                memory[write_binary[AW-1:0]] <= {wr_l, wr_r};
                write_binary <= write_binary_next;
                write_gray   <= write_gray_next;
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            read_binary    <= {(AW+1){1'b0}};
            read_gray      <= {(AW+1){1'b0}};
            write_gray_sync1 <= {(AW+1){1'b0}};
            write_gray_sync2 <= {(AW+1){1'b0}};
            rd_l           <= 16'd0;
            rd_r           <= 16'd0;
            read_have_data <= 1'b0;
        end else begin
            write_gray_sync1 <= write_gray;
            write_gray_sync2 <= write_gray_sync1;

            if (rd_clear) begin
                read_binary    <= {(AW+1){1'b0}};
                read_gray      <= {(AW+1){1'b0}};
                rd_l           <= 16'd0;
                rd_r           <= 16'd0;
                read_have_data <= 1'b0;
            end else begin
                if (rd_pop && read_have_data) begin
                    read_binary    <= read_binary_next;
                    read_gray      <= read_gray_next;
                    read_have_data <= 1'b0;
                end else if (!read_have_data && !memory_empty) begin
                    {rd_l, rd_r}   <= memory[read_binary[AW-1:0]];
                    read_have_data <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
