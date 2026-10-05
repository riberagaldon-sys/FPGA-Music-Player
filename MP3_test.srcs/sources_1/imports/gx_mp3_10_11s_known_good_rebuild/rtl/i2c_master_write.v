`timescale 1ns / 1ps

// Simple 100-kHz I2C write-only master.
// Transaction:
//   START, {DEV_ADDR,0}, REG_ADDR, REG_DATA, STOP
// SDA is open-drain.
module i2c_master_write #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [6:0] dev_addr,
    input  wire [7:0] reg_addr,
    input  wire [7:0] reg_data,
    output reg        busy,
    output reg        done,
    output reg        ack_error,
    output reg        scl,
    inout  wire       sda
);
    localparam integer QUARTER_DIV = CLK_HZ / (I2C_HZ * 4);

    localparam [3:0]
        ST_IDLE    = 4'd0,
        ST_START_A = 4'd1,
        ST_START_B = 4'd2,
        ST_SEND    = 4'd3,
        ST_ACK     = 4'd4,
        ST_STOP_A  = 4'd5,
        ST_STOP_B  = 4'd6,
        ST_STOP_C  = 4'd7;

    reg [31:0] div_cnt;
    wire tick = (div_cnt == QUARTER_DIV-1);

    reg sda_drive_low;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;
    wire sda_in = sda;

    reg [3:0] state;
    reg [1:0] phase;
    reg [1:0] byte_index;
    reg [2:0] bit_index;
    reg [7:0] byte_dev;
    reg [7:0] byte_reg;
    reg [7:0] byte_data;

    function [7:0] current_byte;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: current_byte = byte_dev;
                2'd1: current_byte = byte_reg;
                default: current_byte = byte_data;
            endcase
        end
    endfunction

    wire [7:0] selected_byte = current_byte(byte_index);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt       <= 32'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            ack_error     <= 1'b0;
            scl           <= 1'b1;
            sda_drive_low <= 1'b0;
            state         <= ST_IDLE;
            phase         <= 2'd0;
            byte_index    <= 2'd0;
            bit_index     <= 3'd7;
            byte_dev      <= 8'h20;
            byte_reg      <= 8'h00;
            byte_data     <= 8'h00;
        end else begin
            done <= 1'b0;

            if (tick)
                div_cnt <= 32'd0;
            else
                div_cnt <= div_cnt + 1'b1;

            if (state == ST_IDLE) begin
                scl           <= 1'b1;
                sda_drive_low <= 1'b0;
                busy          <= 1'b0;

                if (start) begin
                    byte_dev   <= {dev_addr, 1'b0};
                    byte_reg   <= reg_addr;
                    byte_data  <= reg_data;
                    ack_error  <= 1'b0;
                    busy       <= 1'b1;
                    state      <= ST_START_A;
                end
            end
            else if (tick) begin
                case (state)
                    ST_START_A: begin
                        // SDA goes low while SCL is high.
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state         <= ST_START_B;
                    end

                    ST_START_B: begin
                        scl        <= 1'b0;
                        byte_index <= 2'd0;
                        bit_index  <= 3'd7;
                        phase      <= 2'd0;
                        state      <= ST_SEND;
                    end

                    ST_SEND: begin
                        case (phase)
                            2'd0: begin
                                scl <= 1'b0;
                                sda_drive_low <= ~selected_byte[bit_index];
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl <= 1'b1;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                scl <= 1'b1;
                                phase <= 2'd3;
                            end
                            default: begin
                                scl <= 1'b0;
                                if (bit_index == 0) begin
                                    phase <= 2'd0;
                                    state <= ST_ACK;
                                end else begin
                                    bit_index <= bit_index - 1'b1;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_ACK: begin
                        case (phase)
                            2'd0: begin
                                scl <= 1'b0;
                                sda_drive_low <= 1'b0; // release for ACK
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl <= 1'b1;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                scl <= 1'b1;
                                if (sda_in)
                                    ack_error <= 1'b1;
                                phase <= 2'd3;
                            end
                            default: begin
                                scl <= 1'b0;
                                if (byte_index == 2) begin
                                    phase <= 2'd0;
                                    state <= ST_STOP_A;
                                end else begin
                                    byte_index <= byte_index + 1'b1;
                                    bit_index  <= 3'd7;
                                    phase      <= 2'd0;
                                    state      <= ST_SEND;
                                end
                            end
                        endcase
                    end

                    ST_STOP_A: begin
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b1;
                        state         <= ST_STOP_B;
                    end

                    ST_STOP_B: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state         <= ST_STOP_C;
                    end

                    ST_STOP_C: begin
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0; // STOP
                        busy          <= 1'b0;
                        done          <= 1'b1;
                        state         <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end
endmodule
