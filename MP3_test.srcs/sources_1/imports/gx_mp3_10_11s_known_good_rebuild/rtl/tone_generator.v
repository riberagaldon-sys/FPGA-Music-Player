`timescale 1ns / 1ps

// 1-kHz, low-level stereo sine for first audio bring-up.
module tone_generator(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    output reg  [15:0] pcm_left,
    output reg  [15:0] pcm_right
);
    reg [31:0] phase_acc;
    localparam [31:0] PHASE_INC = 32'd89478485; // 1000 Hz @ 48 kHz

    (* rom_style = "block" *) reg [15:0] sine_rom [0:255];
    initial $readmemh("sine_256.mem", sine_rom);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= 32'd0;
            pcm_left  <= 16'd0;
            pcm_right <= 16'd0;
        end else if (sample_tick) begin
            phase_acc <= phase_acc + PHASE_INC;
            pcm_left  <= sine_rom[phase_acc[31:24]];
            pcm_right <= sine_rom[phase_acc[31:24]];
        end
    end
endmodule
