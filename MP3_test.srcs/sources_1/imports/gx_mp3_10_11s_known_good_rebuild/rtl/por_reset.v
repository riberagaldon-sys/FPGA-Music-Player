`timescale 1ns / 1ps

module por_reset #(
    parameter integer POR_BITS = 22
)(
    input  wire clk,
    output wire rst_n
);
    reg [POR_BITS-1:0] counter = {POR_BITS{1'b0}};

    always @(posedge clk) begin
        if (!(&counter))
            counter <= counter + {{(POR_BITS-1){1'b0}},1'b1};
    end

    assign rst_n = &counter;
endmodule
