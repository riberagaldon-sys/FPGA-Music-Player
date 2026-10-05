`timescale 1ns / 1ps
`default_nettype none

// SDHC/SDSC SPI block device.
// Initializes the card at 400 kHz, then accepts single-sector CMD17 requests
// at 12.5 MHz and returns exactly 512 byte-valid pulses per successful read.
module sd_spi_block_reader #(
    parameter integer CLK_HZ      = 100_000_000,
    parameter integer INIT_SPI_HZ = 400_000,
    parameter integer DATA_SPI_HZ = 12_500_000
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         sd_cs_n,
    output wire        sd_sclk,
    output wire        sd_mosi,
    input  wire        sd_miso,

    input  wire        read_req,
    input  wire [31:0] read_lba,
    output reg         ready,
    output reg         read_busy,
    output reg         read_done,
    output reg         data_valid,
    output reg  [8:0]  data_index,
    output reg  [7:0]  data_byte,

    output reg         init_done,
    output reg         init_ok,
    output reg         card_sdhc,
    output reg  [7:0]  error_code
);
    reg        spi_start;
    reg [7:0]  spi_tx;
    wire [7:0] spi_rx;
    wire       spi_busy;
    wire       spi_done;
    reg        fast_mode;

    sd_spi_byte_master #(
        .CLK_HZ(CLK_HZ),
        .INIT_SPI_HZ(INIT_SPI_HZ),
        .DATA_SPI_HZ(DATA_SPI_HZ)
    ) u_spi (
        .clk(clk),
        .rst_n(rst_n),
        .fast_mode(fast_mode),
        .start(spi_start),
        .tx_data(spi_tx),
        .rx_data(spi_rx),
        .busy(spi_busy),
        .done(spi_done),
        .sclk(sd_sclk),
        .mosi(sd_mosi),
        .miso(sd_miso)
    );

    localparam [7:0]
        ST_POWER_WAIT   = 8'd0,
        ST_DUMMY_CLOCKS = 8'd1,
        ST_CMD_SEND     = 8'd2,
        ST_CMD_RESP     = 8'd3,
        ST_CMD_EXTRA    = 8'd4,
        ST_GAP          = 8'd5,
        ST_CMD0_SETUP   = 8'd10,
        ST_CMD0_CHECK   = 8'd11,
        ST_CMD8_SETUP   = 8'd12,
        ST_CMD8_CHECK   = 8'd13,
        ST_CMD55_SETUP  = 8'd14,
        ST_CMD55_CHECK  = 8'd15,
        ST_CMD41_SETUP  = 8'd16,
        ST_CMD41_CHECK  = 8'd17,
        ST_CMD58_SETUP  = 8'd18,
        ST_CMD58_CHECK  = 8'd19,
        ST_CMD16_SETUP  = 8'd20,
        ST_CMD16_CHECK  = 8'd21,
        ST_IDLE         = 8'd22,
        ST_CMD17_SETUP  = 8'd23,
        ST_CMD17_CHECK  = 8'd24,
        ST_WAIT_TOKEN   = 8'd25,
        ST_READ_DATA    = 8'd26,
        ST_READ_CRC     = 8'd27,
        ST_READ_COMPLETE= 8'd28,
        ST_ERROR        = 8'd29;

    localparam integer POWER_WAIT_CYCLES = CLK_HZ / 50; // 20 ms

    reg [7:0]  state;
    reg [7:0]  resume_state;
    reg [31:0] power_count;
    reg [3:0]  dummy_count;
    reg        byte_wait;

    reg [5:0]  cmd_index;
    reg [31:0] cmd_arg;
    reg [7:0]  cmd_crc;
    reg [2:0]  cmd_pos;
    reg [2:0]  cmd_extra_len;
    reg [2:0]  extra_count;
    reg [31:0] extra_response;
    reg [7:0]  cmd_return_state;
    reg [7:0]  r1_response;
    reg [5:0]  response_count;

    reg        card_v2;
    reg [3:0]  cmd0_retry;
    reg [13:0] acmd41_retry;
    reg [19:0] token_count;
    reg [9:0]  sector_byte_count;
    reg        crc_count;
    reg [31:0] requested_lba;

    function [7:0] command_byte;
        input [2:0] position;
        begin
            case (position)
                3'd0: command_byte = 8'hFF;
                3'd1: command_byte = {2'b01, cmd_index};
                3'd2: command_byte = cmd_arg[31:24];
                3'd3: command_byte = cmd_arg[23:16];
                3'd4: command_byte = cmd_arg[15:8];
                3'd5: command_byte = cmd_arg[7:0];
                default: command_byte = cmd_crc;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_POWER_WAIT;
            resume_state      <= ST_POWER_WAIT;
            power_count       <= 32'd0;
            dummy_count       <= 4'd0;
            byte_wait         <= 1'b0;
            spi_start         <= 1'b0;
            spi_tx            <= 8'hFF;
            fast_mode         <= 1'b0;
            sd_cs_n           <= 1'b1;
            cmd_index         <= 6'd0;
            cmd_arg           <= 32'd0;
            cmd_crc           <= 8'h01;
            cmd_pos           <= 3'd0;
            cmd_extra_len     <= 3'd0;
            extra_count       <= 3'd0;
            extra_response    <= 32'd0;
            cmd_return_state  <= ST_POWER_WAIT;
            r1_response       <= 8'hFF;
            response_count    <= 6'd0;
            card_v2           <= 1'b0;
            cmd0_retry        <= 4'd0;
            acmd41_retry      <= 14'd0;
            token_count       <= 20'd0;
            sector_byte_count <= 10'd0;
            crc_count         <= 1'b0;
            requested_lba     <= 32'd0;
            ready             <= 1'b0;
            read_busy         <= 1'b0;
            read_done         <= 1'b0;
            data_valid        <= 1'b0;
            data_index        <= 9'd0;
            data_byte         <= 8'd0;
            init_done         <= 1'b0;
            init_ok           <= 1'b0;
            card_sdhc         <= 1'b0;
            error_code        <= 8'h00;
        end else begin
            spi_start  <= 1'b0;
            read_done  <= 1'b0;
            data_valid <= 1'b0;

            case (state)
                ST_POWER_WAIT: begin
                    sd_cs_n  <= 1'b1;
                    ready    <= 1'b0;
                    if (power_count >= POWER_WAIT_CYCLES-1) begin
                        power_count <= 32'd0;
                        dummy_count <= 4'd0;
                        state       <= ST_DUMMY_CLOCKS;
                    end else begin
                        power_count <= power_count + 1'b1;
                    end
                end

                ST_DUMMY_CLOCKS: begin
                    sd_cs_n <= 1'b1;
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (dummy_count == 4'd9) begin
                            dummy_count <= 4'd0;
                            state       <= ST_CMD0_SETUP;
                        end else begin
                            dummy_count <= dummy_count + 1'b1;
                        end
                    end
                end

                ST_CMD_SEND: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= command_byte(cmd_pos);
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (cmd_pos == 3'd6) begin
                            response_count <= 6'd0;
                            state          <= ST_CMD_RESP;
                        end else begin
                            cmd_pos <= cmd_pos + 1'b1;
                        end
                    end
                end

                ST_CMD_RESP: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (!spi_rx[7]) begin
                            r1_response <= spi_rx;
                            if (cmd_extra_len != 0) begin
                                extra_count    <= 3'd0;
                                extra_response <= 32'd0;
                                state          <= ST_CMD_EXTRA;
                            end else begin
                                state <= cmd_return_state;
                            end
                        end else if (response_count == 6'd63) begin
                            r1_response <= 8'hFF;
                            state       <= cmd_return_state;
                        end else begin
                            response_count <= response_count + 1'b1;
                        end
                    end
                end

                ST_CMD_EXTRA: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait      <= 1'b0;
                        extra_response <= {extra_response[23:0], spi_rx};
                        if (extra_count == cmd_extra_len-1'b1)
                            state <= cmd_return_state;
                        else
                            extra_count <= extra_count + 1'b1;
                    end
                end

                ST_GAP: begin
                    sd_cs_n <= 1'b1;
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        state     <= resume_state;
                    end
                end

                ST_CMD0_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd0;
                    cmd_arg          <= 32'h0000_0000;
                    cmd_crc          <= 8'h95;
                    cmd_extra_len    <= 3'd0;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD0_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD0_CHECK: begin
                    sd_cs_n <= 1'b1;
                    if (r1_response == 8'h01) begin
                        resume_state <= ST_CMD8_SETUP;
                        state        <= ST_GAP;
                    end else if (cmd0_retry != 4'd7) begin
                        cmd0_retry   <= cmd0_retry + 1'b1;
                        resume_state <= ST_CMD0_SETUP;
                        state        <= ST_GAP;
                    end else begin
                        init_done  <= 1'b1;
                        error_code <= 8'h01;
                        state      <= ST_ERROR;
                    end
                end

                ST_CMD8_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd8;
                    cmd_arg          <= 32'h0000_01AA;
                    cmd_crc          <= 8'h87;
                    cmd_extra_len    <= 3'd4;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD8_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD8_CHECK: begin
                    sd_cs_n <= 1'b1;
                    if ((r1_response == 8'h01) &&
                        (extra_response[11:0] == 12'h1AA)) begin
                        card_v2      <= 1'b1;
                        resume_state <= ST_CMD55_SETUP;
                        state        <= ST_GAP;
                    end else if (r1_response == 8'h05) begin
                        card_v2      <= 1'b0;
                        resume_state <= ST_CMD55_SETUP;
                        state        <= ST_GAP;
                    end else begin
                        init_done  <= 1'b1;
                        error_code <= 8'h02;
                        state      <= ST_ERROR;
                    end
                end

                ST_CMD55_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd55;
                    cmd_arg          <= 32'h0000_0000;
                    cmd_crc          <= 8'h01;
                    cmd_extra_len    <= 3'd0;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD55_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD55_CHECK: begin
                    sd_cs_n <= 1'b1;
                    if ((r1_response == 8'h01) ||
                        (r1_response == 8'h00)) begin
                        resume_state <= ST_CMD41_SETUP;
                        state        <= ST_GAP;
                    end else begin
                        init_done  <= 1'b1;
                        error_code <= 8'h03;
                        state      <= ST_ERROR;
                    end
                end

                ST_CMD41_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd41;
                    cmd_arg          <= card_v2 ? 32'h4000_0000 : 32'h0000_0000;
                    cmd_crc          <= 8'h01;
                    cmd_extra_len    <= 3'd0;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD41_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD41_CHECK: begin
                    sd_cs_n <= 1'b1;
                    if (r1_response == 8'h00) begin
                        resume_state <= card_v2 ? ST_CMD58_SETUP : ST_CMD16_SETUP;
                        state        <= ST_GAP;
                    end else if ((r1_response == 8'h01) &&
                                 (acmd41_retry != 14'd8191)) begin
                        acmd41_retry <= acmd41_retry + 1'b1;
                        resume_state <= ST_CMD55_SETUP;
                        state        <= ST_GAP;
                    end else begin
                        init_done  <= 1'b1;
                        error_code <= 8'h03;
                        state      <= ST_ERROR;
                    end
                end

                ST_CMD58_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd58;
                    cmd_arg          <= 32'h0000_0000;
                    cmd_crc          <= 8'h01;
                    cmd_extra_len    <= 3'd4;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD58_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD58_CHECK: begin
                    sd_cs_n <= 1'b1;
                    if (r1_response == 8'h00) begin
                        card_sdhc <= extra_response[30];
                        if (extra_response[30]) begin
                            init_done    <= 1'b1;
                            init_ok      <= 1'b1;
                            fast_mode    <= 1'b1;
                            resume_state <= ST_IDLE;
                        end else begin
                            resume_state <= ST_CMD16_SETUP;
                        end
                        state <= ST_GAP;
                    end else begin
                        init_done  <= 1'b1;
                        error_code <= 8'h04;
                        state      <= ST_ERROR;
                    end
                end

                ST_CMD16_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd16;
                    cmd_arg          <= 32'd512;
                    cmd_crc          <= 8'h01;
                    cmd_extra_len    <= 3'd0;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD16_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD16_CHECK: begin
                    sd_cs_n <= 1'b1;
                    if (r1_response == 8'h00) begin
                        card_sdhc   <= 1'b0;
                        init_done   <= 1'b1;
                        init_ok     <= 1'b1;
                        fast_mode   <= 1'b1;
                        resume_state<= ST_IDLE;
                        state       <= ST_GAP;
                    end else begin
                        init_done  <= 1'b1;
                        error_code <= 8'h05;
                        state      <= ST_ERROR;
                    end
                end

                ST_IDLE: begin
                    sd_cs_n  <= 1'b1;
                    ready    <= 1'b1;
                    read_busy<= 1'b0;
                    if (read_req) begin
                        requested_lba <= read_lba;
                        ready         <= 1'b0;
                        read_busy     <= 1'b1;
                        state         <= ST_CMD17_SETUP;
                    end
                end

                ST_CMD17_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd17;
                    cmd_arg          <= card_sdhc ? requested_lba :
                                                      (requested_lba << 9);
                    cmd_crc          <= 8'h01;
                    cmd_extra_len    <= 3'd0;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD17_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD17_CHECK: begin
                    if (r1_response == 8'h00) begin
                        token_count <= 20'd0;
                        state       <= ST_WAIT_TOKEN;
                    end else begin
                        sd_cs_n    <= 1'b1;
                        read_busy  <= 1'b0;
                        error_code <= 8'h06;
                        state      <= ST_ERROR;
                    end
                end

                ST_WAIT_TOKEN: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (spi_rx == 8'hFE) begin
                            sector_byte_count <= 10'd0;
                            state             <= ST_READ_DATA;
                        end else if (token_count == 20'hFFFFF) begin
                            sd_cs_n    <= 1'b1;
                            read_busy  <= 1'b0;
                            error_code <= 8'h07;
                            state      <= ST_ERROR;
                        end else begin
                            token_count <= token_count + 1'b1;
                        end
                    end
                end

                ST_READ_DATA: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait  <= 1'b0;
                        data_valid <= 1'b1;
                        data_index <= sector_byte_count[8:0];
                        data_byte  <= spi_rx;
                        if (sector_byte_count == 10'd511) begin
                            crc_count <= 1'b0;
                            state     <= ST_READ_CRC;
                        end else begin
                            sector_byte_count <= sector_byte_count + 1'b1;
                        end
                    end
                end

                ST_READ_CRC: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (crc_count) begin
                            sd_cs_n      <= 1'b1;
                            resume_state <= ST_READ_COMPLETE;
                            state        <= ST_GAP;
                        end else begin
                            crc_count <= 1'b1;
                        end
                    end
                end

                ST_READ_COMPLETE: begin
                    read_done <= 1'b1;
                    read_busy <= 1'b0;
                    state     <= ST_IDLE;
                end

                ST_ERROR: begin
                    sd_cs_n   <= 1'b1;
                    ready     <= 1'b0;
                    read_busy <= 1'b0;
                end

                default: state <= ST_ERROR;
            endcase
        end
    end
endmodule

`default_nettype wire
