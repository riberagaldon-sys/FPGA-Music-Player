`timescale 1ns / 1ps
`default_nettype none

// SD/TF card bring-up in SPI mode.
//
// Sequence:
//   1. Supply >= 80 clocks with CS high.
//   2. CMD0, CMD8, ACMD41, CMD58 (and CMD16 for SDSC).
//   3. CMD17 reads logical sector 0.
//   4. Check the standard 0x55AA boot-sector/MBR signature.
//
// The interface deliberately remains at 400 kHz for this diagnostic stage.
// Once this test passes, the same pins can be used by the high-speed streaming
// reader without involving the QSPI Flash.
module sd_spi_sector0_test #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer SPI_HZ = 400_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       card_detect_n,

    output reg        sd_cs_n,
    output wire       sd_sclk,
    output wire       sd_mosi,
    input  wire       sd_miso,

    output wire       card_present,
    output reg        init_done,
    output reg        init_ok,
    output reg        read_done,
    output reg        read_ok,
    output reg        card_sdhc,
    output reg  [7:0] error_code
);
    // Synchronize the active-low mechanical card-detect signal.
    reg cd_meta;
    reg cd_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cd_meta <= 1'b1;
            cd_sync <= 1'b1;
        end else begin
            cd_meta <= card_detect_n;
            cd_sync <= cd_meta;
        end
    end
    assign card_present = ~cd_sync;

    // Existing project byte-wide SPI master. SD uses SPI mode 0.
    reg        spi_start;
    reg  [7:0] spi_tx;
    wire [7:0] spi_rx;
    wire       spi_busy;
    wire       spi_done;
    wire       spi_rst_n = rst_n & card_present;

    spi_byte_master #(
        .CLK_HZ(CLK_HZ),
        .SPI_HZ(SPI_HZ)
    ) u_spi (
        .clk(clk),
        .rst_n(spi_rst_n),
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
        ST_WAIT_CARD    = 8'd0,
        ST_POWER_WAIT   = 8'd1,
        ST_DUMMY_CLOCKS = 8'd2,
        ST_CMD_SEND     = 8'd3,
        ST_CMD_RESP     = 8'd4,
        ST_CMD_EXTRA    = 8'd5,
        ST_GAP          = 8'd6,
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
        ST_CMD17_SETUP  = 8'd22,
        ST_CMD17_CHECK  = 8'd23,
        ST_WAIT_TOKEN   = 8'd24,
        ST_READ_DATA    = 8'd25,
        ST_READ_CRC     = 8'd26,
        ST_FINISH       = 8'd27,
        ST_ERROR        = 8'd28;

    localparam integer POWER_WAIT_CYCLES = CLK_HZ / 50; // 20 ms

    reg [7:0]  state;
    reg [7:0]  resume_state;
    reg [31:0] power_count;
    reg [3:0]  dummy_count;
    reg        byte_wait;

    // Generic command sequencer registers.
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
    reg [15:0] token_count;
    reg [9:0]  data_count;
    reg        crc_count;
    reg [7:0]  signature_510;
    reg [7:0]  signature_511;

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
            state             <= ST_WAIT_CARD;
            resume_state      <= ST_WAIT_CARD;
            power_count       <= 32'd0;
            dummy_count       <= 4'd0;
            byte_wait         <= 1'b0;
            spi_start         <= 1'b0;
            spi_tx            <= 8'hFF;
            sd_cs_n           <= 1'b1;
            cmd_index         <= 6'd0;
            cmd_arg           <= 32'd0;
            cmd_crc           <= 8'h01;
            cmd_pos           <= 3'd0;
            cmd_extra_len     <= 3'd0;
            extra_count       <= 3'd0;
            extra_response    <= 32'd0;
            cmd_return_state  <= ST_WAIT_CARD;
            r1_response       <= 8'hFF;
            response_count    <= 6'd0;
            card_v2           <= 1'b0;
            cmd0_retry        <= 4'd0;
            acmd41_retry      <= 14'd0;
            token_count       <= 16'd0;
            data_count        <= 10'd0;
            crc_count         <= 1'b0;
            signature_510     <= 8'd0;
            signature_511     <= 8'd0;
            init_done         <= 1'b0;
            init_ok           <= 1'b0;
            read_done         <= 1'b0;
            read_ok           <= 1'b0;
            card_sdhc         <= 1'b0;
            error_code        <= 8'h00;
        end else begin
            spi_start <= 1'b0;

            // Removing the card returns the complete tester to a known state.
            if (!card_present) begin
                state            <= ST_WAIT_CARD;
                resume_state     <= ST_WAIT_CARD;
                power_count      <= 32'd0;
                dummy_count      <= 4'd0;
                byte_wait        <= 1'b0;
                sd_cs_n          <= 1'b1;
                cmd0_retry       <= 4'd0;
                acmd41_retry     <= 14'd0;
                init_done        <= 1'b0;
                init_ok          <= 1'b0;
                read_done        <= 1'b0;
                read_ok          <= 1'b0;
                card_sdhc        <= 1'b0;
                error_code       <= 8'h00;
            end else begin
                case (state)
                    ST_WAIT_CARD: begin
                        sd_cs_n     <= 1'b1;
                        power_count <= 32'd0;
                        state       <= ST_POWER_WAIT;
                    end

                    ST_POWER_WAIT: begin
                        sd_cs_n <= 1'b1;
                        if (power_count >= POWER_WAIT_CYCLES-1) begin
                            power_count <= 32'd0;
                            dummy_count <= 4'd0;
                            byte_wait   <= 1'b0;
                            state       <= ST_DUMMY_CLOCKS;
                        end else begin
                            power_count <= power_count + 1'b1;
                        end
                    end

                    // Ten 0xFF transfers = 80 clocks while CS remains high.
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

                    // Generic command sender. Position zero supplies one
                    // leading 0xFF byte after CS is asserted.
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

                    // An R1 response is the first byte with bit 7 cleared.
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
                            end else if (response_count == 6'd31) begin
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
                            if (extra_count == cmd_extra_len-1'b1) begin
                                state <= cmd_return_state;
                            end else begin
                                extra_count <= extra_count + 1'b1;
                            end
                        end
                    end

                    // Deselect and provide the mandatory trailing clocks.
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
                            cmd0_retry   <= 4'd0;
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
                            card_v2     <= 1'b1;
                            resume_state <= ST_CMD55_SETUP;
                            state        <= ST_GAP;
                        end else if (r1_response == 8'h05) begin
                            // Version-1 SDSC cards legally reject CMD8.
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
                            acmd41_retry <= 14'd0;
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
                                init_done   <= 1'b1;
                                init_ok     <= 1'b1;
                                resume_state <= ST_CMD17_SETUP;
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
                            init_done    <= 1'b1;
                            init_ok      <= 1'b1;
                            card_sdhc    <= 1'b0;
                            resume_state <= ST_CMD17_SETUP;
                            state        <= ST_GAP;
                        end else begin
                            init_done  <= 1'b1;
                            error_code <= 8'h05;
                            state      <= ST_ERROR;
                        end
                    end

                    ST_CMD17_SETUP: begin
                        sd_cs_n          <= 1'b0;
                        cmd_index        <= 6'd17;
                        cmd_arg          <= 32'h0000_0000; // sector zero
                        cmd_crc          <= 8'h01;
                        cmd_extra_len    <= 3'd0;
                        cmd_pos          <= 3'd0;
                        cmd_return_state <= ST_CMD17_CHECK;
                        state            <= ST_CMD_SEND;
                    end

                    ST_CMD17_CHECK: begin
                        if (r1_response == 8'h00) begin
                            token_count <= 16'd0;
                            state       <= ST_WAIT_TOKEN;
                        end else begin
                            sd_cs_n    <= 1'b1;
                            read_done  <= 1'b1;
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
                                data_count    <= 10'd0;
                                signature_510 <= 8'd0;
                                signature_511 <= 8'd0;
                                state         <= ST_READ_DATA;
                            end else if (token_count == 16'hFFFF) begin
                                sd_cs_n    <= 1'b1;
                                read_done  <= 1'b1;
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
                            byte_wait <= 1'b0;
                            if (data_count == 10'd510)
                                signature_510 <= spi_rx;
                            if (data_count == 10'd511) begin
                                signature_511 <= spi_rx;
                                crc_count     <= 1'b0;
                                state         <= ST_READ_CRC;
                            end else begin
                                data_count <= data_count + 1'b1;
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
                                sd_cs_n     <= 1'b1;
                                resume_state <= ST_FINISH;
                                state        <= ST_GAP;
                            end else begin
                                crc_count <= 1'b1;
                            end
                        end
                    end

                    ST_FINISH: begin
                        read_done <= 1'b1;
                        if ((signature_510 == 8'h55) &&
                            (signature_511 == 8'hAA)) begin
                            read_ok <= 1'b1;
                        end else begin
                            read_ok    <= 1'b0;
                            error_code <= 8'h08;
                        end
                        state <= (signature_510 == 8'h55 &&
                                  signature_511 == 8'hAA) ? ST_FINISH : ST_ERROR;
                    end

                    ST_ERROR: begin
                        sd_cs_n <= 1'b1;
                    end

                    default: state <= ST_WAIT_CARD;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
