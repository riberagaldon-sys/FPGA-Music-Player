`timescale 1ns / 1ps
`default_nettype none

// GX-BIDT XC7A200T Qt-interactive hybrid audio player:
//   * five legacy RAW songs plus ten runtime GXM1 songs from FAT32 SD
//   * one 10-second PCM excerpt from the independent 4-MiB user QSPI Flash
//   * synchronized 4-bit LCD1602 lyrics for every source
//   * 921600-baud Qt remote control and verified SD-slot upload
// Self-contained Design Source: add only this Verilog file and set
// top_sd_audio_lyrics_4bit_all_in_one as the top module.
// SD root files: SONG.RAW, BEAUTY.RAW, DIE4YOU.RAW, PAYPHONE.RAW,
// and STARBOY.RAW (44.1 kHz, signed 16-bit LE stereo PCM).
// KEY0: previous SD song.  KEY1: next SD song (tracks 0..14).
// KEY2: toggle SD/QSPI mode.
// KEY3: copy the first 10.000 seconds of SONG.RAW plus its timed lyrics
//       from SD/FPGA into QSPI, with readback verification.
// All four core-board keys are active low. Legacy lyrics are embedded; GXM
// lyrics arrive inside USRxx.GXM. No .mem or .lrc Design Source is required.


// Hybrid SD-card/QSPI PCM player for GX-BIDT + XC7A200T + ES8388.
//
// SD root files are selected with core-board KEY0/KEY1.  QSPI stores a
// 256-byte header at 0x000000, five timed lyric records at 0x000100, and
// 1,764,000 audio bytes at 0x010000. The QSPI player reads both audio and
// lyric bytes back from Flash. Total address span is safely below 4 MiB.
// Format: 44.1 kHz, signed 16-bit little-endian, stereo interleaved PCM.
// Byte order for every frame: L low, L high, R low, R high.


// Active-low pushbutton synchronizer, debounce filter and one-clock press pulse.
module sly4_button_press #(
    parameter integer CLK_HZ      = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst_n,
    input  wire button_n,
    output reg  press
);
    localparam integer DEBOUNCE_CYCLES =
        (CLK_HZ / 1000) * DEBOUNCE_MS;

    (* ASYNC_REG = "TRUE" *) reg button_meta;
    (* ASYNC_REG = "TRUE" *) reg button_sync;
    reg stable_n;
    reg [21:0] debounce_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            button_meta   <= 1'b1;
            button_sync   <= 1'b1;
            stable_n      <= 1'b1;
            debounce_count <= 22'd0;
            press         <= 1'b0;
        end else begin
            button_meta <= button_n;
            button_sync <= button_meta;
            press       <= 1'b0;

            if (button_sync == stable_n) begin
                debounce_count <= 22'd0;
            end else if (debounce_count == DEBOUNCE_CYCLES-1) begin
                if (stable_n && !button_sync)
                    press <= 1'b1;
                stable_n       <= button_sync;
                debounce_count <= 22'd0;
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end
endmodule


// Read-only mode-0 SPI streamer for the independent GD25Q32 user Flash.
// It validates a small raw-PCM header at address 0, skips the reserved area,
// then exposes the payload at BASE_ADDR through a valid/ready byte interface.
module sly4_qspi_pcm_streamer #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer SPI_HZ = 5_000_000,
    parameter [23:0]  BASE_ADDR = 24'h010000,
    parameter [31:0]  DATA_BYTES = 32'd1_764_000,
    parameter [23:0]  LYRIC_ADDR = 24'h000100,
    parameter [15:0]  LYRIC_BYTES = 16'd180
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    output reg         spi_cs_n,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,

    output reg  [7:0]  data,
    output reg         valid,
    input  wire        ready,
    output reg         header_done,
    output reg         header_ok,
    output reg         eof,
    output reg  [31:0] bytes_sent,
    output reg  [7:0]  error_code,

    output reg         lyric_byte_valid,
    output reg  [7:0]  lyric_byte_index,
    output reg  [7:0]  lyric_byte,
    output reg         lyric_load_done
);
    reg        spi_start;
    reg [7:0]  spi_tx;
    wire [7:0] spi_rx;
    wire       spi_busy;
    wire       spi_done;

    // The existing byte master is also suitable for ordinary mode-0 Flash.
    // Both selectable rates are set to 5 MHz, so fast_mode is constant.
    sly4_sd_spi_byte_master #(
        .CLK_HZ(CLK_HZ),
        .INIT_SPI_HZ(SPI_HZ),
        .DATA_SPI_HZ(SPI_HZ)
    ) u_flash_spi_byte (
        .clk(clk),
        .rst_n(rst_n),
        .fast_mode(1'b1),
        .start(spi_start),
        .tx_data(spi_tx),
        .rx_data(spi_rx),
        .busy(spi_busy),
        .done(spi_done),
        .sclk(spi_sclk),
        .mosi(spi_mosi),
        .miso(spi_miso)
    );

    localparam [2:0]
        ST_IDLE  = 3'd0,
        ST_CMD   = 3'd1,
        ST_READ  = 3'd2,
        ST_DONE  = 3'd3,
        ST_ERROR = 3'd4;

    reg [2:0]  state;
    reg [2:0]  command_index;
    reg        byte_wait;
    reg [23:0] read_addr;
    reg [31:0] payload_count;
    reg        header_error;

    // Version-2 GXRP header. Bytes 0..15 describe PCM; bytes 16..35
    // describe the persistent lyric records stored in QSPI.
    //   0..3  = "GXRP"
    //   4..7  = payload length, little endian
    //   8..11 = sample rate 44100, little endian
    //   12    = channel count 2
    //   13    = sample width 16 bits
    //   14    = interleaved signed little-endian format (0)
    //   15    = header version 2 (persistent lyric metadata present)
    function [7:0] expected_header_byte;
        input [5:0] byte_index;
        begin
            case (byte_index)
                6'd0:  expected_header_byte = 8'h47; // G
                6'd1:  expected_header_byte = 8'h58; // X
                6'd2:  expected_header_byte = 8'h52; // R
                6'd3:  expected_header_byte = 8'h50; // P
                6'd4:  expected_header_byte = DATA_BYTES[7:0];
                6'd5:  expected_header_byte = DATA_BYTES[15:8];
                6'd6:  expected_header_byte = DATA_BYTES[23:16];
                6'd7:  expected_header_byte = DATA_BYTES[31:24];
                6'd8:  expected_header_byte = 8'h44;
                6'd9:  expected_header_byte = 8'hAC;
                6'd10: expected_header_byte = 8'h00;
                6'd11: expected_header_byte = 8'h00;
                6'd12: expected_header_byte = 8'h02;
                6'd13: expected_header_byte = 8'h10;
                6'd14: expected_header_byte = 8'h00;
                6'd15: expected_header_byte = 8'h02; // header version 2
                6'd16: expected_header_byte = 8'h10; // duration 10000 ms
                6'd17: expected_header_byte = 8'h27;
                6'd18: expected_header_byte = 8'h00;
                6'd19: expected_header_byte = 8'h00;
                6'd20: expected_header_byte = BASE_ADDR[7:0];
                6'd21: expected_header_byte = BASE_ADDR[15:8];
                6'd22: expected_header_byte = BASE_ADDR[23:16];
                6'd23: expected_header_byte = 8'h00;
                6'd24: expected_header_byte = LYRIC_ADDR[7:0];
                6'd25: expected_header_byte = LYRIC_ADDR[15:8];
                6'd26: expected_header_byte = LYRIC_ADDR[23:16];
                6'd27: expected_header_byte = 8'h00;
                6'd28: expected_header_byte = 8'd5;  // record count
                6'd29: expected_header_byte = 8'd36; // bytes per record
                6'd30: expected_header_byte = LYRIC_BYTES[7:0];
                6'd31: expected_header_byte = LYRIC_BYTES[15:8];
                6'd32: expected_header_byte = 8'h4C; // L
                6'd33: expected_header_byte = 8'h59; // Y
                6'd34: expected_header_byte = 8'h52; // R
                6'd35: expected_header_byte = 8'h31; // 1
                default: expected_header_byte = 8'hFF;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            command_index  <= 3'd0;
            byte_wait      <= 1'b0;
            read_addr      <= 24'd0;
            payload_count  <= 32'd0;
            header_error   <= 1'b0;
            spi_cs_n       <= 1'b1;
            spi_start      <= 1'b0;
            spi_tx         <= 8'hFF;
            data           <= 8'd0;
            valid          <= 1'b0;
            header_done    <= 1'b0;
            header_ok      <= 1'b0;
            eof            <= 1'b0;
            bytes_sent     <= 32'd0;
            error_code     <= 8'h00;
            lyric_byte_valid <= 1'b0;
            lyric_byte_index <= 8'd0;
            lyric_byte       <= 8'd0;
            lyric_load_done  <= 1'b0;
        end else begin
            spi_start        <= 1'b0;
            lyric_byte_valid <= 1'b0;

            if (!enable) begin
                state          <= ST_IDLE;
                command_index  <= 3'd0;
                byte_wait      <= 1'b0;
                read_addr      <= 24'd0;
                payload_count  <= 32'd0;
                header_error   <= 1'b0;
                spi_cs_n       <= 1'b1;
                valid          <= 1'b0;
                header_done    <= 1'b0;
                header_ok      <= 1'b0;
                eof            <= 1'b0;
                bytes_sent     <= 32'd0;
                error_code     <= 8'h00;
                lyric_byte_index <= 8'd0;
                lyric_byte       <= 8'd0;
                lyric_load_done  <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        spi_cs_n      <= 1'b0;
                        command_index <= 3'd0;
                        read_addr     <= 24'd0;
                        payload_count <= 32'd0;
                        bytes_sent    <= 32'd0;
                        lyric_byte_index <= 8'd0;
                        lyric_load_done  <= 1'b0;
                        state         <= ST_CMD;
                    end

                    ST_CMD: begin
                        if (!byte_wait && !spi_busy) begin
                            case (command_index)
                                3'd0: spi_tx <= 8'h03;
                                3'd1: spi_tx <= 8'h00;
                                3'd2: spi_tx <= 8'h00;
                                default: spi_tx <= 8'h00;
                            endcase
                            spi_start <= 1'b1;
                            byte_wait <= 1'b1;
                        end
                        if (spi_done && byte_wait) begin
                            byte_wait <= 1'b0;
                            if (command_index == 3'd3) begin
                                command_index <= 3'd0;
                                state         <= ST_READ;
                            end else begin
                                command_index <= command_index + 1'b1;
                            end
                        end
                    end

                    ST_READ: begin
                        // A payload byte remains valid until the downstream
                        // path has FIFO space.  Address/count advance once.
                        if (valid && ready) begin
                            valid      <= 1'b0;
                            bytes_sent <= payload_count + 1'b1;
                            if (payload_count == DATA_BYTES-1'b1) begin
                                eof      <= 1'b1;
                                spi_cs_n <= 1'b1;
                                state    <= ST_DONE;
                            end else begin
                                payload_count <= payload_count + 1'b1;
                                read_addr     <= read_addr + 1'b1;
                            end
                        end

                        if (!valid && !byte_wait && !spi_busy) begin
                            spi_tx    <= 8'hFF;
                            spi_start <= 1'b1;
                            byte_wait <= 1'b1;
                        end

                        if (spi_done && byte_wait) begin
                            byte_wait <= 1'b0;
                            if (read_addr < BASE_ADDR) begin
                                if (read_addr < 24'd36) begin
                                    if (spi_rx !=
                                        expected_header_byte(read_addr[5:0]))
                                        header_error <= 1'b1;

                                    if (read_addr == 24'd35) begin
                                        header_done <= 1'b1;
                                        if (header_error ||
                                            (spi_rx != expected_header_byte(6'd35))) begin
                                            header_ok  <= 1'b0;
                                            error_code <= 8'h01;
                                            spi_cs_n   <= 1'b1;
                                            state      <= ST_ERROR;
                                        end else begin
                                            header_ok <= 1'b1;
                                        end
                                    end
                                end

                                // Forward exactly the five 36-byte records
                                // read from QSPI to the QSPI lyric display.
                                if ((read_addr >= LYRIC_ADDR) &&
                                    (read_addr < LYRIC_ADDR + LYRIC_BYTES)) begin
                                    lyric_byte_valid <= 1'b1;
                                    lyric_byte_index <= read_addr - LYRIC_ADDR;
                                    lyric_byte       <= spi_rx;
                                    if (read_addr ==
                                        LYRIC_ADDR + LYRIC_BYTES - 1'b1)
                                        lyric_load_done <= 1'b1;
                                end
                                read_addr <= read_addr + 1'b1;
                            end else begin
                                data  <= spi_rx;
                                valid <= 1'b1;
                            end
                        end
                    end

                    ST_DONE: begin
                        spi_cs_n <= 1'b1;
                        valid    <= 1'b0;
                        eof      <= 1'b1;
                    end

                    default: begin
                        spi_cs_n <= 1'b1;
                        valid    <= 1'b0;
                        state    <= ST_ERROR;
                    end
                endcase
            end
        end
    end
endmodule


// Autonomous board-only SD -> QSPI writer used by core-board KEY3.
//
// Safety/order of operations:
//   1. Wait until FAT32 has found SONG.RAW and confirm it is long enough.
//   2. Erase QSPI blocks 0x000000 through LAST_ERASE_ADDR.
//   3. Buffer one 512-byte SD sector at a time, page-program the audio at
//      BASE_ADDR, and read back every programmed 256-byte page.
//   4. Program/verify the five timed lyric records at LYRIC_ADDR.
//   5. Program and verify the version-2 validity header at address zero LAST.
//
// Because the first erase invalidates the old header and the new header is
// written only after all audio verifies, loss of power cannot leave a partial
// copy that the QSPI player accepts as valid.
module sly4_sd_to_qspi_copier #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer SPI_HZ = 5_000_000,
    parameter [23:0]  BASE_ADDR = 24'h010000,
    parameter [31:0]  DATA_BYTES = 32'd1_764_000,
    parameter [23:0]  LYRIC_ADDR = 24'h000100,
    parameter [23:0]  LAST_ERASE_ADDR = 24'h1B0000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    input  wire        sd_byte_valid,
    input  wire [7:0]  sd_byte,
    input  wire        sd_init_ok,
    input  wire        file_found,
    input  wire [31:0] file_size,
    input  wire [7:0]  sd_error_code,
    input  wire [7:0]  fat_error_code,
    output wire        sector_allow,

    output reg         spi_cs_n,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,

    output reg         done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg  [3:0]  stage,
    output reg  [31:0] bytes_copied
);
    reg        spi_start;
    reg [7:0]  spi_tx;
    wire [7:0] spi_rx;
    wire       spi_busy;
    wire       spi_done;

    sly4_sd_spi_byte_master #(
        .CLK_HZ(CLK_HZ),
        .INIT_SPI_HZ(SPI_HZ),
        .DATA_SPI_HZ(SPI_HZ)
    ) u_flash_write_spi_byte (
        .clk(clk),
        .rst_n(rst_n),
        .fast_mode(1'b1),
        .start(spi_start),
        .tx_data(spi_tx),
        .rx_data(spi_rx),
        .busy(spi_busy),
        .done(spi_done),
        .sclk(spi_sclk),
        .mosi(spi_mosi),
        .miso(spi_miso)
    );

    localparam [4:0]
        ST_WAIT_FILE  = 5'd0,
        ST_ERASE_WREN = 5'd1,
        ST_ERASE_CMD  = 5'd2,
        ST_ERASE_POLL = 5'd3,
        ST_CAPTURE    = 5'd4,
        ST_PAGE_WREN  = 5'd5,
        ST_PAGE_CMD   = 5'd6,
        ST_PAGE_POLL  = 5'd7,
        ST_PAGE_READ  = 5'd8,
        ST_DONE       = 5'd9,
        ST_ERROR      = 5'd10;

    // Conservative limits: 10 seconds per 64-KiB erase and 500 ms per page.
    localparam [31:0] ERASE_TIMEOUT_CYCLES = CLK_HZ * 10;
    localparam [31:0] PAGE_TIMEOUT_CYCLES  = CLK_HZ / 2;

    reg [4:0]  state;
    reg        byte_wait;
    reg [3:0]  gap_count;
    reg [9:0]  sequence_index;
    reg [31:0] operation_timeout;
    reg [23:0] erase_addr;
    reg [23:0] next_flash_addr;
    reg [23:0] page_addr;
    reg [8:0]  page_base;
    reg [9:0]  buffer_count;
    reg [9:0]  buffer_length;
    reg [31:0] total_received;
    localparam [1:0]
        PAGE_AUDIO  = 2'd0,
        PAGE_LYRICS = 2'd1,
        PAGE_HEADER = 2'd2;
    reg [1:0]  page_kind;
    reg        verify_error;

    // Only one sector is required because FAT32 starts a new sector only
    // while sector_allow is high.  LUT RAM keeps block RAM free for audio.
    (* ram_style = "distributed" *) reg [7:0] sector_buffer [0:511];

    wire [9:0] page_byte_offset =
        (sequence_index >= 10'd4) ? sequence_index - 10'd4 : 10'd0;
    wire [9:0] page_buffer_index = {1'b0, page_base} + page_byte_offset;

    function [7:0] header_byte;
        input [7:0] byte_index;
        begin
            case (byte_index)
                8'd0:  header_byte = 8'h47; // G
                8'd1:  header_byte = 8'h58; // X
                8'd2:  header_byte = 8'h52; // R
                8'd3:  header_byte = 8'h50; // P
                8'd4:  header_byte = DATA_BYTES[7:0];
                8'd5:  header_byte = DATA_BYTES[15:8];
                8'd6:  header_byte = DATA_BYTES[23:16];
                8'd7:  header_byte = DATA_BYTES[31:24];
                8'd8:  header_byte = 8'h44; // 44100 little endian
                8'd9:  header_byte = 8'hAC;
                8'd10: header_byte = 8'h00;
                8'd11: header_byte = 8'h00;
                8'd12: header_byte = 8'h02; // stereo
                8'd13: header_byte = 8'h10; // signed 16-bit
                8'd14: header_byte = 8'h00; // LE interleaved
                8'd15: header_byte = 8'h02; // header version 2
                8'd16: header_byte = 8'h10; // duration = 10000 ms
                8'd17: header_byte = 8'h27;
                8'd18: header_byte = 8'h00;
                8'd19: header_byte = 8'h00;
                8'd20: header_byte = BASE_ADDR[7:0];
                8'd21: header_byte = BASE_ADDR[15:8];
                8'd22: header_byte = BASE_ADDR[23:16];
                8'd23: header_byte = 8'h00;
                8'd24: header_byte = LYRIC_ADDR[7:0];
                8'd25: header_byte = LYRIC_ADDR[15:8];
                8'd26: header_byte = LYRIC_ADDR[23:16];
                8'd27: header_byte = 8'h00;
                8'd28: header_byte = 8'd5;
                8'd29: header_byte = 8'd36;
                8'd30: header_byte = 8'hB4; // 180 lyric bytes
                8'd31: header_byte = 8'h00;
                8'd32: header_byte = 8'h4C; // L
                8'd33: header_byte = 8'h59; // Y
                8'd34: header_byte = 8'h52; // R
                8'd35: header_byte = 8'h31; // 1
                default: header_byte = 8'hFF;
            endcase
        end
    endfunction

    function [7:0] packed_char;
        input [127:0] packed_text;
        input [3:0]   char_index;
        begin
            case (char_index)
                4'd0:  packed_char = packed_text[127:120];
                4'd1:  packed_char = packed_text[119:112];
                4'd2:  packed_char = packed_text[111:104];
                4'd3:  packed_char = packed_text[103:96];
                4'd4:  packed_char = packed_text[95:88];
                4'd5:  packed_char = packed_text[87:80];
                4'd6:  packed_char = packed_text[79:72];
                4'd7:  packed_char = packed_text[71:64];
                4'd8:  packed_char = packed_text[63:56];
                4'd9:  packed_char = packed_text[55:48];
                4'd10: packed_char = packed_text[47:40];
                4'd11: packed_char = packed_text[39:32];
                4'd12: packed_char = packed_text[31:24];
                4'd13: packed_char = packed_text[23:16];
                4'd14: packed_char = packed_text[15:8];
                default: packed_char = packed_text[7:0];
            endcase
        end
    endfunction

    // Five records, each: uint32 little-endian start_ms + line1[16] +
    // line2[16]. These are programmed into QSPI and later read back by the
    // display path; they cover the complete 10-second QSPI excerpt.
    function [7:0] lyric_payload_byte;
        input [7:0] byte_index;
        reg [2:0]   record_index;
        reg [5:0]   record_offset;
        reg [31:0]  record_time;
        reg [127:0] record_line1;
        reg [127:0] record_line2;
        begin
            if (byte_index < 8'd36) begin
                record_index  = 3'd0;
                record_offset = byte_index;
            end else if (byte_index < 8'd72) begin
                record_index  = 3'd1;
                record_offset = byte_index - 8'd36;
            end else if (byte_index < 8'd108) begin
                record_index  = 3'd2;
                record_offset = byte_index - 8'd72;
            end else if (byte_index < 8'd144) begin
                record_index  = 3'd3;
                record_offset = byte_index - 8'd108;
            end else begin
                record_index  = 3'd4;
                record_offset = byte_index - 8'd144;
            end

            record_time  = 32'd0;
            record_line1 = "                ";
            record_line2 = "                ";
            case (record_index)
                3'd0: begin
                    record_time  = 32'd0;
                    record_line1 = "WE DON'T TALK...";
                    record_line2 = "K2 SWITCH TO SD ";
                end
                3'd1: begin
                    record_time  = 32'd720;
                    record_line1 = "We don't talk   ";
                    record_line2 = "anymore, we     ";
                end
                3'd2: begin
                    record_time  = 32'd3070;
                    record_line1 = "don't talk      ";
                    record_line2 = "anymore         ";
                end
                3'd3: begin
                    record_time  = 32'd5420;
                    record_line1 = "We don't talk   ";
                    record_line2 = "anymore, like we";
                end
                default: begin
                    record_time  = 32'd7865;
                    record_line1 = "used to do      ";
                    record_line2 = "                ";
                end
            endcase

            if (record_offset == 0)
                lyric_payload_byte = record_time[7:0];
            else if (record_offset == 1)
                lyric_payload_byte = record_time[15:8];
            else if (record_offset == 2)
                lyric_payload_byte = record_time[23:16];
            else if (record_offset == 3)
                lyric_payload_byte = record_time[31:24];
            else if (record_offset < 6'd20)
                lyric_payload_byte = packed_char(
                    record_line1, record_offset - 6'd4);
            else if (record_offset < 6'd36)
                lyric_payload_byte = packed_char(
                    record_line2, record_offset - 6'd20);
            else
                lyric_payload_byte = 8'hFF;
        end
    endfunction

    reg [7:0] selected_page_byte;
    always @* begin
        if (page_kind == PAGE_HEADER)
            selected_page_byte = header_byte(page_byte_offset[7:0]);
        else if (page_kind == PAGE_LYRICS)
            selected_page_byte = (page_byte_offset < 10'd180) ?
                                 lyric_payload_byte(page_byte_offset[7:0]) :
                                 8'hFF;
        else if (page_buffer_index < buffer_length)
            selected_page_byte = sector_buffer[page_buffer_index[8:0]];
        else
            selected_page_byte = 8'hFF;
    end
    wire [3:0] page_write_stage =
        (page_kind == PAGE_LYRICS) ? 4'd5 :
        (page_kind == PAGE_HEADER) ? 4'd6 : 4'd3;
    wire [3:0] page_verify_stage =
        (page_kind == PAGE_LYRICS) ? 4'd5 :
        (page_kind == PAGE_HEADER) ? 4'd6 : 4'd4;

    assign sector_allow = enable && (state == ST_CAPTURE) &&
                          !done && !error;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_WAIT_FILE;
            byte_wait         <= 1'b0;
            gap_count         <= 4'd0;
            sequence_index    <= 10'd0;
            operation_timeout <= 32'd0;
            erase_addr        <= 24'h000000;
            next_flash_addr   <= BASE_ADDR;
            page_addr         <= BASE_ADDR;
            page_base         <= 9'd0;
            buffer_count      <= 10'd0;
            buffer_length     <= 10'd0;
            total_received    <= 32'd0;
            page_kind         <= PAGE_AUDIO;
            verify_error      <= 1'b0;
            spi_cs_n          <= 1'b1;
            spi_start         <= 1'b0;
            spi_tx            <= 8'hFF;
            done              <= 1'b0;
            error             <= 1'b0;
            error_code        <= 8'h00;
            stage             <= 4'd0;
            bytes_copied      <= 32'd0;
        end else begin
            spi_start <= 1'b0;

            if (!enable) begin
                state             <= ST_WAIT_FILE;
                byte_wait         <= 1'b0;
                gap_count         <= 4'd0;
                sequence_index    <= 10'd0;
                operation_timeout <= 32'd0;
                erase_addr        <= 24'h000000;
                next_flash_addr   <= BASE_ADDR;
                page_addr         <= BASE_ADDR;
                page_base         <= 9'd0;
                buffer_count      <= 10'd0;
                buffer_length     <= 10'd0;
                total_received    <= 32'd0;
                page_kind         <= PAGE_AUDIO;
                verify_error      <= 1'b0;
                spi_cs_n          <= 1'b1;
                done              <= 1'b0;
                error             <= 1'b0;
                error_code        <= 8'h00;
                stage             <= 4'd0;
                bytes_copied      <= 32'd0;
            end else if (!done && !error && (sd_error_code != 8'h00)) begin
                spi_cs_n   <= 1'b1;
                error      <= 1'b1;
                error_code <= 8'h01;
                stage      <= 4'd8;
                state      <= ST_ERROR;
            end else if (!done && !error && (fat_error_code != 8'h00)) begin
                spi_cs_n   <= 1'b1;
                error      <= 1'b1;
                error_code <= 8'h02;
                stage      <= 4'd8;
                state      <= ST_ERROR;
            end else begin
                case (state)
                    ST_WAIT_FILE: begin
                        spi_cs_n <= 1'b1;
                        stage    <= 4'd2;
                        if (file_found) begin
                            if (file_size < DATA_BYTES) begin
                                error      <= 1'b1;
                                error_code <= 8'h03;
                                stage      <= 4'd8;
                                state      <= ST_ERROR;
                            end else begin
                                erase_addr     <= 24'h000000;
                                gap_count      <= 4'd0;
                                sequence_index <= 10'd0;
                                stage          <= 4'd1;
                                state          <= ST_ERASE_WREN;
                            end
                        end
                    end

                    // Write Enable (06h), one byte with its own CS window.
                    ST_ERASE_WREN: begin
                        stage <= 4'd1;
                        if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                spi_cs_n  <= 1'b0;
                                spi_tx    <= 8'h06;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait      <= 1'b0;
                                spi_cs_n       <= 1'b1;
                                gap_count      <= 4'd0;
                                sequence_index <= 10'd0;
                                state          <= ST_ERASE_CMD;
                            end
                        end
                    end

                    // 64-KiB Block Erase (D8h + 24-bit address).
                    ST_ERASE_CMD: begin
                        if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                case (sequence_index)
                                    10'd0: spi_tx <= 8'hD8;
                                    10'd1: spi_tx <= erase_addr[23:16];
                                    10'd2: spi_tx <= erase_addr[15:8];
                                    default: spi_tx <= erase_addr[7:0];
                                endcase
                                spi_cs_n  <= 1'b0;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait <= 1'b0;
                                if (sequence_index == 10'd3) begin
                                    spi_cs_n          <= 1'b1;
                                    gap_count         <= 4'd0;
                                    sequence_index    <= 10'd0;
                                    operation_timeout <= 32'd0;
                                    state             <= ST_ERASE_POLL;
                                end else begin
                                    sequence_index <= sequence_index + 1'b1;
                                end
                            end
                        end
                    end

                    // Read Status Register-1 (05h); bit 0 is WIP.
                    ST_ERASE_POLL: begin
                        operation_timeout <= operation_timeout + 1'b1;
                        if (operation_timeout >= ERASE_TIMEOUT_CYCLES-1'b1) begin
                            spi_cs_n   <= 1'b1;
                            error      <= 1'b1;
                            error_code <= 8'h05;
                            stage      <= 4'd8;
                            state      <= ST_ERROR;
                        end else if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                spi_tx    <= (sequence_index == 0) ?
                                             8'h05 : 8'hFF;
                                spi_cs_n  <= 1'b0;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait <= 1'b0;
                                if (sequence_index == 0) begin
                                    sequence_index <= 10'd1;
                                end else begin
                                    spi_cs_n       <= 1'b1;
                                    gap_count      <= 4'd0;
                                    sequence_index <= 10'd0;
                                    if (!spi_rx[0]) begin
                                        if (erase_addr == LAST_ERASE_ADDR) begin
                                            buffer_count    <= 10'd0;
                                            buffer_length   <= 10'd0;
                                            total_received  <= 32'd0;
                                            next_flash_addr <= BASE_ADDR;
                                            page_addr       <= BASE_ADDR;
                                            page_base       <= 9'd0;
                                            page_kind       <= PAGE_AUDIO;
                                            stage           <= 4'd3;
                                            state           <= ST_CAPTURE;
                                        end else begin
                                            erase_addr <= erase_addr + 24'h010000;
                                            stage      <= 4'd1;
                                            state      <= ST_ERASE_WREN;
                                        end
                                    end
                                end
                            end
                        end
                    end

                    // FAT32 supplies one complete sector only while this
                    // state asserts sector_allow.  The last required byte
                    // may be in the middle of the final SD sector.
                    ST_CAPTURE: begin
                        spi_cs_n <= 1'b1;
                        stage    <= 4'd3;
                        if (sd_byte_valid) begin
                            sector_buffer[buffer_count[8:0]] <= sd_byte;
                            total_received <= total_received + 1'b1;
                            if ((total_received == DATA_BYTES-1'b1) ||
                                (buffer_count == 10'd511)) begin
                                buffer_length  <= buffer_count + 1'b1;
                                page_addr      <= next_flash_addr;
                                page_base      <= 9'd0;
                                page_kind      <= PAGE_AUDIO;
                                sequence_index <= 10'd0;
                                gap_count      <= 4'd0;
                                stage          <= 4'd3;
                                state          <= ST_PAGE_WREN;
                            end else begin
                                buffer_count <= buffer_count + 1'b1;
                            end
                        end
                    end

                    // Write Enable before every 256-byte Page Program.
                    ST_PAGE_WREN: begin
                        stage <= page_write_stage;
                        if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                spi_cs_n  <= 1'b0;
                                spi_tx    <= 8'h06;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait      <= 1'b0;
                                spi_cs_n       <= 1'b1;
                                gap_count      <= 4'd0;
                                sequence_index <= 10'd0;
                                state          <= ST_PAGE_CMD;
                            end
                        end
                    end

                    // Page Program (02h + address + exactly 256 bytes).
                    ST_PAGE_CMD: begin
                        stage <= page_write_stage;
                        if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                case (sequence_index)
                                    10'd0: spi_tx <= 8'h02;
                                    10'd1: spi_tx <= page_addr[23:16];
                                    10'd2: spi_tx <= page_addr[15:8];
                                    10'd3: spi_tx <= page_addr[7:0];
                                    default: spi_tx <= selected_page_byte;
                                endcase
                                spi_cs_n  <= 1'b0;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait <= 1'b0;
                                if (sequence_index == 10'd259) begin
                                    spi_cs_n          <= 1'b1;
                                    gap_count         <= 4'd0;
                                    sequence_index    <= 10'd0;
                                    operation_timeout <= 32'd0;
                                    state             <= ST_PAGE_POLL;
                                end else begin
                                    sequence_index <= sequence_index + 1'b1;
                                end
                            end
                        end
                    end

                    // Wait for the Page Program WIP bit to clear.
                    ST_PAGE_POLL: begin
                        operation_timeout <= operation_timeout + 1'b1;
                        if (operation_timeout >= PAGE_TIMEOUT_CYCLES-1'b1) begin
                            spi_cs_n   <= 1'b1;
                            error      <= 1'b1;
                            error_code <= 8'h06;
                            stage      <= 4'd8;
                            state      <= ST_ERROR;
                        end else if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                spi_tx    <= (sequence_index == 0) ?
                                             8'h05 : 8'hFF;
                                spi_cs_n  <= 1'b0;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait <= 1'b0;
                                if (sequence_index == 0) begin
                                    sequence_index <= 10'd1;
                                end else begin
                                    spi_cs_n       <= 1'b1;
                                    gap_count      <= 4'd0;
                                    sequence_index <= 10'd0;
                                    if (!spi_rx[0]) begin
                                        verify_error <= 1'b0;
                                        stage <= page_verify_stage;
                                        state <= ST_PAGE_READ;
                                    end
                                end
                            end
                        end
                    end

                    // Normal Read (03h + address), then verify all 256 bytes.
                    ST_PAGE_READ: begin
                        stage <= page_verify_stage;
                        if (gap_count < 4'd7) begin
                            spi_cs_n  <= 1'b1;
                            gap_count <= gap_count + 1'b1;
                        end else begin
                            if (!byte_wait && !spi_busy) begin
                                case (sequence_index)
                                    10'd0: spi_tx <= 8'h03;
                                    10'd1: spi_tx <= page_addr[23:16];
                                    10'd2: spi_tx <= page_addr[15:8];
                                    10'd3: spi_tx <= page_addr[7:0];
                                    default: spi_tx <= 8'hFF;
                                endcase
                                spi_cs_n  <= 1'b0;
                                spi_start <= 1'b1;
                                byte_wait <= 1'b1;
                            end
                            if (spi_done && byte_wait) begin
                                byte_wait <= 1'b0;
                                if ((sequence_index >= 10'd4) &&
                                    (spi_rx != selected_page_byte))
                                    verify_error <= 1'b1;

                                if (sequence_index == 10'd259) begin
                                    spi_cs_n       <= 1'b1;
                                    gap_count      <= 4'd0;
                                    sequence_index <= 10'd0;
                                    if (verify_error ||
                                        (spi_rx != selected_page_byte)) begin
                                        error      <= 1'b1;
                                        error_code <= 8'h04;
                                        stage      <= 4'd8;
                                        state      <= ST_ERROR;
                                    end else if (page_kind == PAGE_HEADER) begin
                                        done  <= 1'b1;
                                        stage <= 4'd7;
                                        state <= ST_DONE;
                                    end else if ((page_kind == PAGE_AUDIO) &&
                                                 (page_base == 0) &&
                                                 (buffer_length > 10'd256)) begin
                                        page_base  <= 9'd256;
                                        page_addr  <= page_addr + 24'h000100;
                                        gap_count  <= 4'd0;
                                        stage      <= 4'd3;
                                        state      <= ST_PAGE_WREN;
                                    end else begin
                                        if (page_kind == PAGE_LYRICS) begin
                                            // The validity header is always
                                            // the final programmed page.
                                            page_kind      <= PAGE_HEADER;
                                            page_addr      <= 24'h000000;
                                            page_base      <= 9'd0;
                                            sequence_index <= 10'd0;
                                            gap_count      <= 4'd0;
                                            stage          <= 4'd6;
                                            state          <= ST_PAGE_WREN;
                                        end else if (total_received >=
                                                     DATA_BYTES) begin
                                            bytes_copied   <= total_received;
                                            page_kind      <= PAGE_LYRICS;
                                            page_addr      <= LYRIC_ADDR;
                                            page_base      <= 9'd0;
                                            sequence_index <= 10'd0;
                                            gap_count      <= 4'd0;
                                            stage          <= 4'd5;
                                            state          <= ST_PAGE_WREN;
                                        end else begin
                                            bytes_copied <= total_received;
                                            next_flash_addr <= next_flash_addr +
                                                               buffer_length;
                                            buffer_count  <= 10'd0;
                                            buffer_length <= 10'd0;
                                            page_base     <= 9'd0;
                                            stage         <= 4'd3;
                                            state         <= ST_CAPTURE;
                                        end
                                    end
                                end else begin
                                    sequence_index <= sequence_index + 1'b1;
                                end
                            end
                        end
                    end

                    ST_DONE: begin
                        spi_cs_n <= 1'b1;
                        done     <= 1'b1;
                        stage    <= 4'd7;
                    end

                    ST_ERROR: begin
                        spi_cs_n <= 1'b1;
                        error    <= 1'b1;
                        stage    <= 4'd8;
                    end

                    default: begin
                        spi_cs_n   <= 1'b1;
                        error      <= 1'b1;
                        error_code <= 8'h07;
                        stage      <= 4'd8;
                        state      <= ST_ERROR;
                    end
                endcase
            end
        end
    end

    // Kept in the interface so the LCD can distinguish SD initialization
    // from FAT root-directory searching while state is ST_WAIT_FILE.
    wire unused_sd_init_ok = sd_init_ok;
endmodule


// SDHC/SDSC SPI block device.
// Initializes the card at 400 kHz, accepts single-sector CMD17 reads and
// CMD24 writes at 12.5 MHz.  The 512-byte write buffer is filled before
// write_req is asserted; every successful operation finishes with one pulse.
module sly4_sd_spi_block_reader #(
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

    input  wire        write_req,
    input  wire [31:0] write_lba,
    input  wire        write_buffer_we,
    input  wire [8:0]  write_buffer_addr,
    input  wire [7:0]  write_buffer_data,
    output reg         write_busy,
    output reg         write_done,

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

    sly4_sd_spi_byte_master #(
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
        ST_ERROR        = 8'd29,
        ST_CMD24_SETUP  = 8'd30,
        ST_CMD24_CHECK  = 8'd31,
        ST_WRITE_TOKEN  = 8'd32,
        ST_WRITE_DATA   = 8'd33,
        ST_WRITE_CRC    = 8'd34,
        ST_WRITE_RESP   = 8'd35,
        ST_WRITE_BUSY   = 8'd36,
        ST_WRITE_COMPLETE=8'd37;

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
    reg        write_token_phase;
    reg [31:0] requested_lba;
    reg [7:0]  write_buffer [0:511];

    always @(posedge clk) begin
        if (write_buffer_we)
            write_buffer[write_buffer_addr] <= write_buffer_data;
    end

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
            write_token_phase <= 1'b0;
            requested_lba     <= 32'd0;
            ready             <= 1'b0;
            read_busy         <= 1'b0;
            read_done         <= 1'b0;
            write_busy        <= 1'b0;
            write_done        <= 1'b0;
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
            write_done <= 1'b0;
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
                    write_busy <= 1'b0;
                    if (write_req) begin
                        requested_lba <= write_lba;
                        ready         <= 1'b0;
                        write_busy    <= 1'b1;
                        state         <= ST_CMD24_SETUP;
                    end else if (read_req) begin
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

                ST_CMD24_SETUP: begin
                    sd_cs_n          <= 1'b0;
                    cmd_index        <= 6'd24;
                    cmd_arg          <= card_sdhc ? requested_lba :
                                                      (requested_lba << 9);
                    cmd_crc          <= 8'h01;
                    cmd_extra_len    <= 3'd0;
                    cmd_pos          <= 3'd0;
                    cmd_return_state <= ST_CMD24_CHECK;
                    state            <= ST_CMD_SEND;
                end

                ST_CMD24_CHECK: begin
                    if (r1_response == 8'h00) begin
                        sector_byte_count <= 10'd0;
                        write_token_phase <= 1'b0;
                        state             <= ST_WRITE_TOKEN;
                    end else begin
                        sd_cs_n    <= 1'b1;
                        write_busy <= 1'b0;
                        error_code <= 8'h08;
                        state      <= ST_ERROR;
                    end
                end

                ST_WRITE_TOKEN: begin
                    if (!byte_wait && !spi_busy) begin
                        // SD cards require at least one Nwr byte between the
                        // CMD24 response and the single-block data token.
                        spi_tx    <= write_token_phase ? 8'hFE : 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (!write_token_phase)
                            write_token_phase <= 1'b1;
                        else begin
                            write_token_phase <= 1'b0;
                            state             <= ST_WRITE_DATA;
                        end
                    end
                end

                ST_WRITE_DATA: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= write_buffer[sector_byte_count[8:0]];
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (sector_byte_count == 10'd511) begin
                            crc_count <= 1'b0;
                            state     <= ST_WRITE_CRC;
                        end else begin
                            sector_byte_count <= sector_byte_count + 1'b1;
                        end
                    end
                end

                ST_WRITE_CRC: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (crc_count) begin
                            response_count <= 6'd0;
                            state          <= ST_WRITE_RESP;
                        end else begin
                            crc_count <= 1'b1;
                        end
                    end
                end

                ST_WRITE_RESP: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if ((spi_rx & 8'h1F) == 8'h05) begin
                            token_count <= 20'd0;
                            state       <= ST_WRITE_BUSY;
                        end else if (response_count == 6'd63) begin
                            sd_cs_n    <= 1'b1;
                            write_busy <= 1'b0;
                            error_code <= 8'h09;
                            state      <= ST_ERROR;
                        end else begin
                            response_count <= response_count + 1'b1;
                        end
                    end
                end

                ST_WRITE_BUSY: begin
                    if (!byte_wait && !spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                        byte_wait <= 1'b1;
                    end
                    if (spi_done && byte_wait) begin
                        byte_wait <= 1'b0;
                        if (spi_rx == 8'hFF) begin
                            sd_cs_n      <= 1'b1;
                            resume_state <= ST_WRITE_COMPLETE;
                            state        <= ST_GAP;
                        end else if (token_count == 20'hFFFFF) begin
                            sd_cs_n    <= 1'b1;
                            write_busy <= 1'b0;
                            error_code <= 8'h0A;
                            state      <= ST_ERROR;
                        end else begin
                            token_count <= token_count + 1'b1;
                        end
                    end
                end

                ST_WRITE_COMPLETE: begin
                    write_done <= 1'b1;
                    write_busy <= 1'b0;
                    state      <= ST_IDLE;
                end

                ST_ERROR: begin
                    sd_cs_n   <= 1'b1;
                    ready     <= 1'b0;
                    read_busy <= 1'b0;
                    write_busy<= 1'b0;
                end

                default: state <= ST_ERROR;
            endcase
        end
    end
endmodule


// SPI mode-0 byte master with the two clock rates required by SD cards:
// <=400 kHz during card initialization and 12.5 MHz for sector streaming.
module sly4_sd_spi_byte_master #(
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


// FAT32 media streamer for one selected root-directory 8.3 file.
// Tracks 0..4 are the five legacy RAW files. Tracks 5..14 are
// USR00.GXM..USR09.GXM. GXM headers and timed LCD records are checked and
// removed from the PCM stream before bytes reach the audio FIFO.
//
// Supported layouts:
//   * FAT32 volume beginning directly at LBA 0
//   * MBR-partitioned card with the FAT32 volume in partition entry 0
//   * Fragmented files and multi-cluster root directories (FAT chain followed)
//
// Every RAW file must contain headerless, little-endian stereo PCM:
// left-low, left-high, right-low, right-high, repeated for every sample.
module sly4_fat32_song_raw_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  track_index,

    input  wire        sd_init_ok,
    input  wire [7:0]  sd_error_code,
    input  wire        block_ready,
    output reg         block_read_req,
    output reg  [31:0] block_read_lba,
    input  wire        block_data_valid,
    input  wire [8:0]  block_data_index,
    input  wire [7:0]  block_data_byte,
    input  wire        block_read_done,

    // Asserted only between sectors. It lets the audio FIFO reserve room for
    // all 128 stereo frames contained in the next 512-byte sector.
    input  wire        sector_allow,

    output reg         out_valid,
    output reg  [7:0]  out_byte,
    output reg         mount_done,
    output reg         file_found,
    output reg         playing,
    output reg         eof,
    output reg  [31:0] file_size,
    output reg  [31:0] bytes_sent,
    output reg  [7:0]  error_code,

    output reg          gxm_mode,
    output reg          gxm_header_done,
    output reg          gxm_header_ok,
    output reg  [127:0] gxm_title,
    output reg          gxm_lyric_valid,
    output reg  [13:0]  gxm_lyric_index,
    output reg  [7:0]   gxm_lyric_byte,
    output reg  [8:0]   gxm_lyric_count,
    output reg          gxm_lyrics_done,
    output reg          gxm_audio_crc_ok,

    output reg  [31:0]  selected_start_cluster,
    output wire [31:0]  fs_fat_start_lba,
    output wire [31:0]  fs_data_start_lba,
    output wire [7:0]   fs_sectors_per_cluster
);
    localparam [7:0]
        FS_WAIT_SD       = 8'd0,
        FS_LBA0_REQ      = 8'd1,
        FS_LBA0_WAIT     = 8'd2,
        FS_BOOT_REQ      = 8'd3,
        FS_BOOT_WAIT     = 8'd4,
        FS_MOUNT_COMPUTE = 8'd5,
        FS_ROOT_REQ      = 8'd6,
        FS_ROOT_WAIT     = 8'd7,
        FS_FAT_REQ       = 8'd8,
        FS_FAT_WAIT      = 8'd9,
        FS_FAT_EVAL      = 8'd10,
        FS_FILE_REQ      = 8'd11,
        FS_FILE_WAIT     = 8'd12,
        FS_FILE_NEXT     = 8'd13,
        FS_DONE          = 8'd14,
        FS_ERROR         = 8'd15,
        FS_GXM_HEADER_EVAL = 8'd16;

    reg [7:0] state;

    // Boot-sector and first MBR partition fields.
    reg [15:0] bpb_bytes_per_sector;
    reg [7:0]  bpb_sectors_per_cluster;
    reg [15:0] bpb_reserved_sectors;
    reg [7:0]  bpb_num_fats;
    reg [31:0] bpb_fat_size;
    reg [31:0] bpb_root_cluster;
    reg [31:0] partition_lba;
    reg [7:0]  signature_510;
    reg [7:0]  signature_511;

    reg [31:0] volume_start_lba;
    reg [31:0] fat_start_lba;
    reg [31:0] data_start_lba;
    reg [7:0]  sectors_per_cluster;

    // Directory scan fields.
    reg [31:0] current_cluster;
    reg [7:0]  cluster_sector;
    reg        entry_match;
    reg [7:0]  entry_first_byte;
    reg [7:0]  entry_attribute;
    reg [15:0] entry_cluster_high;
    reg [15:0] entry_cluster_low;
    reg [31:0] entry_file_size;
    reg        directory_end_seen;
    reg        directory_match_found;
    reg [31:0] found_cluster;
    reg [31:0] found_size;

    // FAT lookup fields. fat_for_file=0 follows the root directory chain;
    // fat_for_file=1 follows the selected RAW file's cluster chain.
    reg        fat_for_file;
    reg [8:0]  fat_entry_offset;
    reg [7:0]  fat_byte0;
    reg [7:0]  fat_byte1;
    reg [7:0]  fat_byte2;
    reg [7:0]  fat_byte3;
    wire [31:0] next_cluster =
        ({fat_byte3, fat_byte2, fat_byte1, fat_byte0} & 32'h0FFF_FFFF);

    reg [31:0] bytes_remaining;

    // GXM1 header fields and streaming CRC state.
    reg [31:0] gxm_magic;
    reg [15:0] gxm_version;
    reg [15:0] gxm_header_bytes;
    reg [31:0] gxm_audio_offset;
    reg [31:0] gxm_audio_bytes;
    reg [31:0] gxm_audio_crc_expected;
    reg [31:0] gxm_sample_rate;
    reg [15:0] gxm_channels;
    reg [15:0] gxm_bits_per_sample;
    reg [31:0] gxm_lyric_offset;
    reg [15:0] gxm_lyric_count_field;
    reg [15:0] gxm_record_bytes;
    reg [31:0] gxm_lyric_crc_expected;
    reg [31:0] gxm_header_crc_expected;
    reg [31:0] gxm_header_crc_state;
    reg [31:0] gxm_lyric_crc_state;
    reg [31:0] gxm_audio_crc_state;
    reg        gxm_lyric_bad;
    reg        gxm_audio_bad;
    wire [31:0] gxm_lyric_total_bytes = gxm_lyric_count * 32'd36;

    assign fs_fat_start_lba = fat_start_lba;
    assign fs_data_start_lba = data_start_lba;
    assign fs_sectors_per_cluster = sectors_per_cluster;

    function [31:0] gxm_crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        integer crc_bit;
        reg [31:0] value;
        begin
            value = crc_in ^ data_in;
            for (crc_bit=0; crc_bit<8; crc_bit=crc_bit+1)
                value = value[0] ? ((value >> 1) ^ 32'hEDB8_8320) :
                                   (value >> 1);
            gxm_crc32_byte = value;
        end
    endfunction

    wire boot_signature_ok = (signature_510 == 8'h55) &&
                             (signature_511 == 8'hAA);
    wire boot_parameters_ok = boot_signature_ok &&
                              (bpb_bytes_per_sector == 16'd512) &&
                              (bpb_sectors_per_cluster != 0) &&
                              ((bpb_sectors_per_cluster &
                                (bpb_sectors_per_cluster-1'b1)) == 0) &&
                              (bpb_reserved_sectors != 0) &&
                              (bpb_num_fats != 0) &&
                              (bpb_fat_size != 0) &&
                              (bpb_root_cluster >= 2);

    function [7:0] target_name_byte;
        input [3:0] track;
        input [4:0] position;
        reg [3:0] user_slot;
        begin
            user_slot = track - 4'd5;
            if (track >= 4'd5) begin
                target_name_byte = " ";
                case (position)
                    5'd0: target_name_byte = "U";
                    5'd1: target_name_byte = "S";
                    5'd2: target_name_byte = "R";
                    5'd3: target_name_byte = "0";
                    5'd4: target_name_byte = 8'h30 + {4'd0, user_slot};
                    5'd8: target_name_byte = "G";
                    5'd9: target_name_byte = "X";
                    5'd10: target_name_byte = "M";
                    default: target_name_byte = " ";
                endcase
            end else if (position == 5'd8) begin
                target_name_byte = "R";
            end else if (position == 5'd9) begin
                target_name_byte = "A";
            end else if (position == 5'd10) begin
                target_name_byte = "W";
            end else begin
                target_name_byte = " ";
                case (track[2:0])
                    3'd0: case (position) // SONG
                        5'd0: target_name_byte = "S";
                        5'd1: target_name_byte = "O";
                        5'd2: target_name_byte = "N";
                        5'd3: target_name_byte = "G";
                        default: target_name_byte = " ";
                    endcase
                    3'd1: case (position) // BEAUTY
                        5'd0: target_name_byte = "B";
                        5'd1: target_name_byte = "E";
                        5'd2: target_name_byte = "A";
                        5'd3: target_name_byte = "U";
                        5'd4: target_name_byte = "T";
                        5'd5: target_name_byte = "Y";
                        default: target_name_byte = " ";
                    endcase
                    3'd2: case (position) // DIE4YOU
                        5'd0: target_name_byte = "D";
                        5'd1: target_name_byte = "I";
                        5'd2: target_name_byte = "E";
                        5'd3: target_name_byte = "4";
                        5'd4: target_name_byte = "Y";
                        5'd5: target_name_byte = "O";
                        5'd6: target_name_byte = "U";
                        default: target_name_byte = " ";
                    endcase
                    3'd3: case (position) // PAYPHONE
                        5'd0: target_name_byte = "P";
                        5'd1: target_name_byte = "A";
                        5'd2: target_name_byte = "Y";
                        5'd3: target_name_byte = "P";
                        5'd4: target_name_byte = "H";
                        5'd5: target_name_byte = "O";
                        5'd6: target_name_byte = "N";
                        5'd7: target_name_byte = "E";
                        default: target_name_byte = " ";
                    endcase
                    default: case (position) // STARBOY
                        5'd0: target_name_byte = "S";
                        5'd1: target_name_byte = "T";
                        5'd2: target_name_byte = "A";
                        5'd3: target_name_byte = "R";
                        5'd4: target_name_byte = "B";
                        5'd5: target_name_byte = "O";
                        5'd6: target_name_byte = "Y";
                        default: target_name_byte = " ";
                    endcase
                endcase
            end
        end
    endfunction

    function [31:0] cluster_sector_lba;
        input [31:0] cluster_number;
        input [7:0]  sector_number;
        begin
            cluster_sector_lba = data_start_lba +
                ((cluster_number-2) * sectors_per_cluster) + sector_number;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                   <= FS_WAIT_SD;
            block_read_req          <= 1'b0;
            block_read_lba          <= 32'd0;
            out_valid               <= 1'b0;
            out_byte                <= 8'd0;
            mount_done              <= 1'b0;
            file_found              <= 1'b0;
            playing                 <= 1'b0;
            eof                     <= 1'b0;
            file_size               <= 32'd0;
            bytes_sent              <= 32'd0;
            error_code              <= 8'h00;
            bpb_bytes_per_sector    <= 16'd0;
            bpb_sectors_per_cluster <= 8'd0;
            bpb_reserved_sectors    <= 16'd0;
            bpb_num_fats            <= 8'd0;
            bpb_fat_size            <= 32'd0;
            bpb_root_cluster        <= 32'd0;
            partition_lba           <= 32'd0;
            signature_510           <= 8'd0;
            signature_511           <= 8'd0;
            volume_start_lba        <= 32'd0;
            fat_start_lba           <= 32'd0;
            data_start_lba          <= 32'd0;
            sectors_per_cluster     <= 8'd0;
            current_cluster         <= 32'd0;
            cluster_sector          <= 8'd0;
            entry_match             <= 1'b0;
            entry_first_byte        <= 8'd0;
            entry_attribute         <= 8'd0;
            entry_cluster_high      <= 16'd0;
            entry_cluster_low       <= 16'd0;
            entry_file_size         <= 32'd0;
            directory_end_seen      <= 1'b0;
            directory_match_found   <= 1'b0;
            found_cluster           <= 32'd0;
            found_size              <= 32'd0;
            fat_for_file            <= 1'b0;
            fat_entry_offset        <= 9'd0;
            fat_byte0               <= 8'd0;
            fat_byte1               <= 8'd0;
            fat_byte2               <= 8'd0;
            fat_byte3               <= 8'd0;
            bytes_remaining         <= 32'd0;
            gxm_mode                <= 1'b0;
            gxm_header_done         <= 1'b0;
            gxm_header_ok           <= 1'b0;
            gxm_title               <= "USER SONG       ";
            gxm_lyric_valid         <= 1'b0;
            gxm_lyric_index         <= 14'd0;
            gxm_lyric_byte          <= 8'd0;
            gxm_lyric_count         <= 9'd0;
            gxm_lyrics_done         <= 1'b0;
            gxm_audio_crc_ok        <= 1'b0;
            selected_start_cluster  <= 32'd0;
            gxm_magic               <= 32'd0;
            gxm_version             <= 16'd0;
            gxm_header_bytes        <= 16'd0;
            gxm_audio_offset        <= 32'd0;
            gxm_audio_bytes         <= 32'd0;
            gxm_audio_crc_expected  <= 32'd0;
            gxm_sample_rate         <= 32'd0;
            gxm_channels            <= 16'd0;
            gxm_bits_per_sample     <= 16'd0;
            gxm_lyric_offset        <= 32'd0;
            gxm_lyric_count_field   <= 16'd0;
            gxm_record_bytes        <= 16'd0;
            gxm_lyric_crc_expected  <= 32'd0;
            gxm_header_crc_expected <= 32'd0;
            gxm_header_crc_state    <= 32'hFFFF_FFFF;
            gxm_lyric_crc_state     <= 32'hFFFF_FFFF;
            gxm_audio_crc_state     <= 32'hFFFF_FFFF;
            gxm_lyric_bad           <= 1'b0;
            gxm_audio_bad           <= 1'b0;
        end else begin
            block_read_req <= 1'b0;
            out_valid      <= 1'b0;
            gxm_lyric_valid<= 1'b0;

            if (sd_error_code != 8'h00) begin
                playing    <= 1'b0;
                error_code <= 8'h06;
                state      <= FS_ERROR;
            end else begin
                case (state)
                    FS_WAIT_SD: begin
                        if (sd_init_ok)
                            state <= FS_LBA0_REQ;
                    end

                    FS_LBA0_REQ: begin
                        if (block_ready) begin
                            block_read_lba          <= 32'd0;
                            block_read_req          <= 1'b1;
                            bpb_bytes_per_sector    <= 16'd0;
                            bpb_sectors_per_cluster <= 8'd0;
                            bpb_reserved_sectors    <= 16'd0;
                            bpb_num_fats            <= 8'd0;
                            bpb_fat_size            <= 32'd0;
                            bpb_root_cluster        <= 32'd0;
                            partition_lba           <= 32'd0;
                            signature_510           <= 8'd0;
                            signature_511           <= 8'd0;
                            state                   <= FS_LBA0_WAIT;
                        end
                    end

                    FS_LBA0_WAIT: begin
                        if (block_data_valid) begin
                            case (block_data_index)
                                9'd11:  bpb_bytes_per_sector[7:0]    <= block_data_byte;
                                9'd12:  bpb_bytes_per_sector[15:8]   <= block_data_byte;
                                9'd13:  bpb_sectors_per_cluster      <= block_data_byte;
                                9'd14:  bpb_reserved_sectors[7:0]    <= block_data_byte;
                                9'd15:  bpb_reserved_sectors[15:8]   <= block_data_byte;
                                9'd16:  bpb_num_fats                  <= block_data_byte;
                                9'd36:  bpb_fat_size[7:0]             <= block_data_byte;
                                9'd37:  bpb_fat_size[15:8]            <= block_data_byte;
                                9'd38:  bpb_fat_size[23:16]           <= block_data_byte;
                                9'd39:  bpb_fat_size[31:24]           <= block_data_byte;
                                9'd44:  bpb_root_cluster[7:0]         <= block_data_byte;
                                9'd45:  bpb_root_cluster[15:8]        <= block_data_byte;
                                9'd46:  bpb_root_cluster[23:16]       <= block_data_byte;
                                9'd47:  bpb_root_cluster[31:24]       <= block_data_byte;
                                9'd454: partition_lba[7:0]            <= block_data_byte;
                                9'd455: partition_lba[15:8]           <= block_data_byte;
                                9'd456: partition_lba[23:16]          <= block_data_byte;
                                9'd457: partition_lba[31:24]          <= block_data_byte;
                                9'd510: signature_510                 <= block_data_byte;
                                9'd511: signature_511                 <= block_data_byte;
                                default: ;
                            endcase
                        end

                        if (block_read_done) begin
                            if (boot_parameters_ok) begin
                                volume_start_lba <= 32'd0;
                                state            <= FS_MOUNT_COMPUTE;
                            end else if (boot_signature_ok &&
                                         (partition_lba != 0)) begin
                                volume_start_lba <= partition_lba;
                                state            <= FS_BOOT_REQ;
                            end else begin
                                mount_done <= 1'b1;
                                error_code <= 8'h01;
                                state      <= FS_ERROR;
                            end
                        end
                    end

                    FS_BOOT_REQ: begin
                        if (block_ready) begin
                            block_read_lba          <= volume_start_lba;
                            block_read_req          <= 1'b1;
                            bpb_bytes_per_sector    <= 16'd0;
                            bpb_sectors_per_cluster <= 8'd0;
                            bpb_reserved_sectors    <= 16'd0;
                            bpb_num_fats            <= 8'd0;
                            bpb_fat_size            <= 32'd0;
                            bpb_root_cluster        <= 32'd0;
                            signature_510           <= 8'd0;
                            signature_511           <= 8'd0;
                            state                   <= FS_BOOT_WAIT;
                        end
                    end

                    FS_BOOT_WAIT: begin
                        if (block_data_valid) begin
                            case (block_data_index)
                                9'd11:  bpb_bytes_per_sector[7:0]    <= block_data_byte;
                                9'd12:  bpb_bytes_per_sector[15:8]   <= block_data_byte;
                                9'd13:  bpb_sectors_per_cluster      <= block_data_byte;
                                9'd14:  bpb_reserved_sectors[7:0]    <= block_data_byte;
                                9'd15:  bpb_reserved_sectors[15:8]   <= block_data_byte;
                                9'd16:  bpb_num_fats                  <= block_data_byte;
                                9'd36:  bpb_fat_size[7:0]             <= block_data_byte;
                                9'd37:  bpb_fat_size[15:8]            <= block_data_byte;
                                9'd38:  bpb_fat_size[23:16]           <= block_data_byte;
                                9'd39:  bpb_fat_size[31:24]           <= block_data_byte;
                                9'd44:  bpb_root_cluster[7:0]         <= block_data_byte;
                                9'd45:  bpb_root_cluster[15:8]        <= block_data_byte;
                                9'd46:  bpb_root_cluster[23:16]       <= block_data_byte;
                                9'd47:  bpb_root_cluster[31:24]       <= block_data_byte;
                                9'd510: signature_510                 <= block_data_byte;
                                9'd511: signature_511                 <= block_data_byte;
                                default: ;
                            endcase
                        end

                        if (block_read_done) begin
                            if (boot_parameters_ok) begin
                                state <= FS_MOUNT_COMPUTE;
                            end else begin
                                mount_done <= 1'b1;
                                error_code <= 8'h02;
                                state      <= FS_ERROR;
                            end
                        end
                    end

                    FS_MOUNT_COMPUTE: begin
                        fat_start_lba       <= volume_start_lba +
                                               bpb_reserved_sectors;
                        data_start_lba      <= volume_start_lba +
                                               bpb_reserved_sectors +
                                               (bpb_num_fats * bpb_fat_size);
                        sectors_per_cluster <= bpb_sectors_per_cluster;
                        current_cluster     <= bpb_root_cluster;
                        cluster_sector      <= 8'd0;
                        state               <= FS_ROOT_REQ;
                    end

                    FS_ROOT_REQ: begin
                        if (block_ready) begin
                            block_read_lba        <= cluster_sector_lba(
                                                        current_cluster,
                                                        cluster_sector);
                            block_read_req        <= 1'b1;
                            directory_end_seen    <= 1'b0;
                            directory_match_found <= 1'b0;
                            state                 <= FS_ROOT_WAIT;
                        end
                    end

                    FS_ROOT_WAIT: begin
                        if (block_data_valid) begin
                            case (block_data_index[4:0])
                                5'd0: begin
                                    entry_first_byte   <= block_data_byte;
                                    entry_match        <=
                                        (block_data_byte ==
                                         target_name_byte(track_index, 0));
                                    entry_attribute    <= 8'd0;
                                    entry_cluster_high <= 16'd0;
                                    entry_cluster_low  <= 16'd0;
                                    entry_file_size    <= 32'd0;
                                    if (block_data_byte == 8'h00)
                                        directory_end_seen <= 1'b1;
                                end
                                5'd1, 5'd2, 5'd3, 5'd4, 5'd5,
                                5'd6, 5'd7, 5'd8, 5'd9, 5'd10:
                                    entry_match <= entry_match &&
                                        (block_data_byte ==
                                         target_name_byte(
                                             track_index,
                                             block_data_index[4:0]));
                                5'd11: entry_attribute       <= block_data_byte;
                                5'd20: entry_cluster_high[7:0]  <= block_data_byte;
                                5'd21: entry_cluster_high[15:8] <= block_data_byte;
                                5'd26: entry_cluster_low[7:0]   <= block_data_byte;
                                5'd27: entry_cluster_low[15:8]  <= block_data_byte;
                                5'd28: entry_file_size[7:0]     <= block_data_byte;
                                5'd29: entry_file_size[15:8]    <= block_data_byte;
                                5'd30: entry_file_size[23:16]   <= block_data_byte;
                                5'd31: begin
                                    if (entry_match &&
                                        (entry_first_byte != 8'hE5) &&
                                        (entry_attribute != 8'h0F) &&
                                        ((entry_attribute & 8'h18) == 0)) begin
                                        directory_match_found <= 1'b1;
                                        found_cluster <=
                                            {entry_cluster_high,
                                             entry_cluster_low};
                                        found_size <=
                                            {block_data_byte,
                                             entry_file_size[23:0]};
                                    end
                                end
                                default: ;
                            endcase
                        end

                        if (block_read_done) begin
                            if (directory_match_found) begin
                                if ((found_cluster < 2) ||
                                    (found_size == 0)) begin
                                    mount_done <= 1'b1;
                                    error_code <= 8'h04;
                                    state      <= FS_ERROR;
                                end else begin
                                    current_cluster <= found_cluster;
                                    selected_start_cluster <= found_cluster;
                                    cluster_sector  <= 8'd0;
                                    file_size       <= found_size;
                                    bytes_remaining <= found_size;
                                    bytes_sent      <= 32'd0;
                                    mount_done      <= 1'b1;
                                    file_found      <= 1'b1;
                                    playing         <= 1'b1;
                                    gxm_mode        <= (track_index >= 4'd5);
                                    gxm_header_done <= 1'b0;
                                    gxm_header_ok   <= 1'b0;
                                    gxm_lyrics_done <= 1'b0;
                                    gxm_audio_crc_ok<= 1'b0;
                                    gxm_magic       <= 32'd0;
                                    gxm_version     <= 16'd0;
                                    gxm_header_bytes<= 16'd0;
                                    gxm_audio_offset<= 32'd0;
                                    gxm_audio_bytes <= 32'd0;
                                    gxm_audio_crc_expected <= 32'd0;
                                    gxm_sample_rate <= 32'd0;
                                    gxm_channels    <= 16'd0;
                                    gxm_bits_per_sample <= 16'd0;
                                    gxm_lyric_offset<= 32'd0;
                                    gxm_lyric_count <= 9'd0;
                                    gxm_lyric_count_field <= 16'd0;
                                    gxm_record_bytes<= 16'd0;
                                    gxm_lyric_crc_expected <= 32'd0;
                                    gxm_header_crc_expected<= 32'd0;
                                    gxm_header_crc_state <= 32'hFFFF_FFFF;
                                    gxm_lyric_crc_state  <= 32'hFFFF_FFFF;
                                    gxm_audio_crc_state  <= 32'hFFFF_FFFF;
                                    gxm_lyric_bad    <= 1'b0;
                                    gxm_audio_bad    <= 1'b0;
                                    gxm_title        <= "USER SONG       ";
                                    state           <= FS_FILE_REQ;
                                end
                            end else if (directory_end_seen) begin
                                mount_done <= 1'b1;
                                error_code <= 8'h03;
                                state      <= FS_ERROR;
                            end else if (cluster_sector+1'b1 <
                                         sectors_per_cluster) begin
                                cluster_sector <= cluster_sector + 1'b1;
                                state          <= FS_ROOT_REQ;
                            end else begin
                                fat_for_file <= 1'b0;
                                state        <= FS_FAT_REQ;
                            end
                        end
                    end

                    FS_FAT_REQ: begin
                        if (block_ready) begin
                            block_read_lba   <= fat_start_lba +
                                                (current_cluster >> 7);
                            fat_entry_offset <= {current_cluster[6:0], 2'b00};
                            fat_byte0         <= 8'd0;
                            fat_byte1         <= 8'd0;
                            fat_byte2         <= 8'd0;
                            fat_byte3         <= 8'd0;
                            block_read_req    <= 1'b1;
                            state             <= FS_FAT_WAIT;
                        end
                    end

                    FS_FAT_WAIT: begin
                        if (block_data_valid) begin
                            if (block_data_index == fat_entry_offset)
                                fat_byte0 <= block_data_byte;
                            else if (block_data_index == fat_entry_offset+1'b1)
                                fat_byte1 <= block_data_byte;
                            else if (block_data_index == fat_entry_offset+2'd2)
                                fat_byte2 <= block_data_byte;
                            else if (block_data_index == fat_entry_offset+2'd3)
                                fat_byte3 <= block_data_byte;
                        end
                        if (block_read_done)
                            state <= FS_FAT_EVAL;
                    end

                    FS_FAT_EVAL: begin
                        if ((next_cluster < 2) ||
                            (next_cluster >= 32'h0FFF_FFF8)) begin
                            if (!fat_for_file) begin
                                mount_done <= 1'b1;
                                error_code <= 8'h03;
                            end else if (bytes_remaining == 0) begin
                                playing <= 1'b0;
                                eof     <= 1'b1;
                                state   <= FS_DONE;
                            end else begin
                                playing    <= 1'b0;
                                error_code <= 8'h05;
                            end
                            if (!fat_for_file || (bytes_remaining != 0))
                                state <= FS_ERROR;
                        end else begin
                            current_cluster <= next_cluster;
                            cluster_sector  <= 8'd0;
                            state <= fat_for_file ? FS_FILE_REQ : FS_ROOT_REQ;
                        end
                    end

                    FS_FILE_REQ: begin
                        if (bytes_remaining == 0) begin
                            playing <= 1'b0;
                            eof     <= 1'b1;
                            state   <= FS_DONE;
                        end else if (sector_allow && block_ready) begin
                            block_read_lba <= cluster_sector_lba(
                                                  current_cluster,
                                                  cluster_sector);
                            block_read_req <= 1'b1;
                            state          <= FS_FILE_WAIT;
                        end
                    end

                    FS_FILE_WAIT: begin
                        if (block_data_valid && (bytes_remaining != 0)) begin
                            bytes_remaining <= bytes_remaining - 1'b1;
                            bytes_sent      <= bytes_sent + 1'b1;

                            if (!gxm_mode) begin
                                out_valid <= 1'b1;
                                out_byte  <= block_data_byte;
                            end else begin
                                // Header CRC covers bytes 0..507.
                                if (bytes_sent < 32'd508)
                                    gxm_header_crc_state <= gxm_crc32_byte(
                                        gxm_header_crc_state,
                                        block_data_byte);

                                if (bytes_sent < 32'd512) begin
                                    case (bytes_sent[8:0])
                                        9'd0:   gxm_magic[7:0] <= block_data_byte;
                                        9'd1:   gxm_magic[15:8] <= block_data_byte;
                                        9'd2:   gxm_magic[23:16] <= block_data_byte;
                                        9'd3:   gxm_magic[31:24] <= block_data_byte;
                                        9'd4:   gxm_version[7:0] <= block_data_byte;
                                        9'd5:   gxm_version[15:8] <= block_data_byte;
                                        9'd6:   gxm_header_bytes[7:0] <= block_data_byte;
                                        9'd7:   gxm_header_bytes[15:8] <= block_data_byte;
                                        9'd8:   gxm_audio_offset[7:0] <= block_data_byte;
                                        9'd9:   gxm_audio_offset[15:8] <= block_data_byte;
                                        9'd10:  gxm_audio_offset[23:16] <= block_data_byte;
                                        9'd11:  gxm_audio_offset[31:24] <= block_data_byte;
                                        9'd12:  gxm_audio_bytes[7:0] <= block_data_byte;
                                        9'd13:  gxm_audio_bytes[15:8] <= block_data_byte;
                                        9'd14:  gxm_audio_bytes[23:16] <= block_data_byte;
                                        9'd15:  gxm_audio_bytes[31:24] <= block_data_byte;
                                        9'd16:  gxm_audio_crc_expected[7:0] <= block_data_byte;
                                        9'd17:  gxm_audio_crc_expected[15:8] <= block_data_byte;
                                        9'd18:  gxm_audio_crc_expected[23:16] <= block_data_byte;
                                        9'd19:  gxm_audio_crc_expected[31:24] <= block_data_byte;
                                        9'd20:  gxm_sample_rate[7:0] <= block_data_byte;
                                        9'd21:  gxm_sample_rate[15:8] <= block_data_byte;
                                        9'd22:  gxm_sample_rate[23:16] <= block_data_byte;
                                        9'd23:  gxm_sample_rate[31:24] <= block_data_byte;
                                        9'd24:  gxm_channels[7:0] <= block_data_byte;
                                        9'd25:  gxm_channels[15:8] <= block_data_byte;
                                        9'd26:  gxm_bits_per_sample[7:0] <= block_data_byte;
                                        9'd27:  gxm_bits_per_sample[15:8] <= block_data_byte;
                                        9'd28:  gxm_lyric_offset[7:0] <= block_data_byte;
                                        9'd29:  gxm_lyric_offset[15:8] <= block_data_byte;
                                        9'd30:  gxm_lyric_offset[23:16] <= block_data_byte;
                                        9'd31:  gxm_lyric_offset[31:24] <= block_data_byte;
                                        9'd32:  gxm_lyric_count_field[7:0] <= block_data_byte;
                                        9'd33:  gxm_lyric_count_field[15:8] <= block_data_byte;
                                        9'd34:  gxm_record_bytes[7:0] <= block_data_byte;
                                        9'd35:  gxm_record_bytes[15:8] <= block_data_byte;
                                        9'd36:  gxm_lyric_crc_expected[7:0] <= block_data_byte;
                                        9'd37:  gxm_lyric_crc_expected[15:8] <= block_data_byte;
                                        9'd38:  gxm_lyric_crc_expected[23:16] <= block_data_byte;
                                        9'd39:  gxm_lyric_crc_expected[31:24] <= block_data_byte;
                                        9'd48, 9'd49, 9'd50, 9'd51,
                                        9'd52, 9'd53, 9'd54, 9'd55,
                                        9'd56, 9'd57, 9'd58, 9'd59,
                                        9'd60, 9'd61, 9'd62, 9'd63:
                                            gxm_title <= {gxm_title[119:0],
                                                          block_data_byte};
                                        9'd508: gxm_header_crc_expected[7:0] <= block_data_byte;
                                        9'd509: gxm_header_crc_expected[15:8] <= block_data_byte;
                                        9'd510: gxm_header_crc_expected[23:16] <= block_data_byte;
                                        9'd511: gxm_header_crc_expected[31:24] <= block_data_byte;
                                        default: ;
                                    endcase
                                end else if (gxm_header_ok &&
                                             (bytes_sent >= gxm_lyric_offset) &&
                                             (bytes_sent < gxm_lyric_offset +
                                                           gxm_lyric_total_bytes)) begin
                                    gxm_lyric_valid <= 1'b1;
                                    gxm_lyric_index <= bytes_sent[13:0] -
                                                       gxm_lyric_offset[13:0];
                                    gxm_lyric_byte  <= block_data_byte;
                                    gxm_lyric_crc_state <= gxm_crc32_byte(
                                        gxm_lyric_crc_state,
                                        block_data_byte);
                                    if (bytes_sent == gxm_lyric_offset +
                                                      gxm_lyric_total_bytes - 1'b1) begin
                                        if ((gxm_crc32_byte(
                                                gxm_lyric_crc_state,
                                                block_data_byte) ^
                                             32'hFFFF_FFFF) ==
                                            gxm_lyric_crc_expected) begin
                                            gxm_lyrics_done <= 1'b1;
                                        end else begin
                                            gxm_lyric_bad <= 1'b1;
                                        end
                                    end
                                end else if (gxm_header_ok &&
                                             (bytes_sent >= gxm_audio_offset) &&
                                             (bytes_sent < gxm_audio_offset +
                                                           gxm_audio_bytes)) begin
                                    out_valid <= 1'b1;
                                    out_byte  <= block_data_byte;
                                    gxm_audio_crc_state <= gxm_crc32_byte(
                                        gxm_audio_crc_state,
                                        block_data_byte);
                                    if (bytes_sent == gxm_audio_offset +
                                                      gxm_audio_bytes - 1'b1) begin
                                        if ((gxm_crc32_byte(
                                                gxm_audio_crc_state,
                                                block_data_byte) ^
                                             32'hFFFF_FFFF) ==
                                            gxm_audio_crc_expected)
                                            gxm_audio_crc_ok <= 1'b1;
                                        else
                                            gxm_audio_bad <= 1'b1;
                                    end
                                end
                            end
                        end
                        if (block_read_done) begin
                            if (gxm_mode && !gxm_header_done)
                                state <= FS_GXM_HEADER_EVAL;
                            else
                                state <= FS_FILE_NEXT;
                        end
                    end

                    FS_GXM_HEADER_EVAL: begin
                        gxm_header_done <= 1'b1;
                        if ((gxm_magic != 32'h314D_5847) ||
                            (gxm_version != 16'd1) ||
                            (gxm_header_bytes != 16'd512) ||
                            (gxm_audio_offset != 32'h0001_0000) ||
                            (gxm_audio_bytes == 0) ||
                            (gxm_audio_bytes[1:0] != 0) ||
                            (gxm_audio_bytes > 32'd100_597_760) ||
                            (gxm_sample_rate != 32'd44_100) ||
                            (gxm_channels != 16'd2) ||
                            (gxm_bits_per_sample != 16'd16) ||
                            (gxm_lyric_offset != 32'd512) ||
                            (gxm_lyric_count_field == 0) ||
                            (gxm_lyric_count_field > 16'd256) ||
                            (gxm_record_bytes != 16'd36) ||
                            (file_size < gxm_audio_offset + gxm_audio_bytes) ||
                            ((gxm_header_crc_state ^ 32'hFFFF_FFFF) !=
                             gxm_header_crc_expected)) begin
                            gxm_header_ok <= 1'b0;
                            playing       <= 1'b0;
                            error_code    <= 8'h07;
                            state         <= FS_ERROR;
                        end else begin
                            gxm_header_ok       <= 1'b1;
                            gxm_lyric_count     <= gxm_lyric_count_field[8:0];
                            gxm_lyric_crc_state <= 32'hFFFF_FFFF;
                            gxm_audio_crc_state <= 32'hFFFF_FFFF;
                            // Exactly the GXM prefix and valid PCM are read;
                            // the unused tail of a 96-MiB slot is ignored.
                            bytes_remaining <= (gxm_audio_offset +
                                                gxm_audio_bytes) - bytes_sent;
                            state <= FS_FILE_NEXT;
                        end
                    end

                    FS_FILE_NEXT: begin
                        if (gxm_mode && gxm_lyric_bad) begin
                            gxm_header_ok <= 1'b0;
                            playing       <= 1'b0;
                            error_code    <= 8'h08;
                            state         <= FS_ERROR;
                        end else if (gxm_mode && gxm_audio_bad) begin
                            gxm_header_ok <= 1'b0;
                            playing       <= 1'b0;
                            error_code    <= 8'h09;
                            state         <= FS_ERROR;
                        end else if (bytes_remaining == 0) begin
                            playing <= 1'b0;
                            eof     <= 1'b1;
                            state   <= FS_DONE;
                        end else if (cluster_sector+1'b1 <
                                     sectors_per_cluster) begin
                            cluster_sector <= cluster_sector + 1'b1;
                            state          <= FS_FILE_REQ;
                        end else begin
                            fat_for_file <= 1'b1;
                            state        <= FS_FAT_REQ;
                        end
                    end

                    FS_DONE: begin
                        playing <= 1'b0;
                    end

                    FS_ERROR: begin
                        playing <= 1'b0;
                    end

                    default: state <= FS_ERROR;
                endcase
            end
        end
    end
endmodule


// Dual-clock stereo PCM FIFO with a write-domain fill-level estimate.
//
// The RAM read and write ports deliberately live in two small, reset-free
// clocked processes.  This is the Vivado simple-dual-port BRAM inference
// pattern.  Keeping pointer/reset logic out of the RAM processes prevents
// synthesis from trying to dissolve the 4096 x 32 memory into flip-flops.
module sly4_async_stereo_fifo_level #(
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
    wire memory_after_pop_empty = (read_gray_next == write_gray_sync2);
    assign rd_empty = ~read_have_data;

    // Pure write port: no reset branch and no assignments to pointer state.
    wire write_memory_enable = wr_rst_n && !wr_clear &&
                               wr_en && !wr_full;
    always @(posedge wr_clk) begin
        if (write_memory_enable)
            memory[write_binary[AW-1:0]] <= {wr_l, wr_r};
    end

    // First-word-fall-through read port.  When the current word is consumed,
    // preload the following word in the same read-clock edge when available.
    wire pop_current = rd_pop && read_have_data;
    wire load_first  = !read_have_data && !memory_empty;
    wire load_next   = pop_current && !memory_after_pop_empty;
    wire read_memory_enable = rd_rst_n && !rd_clear &&
                              (load_first || load_next);
    wire [AW-1:0] read_memory_address = load_next ?
        read_binary_next[AW-1:0] : read_binary[AW-1:0];

    // No reset on BRAM output registers; rd_empty qualifies their validity.
    always @(posedge rd_clk) begin
        if (read_memory_enable)
            {rd_l, rd_r} <= memory[read_memory_address];
    end

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
            read_have_data <= 1'b0;
        end else begin
            write_gray_sync1 <= write_gray;
            write_gray_sync2 <= write_gray_sync1;

            if (rd_clear) begin
                read_binary    <= {(AW+1){1'b0}};
                read_gray      <= {(AW+1){1'b0}};
                read_have_data <= 1'b0;
            end else if (pop_current) begin
                read_binary    <= read_binary_next;
                read_gray      <= read_gray_next;
                read_have_data <= !memory_after_pop_empty;
            end else if (load_first) begin
                read_have_data <= 1'b1;
            end
        end
    end
endmodule


// --------------------------------------------------------------------------
// QSPI-resident lyric receiver/display.
// Each of the five Flash records is:
//   little-endian uint32 start_ms, 16 LCD bytes for line 1, 16 for line 2.
// The packed line registers below are loaded only from bytes read through the
// QSPI SPI master. Thus QSPI playback does not use the embedded SD lyric table.
// --------------------------------------------------------------------------
module sly4_qspi_lyrics_display (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         active,
    input  wire         load_valid,
    input  wire [7:0]   load_index,
    input  wire [7:0]   load_byte,
    input  wire         load_done,
    input  wire [31:0]  play_ms_gray_async,
    output reg          ready,
    output reg  [127:0] line1,
    output reg  [127:0] line2
);
    reg [31:0]  record_time [0:4];
    reg [127:0] record_line1[0:4];
    reg [127:0] record_line2[0:4];
    reg [2:0]   load_record;
    reg [5:0]   load_offset;

    always @* begin
        if (load_index < 8'd36) begin
            load_record = 3'd0;
            load_offset = load_index;
        end else if (load_index < 8'd72) begin
            load_record = 3'd1;
            load_offset = load_index - 8'd36;
        end else if (load_index < 8'd108) begin
            load_record = 3'd2;
            load_offset = load_index - 8'd72;
        end else if (load_index < 8'd144) begin
            load_record = 3'd3;
            load_offset = load_index - 8'd108;
        end else begin
            load_record = 3'd4;
            load_offset = load_index - 8'd144;
        end
    end

    integer clear_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready <= 1'b0;
            for (clear_index=0; clear_index<5;
                 clear_index=clear_index+1) begin
                record_time[clear_index]  <= 32'd0;
                record_line1[clear_index] <= 128'd0;
                record_line2[clear_index] <= 128'd0;
            end
        end else begin
            if (load_valid && (load_index < 8'd180)) begin
                case (load_offset)
                    6'd0: record_time[load_record][7:0]   <= load_byte;
                    6'd1: record_time[load_record][15:8]  <= load_byte;
                    6'd2: record_time[load_record][23:16] <= load_byte;
                    6'd3: record_time[load_record][31:24] <= load_byte;
                    default: begin
                        if (load_offset < 6'd20)
                            record_line1[load_record] <=
                                {record_line1[load_record][119:0], load_byte};
                        else
                            record_line2[load_record] <=
                                {record_line2[load_record][119:0], load_byte};
                    end
                endcase
            end
            if (load_done)
                ready <= 1'b1;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [31:0] play_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] play_gray_sync;
    function [31:0] gray_to_binary32_qspi;
        input [31:0] gray_value;
        integer bit_number;
        begin
            gray_to_binary32_qspi[31] = gray_value[31];
            for (bit_number=30; bit_number>=0; bit_number=bit_number-1)
                gray_to_binary32_qspi[bit_number] =
                    gray_to_binary32_qspi[bit_number+1] ^
                    gray_value[bit_number];
        end
    endfunction
    wire [31:0] play_ms_qspi =
        gray_to_binary32_qspi(play_gray_sync);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_gray_meta <= 32'd0;
            play_gray_sync <= 32'd0;
        end else begin
            play_gray_meta <= play_ms_gray_async;
            play_gray_sync <= play_gray_meta;
        end
    end

    reg [2:0] display_record;
    always @* begin
        if (!active || !ready)
            display_record = 3'd0;
        else if (play_ms_qspi >= record_time[4])
            display_record = 3'd4;
        else if (play_ms_qspi >= record_time[3])
            display_record = 3'd3;
        else if (play_ms_qspi >= record_time[2])
            display_record = 3'd2;
        else if (play_ms_qspi >= record_time[1])
            display_record = 3'd1;
        else
            display_record = 3'd0;
    end

    always @* begin
        if (!ready) begin
            line1 = "QSPI LYRIC WAIT ";
            line2 = "                ";
        end else begin
            line1 = record_line1[display_record];
            line2 = record_line2[display_record];
        end
    end
endmodule


// --------------------------------------------------------------------------
// Runtime-loaded GXM lyric display.
// The FAT32 reader supplies sequential 36-byte records.  Text bytes use BRAM
// without a reset loop, avoiding the unsupported large-memory inference that
// older Vivado runs reported for monolithic lyric arrays.
// --------------------------------------------------------------------------
module gx5_gxm_lyrics_display (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         active,
    input  wire         load_valid,
    input  wire [13:0]  load_index,
    input  wire [7:0]   load_byte,
    input  wire [8:0]   load_count,
    input  wire         load_done,
    input  wire [31:0]  play_ms_gray_async,
    output reg          ready,
    output reg  [127:0] line1,
    output reg  [127:0] line2
);
    reg [31:0] record_time [0:255];
    (* ram_style = "block" *) reg [7:0] record_text [0:8191];

    reg [7:0]  load_record;
    reg [5:0]  load_offset;
    reg [13:0] expected_index;
    reg        load_error;
    reg [8:0]  record_count;

    wire [12:0] load_text_address =
        {load_record, 5'b00000} + (load_offset - 6'd4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_record   <= 8'd0;
            load_offset   <= 6'd0;
            expected_index<= 14'd0;
            load_error    <= 1'b0;
            record_count  <= 9'd0;
            ready         <= 1'b0;
        end else begin
            if (load_valid) begin
                if (load_index != expected_index)
                    load_error <= 1'b1;
                expected_index <= expected_index + 1'b1;

                case (load_offset)
                    6'd0: record_time[load_record][7:0]   <= load_byte;
                    6'd1: record_time[load_record][15:8]  <= load_byte;
                    6'd2: record_time[load_record][23:16] <= load_byte;
                    6'd3: record_time[load_record][31:24] <= load_byte;
                    default: record_text[load_text_address] <= load_byte;
                endcase

                if (load_offset == 6'd35) begin
                    load_offset <= 6'd0;
                    load_record <= load_record + 1'b1;
                end else begin
                    load_offset <= load_offset + 1'b1;
                end
            end

            if (load_done) begin
                record_count <= load_count;
                ready <= !load_error &&
                         (!load_valid || (load_index == expected_index)) &&
                         (load_count != 0) &&
                         ((expected_index + (load_valid ? 1'b1 : 1'b0)) ==
                          (load_count * 14'd36));
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [31:0] play_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] play_gray_sync;
    function [31:0] gray_to_binary32_gxm;
        input [31:0] gray_value;
        integer bit_number;
        begin
            gray_to_binary32_gxm[31] = gray_value[31];
            for (bit_number=30; bit_number>=0; bit_number=bit_number-1)
                gray_to_binary32_gxm[bit_number] =
                    gray_to_binary32_gxm[bit_number+1] ^ gray_value[bit_number];
        end
    endfunction
    wire [31:0] play_ms_gxm = gray_to_binary32_gxm(play_gray_sync);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_gray_meta <= 32'd0;
            play_gray_sync <= 32'd0;
        end else begin
            play_gray_meta <= play_ms_gray_async;
            play_gray_sync <= play_gray_meta;
        end
    end

    reg [7:0] display_record;
    reg [7:0] line_target;
    reg [5:0] line_byte_index;
    reg       line_loading;
    reg       load_done_seen;
    wire [12:0] line_text_address =
        {line_target, 5'b00000} + line_byte_index[4:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            display_record <= 8'd0;
            line_target    <= 8'd0;
            line_byte_index<= 6'd0;
            line_loading   <= 1'b0;
            load_done_seen <= 1'b0;
            line1          <= "GXM LYRIC WAIT  ";
            line2          <= "                ";
        end else begin
            if (load_done && !load_done_seen && !load_error &&
                (load_count != 0)) begin
                load_done_seen <= 1'b1;
                display_record <= 8'd0;
                line_target    <= 8'd0;
                line_byte_index<= 6'd0;
                line_loading   <= 1'b1;
                line1          <= 128'd0;
                line2          <= 128'd0;
            end else if (active && ready &&
                         ({1'b0, display_record} + 1'b1 < record_count) &&
                         (play_ms_gxm >= record_time[display_record + 1'b1])) begin
                display_record <= display_record + 1'b1;
                line_target    <= display_record + 1'b1;
                line_byte_index<= 6'd0;
                line_loading   <= 1'b1;
                line1          <= 128'd0;
                line2          <= 128'd0;
            end

            if (line_loading) begin
                if (line_byte_index < 6'd16)
                    line1 <= {line1[119:0], record_text[line_text_address]};
                else
                    line2 <= {line2[119:0], record_text[line_text_address]};

                if (line_byte_index == 6'd31) begin
                    line_byte_index <= 6'd0;
                    line_loading    <= 1'b0;
                end else begin
                    line_byte_index <= line_byte_index + 1'b1;
                end
            end
        end
    end
endmodule


// --------------------------------------------------------------------------
// SD-mode embedded lyrics. QSPI mode deliberately bypasses this table and
// displays the five records loaded back from physical QSPI Flash.
// --------------------------------------------------------------------------
// --------------------------------------------------------------------------
// Complete synchronized lyrics for the supplied SONG.RAW / LRC pair.
// 66 timestamped entries -> 109 two-line pages including start/end blanks.
// Long entries are word-wrapped to 16 characters and their subpages are
// distributed inside the original LRC time interval.
// --------------------------------------------------------------------------
// --------------------------------------------------------------------------
// Five-track synchronized LCD1602 lyrics. Track 0 preserves the previously
// verified timing. Beauty And A Beat now uses the timestamps from the
// matching full-length MP3/LRC pair; Payphone retains its fitted time axis.
// Long LRC entries are word-wrapped into 16-character rows and their pages
// are distributed within the original timestamp interval.
// --------------------------------------------------------------------------
module sly4_lyrics_display (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         active,
    input  wire [2:0]   track_index,
    input  wire         qspi_mode,
    input  wire [31:0]  play_ms_gray_async,
    output reg  [127:0] line1,
    output reg  [127:0] line2
);
    function [7:0] last_page_for_track;
        input [2:0] track;
        begin
            case (track)
                3'd0: last_page_for_track = 8'd108;
                3'd1: last_page_for_track = 8'd73;
                3'd2: last_page_for_track = 8'd78;
                3'd3: last_page_for_track = 8'd131;
                3'd4: last_page_for_track = 8'd142;
                default: last_page_for_track = 8'd142;
            endcase
        end
    endfunction

    function [31:0] page_start_ms;
        input [2:0] track;
        input [7:0] index;
        begin
            page_start_ms = 32'd0;
            case (track)
                3'd0: begin
                    case (index)
                        8'd0: page_start_ms = 32'd0;
                        8'd1: page_start_ms = 32'd720;
                        8'd2: page_start_ms = 32'd3070;
                        8'd3: page_start_ms = 32'd5420;
                        8'd4: page_start_ms = 32'd7865;
                        8'd5: page_start_ms = 32'd10310;
                        8'd6: page_start_ms = 32'd12670;
                        8'd7: page_start_ms = 32'd14300;
                        8'd8: page_start_ms = 32'd17090;
                        8'd9: page_start_ms = 32'd19880;
                        8'd10: page_start_ms = 32'd21675;
                        8'd11: page_start_ms = 32'd23470;
                        8'd12: page_start_ms = 32'd25850;
                        8'd13: page_start_ms = 32'd27605;
                        8'd14: page_start_ms = 32'd29360;
                        8'd15: page_start_ms = 32'd31230;
                        8'd16: page_start_ms = 32'd33100;
                        8'd17: page_start_ms = 32'd35420;
                        8'd18: page_start_ms = 32'd39370;
                        8'd19: page_start_ms = 32'd41100;
                        8'd20: page_start_ms = 32'd42245;
                        8'd21: page_start_ms = 32'd43390;
                        8'd22: page_start_ms = 32'd44845;
                        8'd23: page_start_ms = 32'd46300;
                        8'd24: page_start_ms = 32'd48990;
                        8'd25: page_start_ms = 32'd50470;
                        8'd26: page_start_ms = 32'd51735;
                        8'd27: page_start_ms = 32'd53000;
                        8'd28: page_start_ms = 32'd54275;
                        8'd29: page_start_ms = 32'd55550;
                        8'd30: page_start_ms = 32'd58200;
                        8'd31: page_start_ms = 32'd60600;
                        8'd32: page_start_ms = 32'd63000;
                        8'd33: page_start_ms = 32'd65435;
                        8'd34: page_start_ms = 32'd67870;
                        8'd35: page_start_ms = 32'd70220;
                        8'd36: page_start_ms = 32'd71740;
                        8'd37: page_start_ms = 32'd76140;
                        8'd38: page_start_ms = 32'd80540;
                        8'd39: page_start_ms = 32'd83310;
                        8'd40: page_start_ms = 32'd85190;
                        8'd41: page_start_ms = 32'd87070;
                        8'd42: page_start_ms = 32'd89140;
                        8'd43: page_start_ms = 32'd91020;
                        8'd44: page_start_ms = 32'd92900;
                        8'd45: page_start_ms = 32'd94900;
                        8'd46: page_start_ms = 32'd96900;
                        8'd47: page_start_ms = 32'd98530;
                        8'd48: page_start_ms = 32'd99705;
                        8'd49: page_start_ms = 32'd100880;
                        8'd50: page_start_ms = 32'd103685;
                        8'd51: page_start_ms = 32'd106490;
                        8'd52: page_start_ms = 32'd108070;
                        8'd53: page_start_ms = 32'd109305;
                        8'd54: page_start_ms = 32'd110540;
                        8'd55: page_start_ms = 32'd111865;
                        8'd56: page_start_ms = 32'd113190;
                        8'd57: page_start_ms = 32'd115660;
                        8'd58: page_start_ms = 32'd116945;
                        8'd59: page_start_ms = 32'd118230;
                        8'd60: page_start_ms = 32'd119435;
                        8'd61: page_start_ms = 32'd120640;
                        8'd62: page_start_ms = 32'd123050;
                        8'd63: page_start_ms = 32'd125460;
                        8'd64: page_start_ms = 32'd126605;
                        8'd65: page_start_ms = 32'd127750;
                        8'd66: page_start_ms = 32'd128625;
                        8'd67: page_start_ms = 32'd129500;
                        8'd68: page_start_ms = 32'd136630;
                        8'd69: page_start_ms = 32'd143760;
                        8'd70: page_start_ms = 32'd154500;
                        8'd71: page_start_ms = 32'd156130;
                        8'd72: page_start_ms = 32'd157375;
                        8'd73: page_start_ms = 32'd158620;
                        8'd74: page_start_ms = 32'd159860;
                        8'd75: page_start_ms = 32'd161100;
                        8'd76: page_start_ms = 32'd164110;
                        8'd77: page_start_ms = 32'd165640;
                        8'd78: page_start_ms = 32'd166860;
                        8'd79: page_start_ms = 32'd168080;
                        8'd80: page_start_ms = 32'd169395;
                        8'd81: page_start_ms = 32'd170710;
                        8'd82: page_start_ms = 32'd173330;
                        8'd83: page_start_ms = 32'd174605;
                        8'd84: page_start_ms = 32'd175880;
                        8'd85: page_start_ms = 32'd177040;
                        8'd86: page_start_ms = 32'd178200;
                        8'd87: page_start_ms = 32'd180650;
                        8'd88: page_start_ms = 32'd183100;
                        8'd89: page_start_ms = 32'd184230;
                        8'd90: page_start_ms = 32'd185360;
                        8'd91: page_start_ms = 32'd186180;
                        8'd92: page_start_ms = 32'd187000;
                        8'd93: page_start_ms = 32'd189825;
                        8'd94: page_start_ms = 32'd192650;
                        8'd95: page_start_ms = 32'd194330;
                        8'd96: page_start_ms = 32'd195665;
                        8'd97: page_start_ms = 32'd197000;
                        8'd98: page_start_ms = 32'd198270;
                        8'd99: page_start_ms = 32'd199540;
                        8'd100: page_start_ms = 32'd202230;
                        8'd101: page_start_ms = 32'd203155;
                        8'd102: page_start_ms = 32'd204080;
                        8'd103: page_start_ms = 32'd205350;
                        8'd104: page_start_ms = 32'd206620;
                        8'd105: page_start_ms = 32'd207920;
                        8'd106: page_start_ms = 32'd209220;
                        8'd107: page_start_ms = 32'd211880;
                        8'd108: page_start_ms = 32'd215880;
                        default: page_start_ms = 32'd215880;
                    endcase
                end
                3'd1: begin
                    case (index)
                        8'd0: page_start_ms = 32'd0;
                        8'd1: page_start_ms = 32'd3000;
                        8'd2: page_start_ms = 32'd6000;
                        8'd3: page_start_ms = 32'd9000;
                        8'd4: page_start_ms = 32'd11000;
                        8'd5: page_start_ms = 32'd15000;
                        8'd6: page_start_ms = 32'd17000;
                        8'd7: page_start_ms = 32'd19500;
                        8'd8: page_start_ms = 32'd22000;
                        8'd9: page_start_ms = 32'd25000;
                        8'd10: page_start_ms = 32'd27500;
                        8'd11: page_start_ms = 32'd30000;
                        8'd12: page_start_ms = 32'd32000;
                        8'd13: page_start_ms = 32'd34000;
                        8'd14: page_start_ms = 32'd35500;
                        8'd15: page_start_ms = 32'd37000;
                        8'd16: page_start_ms = 32'd39000;
                        8'd17: page_start_ms = 32'd41000;
                        8'd18: page_start_ms = 32'd42500;
                        8'd19: page_start_ms = 32'd44000;
                        8'd20: page_start_ms = 32'd48500;
                        8'd21: page_start_ms = 32'd53000;
                        8'd22: page_start_ms = 32'd59000;
                        8'd23: page_start_ms = 32'd65000;
                        8'd24: page_start_ms = 32'd68000;
                        8'd25: page_start_ms = 32'd74000;
                        8'd26: page_start_ms = 32'd90000;
                        8'd27: page_start_ms = 32'd92000;
                        8'd28: page_start_ms = 32'd94500;
                        8'd29: page_start_ms = 32'd97000;
                        8'd30: page_start_ms = 32'd100000;
                        8'd31: page_start_ms = 32'd102500;
                        8'd32: page_start_ms = 32'd105000;
                        8'd33: page_start_ms = 32'd107000;
                        8'd34: page_start_ms = 32'd109000;
                        8'd35: page_start_ms = 32'd110500;
                        8'd36: page_start_ms = 32'd112000;
                        8'd37: page_start_ms = 32'd114000;
                        8'd38: page_start_ms = 32'd116000;
                        8'd39: page_start_ms = 32'd117500;
                        8'd40: page_start_ms = 32'd119000;
                        8'd41: page_start_ms = 32'd123500;
                        8'd42: page_start_ms = 32'd128000;
                        8'd43: page_start_ms = 32'd134000;
                        8'd44: page_start_ms = 32'd140000;
                        8'd45: page_start_ms = 32'd143000;
                        8'd46: page_start_ms = 32'd150000;
                        8'd47: page_start_ms = 32'd151000;
                        8'd48: page_start_ms = 32'd152000;
                        8'd49: page_start_ms = 32'd153000;
                        8'd50: page_start_ms = 32'd155000;
                        8'd51: page_start_ms = 32'd156000;
                        8'd52: page_start_ms = 32'd157000;
                        8'd53: page_start_ms = 32'd159000;
                        8'd54: page_start_ms = 32'd161000;
                        8'd55: page_start_ms = 32'd163000;
                        8'd56: page_start_ms = 32'd165000;
                        8'd57: page_start_ms = 32'd166000;
                        8'd58: page_start_ms = 32'd167000;
                        8'd59: page_start_ms = 32'd167500;
                        8'd60: page_start_ms = 32'd168000;
                        8'd61: page_start_ms = 32'd169500;
                        8'd62: page_start_ms = 32'd171000;
                        8'd63: page_start_ms = 32'd171500;
                        8'd64: page_start_ms = 32'd172000;
                        8'd65: page_start_ms = 32'd174000;
                        8'd66: page_start_ms = 32'd176500;
                        8'd67: page_start_ms = 32'd179000;
                        8'd68: page_start_ms = 32'd183500;
                        8'd69: page_start_ms = 32'd188000;
                        8'd70: page_start_ms = 32'd194000;
                        8'd71: page_start_ms = 32'd199000;
                        8'd72: page_start_ms = 32'd203000;
                        8'd73: page_start_ms = 32'd208000;
                        default: page_start_ms = 32'd208000;
                    endcase
                end
                3'd2: begin
                    case (index)
                        8'd0: page_start_ms = 32'd0;
                        8'd1: page_start_ms = 32'd6890;
                        8'd2: page_start_ms = 32'd9365;
                        8'd3: page_start_ms = 32'd11840;
                        8'd4: page_start_ms = 32'd14300;
                        8'd5: page_start_ms = 32'd16760;
                        8'd6: page_start_ms = 32'd19300;
                        8'd7: page_start_ms = 32'd21840;
                        8'd8: page_start_ms = 32'd24350;
                        8'd9: page_start_ms = 32'd26860;
                        8'd10: page_start_ms = 32'd29375;
                        8'd11: page_start_ms = 32'd31890;
                        8'd12: page_start_ms = 32'd34460;
                        8'd13: page_start_ms = 32'd37030;
                        8'd14: page_start_ms = 32'd39580;
                        8'd15: page_start_ms = 32'd42130;
                        8'd16: page_start_ms = 32'd44560;
                        8'd17: page_start_ms = 32'd46990;
                        8'd18: page_start_ms = 32'd52300;
                        8'd19: page_start_ms = 32'd57270;
                        8'd20: page_start_ms = 32'd59810;
                        8'd21: page_start_ms = 32'd62350;
                        8'd22: page_start_ms = 32'd64840;
                        8'd23: page_start_ms = 32'd67330;
                        8'd24: page_start_ms = 32'd72430;
                        8'd25: page_start_ms = 32'd77530;
                        8'd26: page_start_ms = 32'd82540;
                        8'd27: page_start_ms = 32'd87550;
                        8'd28: page_start_ms = 32'd91400;
                        8'd29: page_start_ms = 32'd92370;
                        8'd30: page_start_ms = 32'd93990;
                        8'd31: page_start_ms = 32'd94870;
                        8'd32: page_start_ms = 32'd96420;
                        8'd33: page_start_ms = 32'd97420;
                        8'd34: page_start_ms = 32'd98900;
                        8'd35: page_start_ms = 32'd99880;
                        8'd36: page_start_ms = 32'd101580;
                        8'd37: page_start_ms = 32'd102380;
                        8'd38: page_start_ms = 32'd104060;
                        8'd39: page_start_ms = 32'd104900;
                        8'd40: page_start_ms = 32'd106470;
                        8'd41: page_start_ms = 32'd107500;
                        8'd42: page_start_ms = 32'd109010;
                        8'd43: page_start_ms = 32'd110040;
                        8'd44: page_start_ms = 32'd118080;
                        8'd45: page_start_ms = 32'd119975;
                        8'd46: page_start_ms = 32'd121870;
                        8'd47: page_start_ms = 32'd122970;
                        8'd48: page_start_ms = 32'd124070;
                        8'd49: page_start_ms = 32'd125360;
                        8'd50: page_start_ms = 32'd126650;
                        8'd51: page_start_ms = 32'd127890;
                        8'd52: page_start_ms = 32'd129130;
                        8'd53: page_start_ms = 32'd136865;
                        8'd54: page_start_ms = 32'd144600;
                        8'd55: page_start_ms = 32'd147030;
                        8'd56: page_start_ms = 32'd149460;
                        8'd57: page_start_ms = 32'd151905;
                        8'd58: page_start_ms = 32'd154350;
                        8'd59: page_start_ms = 32'd156945;
                        8'd60: page_start_ms = 32'd159540;
                        8'd61: page_start_ms = 32'd161960;
                        8'd62: page_start_ms = 32'd164380;
                        8'd63: page_start_ms = 32'd172210;
                        8'd64: page_start_ms = 32'd177370;
                        8'd65: page_start_ms = 32'd182260;
                        8'd66: page_start_ms = 32'd184815;
                        8'd67: page_start_ms = 32'd187370;
                        8'd68: page_start_ms = 32'd192410;
                        8'd69: page_start_ms = 32'd197450;
                        8'd70: page_start_ms = 32'd199435;
                        8'd71: page_start_ms = 32'd201420;
                        8'd72: page_start_ms = 32'd202330;
                        8'd73: page_start_ms = 32'd203810;
                        8'd74: page_start_ms = 32'd204700;
                        8'd75: page_start_ms = 32'd206290;
                        8'd76: page_start_ms = 32'd207250;
                        8'd77: page_start_ms = 32'd208740;
                        8'd78: page_start_ms = 32'd209890;
                        default: page_start_ms = 32'd209890;
                    endcase
                end
                3'd3: begin
                    case (index)
                        8'd0: page_start_ms = 32'd0;
                        8'd1: page_start_ms = 32'd195;
                        8'd2: page_start_ms = 32'd4086;
                        8'd3: page_start_ms = 32'd7978;
                        8'd4: page_start_ms = 32'd8730;
                        8'd5: page_start_ms = 32'd10917;
                        8'd6: page_start_ms = 32'd13036;
                        8'd7: page_start_ms = 32'd14789;
                        8'd8: page_start_ms = 32'd16542;
                        8'd9: page_start_ms = 32'd17519;
                        8'd10: page_start_ms = 32'd18900;
                        8'd11: page_start_ms = 32'd20282;
                        8'd12: page_start_ms = 32'd22460;
                        8'd13: page_start_ms = 32'd22977;
                        8'd14: page_start_ms = 32'd25106;
                        8'd15: page_start_ms = 32'd27196;
                        8'd16: page_start_ms = 32'd29393;
                        8'd17: page_start_ms = 32'd31424;
                        8'd18: page_start_ms = 32'd33231;
                        8'd19: page_start_ms = 32'd34559;
                        8'd20: page_start_ms = 32'd35887;
                        8'd21: page_start_ms = 32'd38025;
                        8'd22: page_start_ms = 32'd40125;
                        8'd23: page_start_ms = 32'd42342;
                        8'd24: page_start_ms = 32'd44431;
                        8'd25: page_start_ms = 32'd46541;
                        8'd26: page_start_ms = 32'd51345;
                        8'd27: page_start_ms = 32'd55295;
                        8'd28: page_start_ms = 32'd59245;
                        8'd29: page_start_ms = 32'd59792;
                        8'd30: page_start_ms = 32'd61999;
                        8'd31: page_start_ms = 32'd64118;
                        8'd32: page_start_ms = 32'd66129;
                        8'd33: page_start_ms = 32'd68141;
                        8'd34: page_start_ms = 32'd70084;
                        8'd35: page_start_ms = 32'd72028;
                        8'd36: page_start_ms = 32'd72594;
                        8'd37: page_start_ms = 32'd74434;
                        8'd38: page_start_ms = 32'd76275;
                        8'd39: page_start_ms = 32'd76871;
                        8'd40: page_start_ms = 32'd78746;
                        8'd41: page_start_ms = 32'd80621;
                        8'd42: page_start_ms = 32'd81138;
                        8'd43: page_start_ms = 32'd82866;
                        8'd44: page_start_ms = 32'd84595;
                        8'd45: page_start_ms = 32'd85259;
                        8'd46: page_start_ms = 32'd87109;
                        8'd47: page_start_ms = 32'd88960;
                        8'd48: page_start_ms = 32'd89785;
                        8'd49: page_start_ms = 32'd90611;
                        8'd50: page_start_ms = 32'd91109;
                        8'd51: page_start_ms = 32'd93296;
                        8'd52: page_start_ms = 32'd95415;
                        8'd53: page_start_ms = 32'd97505;
                        8'd54: page_start_ms = 32'd99614;
                        8'd55: page_start_ms = 32'd101128;
                        8'd56: page_start_ms = 32'd102592;
                        8'd57: page_start_ms = 32'd104057;
                        8'd58: page_start_ms = 32'd106147;
                        8'd59: page_start_ms = 32'd108266;
                        8'd60: page_start_ms = 32'd110395;
                        8'd61: page_start_ms = 32'd112611;
                        8'd62: page_start_ms = 32'd114691;
                        8'd63: page_start_ms = 32'd117069;
                        8'd64: page_start_ms = 32'd119447;
                        8'd65: page_start_ms = 32'd123714;
                        8'd66: page_start_ms = 32'd127982;
                        8'd67: page_start_ms = 32'd130198;
                        8'd68: page_start_ms = 32'd132327;
                        8'd69: page_start_ms = 32'd134285;
                        8'd70: page_start_ms = 32'd136243;
                        8'd71: page_start_ms = 32'd138498;
                        8'd72: page_start_ms = 32'd140754;
                        8'd73: page_start_ms = 32'd142561;
                        8'd74: page_start_ms = 32'd144368;
                        8'd75: page_start_ms = 32'd145061;
                        8'd76: page_start_ms = 32'd146921;
                        8'd77: page_start_ms = 32'd148781;
                        8'd78: page_start_ms = 32'd149348;
                        8'd79: page_start_ms = 32'd151032;
                        8'd80: page_start_ms = 32'd152717;
                        8'd81: page_start_ms = 32'd153273;
                        8'd82: page_start_ms = 32'd155402;
                        8'd83: page_start_ms = 32'd158146;
                        8'd84: page_start_ms = 32'd158702;
                        8'd85: page_start_ms = 32'd159259;
                        8'd86: page_start_ms = 32'd160167;
                        8'd87: page_start_ms = 32'd161076;
                        8'd88: page_start_ms = 32'd161769;
                        8'd89: page_start_ms = 32'd163292;
                        8'd90: page_start_ms = 32'd164288;
                        8'd91: page_start_ms = 32'd165284;
                        8'd92: page_start_ms = 32'd165880;
                        8'd93: page_start_ms = 32'd166476;
                        8'd94: page_start_ms = 32'd167696;
                        8'd95: page_start_ms = 32'd168150;
                        8'd96: page_start_ms = 32'd168605;
                        8'd97: page_start_ms = 32'd169659;
                        8'd98: page_start_ms = 32'd170215;
                        8'd99: page_start_ms = 32'd170772;
                        8'd100: page_start_ms = 32'd171895;
                        8'd101: page_start_ms = 32'd172998;
                        8'd102: page_start_ms = 32'd174102;
                        8'd103: page_start_ms = 32'd176040;
                        8'd104: page_start_ms = 32'd177979;
                        8'd105: page_start_ms = 32'd180313;
                        8'd106: page_start_ms = 32'd182647;
                        8'd107: page_start_ms = 32'd183672;
                        8'd108: page_start_ms = 32'd184698;
                        8'd109: page_start_ms = 32'd185581;
                        8'd110: page_start_ms = 32'd186465;
                        8'd111: page_start_ms = 32'd187099;
                        8'd112: page_start_ms = 32'd187734;
                        8'd113: page_start_ms = 32'd191674;
                        8'd114: page_start_ms = 32'd195615;
                        8'd115: page_start_ms = 32'd196181;
                        8'd116: page_start_ms = 32'd198339;
                        8'd117: page_start_ms = 32'd200478;
                        8'd118: page_start_ms = 32'd202460;
                        8'd119: page_start_ms = 32'd204443;
                        8'd120: page_start_ms = 32'd206464;
                        8'd121: page_start_ms = 32'd208485;
                        8'd122: page_start_ms = 32'd209052;
                        8'd123: page_start_ms = 32'd210844;
                        8'd124: page_start_ms = 32'd212636;
                        8'd125: page_start_ms = 32'd213221;
                        8'd126: page_start_ms = 32'd214940;
                        8'd127: page_start_ms = 32'd216659;
                        8'd128: page_start_ms = 32'd217499;
                        8'd129: page_start_ms = 32'd219193;
                        8'd130: page_start_ms = 32'd220887;
                        8'd131: page_start_ms = 32'd221473;
                        default: page_start_ms = 32'd221473;
                    endcase
                end
                3'd4: begin
                    case (index)
                        8'd0: page_start_ms = 32'd0;
                        8'd1: page_start_ms = 32'd16260;
                        8'd2: page_start_ms = 32'd17463;
                        8'd3: page_start_ms = 32'd18666;
                        8'd4: page_start_ms = 32'd19965;
                        8'd5: page_start_ms = 32'd21264;
                        8'd6: page_start_ms = 32'd22565;
                        8'd7: page_start_ms = 32'd23866;
                        8'd8: page_start_ms = 32'd25157;
                        8'd9: page_start_ms = 32'd26448;
                        8'd10: page_start_ms = 32'd27771;
                        8'd11: page_start_ms = 32'd29095;
                        8'd12: page_start_ms = 32'd30364;
                        8'd13: page_start_ms = 32'd31634;
                        8'd14: page_start_ms = 32'd32927;
                        8'd15: page_start_ms = 32'd34221;
                        8'd16: page_start_ms = 32'd35560;
                        8'd17: page_start_ms = 32'd36900;
                        8'd18: page_start_ms = 32'd37100;
                        8'd19: page_start_ms = 32'd38211;
                        8'd20: page_start_ms = 32'd39322;
                        8'd21: page_start_ms = 32'd40765;
                        8'd22: page_start_ms = 32'd42208;
                        8'd23: page_start_ms = 32'd43189;
                        8'd24: page_start_ms = 32'd44170;
                        8'd25: page_start_ms = 32'd44920;
                        8'd26: page_start_ms = 32'd45670;
                        8'd27: page_start_ms = 32'd47283;
                        8'd28: page_start_ms = 32'd48508;
                        8'd29: page_start_ms = 32'd49734;
                        8'd30: page_start_ms = 32'd51066;
                        8'd31: page_start_ms = 32'd52398;
                        8'd32: page_start_ms = 32'd53417;
                        8'd33: page_start_ms = 32'd54437;
                        8'd34: page_start_ms = 32'd55731;
                        8'd35: page_start_ms = 32'd57025;
                        8'd36: page_start_ms = 32'd57128;
                        8'd37: page_start_ms = 32'd61266;
                        8'd38: page_start_ms = 32'd62202;
                        8'd39: page_start_ms = 32'd66062;
                        8'd40: page_start_ms = 32'd66730;
                        8'd41: page_start_ms = 32'd67398;
                        8'd42: page_start_ms = 32'd71567;
                        8'd43: page_start_ms = 32'd72525;
                        8'd44: page_start_ms = 32'd76400;
                        8'd45: page_start_ms = 32'd77181;
                        8'd46: page_start_ms = 32'd77962;
                        8'd47: page_start_ms = 32'd78079;
                        8'd48: page_start_ms = 32'd79365;
                        8'd49: page_start_ms = 32'd80651;
                        8'd50: page_start_ms = 32'd81930;
                        8'd51: page_start_ms = 32'd83210;
                        8'd52: page_start_ms = 32'd85785;
                        8'd53: page_start_ms = 32'd87058;
                        8'd54: page_start_ms = 32'd88332;
                        8'd55: page_start_ms = 32'd89356;
                        8'd56: page_start_ms = 32'd90381;
                        8'd57: page_start_ms = 32'd93611;
                        8'd58: page_start_ms = 32'd94626;
                        8'd59: page_start_ms = 32'd95641;
                        8'd60: page_start_ms = 32'd96972;
                        8'd61: page_start_ms = 32'd98304;
                        8'd62: page_start_ms = 32'd98954;
                        8'd63: page_start_ms = 32'd100086;
                        8'd64: page_start_ms = 32'd101218;
                        8'd65: page_start_ms = 32'd102636;
                        8'd66: page_start_ms = 32'd104054;
                        8'd67: page_start_ms = 32'd105054;
                        8'd68: page_start_ms = 32'd106054;
                        8'd69: page_start_ms = 32'd106804;
                        8'd70: page_start_ms = 32'd107555;
                        8'd71: page_start_ms = 32'd109002;
                        8'd72: page_start_ms = 32'd110342;
                        8'd73: page_start_ms = 32'd111682;
                        8'd74: page_start_ms = 32'd113004;
                        8'd75: page_start_ms = 32'd114327;
                        8'd76: page_start_ms = 32'd115304;
                        8'd77: page_start_ms = 32'd116281;
                        8'd78: page_start_ms = 32'd117603;
                        8'd79: page_start_ms = 32'd118925;
                        8'd80: page_start_ms = 32'd119045;
                        8'd81: page_start_ms = 32'd123273;
                        8'd82: page_start_ms = 32'd124240;
                        8'd83: page_start_ms = 32'd128013;
                        8'd84: page_start_ms = 32'd128668;
                        8'd85: page_start_ms = 32'd129323;
                        8'd86: page_start_ms = 32'd133445;
                        8'd87: page_start_ms = 32'd134487;
                        8'd88: page_start_ms = 32'd138344;
                        8'd89: page_start_ms = 32'd139210;
                        8'd90: page_start_ms = 32'd140076;
                        8'd91: page_start_ms = 32'd140659;
                        8'd92: page_start_ms = 32'd141899;
                        8'd93: page_start_ms = 32'd143198;
                        8'd94: page_start_ms = 32'd144497;
                        8'd95: page_start_ms = 32'd147079;
                        8'd96: page_start_ms = 32'd149661;
                        8'd97: page_start_ms = 32'd150935;
                        8'd98: page_start_ms = 32'd152210;
                        8'd99: page_start_ms = 32'd153510;
                        8'd100: page_start_ms = 32'd154811;
                        8'd101: page_start_ms = 32'd155949;
                        8'd102: page_start_ms = 32'd157087;
                        8'd103: page_start_ms = 32'd158685;
                        8'd104: page_start_ms = 32'd160284;
                        8'd105: page_start_ms = 32'd160906;
                        8'd106: page_start_ms = 32'd162027;
                        8'd107: page_start_ms = 32'd163149;
                        8'd108: page_start_ms = 32'd164637;
                        8'd109: page_start_ms = 32'd166126;
                        8'd110: page_start_ms = 32'd167045;
                        8'd111: page_start_ms = 32'd167964;
                        8'd112: page_start_ms = 32'd169183;
                        8'd113: page_start_ms = 32'd171112;
                        8'd114: page_start_ms = 32'd172412;
                        8'd115: page_start_ms = 32'd173712;
                        8'd116: page_start_ms = 32'd174994;
                        8'd117: page_start_ms = 32'd176277;
                        8'd118: page_start_ms = 32'd177311;
                        8'd119: page_start_ms = 32'd178345;
                        8'd120: page_start_ms = 32'd179579;
                        8'd121: page_start_ms = 32'd180814;
                        8'd122: page_start_ms = 32'd180958;
                        8'd123: page_start_ms = 32'd185064;
                        8'd124: page_start_ms = 32'd186114;
                        8'd125: page_start_ms = 32'd189924;
                        8'd126: page_start_ms = 32'd190602;
                        8'd127: page_start_ms = 32'd191281;
                        8'd128: page_start_ms = 32'd195460;
                        8'd129: page_start_ms = 32'd196433;
                        8'd130: page_start_ms = 32'd200344;
                        8'd131: page_start_ms = 32'd200923;
                        8'd132: page_start_ms = 32'd201502;
                        8'd133: page_start_ms = 32'd201642;
                        8'd134: page_start_ms = 32'd205854;
                        8'd135: page_start_ms = 32'd206771;
                        8'd136: page_start_ms = 32'd210659;
                        8'd137: page_start_ms = 32'd211294;
                        8'd138: page_start_ms = 32'd211930;
                        8'd139: page_start_ms = 32'd216140;
                        8'd140: page_start_ms = 32'd216974;
                        8'd141: page_start_ms = 32'd220944;
                        8'd142: page_start_ms = 32'd225702;
                        default: page_start_ms = 32'd225702;
                    endcase
                end
                default: page_start_ms = 32'd0;
            endcase
        end
    endfunction

    (* ASYNC_REG = "TRUE" *) reg [31:0] play_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] play_gray_sync;

    function [31:0] gray_to_binary32;
        input [31:0] gray_value;
        integer bit_number;
        begin
            gray_to_binary32[31] = gray_value[31];
            for (bit_number=30; bit_number>=0; bit_number=bit_number-1)
                gray_to_binary32[bit_number] =
                    gray_to_binary32[bit_number+1] ^ gray_value[bit_number];
        end
    endfunction

    wire [31:0] play_ms = gray_to_binary32(play_gray_sync);
    wire [7:0] last_page = last_page_for_track(track_index);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_gray_meta <= 32'd0;
            play_gray_sync <= 32'd0;
        end else begin
            play_gray_meta <= play_ms_gray_async;
            play_gray_sync <= play_gray_meta;
        end
    end

    reg [7:0] page_index;
    reg [2:0] page_track;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page_index <= 8'd0;
            page_track <= 3'd0;
        end else if (!active || (page_track != track_index)) begin
            page_index <= 8'd0;
            page_track <= track_index;
        end else if ((page_index != 0) &&
                     (play_ms < page_start_ms(track_index, page_index))) begin
            page_index <= 8'd0;
        end else if ((page_index < last_page) &&
                     (play_ms >= page_start_ms(track_index,
                                                    page_index + 8'd1))) begin
            page_index <= page_index + 8'd1;
        end
    end

    always @* begin
        line1 = "LYRIC PAGE ERROR";
        line2 = "RESET FPGA      ";
        case (track_index)
            3'd0: begin
                case (page_index)
                    8'd0: begin
                        line1 = "WE DON'T TALK...";
                        line2 = qspi_mode ? "K2 SWITCH TO SD " :
                                            "K0 PREV  K1 NEXT";
                    end
                    8'd1: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore, we     ";
                    end
                    8'd2: begin
                        line1 = "don't talk      ";
                        line2 = "anymore         ";
                    end
                    8'd3: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore, like we";
                    end
                    8'd4: begin
                        line1 = "used to do      ";
                        line2 = "                ";
                    end
                    8'd5: begin
                        line1 = "We don't love   ";
                        line2 = "anymore         ";
                    end
                    8'd6: begin
                        line1 = "What was all of ";
                        line2 = "it for?         ";
                    end
                    8'd7: begin
                        line1 = "Oh, we don't    ";
                        line2 = "talk anymore,   ";
                    end
                    8'd8: begin
                        line1 = "like we used to ";
                        line2 = "do              ";
                    end
                    8'd9: begin
                        line1 = "I just heard you";
                        line2 = "found the one   ";
                    end
                    8'd10: begin
                        line1 = "you've been     ";
                        line2 = "looking         ";
                    end
                    8'd11: begin
                        line1 = "You've been     ";
                        line2 = "looking for     ";
                    end
                    8'd12: begin
                        line1 = "I wish I would  ";
                        line2 = "have known that ";
                    end
                    8'd13: begin
                        line1 = "wasn't me       ";
                        line2 = "                ";
                    end
                    8'd14: begin
                        line1 = "Cause even after";
                        line2 = "all this time I ";
                    end
                    8'd15: begin
                        line1 = "still wonder    ";
                        line2 = "                ";
                    end
                    8'd16: begin
                        line1 = "Why I can't move";
                        line2 = "on              ";
                    end
                    8'd17: begin
                        line1 = "Just the way you";
                        line2 = "did so easily   ";
                    end
                    8'd18: begin
                        line1 = "Don't wanna know";
                        line2 = "                ";
                    end
                    8'd19: begin
                        line1 = "what kind of    ";
                        line2 = "dress you're    ";
                    end
                    8'd20: begin
                        line1 = "wearing tonight ";
                        line2 = "                ";
                    end
                    8'd21: begin
                        line1 = "If he's holding ";
                        line2 = "onto you so     ";
                    end
                    8'd22: begin
                        line1 = "tight           ";
                        line2 = "                ";
                    end
                    8'd23: begin
                        line1 = "The way I did   ";
                        line2 = "before          ";
                    end
                    8'd24: begin
                        line1 = "I overdosed     ";
                        line2 = "                ";
                    end
                    8'd25: begin
                        line1 = "Should've known ";
                        line2 = "your love was a ";
                    end
                    8'd26: begin
                        line1 = "game            ";
                        line2 = "                ";
                    end
                    8'd27: begin
                        line1 = "Now I can't get ";
                        line2 = "you out of my   ";
                    end
                    8'd28: begin
                        line1 = "brain           ";
                        line2 = "                ";
                    end
                    8'd29: begin
                        line1 = "Oh, it's such a ";
                        line2 = "shame           ";
                    end
                    8'd30: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore, we     ";
                    end
                    8'd31: begin
                        line1 = "don't talk      ";
                        line2 = "anymore         ";
                    end
                    8'd32: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore, like we";
                    end
                    8'd33: begin
                        line1 = "used to do      ";
                        line2 = "                ";
                    end
                    8'd34: begin
                        line1 = "We don't love   ";
                        line2 = "anymore         ";
                    end
                    8'd35: begin
                        line1 = "What was all of ";
                        line2 = "it for?         ";
                    end
                    8'd36: begin
                        line1 = "Oh, we don't    ";
                        line2 = "talk anymore,   ";
                    end
                    8'd37: begin
                        line1 = "like we used to ";
                        line2 = "do              ";
                    end
                    8'd38: begin
                        line1 = "Who knows how to";
                        line2 = "love you like me";
                    end
                    8'd39: begin
                        line1 = "There must be a ";
                        line2 = "good reason that";
                    end
                    8'd40: begin
                        line1 = "you're gone     ";
                        line2 = "                ";
                    end
                    8'd41: begin
                        line1 = "Every now and   ";
                        line2 = "then I think you";
                    end
                    8'd42: begin
                        line1 = "Might want me to";
                        line2 = "come show up at ";
                    end
                    8'd43: begin
                        line1 = "your door       ";
                        line2 = "                ";
                    end
                    8'd44: begin
                        line1 = "But I'm just too";
                        line2 = "afraid that I'll";
                    end
                    8'd45: begin
                        line1 = "be wrong        ";
                        line2 = "                ";
                    end
                    8'd46: begin
                        line1 = "Don't wanna know";
                        line2 = "                ";
                    end
                    8'd47: begin
                        line1 = "If you're       ";
                        line2 = "looking into her";
                    end
                    8'd48: begin
                        line1 = "eyes            ";
                        line2 = "                ";
                    end
                    8'd49: begin
                        line1 = "If she's holding";
                        line2 = "onto you so     ";
                    end
                    8'd50: begin
                        line1 = "tight the way I ";
                        line2 = "did before      ";
                    end
                    8'd51: begin
                        line1 = "I overdosed     ";
                        line2 = "                ";
                    end
                    8'd52: begin
                        line1 = "Should've known ";
                        line2 = "your love was a ";
                    end
                    8'd53: begin
                        line1 = "game            ";
                        line2 = "                ";
                    end
                    8'd54: begin
                        line1 = "Now I can't get ";
                        line2 = "you out of my   ";
                    end
                    8'd55: begin
                        line1 = "brain           ";
                        line2 = "                ";
                    end
                    8'd56: begin
                        line1 = "Oh, it's such a ";
                        line2 = "shame           ";
                    end
                    8'd57: begin
                        line1 = "That we don't   ";
                        line2 = "talk anymore (We";
                    end
                    8'd58: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd59: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore (We     ";
                    end
                    8'd60: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd61: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore, like we";
                    end
                    8'd62: begin
                        line1 = "used to do      ";
                        line2 = "                ";
                    end
                    8'd63: begin
                        line1 = "We don't love   ";
                        line2 = "anymore (We     ";
                    end
                    8'd64: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd65: begin
                        line1 = "What was all of ";
                        line2 = "it for? (We     ";
                    end
                    8'd66: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd67: begin
                        line1 = "Oh, we don't    ";
                        line2 = "talk anymore,   ";
                    end
                    8'd68: begin
                        line1 = "like we used to ";
                        line2 = "do              ";
                    end
                    8'd69: begin
                        line1 = "Like we used to ";
                        line2 = "do              ";
                    end
                    8'd70: begin
                        line1 = "Don't wanna know";
                        line2 = "                ";
                    end
                    8'd71: begin
                        line1 = "kind of dress   ";
                        line2 = "you're wearing  ";
                    end
                    8'd72: begin
                        line1 = "tonight         ";
                        line2 = "                ";
                    end
                    8'd73: begin
                        line1 = "If he's giving  ";
                        line2 = "it to you just  ";
                    end
                    8'd74: begin
                        line1 = "right           ";
                        line2 = "                ";
                    end
                    8'd75: begin
                        line1 = "The way I did   ";
                        line2 = "before          ";
                    end
                    8'd76: begin
                        line1 = "I overdosed     ";
                        line2 = "                ";
                    end
                    8'd77: begin
                        line1 = "Should've known ";
                        line2 = "your love was a ";
                    end
                    8'd78: begin
                        line1 = "game            ";
                        line2 = "                ";
                    end
                    8'd79: begin
                        line1 = "Now I can't get ";
                        line2 = "you out of my   ";
                    end
                    8'd80: begin
                        line1 = "brain           ";
                        line2 = "                ";
                    end
                    8'd81: begin
                        line1 = "Oh, it's such a ";
                        line2 = "shame           ";
                    end
                    8'd82: begin
                        line1 = "That we don't   ";
                        line2 = "talk anymore (We";
                    end
                    8'd83: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd84: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore (We     ";
                    end
                    8'd85: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd86: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore, like we";
                    end
                    8'd87: begin
                        line1 = "used to do      ";
                        line2 = "                ";
                    end
                    8'd88: begin
                        line1 = "We don't love   ";
                        line2 = "anymore (We     ";
                    end
                    8'd89: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd90: begin
                        line1 = "What was all of ";
                        line2 = "it for? (We     ";
                    end
                    8'd91: begin
                        line1 = "don't, we don't)";
                        line2 = "                ";
                    end
                    8'd92: begin
                        line1 = "Oh, we don't    ";
                        line2 = "talk anymore,   ";
                    end
                    8'd93: begin
                        line1 = "like we used to ";
                        line2 = "do              ";
                    end
                    8'd94: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore         ";
                    end
                    8'd95: begin
                        line1 = "What kind of    ";
                        line2 = "dress you're    ";
                    end
                    8'd96: begin
                        line1 = "wearing tonight ";
                        line2 = "(Oh)            ";
                    end
                    8'd97: begin
                        line1 = "If he's holding ";
                        line2 = "onto you so     ";
                    end
                    8'd98: begin
                        line1 = "tight (Oh)      ";
                        line2 = "                ";
                    end
                    8'd99: begin
                        line1 = "The way I did   ";
                        line2 = "before          ";
                    end
                    8'd100: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore (I      ";
                    end
                    8'd101: begin
                        line1 = "overdosed)      ";
                        line2 = "                ";
                    end
                    8'd102: begin
                        line1 = "Should've known ";
                        line2 = "your love was a ";
                    end
                    8'd103: begin
                        line1 = "game (Oh)       ";
                        line2 = "                ";
                    end
                    8'd104: begin
                        line1 = "Now I can't get ";
                        line2 = "you out of my   ";
                    end
                    8'd105: begin
                        line1 = "brain (Woah)    ";
                        line2 = "                ";
                    end
                    8'd106: begin
                        line1 = "Oh, it's such a ";
                        line2 = "shame           ";
                    end
                    8'd107: begin
                        line1 = "We don't talk   ";
                        line2 = "anymore         ";
                    end
                    8'd108: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    default: begin
                        line1 = "LYRIC PAGE ERROR";
                        line2 = "RESET FPGA      ";
                    end
                endcase
            end
            3'd1: begin
                case (page_index)
                    8'd0: begin
                        line1 = "BEAUTY AND BEAT ";
                        line2 = "K0 PREV  K1 NEXT";
                    end
                    8'd1: begin
                        line1 = "Yeah            ";
                        line2 = "                ";
                    end
                    8'd2: begin
                        line1 = "Young Money     ";
                        line2 = "                ";
                    end
                    8'd3: begin
                        line1 = "Nicki Minaj     ";
                        line2 = "                ";
                    end
                    8'd4: begin
                        line1 = "Justin          ";
                        line2 = "                ";
                    end
                    8'd5: begin
                        line1 = "Show you off    ";
                        line2 = "                ";
                    end
                    8'd6: begin
                        line1 = "Tonight I wanna ";
                        line2 = "show you off aye";
                    end
                    8'd7: begin
                        line1 = "aye aye         ";
                        line2 = "                ";
                    end
                    8'd8: begin
                        line1 = "What you got    ";
                        line2 = "                ";
                    end
                    8'd9: begin
                        line1 = "A billion       ";
                        line2 = "could've never  ";
                    end
                    8'd10: begin
                        line1 = "bought aye aye  ";
                        line2 = "aye             ";
                    end
                    8'd11: begin
                        line1 = "We gonna party  ";
                        line2 = "like it's 3012  ";
                    end
                    8'd12: begin
                        line1 = "tonight         ";
                        line2 = "                ";
                    end
                    8'd13: begin
                        line1 = "I wanna show you";
                        line2 = "all the finer   ";
                    end
                    8'd14: begin
                        line1 = "things in life  ";
                        line2 = "                ";
                    end
                    8'd15: begin
                        line1 = "So just forget  ";
                        line2 = "about the world ";
                    end
                    8'd16: begin
                        line1 = "we young tonight";
                        line2 = "                ";
                    end
                    8'd17: begin
                        line1 = "I'm coming for  ";
                        line2 = "ya I'm coming   ";
                    end
                    8'd18: begin
                        line1 = "for ya          ";
                        line2 = "                ";
                    end
                    8'd19: begin
                        line1 = "Cause all I need";
                        line2 = "is a beauty and ";
                    end
                    8'd20: begin
                        line1 = "a beat          ";
                        line2 = "                ";
                    end
                    8'd21: begin
                        line1 = "Who can make my ";
                        line2 = "life complete   ";
                    end
                    8'd22: begin
                        line1 = "It's all 'bout  ";
                        line2 = "you             ";
                    end
                    8'd23: begin
                        line1 = "When the music  ";
                        line2 = "makes you move  ";
                    end
                    8'd24: begin
                        line1 = "Baby do it like ";
                        line2 = "you do          ";
                    end
                    8'd25: begin
                        line1 = "'Cause          ";
                        line2 = "                ";
                    end
                    8'd26: begin
                        line1 = "Body rock       ";
                        line2 = "                ";
                    end
                    8'd27: begin
                        line1 = "Girl I can feel ";
                        line2 = "your body rock  ";
                    end
                    8'd28: begin
                        line1 = "aye aye aye     ";
                        line2 = "                ";
                    end
                    8'd29: begin
                        line1 = "Take a bow      ";
                        line2 = "                ";
                    end
                    8'd30: begin
                        line1 = "You're on the   ";
                        line2 = "hottest ticket  ";
                    end
                    8'd31: begin
                        line1 = "now ooh aye aye ";
                        line2 = "aye             ";
                    end
                    8'd32: begin
                        line1 = "We gonna party  ";
                        line2 = "like it's 3012  ";
                    end
                    8'd33: begin
                        line1 = "tonight         ";
                        line2 = "                ";
                    end
                    8'd34: begin
                        line1 = "I want to show  ";
                        line2 = "you all the     ";
                    end
                    8'd35: begin
                        line1 = "finer things in ";
                        line2 = "life            ";
                    end
                    8'd36: begin
                        line1 = "So just forget  ";
                        line2 = "about the world ";
                    end
                    8'd37: begin
                        line1 = "we young tonight";
                        line2 = "                ";
                    end
                    8'd38: begin
                        line1 = "I'm coming for  ";
                        line2 = "ya I'm coming   ";
                    end
                    8'd39: begin
                        line1 = "for ya          ";
                        line2 = "                ";
                    end
                    8'd40: begin
                        line1 = "Cause all I need";
                        line2 = "is a beauty and ";
                    end
                    8'd41: begin
                        line1 = "a beat          ";
                        line2 = "                ";
                    end
                    8'd42: begin
                        line1 = "Who can make my ";
                        line2 = "life complete   ";
                    end
                    8'd43: begin
                        line1 = "It's all 'bout  ";
                        line2 = "you             ";
                    end
                    8'd44: begin
                        line1 = "When the music  ";
                        line2 = "makes you move  ";
                    end
                    8'd45: begin
                        line1 = "Baby do it like ";
                        line2 = "you do          ";
                    end
                    8'd46: begin
                        line1 = "In time ink     ";
                        line2 = "lines           ";
                    end
                    8'd47: begin
                        line1 = "******* couldn't";
                        line2 = "get on my       ";
                    end
                    8'd48: begin
                        line1 = "incline         ";
                        line2 = "                ";
                    end
                    8'd49: begin
                        line1 = "World tours it's";
                        line2 = "mine            ";
                    end
                    8'd50: begin
                        line1 = "Ten little      ";
                        line2 = "letters on a big";
                    end
                    8'd51: begin
                        line1 = "sign            ";
                        line2 = "                ";
                    end
                    8'd52: begin
                        line1 = "Justin Bieber   ";
                        line2 = "you know I'mma  ";
                    end
                    8'd53: begin
                        line1 = "hit 'em with the";
                        line2 = "ether           ";
                    end
                    8'd54: begin
                        line1 = "Buns out wiener ";
                        line2 = "but I gotta keep";
                    end
                    8'd55: begin
                        line1 = "an eye out for  ";
                        line2 = "Selener         ";
                    end
                    8'd56: begin
                        line1 = "Beauty beauty   ";
                        line2 = "and the beast   ";
                    end
                    8'd57: begin
                        line1 = "Beauty from the ";
                        line2 = "East            ";
                    end
                    8'd58: begin
                        line1 = "Beautiful       ";
                        line2 = "confessions of  ";
                    end
                    8'd59: begin
                        line1 = "the priest      ";
                        line2 = "                ";
                    end
                    8'd60: begin
                        line1 = "Beast beauty    ";
                        line2 = "from the streets";
                    end
                    8'd61: begin
                        line1 = "beat will get   ";
                        line2 = "deceased        ";
                    end
                    8'd62: begin
                        line1 = "Every time      ";
                        line2 = "Beauty on the   ";
                    end
                    8'd63: begin
                        line1 = "beat            ";
                        line2 = "                ";
                    end
                    8'd64: begin
                        line1 = "Body rock       ";
                        line2 = "                ";
                    end
                    8'd65: begin
                        line1 = "Girl I wanna    ";
                        line2 = "feel your body  ";
                    end
                    8'd66: begin
                        line1 = "rock            ";
                        line2 = "                ";
                    end
                    8'd67: begin
                        line1 = "Cause all I need";
                        line2 = "is a beauty and ";
                    end
                    8'd68: begin
                        line1 = "a beat          ";
                        line2 = "                ";
                    end
                    8'd69: begin
                        line1 = "Who can make my ";
                        line2 = "life complete   ";
                    end
                    8'd70: begin
                        line1 = "It's all 'bout  ";
                        line2 = "you             ";
                    end
                    8'd71: begin
                        line1 = "When the music  ";
                        line2 = "makes you move  ";
                    end
                    8'd72: begin
                        line1 = "Baby do it like ";
                        line2 = "you do          ";
                    end
                    8'd73: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    default: begin
                        line1 = "LYRIC PAGE ERROR";
                        line2 = "RESET FPGA      ";
                    end
                endcase
            end
            3'd2: begin
                case (page_index)
                    8'd0: begin
                        line1 = "DIE FOR YOU     ";
                        line2 = "K0 PREV  K1 NEXT";
                    end
                    8'd1: begin
                        line1 = "Time slows down ";
                        line2 = "when it can get ";
                    end
                    8'd2: begin
                        line1 = "no worse        ";
                        line2 = "                ";
                    end
                    8'd3: begin
                        line1 = "I can feel it   ";
                        line2 = "running out on  ";
                    end
                    8'd4: begin
                        line1 = "me              ";
                        line2 = "                ";
                    end
                    8'd5: begin
                        line1 = "I don't want    ";
                        line2 = "these to be my  ";
                    end
                    8'd6: begin
                        line1 = "last words      ";
                        line2 = "                ";
                    end
                    8'd7: begin
                        line1 = "All forgotten   ";
                        line2 = "'cause that's   ";
                    end
                    8'd8: begin
                        line1 = "all they'll be  ";
                        line2 = "                ";
                    end
                    8'd9: begin
                        line1 = "Now there's only";
                        line2 = "one thing I can ";
                    end
                    8'd10: begin
                        line1 = "do              ";
                        line2 = "                ";
                    end
                    8'd11: begin
                        line1 = "Fight until the ";
                        line2 = "end like I      ";
                    end
                    8'd12: begin
                        line1 = "promised to     ";
                        line2 = "                ";
                    end
                    8'd13: begin
                        line1 = "Wishing there   ";
                        line2 = "was something   ";
                    end
                    8'd14: begin
                        line1 = "left to lose    ";
                        line2 = "                ";
                    end
                    8'd15: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd16: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd17: begin
                        line1 = "What do you see ";
                        line2 = "before it's over";
                    end
                    8'd18: begin
                        line1 = "Blinding flashes";
                        line2 = "getting closer  ";
                    end
                    8'd19: begin
                        line1 = "Wish that I had ";
                        line2 = "something left  ";
                    end
                    8'd20: begin
                        line1 = "to lose         ";
                        line2 = "                ";
                    end
                    8'd21: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd22: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd23: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd24: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd25: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd26: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd27: begin
                        line1 = "This could be   ";
                        line2 = "the day         ";
                    end
                    8'd28: begin
                        line1 = "Everything I    ";
                        line2 = "know            ";
                    end
                    8'd29: begin
                        line1 = "Everything I    ";
                        line2 = "hold tight      ";
                    end
                    8'd30: begin
                        line1 = "When to let it  ";
                        line2 = "go              ";
                    end
                    8'd31: begin
                        line1 = "When to make em ";
                        line2 = "all fight       ";
                    end
                    8'd32: begin
                        line1 = "When I'm in     ";
                        line2 = "control         ";
                    end
                    8'd33: begin
                        line1 = "When I'm out of ";
                        line2 = "my mind         ";
                    end
                    8'd34: begin
                        line1 = "When I gotta    ";
                        line2 = "live            ";
                    end
                    8'd35: begin
                        line1 = "When I gotta die";
                        line2 = "gotta die       ";
                    end
                    8'd36: begin
                        line1 = "Everything I    ";
                        line2 = "know            ";
                    end
                    8'd37: begin
                        line1 = "Everything I    ";
                        line2 = "hold tight      ";
                    end
                    8'd38: begin
                        line1 = "When to let it  ";
                        line2 = "go              ";
                    end
                    8'd39: begin
                        line1 = "When to make em ";
                        line2 = "all fight       ";
                    end
                    8'd40: begin
                        line1 = "When I'm in     ";
                        line2 = "control         ";
                    end
                    8'd41: begin
                        line1 = "When I'm out of ";
                        line2 = "my mind         ";
                    end
                    8'd42: begin
                        line1 = "When I gotta    ";
                        line2 = "live            ";
                    end
                    8'd43: begin
                        line1 = "When I gotta die";
                        line2 = "                ";
                    end
                    8'd44: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd45: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd46: begin
                        line1 = "Everything I    ";
                        line2 = "know Everything ";
                    end
                    8'd47: begin
                        line1 = "I hold tight    ";
                        line2 = "                ";
                    end
                    8'd48: begin
                        line1 = "When to let it  ";
                        line2 = "go When to make ";
                    end
                    8'd49: begin
                        line1 = "em all fight    ";
                        line2 = "                ";
                    end
                    8'd50: begin
                        line1 = "When I'm in     ";
                        line2 = "control When I'm";
                    end
                    8'd51: begin
                        line1 = "out of my mind  ";
                        line2 = "                ";
                    end
                    8'd52: begin
                        line1 = "When I gotta    ";
                        line2 = "live When I     ";
                    end
                    8'd53: begin
                        line1 = "gotta die       ";
                        line2 = "                ";
                    end
                    8'd54: begin
                        line1 = "Feeling like    ";
                        line2 = "there's nothing ";
                    end
                    8'd55: begin
                        line1 = "I can do        ";
                        line2 = "                ";
                    end
                    8'd56: begin
                        line1 = "This could be   ";
                        line2 = "the end it's    ";
                    end
                    8'd57: begin
                        line1 = "mine to choose  ";
                        line2 = "                ";
                    end
                    8'd58: begin
                        line1 = "It's taken me my";
                        line2 = "lifetime just to";
                    end
                    8'd59: begin
                        line1 = "prove           ";
                        line2 = "                ";
                    end
                    8'd60: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd61: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd62: begin
                        line1 = "Don't let it be ";
                        line2 = "the day         ";
                    end
                    8'd63: begin
                        line1 = "What do you see ";
                        line2 = "before it's over";
                    end
                    8'd64: begin
                        line1 = "Blinding flashes";
                        line2 = "getting closer  ";
                    end
                    8'd65: begin
                        line1 = "Sacrificing     ";
                        line2 = "everything I    ";
                    end
                    8'd66: begin
                        line1 = "knew            ";
                        line2 = "                ";
                    end
                    8'd67: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd68: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd69: begin
                        line1 = "This could be   ";
                        line2 = "the day I die   ";
                    end
                    8'd70: begin
                        line1 = "for you         ";
                        line2 = "                ";
                    end
                    8'd71: begin
                        line1 = "Everything I    ";
                        line2 = "know            ";
                    end
                    8'd72: begin
                        line1 = "Everything I    ";
                        line2 = "hold tight      ";
                    end
                    8'd73: begin
                        line1 = "When to let it  ";
                        line2 = "go              ";
                    end
                    8'd74: begin
                        line1 = "When to make em ";
                        line2 = "all fight       ";
                    end
                    8'd75: begin
                        line1 = "When I'm in     ";
                        line2 = "control         ";
                    end
                    8'd76: begin
                        line1 = "When I'm out of ";
                        line2 = "my mind         ";
                    end
                    8'd77: begin
                        line1 = "When I gotta    ";
                        line2 = "live            ";
                    end
                    8'd78: begin
                        line1 = "When I gotta die";
                        line2 = "                ";
                    end
                    default: begin
                        line1 = "LYRIC PAGE ERROR";
                        line2 = "RESET FPGA      ";
                    end
                endcase
            end
            3'd3: begin
                case (page_index)
                    8'd0: begin
                        line1 = "PAYPHONE        ";
                        line2 = "K0 PREV  K1 NEXT";
                    end
                    8'd1: begin
                        line1 = "I'm at a        ";
                        line2 = "payphone trying ";
                    end
                    8'd2: begin
                        line1 = "to call home    ";
                        line2 = "                ";
                    end
                    8'd3: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd4: begin
                        line1 = "Where have the  ";
                        line2 = "times gone?     ";
                    end
                    8'd5: begin
                        line1 = "Baby, it's all  ";
                        line2 = "wrong           ";
                    end
                    8'd6: begin
                        line1 = "Where are the   ";
                        line2 = "plans we made   ";
                    end
                    8'd7: begin
                        line1 = "for two         ";
                        line2 = "                ";
                    end
                    8'd8: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd9: begin
                        line1 = "Yeah, I, I know ";
                        line2 = "it's hard to    ";
                    end
                    8'd10: begin
                        line1 = "remember        ";
                        line2 = "                ";
                    end
                    8'd11: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd12: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd13: begin
                        line1 = "It's even harder";
                        line2 = "to picture,     ";
                    end
                    8'd14: begin
                        line1 = "That you're not ";
                        line2 = "here next to me.";
                    end
                    8'd15: begin
                        line1 = "You say it's too";
                        line2 = "late to make it,";
                    end
                    8'd16: begin
                        line1 = "But is it too   ";
                        line2 = "late to try?    ";
                    end
                    8'd17: begin
                        line1 = "And in our time ";
                        line2 = "that you wasted ";
                    end
                    8'd18: begin
                        line1 = "All of our      ";
                        line2 = "bridges burned  ";
                    end
                    8'd19: begin
                        line1 = "down            ";
                        line2 = "                ";
                    end
                    8'd20: begin
                        line1 = "I've wasted my  ";
                        line2 = "nights,         ";
                    end
                    8'd21: begin
                        line1 = "You turned out  ";
                        line2 = "the lights      ";
                    end
                    8'd22: begin
                        line1 = "Now I'm         ";
                        line2 = "paralyzed.      ";
                    end
                    8'd23: begin
                        line1 = "Still stuck in  ";
                        line2 = "that time       ";
                    end
                    8'd24: begin
                        line1 = "When we called  ";
                        line2 = "it love         ";
                    end
                    8'd25: begin
                        line1 = "But even the sun";
                        line2 = "sets in paradise";
                    end
                    8'd26: begin
                        line1 = "I'm at a        ";
                        line2 = "payphone trying ";
                    end
                    8'd27: begin
                        line1 = "to call home    ";
                        line2 = "                ";
                    end
                    8'd28: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd29: begin
                        line1 = "Where have the  ";
                        line2 = "times gone      ";
                    end
                    8'd30: begin
                        line1 = "Baby, it's all  ";
                        line2 = "wrong           ";
                    end
                    8'd31: begin
                        line1 = "Where are the   ";
                        line2 = "plans we made   ";
                    end
                    8'd32: begin
                        line1 = "for two         ";
                        line2 = "                ";
                    end
                    8'd33: begin
                        line1 = "If \"Happy Ever  ";
                        line2 = "After\" did      ";
                    end
                    8'd34: begin
                        line1 = "exist,          ";
                        line2 = "                ";
                    end
                    8'd35: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd36: begin
                        line1 = "I would still be";
                        line2 = "holding you like";
                    end
                    8'd37: begin
                        line1 = "this            ";
                        line2 = "                ";
                    end
                    8'd38: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd39: begin
                        line1 = "All those fairy ";
                        line2 = "tales are full  ";
                    end
                    8'd40: begin
                        line1 = "of bullshit     ";
                        line2 = "                ";
                    end
                    8'd41: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd42: begin
                        line1 = "One more ****ing";
                        line2 = "love song, I'll ";
                    end
                    8'd43: begin
                        line1 = "be sick         ";
                        line2 = "                ";
                    end
                    8'd44: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd45: begin
                        line1 = "Oh, you turned  ";
                        line2 = "your back on    ";
                    end
                    8'd46: begin
                        line1 = "tomorrow        ";
                        line2 = "                ";
                    end
                    8'd47: begin
                        line1 = "'Cause you      ";
                        line2 = "forgot          ";
                    end
                    8'd48: begin
                        line1 = "yesterday.      ";
                        line2 = "                ";
                    end
                    8'd49: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd50: begin
                        line1 = "I gave you my   ";
                        line2 = "love to borrow, ";
                    end
                    8'd51: begin
                        line1 = "But you just    ";
                        line2 = "gave it away.   ";
                    end
                    8'd52: begin
                        line1 = "You can't expect";
                        line2 = "me to be fine,  ";
                    end
                    8'd53: begin
                        line1 = "I don't expect  ";
                        line2 = "you to care     ";
                    end
                    8'd54: begin
                        line1 = "I know I've said";
                        line2 = "it before       ";
                    end
                    8'd55: begin
                        line1 = "But all of our  ";
                        line2 = "bridges burned  ";
                    end
                    8'd56: begin
                        line1 = "down.           ";
                        line2 = "                ";
                    end
                    8'd57: begin
                        line1 = "I've wasted my  ";
                        line2 = "nights,         ";
                    end
                    8'd58: begin
                        line1 = "You turned out  ";
                        line2 = "the lights      ";
                    end
                    8'd59: begin
                        line1 = "Now I'm         ";
                        line2 = "paralyzed.      ";
                    end
                    8'd60: begin
                        line1 = "Still stuck in  ";
                        line2 = "that time       ";
                    end
                    8'd61: begin
                        line1 = "When we called  ";
                        line2 = "it love         ";
                    end
                    8'd62: begin
                        line1 = "But even the sun";
                        line2 = "sets in         ";
                    end
                    8'd63: begin
                        line1 = "paradise.       ";
                        line2 = "                ";
                    end
                    8'd64: begin
                        line1 = "I'm at a        ";
                        line2 = "payphone trying ";
                    end
                    8'd65: begin
                        line1 = "to call home    ";
                        line2 = "                ";
                    end
                    8'd66: begin
                        line1 = "Where have the  ";
                        line2 = "times gone?     ";
                    end
                    8'd67: begin
                        line1 = "Baby, it's all  ";
                        line2 = "wrong           ";
                    end
                    8'd68: begin
                        line1 = "Where are the   ";
                        line2 = "plans we made   ";
                    end
                    8'd69: begin
                        line1 = "for two?        ";
                        line2 = "                ";
                    end
                    8'd70: begin
                        line1 = "If \"Happy Ever  ";
                        line2 = "After\" did      ";
                    end
                    8'd71: begin
                        line1 = "exist,          ";
                        line2 = "                ";
                    end
                    8'd72: begin
                        line1 = "I would still be";
                        line2 = "holding you like";
                    end
                    8'd73: begin
                        line1 = "this            ";
                        line2 = "                ";
                    end
                    8'd74: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd75: begin
                        line1 = "All those fairy ";
                        line2 = "tales are full  ";
                    end
                    8'd76: begin
                        line1 = "of bullshit     ";
                        line2 = "                ";
                    end
                    8'd77: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd78: begin
                        line1 = "One more ****ing";
                        line2 = "love song, I'll ";
                    end
                    8'd79: begin
                        line1 = "be sick         ";
                        line2 = "                ";
                    end
                    8'd80: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd81: begin
                        line1 = "Now I'm at a    ";
                        line2 = "payphone        ";
                    end
                    8'd82: begin
                        line1 = "Man, **** that  ";
                        line2 = "shi             ";
                    end
                    8'd83: begin
                        line1 = "While you're    ";
                        line2 = "sitting round   ";
                    end
                    8'd84: begin
                        line1 = "wondering       ";
                        line2 = "                ";
                    end
                    8'd85: begin
                        line1 = "Why it wasn't   ";
                        line2 = "you who came up ";
                    end
                    8'd86: begin
                        line1 = "from nothing,   ";
                        line2 = "                ";
                    end
                    8'd87: begin
                        line1 = "Made it from the";
                        line2 = "bottom          ";
                    end
                    8'd88: begin
                        line1 = "Now when you see";
                        line2 = "me I'm stunning,";
                    end
                    8'd89: begin
                        line1 = "And all of my   ";
                        line2 = "cars start with ";
                    end
                    8'd90: begin
                        line1 = "a push of a     ";
                        line2 = "button          ";
                    end
                    8'd91: begin
                        line1 = "Telling me the  ";
                        line2 = "chances I blew  ";
                    end
                    8'd92: begin
                        line1 = "up              ";
                        line2 = "                ";
                    end
                    8'd93: begin
                        line1 = "Or whatever you ";
                        line2 = "call it,        ";
                    end
                    8'd94: begin
                        line1 = "Switch the      ";
                        line2 = "number to my    ";
                    end
                    8'd95: begin
                        line1 = "phone           ";
                        line2 = "                ";
                    end
                    8'd96: begin
                        line1 = "So you never    ";
                        line2 = "could call it,  ";
                    end
                    8'd97: begin
                        line1 = "Don't need my   ";
                        line2 = "name on my      ";
                    end
                    8'd98: begin
                        line1 = "*******rt,      ";
                        line2 = "                ";
                    end
                    8'd99: begin
                        line1 = "You can tell it ";
                        line2 = "I'm ballin.     ";
                    end
                    8'd100: begin
                        line1 = "Swish, what a   ";
                        line2 = "shame could have";
                    end
                    8'd101: begin
                        line1 = "got picked      ";
                        line2 = "                ";
                    end
                    8'd102: begin
                        line1 = "Had a really    ";
                        line2 = "good game but   ";
                    end
                    8'd103: begin
                        line1 = "you missed your ";
                        line2 = "last shot       ";
                    end
                    8'd104: begin
                        line1 = "Or what you     ";
                        line2 = "could have saw  ";
                    end
                    8'd105: begin
                        line1 = "but sad to say  ";
                        line2 = "it's over for.  ";
                    end
                    8'd106: begin
                        line1 = "Wiz like go     ";
                        line2 = "away, got what  ";
                    end
                    8'd107: begin
                        line1 = "you was looking ";
                        line2 = "for             ";
                    end
                    8'd108: begin
                        line1 = "Now it's me who ";
                        line2 = "they want, so   ";
                    end
                    8'd109: begin
                        line1 = "you can go and  ";
                        line2 = "take            ";
                    end
                    8'd110: begin
                        line1 = "That little     ";
                        line2 = "piece of shit   ";
                    end
                    8'd111: begin
                        line1 = "with you        ";
                        line2 = "                ";
                    end
                    8'd112: begin
                        line1 = "I'm at a        ";
                        line2 = "payphone trying ";
                    end
                    8'd113: begin
                        line1 = "to call home    ";
                        line2 = "                ";
                    end
                    8'd114: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd115: begin
                        line1 = "Where have the  ";
                        line2 = "times gone?     ";
                    end
                    8'd116: begin
                        line1 = "Baby, it's all  ";
                        line2 = "wrong           ";
                    end
                    8'd117: begin
                        line1 = "Where are the   ";
                        line2 = "plans we made   ";
                    end
                    8'd118: begin
                        line1 = "for two?        ";
                        line2 = "                ";
                    end
                    8'd119: begin
                        line1 = "If \"Happy Ever  ";
                        line2 = "After\" did      ";
                    end
                    8'd120: begin
                        line1 = "exist,          ";
                        line2 = "                ";
                    end
                    8'd121: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd122: begin
                        line1 = "I would still be";
                        line2 = "holding you like";
                    end
                    8'd123: begin
                        line1 = "this            ";
                        line2 = "                ";
                    end
                    8'd124: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd125: begin
                        line1 = "All those fairy ";
                        line2 = "tales are full  ";
                    end
                    8'd126: begin
                        line1 = "of bullshit     ";
                        line2 = "                ";
                    end
                    8'd127: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd128: begin
                        line1 = "One more ****ing";
                        line2 = "love song, I'll ";
                    end
                    8'd129: begin
                        line1 = "be sick         ";
                        line2 = "                ";
                    end
                    8'd130: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd131: begin
                        line1 = "Now I'm at a    ";
                        line2 = "payphone        ";
                    end
                    default: begin
                        line1 = "LYRIC PAGE ERROR";
                        line2 = "RESET FPGA      ";
                    end
                endcase
            end
            3'd4: begin
                case (page_index)
                    8'd0: begin
                        line1 = "STARBOY         ";
                        line2 = "K0 PREV  K1 NEXT";
                    end
                    8'd1: begin
                        line1 = "I'm tryna put   ";
                        line2 = "you in the worst";
                    end
                    8'd2: begin
                        line1 = "mood, ah        ";
                        line2 = "                ";
                    end
                    8'd3: begin
                        line1 = "P1 cleaner than ";
                        line2 = "your church     ";
                    end
                    8'd4: begin
                        line1 = "shoes, ah       ";
                        line2 = "                ";
                    end
                    8'd5: begin
                        line1 = "Milli point two ";
                        line2 = "just to hurt    ";
                    end
                    8'd6: begin
                        line1 = "you, ah         ";
                        line2 = "                ";
                    end
                    8'd7: begin
                        line1 = "All red lamb    ";
                        line2 = "just to tease   ";
                    end
                    8'd8: begin
                        line1 = "you, ah         ";
                        line2 = "                ";
                    end
                    8'd9: begin
                        line1 = "None of these   ";
                        line2 = "toys on lease   ";
                    end
                    8'd10: begin
                        line1 = "too, ah         ";
                        line2 = "                ";
                    end
                    8'd11: begin
                        line1 = "Made your whole ";
                        line2 = "year in a week  ";
                    end
                    8'd12: begin
                        line1 = "too, yeah       ";
                        line2 = "                ";
                    end
                    8'd13: begin
                        line1 = "Main b***h out  ";
                        line2 = "of your league  ";
                    end
                    8'd14: begin
                        line1 = "too, ah         ";
                        line2 = "                ";
                    end
                    8'd15: begin
                        line1 = "Side b***h out  ";
                        line2 = "of your league  ";
                    end
                    8'd16: begin
                        line1 = "too, ah         ";
                        line2 = "                ";
                    end
                    8'd17: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd18: begin
                        line1 = "House so empty, ";
                        line2 = "need a          ";
                    end
                    8'd19: begin
                        line1 = "centerpiece     ";
                        line2 = "                ";
                    end
                    8'd20: begin
                        line1 = "Twenty racks, a ";
                        line2 = "table cut from  ";
                    end
                    8'd21: begin
                        line1 = "ebony           ";
                        line2 = "                ";
                    end
                    8'd22: begin
                        line1 = "Cut that ivory  ";
                        line2 = "into skinny     ";
                    end
                    8'd23: begin
                        line1 = "pieces          ";
                        line2 = "                ";
                    end
                    8'd24: begin
                        line1 = "Then she clean  ";
                        line2 = "it with her     ";
                    end
                    8'd25: begin
                        line1 = "face, man       ";
                        line2 = "                ";
                    end
                    8'd26: begin
                        line1 = "I love my baby  ";
                        line2 = "                ";
                    end
                    8'd27: begin
                        line1 = "You talking     ";
                        line2 = "money, need a   ";
                    end
                    8'd28: begin
                        line1 = "hearing aid     ";
                        line2 = "                ";
                    end
                    8'd29: begin
                        line1 = "You talking     ";
                        line2 = "'bout me, I     ";
                    end
                    8'd30: begin
                        line1 = "don't see the   ";
                        line2 = "shade           ";
                    end
                    8'd31: begin
                        line1 = "Switch up my    ";
                        line2 = "style, I take   ";
                    end
                    8'd32: begin
                        line1 = "any lane        ";
                        line2 = "                ";
                    end
                    8'd33: begin
                        line1 = "I switch up my  ";
                        line2 = "cup, I kill any ";
                    end
                    8'd34: begin
                        line1 = "pain            ";
                        line2 = "                ";
                    end
                    8'd35: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd36: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd37: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd38: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd39: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd40: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd41: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd42: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd43: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd44: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd45: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd46: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd47: begin
                        line1 = "Every day a     ";
                        line2 = "nigga try to    ";
                    end
                    8'd48: begin
                        line1 = "test me, ah     ";
                        line2 = "                ";
                    end
                    8'd49: begin
                        line1 = "Every day a     ";
                        line2 = "nigga try to end";
                    end
                    8'd50: begin
                        line1 = "me, ah          ";
                        line2 = "                ";
                    end
                    8'd51: begin
                        line1 = "Pull off in that";
                        line2 = "roadster SV, ah ";
                    end
                    8'd52: begin
                        line1 = "Pockets over    ";
                        line2 = "weight getting  ";
                    end
                    8'd53: begin
                        line1 = "hefty, ah       ";
                        line2 = "                ";
                    end
                    8'd54: begin
                        line1 = "Coming for the  ";
                        line2 = "king, that's a  ";
                    end
                    8'd55: begin
                        line1 = "far cry         ";
                        line2 = "                ";
                    end
                    8'd56: begin
                        line1 = "I come alive in ";
                        line2 = "the fall time I ";
                    end
                    8'd57: begin
                        line1 = "No competition, ";
                        line2 = "I don't really  ";
                    end
                    8'd58: begin
                        line1 = "listen          ";
                        line2 = "                ";
                    end
                    8'd59: begin
                        line1 = "I'm in the blue ";
                        line2 = "Mulsanne bumping";
                    end
                    8'd60: begin
                        line1 = "New Edition     ";
                        line2 = "                ";
                    end
                    8'd61: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd62: begin
                        line1 = "House so empty, ";
                        line2 = "need a          ";
                    end
                    8'd63: begin
                        line1 = "centerpiece     ";
                        line2 = "                ";
                    end
                    8'd64: begin
                        line1 = "Twenty racks, a ";
                        line2 = "table cut from  ";
                    end
                    8'd65: begin
                        line1 = "ebony           ";
                        line2 = "                ";
                    end
                    8'd66: begin
                        line1 = "Cut that ivory  ";
                        line2 = "into skinny     ";
                    end
                    8'd67: begin
                        line1 = "pieces          ";
                        line2 = "                ";
                    end
                    8'd68: begin
                        line1 = "Then she clean  ";
                        line2 = "it with her     ";
                    end
                    8'd69: begin
                        line1 = "face, man       ";
                        line2 = "                ";
                    end
                    8'd70: begin
                        line1 = "I love my baby  ";
                        line2 = "                ";
                    end
                    8'd71: begin
                        line1 = "You talking     ";
                        line2 = "money, need a   ";
                    end
                    8'd72: begin
                        line1 = "hearing aid     ";
                        line2 = "                ";
                    end
                    8'd73: begin
                        line1 = "You talking     ";
                        line2 = "'bout me, I     ";
                    end
                    8'd74: begin
                        line1 = "don't see the   ";
                        line2 = "shade           ";
                    end
                    8'd75: begin
                        line1 = "Switch up my    ";
                        line2 = "style, I take   ";
                    end
                    8'd76: begin
                        line1 = "any lane        ";
                        line2 = "                ";
                    end
                    8'd77: begin
                        line1 = "I switch up my  ";
                        line2 = "cup, I kill any ";
                    end
                    8'd78: begin
                        line1 = "pain            ";
                        line2 = "                ";
                    end
                    8'd79: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd80: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd81: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd82: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd83: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd84: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd85: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd86: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd87: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd88: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd89: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd90: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd91: begin
                        line1 = "Let a nigga brag";
                        line2 = "Pitt            ";
                    end
                    8'd92: begin
                        line1 = "Legend of the   ";
                        line2 = "fall took the   ";
                    end
                    8'd93: begin
                        line1 = "year like a     ";
                        line2 = "bandit          ";
                    end
                    8'd94: begin
                        line1 = "Bought mama a   ";
                        line2 = "crib and a brand";
                    end
                    8'd95: begin
                        line1 = "new wagon       ";
                        line2 = "                ";
                    end
                    8'd96: begin
                        line1 = "Star Trek roof  ";
                        line2 = "in that Wraith  ";
                    end
                    8'd97: begin
                        line1 = "of Khan         ";
                        line2 = "                ";
                    end
                    8'd98: begin
                        line1 = "Girls get loose ";
                        line2 = "when they hear  ";
                    end
                    8'd99: begin
                        line1 = "this song       ";
                        line2 = "                ";
                    end
                    8'd100: begin
                        line1 = "Hundred on the  ";
                        line2 = "dash get me     ";
                    end
                    8'd101: begin
                        line1 = "close to God    ";
                        line2 = "                ";
                    end
                    8'd102: begin
                        line1 = "We don't pray   ";
                        line2 = "for love, we    ";
                    end
                    8'd103: begin
                        line1 = "just pray for   ";
                        line2 = "cars            ";
                    end
                    8'd104: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd105: begin
                        line1 = "House so empty, ";
                        line2 = "need a          ";
                    end
                    8'd106: begin
                        line1 = "centerpiece     ";
                        line2 = "                ";
                    end
                    8'd107: begin
                        line1 = "Twenty racks, a ";
                        line2 = "table cut from  ";
                    end
                    8'd108: begin
                        line1 = "ebony           ";
                        line2 = "                ";
                    end
                    8'd109: begin
                        line1 = "Cut that ivory  ";
                        line2 = "into skinny     ";
                    end
                    8'd110: begin
                        line1 = "pieces          ";
                        line2 = "                ";
                    end
                    8'd111: begin
                        line1 = "Then she clean  ";
                        line2 = "it with her face";
                    end
                    8'd112: begin
                        line1 = "Man, I love my  ";
                        line2 = "baby            ";
                    end
                    8'd113: begin
                        line1 = "You talking     ";
                        line2 = "money, need a   ";
                    end
                    8'd114: begin
                        line1 = "hearing aid     ";
                        line2 = "                ";
                    end
                    8'd115: begin
                        line1 = "You talking     ";
                        line2 = "'bout me, I     ";
                    end
                    8'd116: begin
                        line1 = "don't see the   ";
                        line2 = "shade           ";
                    end
                    8'd117: begin
                        line1 = "Switch up my    ";
                        line2 = "style, I take   ";
                    end
                    8'd118: begin
                        line1 = "any lane        ";
                        line2 = "                ";
                    end
                    8'd119: begin
                        line1 = "I switch up my  ";
                        line2 = "cup, I kill any ";
                    end
                    8'd120: begin
                        line1 = "pain            ";
                        line2 = "                ";
                    end
                    8'd121: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd122: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd123: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd124: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd125: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd126: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd127: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd128: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd129: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd130: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd131: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd132: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd133: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd134: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd135: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd136: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd137: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    8'd138: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd139: begin
                        line1 = "Look what you've";
                        line2 = "done!           ";
                    end
                    8'd140: begin
                        line1 = "Ha-ha-ha-ha-ha-h";
                        line2 = "a-ha-ha-ha-ha   ";
                    end
                    8'd141: begin
                        line1 = "I'm a           ";
                        line2 = "mother****in'   ";
                    end
                    8'd142: begin
                        line1 = "Starboy         ";
                        line2 = "                ";
                    end
                    default: begin
                        line1 = "LYRIC PAGE ERROR";
                        line2 = "RESET FPGA      ";
                    end
                endcase
            end
            default: begin
                line1 = "TRACK ERROR     ";
                line2 = "RESET FPGA      ";
            end
        endcase
    end
endmodule

module sly4_por_reset #(
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
// 100 MHz -> 11.289602856 MHz ~= 44.100011 kHz * 256 (0.253 ppm error).
// VCO = 100/3*31.625 = 1054.1666667 MHz
// OUT = VCO/93.375.
module sly4_audio_clock_gen(
    input wire clk_100m,
    input wire rst_n,
    output wire mclk_audio,
    output wire locked
);
    wire fb_raw, fb_buf, out_raw;
    MMCME2_BASE #(
        .CLKFBOUT_MULT_F(31.625),
        .DIVCLK_DIVIDE(3),
        .CLKOUT0_DIVIDE_F(93.375),
        .CLKIN1_PERIOD(10.000)
    ) mmcm (
        .CLKIN1(clk_100m), .RST(~rst_n), .PWRDWN(1'b0),
        .CLKFBIN(fb_buf), .CLKFBOUT(fb_raw),
        .CLKOUT0(out_raw), .LOCKED(locked)
    );
    BUFG b0(.I(fb_raw),.O(fb_buf));
    BUFG b1(.I(out_raw),.O(mclk_audio));
endmodule

// ES8388 control port.
// The board ties CE low, therefore the 7-bit I2C address is 0x10.
// Configuration: slave, 48-kHz family, 256*Fs MCLK, 16-bit I2S,
// ADC from LIN2/RIN2 (board LINE_IN), DAC to headphone/line outputs.
module sly4_es8388_init #(
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

    sly4_i2c_master_write #(
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

// Simple 100-kHz I2C write-only master.
// Transaction:
//   START, {DEV_ADDR,0}, REG_ADDR, REG_DATA, STOP
// SDA is open-drain.
module sly4_i2c_master_write #(
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

// ES8388 slave-mode I2S interface.
// MCLK = 12.288 MHz, BCLK = MCLK/4 = 3.072 MHz, LRCK = 48 kHz.
// 32-bit slot per channel; 16 payload bits, standard one-bit I2S delay.
module sly4_i2s_audio_if(
    input  wire        mclk,
    input  wire        rst_n,

    input  wire [15:0] tx_left,
    input  wire [15:0] tx_right,

    input  wire        adc_data,
    output reg         dac_data,
    output reg         bclk,
    output reg         lrclk,

    output reg  [15:0] rx_left,
    output reg  [15:0] rx_right,
    output reg         rx_valid,
    output reg         frame_tick
);
    reg [1:0] mclk_div;
    reg [5:0] bit_pos;

    reg [15:0] tx_latched_l;
    reg [15:0] tx_latched_r;
    reg [15:0] rx_shift_l;
    reg [15:0] rx_shift_r;

    function tx_bit;
        input [5:0] pos;
        input [15:0] l;
        input [15:0] r;
        integer bi;
        begin
            tx_bit = 1'b0;
            if ((pos >= 1) && (pos <= 16)) begin
                bi = 16 - pos;
                tx_bit = l[bi];
            end
            else if ((pos >= 33) && (pos <= 48)) begin
                bi = 48 - pos;
                tx_bit = r[bi];
            end
        end
    endfunction

    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            mclk_div     <= 2'd0;
            bit_pos      <= 6'd0;
            bclk         <= 1'b0;
            lrclk        <= 1'b0;
            dac_data     <= 1'b0;
            tx_latched_l <= 16'd0;
            tx_latched_r <= 16'd0;
            rx_shift_l   <= 16'd0;
            rx_shift_r   <= 16'd0;
            rx_left      <= 16'd0;
            rx_right     <= 16'd0;
            rx_valid     <= 1'b0;
            frame_tick   <= 1'b0;
        end else begin
            rx_valid   <= 1'b0;
            frame_tick <= 1'b0;
            mclk_div   <= mclk_div + 1'b1;

            // Rising edge of BCLK.
            if (mclk_div == 2'd1) begin
                bclk <= 1'b1;

                if ((bit_pos >= 1) && (bit_pos <= 16))
                    rx_shift_l <= {rx_shift_l[14:0], adc_data};
                else if ((bit_pos >= 33) && (bit_pos <= 48))
                    rx_shift_r <= {rx_shift_r[14:0], adc_data};

                if (bit_pos == 6'd63) begin
                    bit_pos      <= 6'd0;
                    rx_left      <= rx_shift_l;
                    rx_right     <= rx_shift_r;
                    rx_valid     <= 1'b1;
                    frame_tick   <= 1'b1;
                    tx_latched_l <= tx_left;
                    tx_latched_r <= tx_right;
                end else begin
                    bit_pos <= bit_pos + 1'b1;
                end
            end

            // Falling edge of BCLK: change output data for next rising edge.
            if (mclk_div == 2'd3) begin
                bclk     <= 1'b0;
                lrclk    <= (bit_pos >= 6'd32);
                dac_data <= tx_bit(bit_pos, tx_latched_l, tx_latched_r);
            end
        end
    end
endmodule
module sly4_play_time_ms(
 input wire clk,input wire rst_n,input wire reset_time,
 input wire sample_tick,input wire advance,
 output reg [31:0] ms
);
 reg [15:0] acc;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin acc<=0;ms<=0; end
  else if(reset_time) begin acc<=0;ms<=0; end
  else if(sample_tick && advance) begin
    // 44.1 kHz: add 1000 per sample, emit 1 ms whenever >=44100.
    if(acc + 16'd1000 >= 16'd44100) begin
      acc <= acc + 16'd1000 - 16'd44100; ms<=ms+1'b1;
    end else acc<=acc+16'd1000;
  end
 end
endmodule

// Verified LCD1602 4-bit driver.
// Only LCD_D[7:4] carry nibbles; LCD_D[3:0] remain low.
// Standard entry sequence: 3, 3, 3, 2.
module sly4_lcd1602_driver #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output wire [7:0]   lcd_d,
    output reg          lcd_rs,
    output wire         lcd_rw,
    output reg          lcd_e
);

    // 4-bit mode: only D4-D7 are used.
    reg [3:0] lcd_nibble;
    assign lcd_d[7:4] = lcd_nibble;
    assign lcd_d[3:0] = 4'b0000;
    assign lcd_rw      = 1'b0;

    // 10 us timing tick.
    localparam integer TICK_DIV = CLK_HZ / 100_000;
    reg [31:0] tick_cnt;
    wire tick = (tick_cnt == TICK_DIV-1);

    reg [15:0] wait_ticks;

    localparam ST_RAW_SETUP = 4'd0;
    localparam ST_RAW_E_HI  = 4'd1;
    localparam ST_RAW_E_LO  = 4'd2;
    localparam ST_LOAD_BYTE = 4'd3;
    localparam ST_HI_SETUP  = 4'd4;
    localparam ST_HI_E_HI   = 4'd5;
    localparam ST_HI_E_LO   = 4'd6;
    localparam ST_LO_SETUP  = 4'd7;
    localparam ST_LO_E_HI   = 4'd8;
    localparam ST_LO_E_LO   = 4'd9;

    reg [3:0] state;

    // Startup raw nibbles: 3,3,3,2.
    reg [2:0] raw_idx;

    // init_mode=1: normal full-byte initialization commands.
    // init_mode=0: normal line refresh.
    reg       init_mode;
    reg [2:0] init_idx;
    reg [5:0] op_idx;

    reg [7:0] cur_byte;
    reg       cur_rs;

    function [3:0] raw_init_nibble;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: raw_init_nibble = 4'h3;
                3'd1: raw_init_nibble = 4'h3;
                3'd2: raw_init_nibble = 4'h3;
                default: raw_init_nibble = 4'h2;
            endcase
        end
    endfunction

    function [15:0] raw_delay_after;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: raw_delay_after = 16'd500; // 5 ms
                3'd1: raw_delay_after = 16'd20;  // 200 us
                3'd2: raw_delay_after = 16'd20;  // 200 us
                default: raw_delay_after = 16'd20;
            endcase
        end
    endfunction

    function [7:0] init_cmd;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: init_cmd = 8'h28; // 4-bit, 2 lines, 5x8
                3'd1: init_cmd = 8'h08; // display off
                3'd2: init_cmd = 8'h01; // clear display
                3'd3: init_cmd = 8'h06; // increment, display shift OFF
                default: init_cmd = 8'h0C; // display on, cursor off
            endcase
        end
    endfunction

    function [7:0] line_char;
        input [127:0] text;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  line_char = text[127:120];
                5'd1:  line_char = text[119:112];
                5'd2:  line_char = text[111:104];
                5'd3:  line_char = text[103:96];
                5'd4:  line_char = text[95:88];
                5'd5:  line_char = text[87:80];
                5'd6:  line_char = text[79:72];
                5'd7:  line_char = text[71:64];
                5'd8:  line_char = text[63:56];
                5'd9:  line_char = text[55:48];
                5'd10: line_char = text[47:40];
                5'd11: line_char = text[39:32];
                5'd12: line_char = text[31:24];
                5'd13: line_char = text[23:16];
                5'd14: line_char = text[15:8];
                default: line_char = text[7:0];
            endcase
        end
    endfunction

    task load_refresh_byte;
        input [5:0] idx;
        begin
            if (idx == 6'd0) begin
                cur_rs   <= 1'b0;
                cur_byte <= 8'h80;
            end
            else if ((idx >= 6'd1) && (idx <= 6'd16)) begin
                cur_rs   <= 1'b1;
                cur_byte <= line_char(line1, idx - 6'd1);
            end
            else if (idx == 6'd17) begin
                cur_rs   <= 1'b0;
                cur_byte <= 8'hC0;
            end
            else begin
                cur_rs   <= 1'b1;
                cur_byte <= line_char(line2, idx - 6'd18);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt    <= 32'd0;
            wait_ticks  <= 16'd10000; // 100 ms LCD power-up wait
            state       <= ST_RAW_SETUP;
            raw_idx     <= 3'd0;
            init_mode   <= 1'b1;
            init_idx    <= 3'd0;
            op_idx      <= 6'd0;
            cur_byte    <= 8'h00;
            cur_rs      <= 1'b0;
            lcd_nibble  <= 4'h0;
            lcd_rs      <= 1'b0;
            lcd_e       <= 1'b0;
        end
        else begin
            if (tick)
                tick_cnt <= 32'd0;
            else
                tick_cnt <= tick_cnt + 1'b1;

            if (tick) begin
                if (wait_ticks != 0) begin
                    wait_ticks <= wait_ticks - 1'b1;
                    lcd_e <= 1'b0;
                end
                else begin
                    case (state)

                        // ----------------------------------------------------
                        // Standard HD44780 4-bit entry: 3,3,3,2.
                        // Each nibble is set up one tick BEFORE E rises.
                        // ----------------------------------------------------
                        ST_RAW_SETUP: begin
                            lcd_rs     <= 1'b0;
                            lcd_nibble <= raw_init_nibble(raw_idx);
                            lcd_e      <= 1'b0;
                            state      <= ST_RAW_E_HI;
                        end

                        ST_RAW_E_HI: begin
                            lcd_e <= 1'b1;
                            state <= ST_RAW_E_LO;
                        end

                        ST_RAW_E_LO: begin
                            lcd_e <= 1'b0;

                            if (raw_idx == 3'd3) begin
                                init_mode  <= 1'b1;
                                init_idx   <= 3'd0;
                                wait_ticks <= 16'd20;
                                state      <= ST_LOAD_BYTE;
                            end
                            else begin
                                wait_ticks <= raw_delay_after(raw_idx);
                                raw_idx    <= raw_idx + 1'b1;
                                state      <= ST_RAW_SETUP;
                            end
                        end

                        // ----------------------------------------------------
                        // Load either one initialization command or one
                        // display-refresh byte.
                        // ----------------------------------------------------
                        ST_LOAD_BYTE: begin
                            if (init_mode) begin
                                cur_rs   <= 1'b0;
                                cur_byte <= init_cmd(init_idx);
                            end
                            else begin
                                load_refresh_byte(op_idx);
                            end
                            state <= ST_HI_SETUP;
                        end

                        // ----------------------------------------------------
                        // Send HIGH nibble.
                        // ----------------------------------------------------
                        ST_HI_SETUP: begin
                            lcd_rs     <= cur_rs;
                            lcd_nibble <= cur_byte[7:4];
                            lcd_e      <= 1'b0;
                            state      <= ST_HI_E_HI;
                        end

                        ST_HI_E_HI: begin
                            lcd_e <= 1'b1;
                            state <= ST_HI_E_LO;
                        end

                        ST_HI_E_LO: begin
                            lcd_e <= 1'b0;
                            state <= ST_LO_SETUP;
                        end

                        // ----------------------------------------------------
                        // Send LOW nibble.
                        // ----------------------------------------------------
                        ST_LO_SETUP: begin
                            lcd_rs     <= cur_rs;
                            lcd_nibble <= cur_byte[3:0];
                            lcd_e      <= 1'b0;
                            state      <= ST_LO_E_HI;
                        end

                        ST_LO_E_HI: begin
                            lcd_e <= 1'b1;
                            state <= ST_LO_E_LO;
                        end

                        ST_LO_E_LO: begin
                            lcd_e <= 1'b0;

                            if (init_mode) begin
                                if (init_idx == 3'd4) begin
                                    // Initialization complete.
                                    init_mode  <= 1'b0;
                                    op_idx     <= 6'd0;
                                    wait_ticks <= 16'd20;
                                    state      <= ST_LOAD_BYTE;
                                end
                                else begin
                                    // Clear command needs >1.5 ms.
                                    if (init_idx == 3'd2)
                                        wait_ticks <= 16'd250; // 2.5 ms
                                    else
                                        wait_ticks <= 16'd5;   // 50 us

                                    init_idx <= init_idx + 1'b1;
                                    state    <= ST_LOAD_BYTE;
                                end
                            end
                            else begin
                                if (op_idx == 6'd33) begin
                                    // Full two-line refresh completed.
                                    // Wait 100 ms, then rewrite from DDRAM 0x80.
                                    op_idx     <= 6'd0;
                                    wait_ticks <= 16'd10000;
                                    state      <= ST_LOAD_BYTE;
                                end
                                else begin
                                    op_idx     <= op_idx + 1'b1;
                                    wait_ticks <= 16'd5; // 50 us
                                    state      <= ST_LOAD_BYTE;
                                end
                            end
                        end

                        default: begin
                            lcd_e <= 1'b0;
                            state <= ST_RAW_SETUP;
                        end
                    endcase
                end
            end
        end
    end

endmodule

// --------------------------------------------------------------------------
// 100-MHz, 8N1 UART primitives.  The Qt-compatible build uses 921600 baud.
// --------------------------------------------------------------------------
module gx5_uart_rx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 921_600
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
    localparam [1:0] RX_IDLE=2'd0, RX_START=2'd1,
                     RX_DATA=2'd2, RX_STOP=2'd3;
    (* ASYNC_REG = "TRUE" *) reg rx_meta;
    (* ASYNC_REG = "TRUE" *) reg rx_sync;
    reg [1:0] state;
    reg [15:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta   <= 1'b1;
            rx_sync   <= 1'b1;
            state     <= RX_IDLE;
            count     <= 16'd0;
            bit_index <= 3'd0;
            shift     <= 8'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            valid   <= 1'b0;
            case (state)
                RX_IDLE: begin
                    count <= 16'd0;
                    if (!rx_sync) begin
                        count <= (CLKS_PER_BIT/2)-1;
                        state <= RX_START;
                    end
                end
                RX_START: begin
                    if (count != 0)
                        count <= count - 1'b1;
                    else if (!rx_sync) begin
                        count     <= CLKS_PER_BIT-1;
                        bit_index <= 3'd0;
                        state     <= RX_DATA;
                    end else begin
                        state <= RX_IDLE;
                    end
                end
                RX_DATA: begin
                    if (count != 0)
                        count <= count - 1'b1;
                    else begin
                        shift[bit_index] <= rx_sync;
                        count <= CLKS_PER_BIT-1;
                        if (bit_index == 3'd7)
                            state <= RX_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end
                end
                default: begin
                    if (count != 0)
                        count <= count - 1'b1;
                    else begin
                        if (rx_sync) begin
                            data  <= shift;
                            valid <= 1'b1;
                        end
                        state <= RX_IDLE;
                    end
                end
            endcase
        end
    end
endmodule


module gx5_uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 921_600
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy,
    output reg        done
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
    reg [15:0] count;
    reg [3:0] bit_index;
    reg [9:0] frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx        <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b0;
            count     <= 16'd0;
            bit_index <= 4'd0;
            frame     <= 10'h3FF;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                tx <= 1'b1;
                if (start) begin
                    frame     <= {1'b1, data, 1'b0};
                    tx        <= 1'b0;
                    busy      <= 1'b1;
                    count     <= CLKS_PER_BIT-1;
                    bit_index <= 4'd0;
                end
            end else if (count != 0) begin
                count <= count - 1'b1;
            end else if (bit_index == 4'd9) begin
                tx   <= 1'b1;
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                bit_index <= bit_index + 1'b1;
                tx        <= frame[bit_index + 1'b1];
                count     <= CLKS_PER_BIT-1;
            end
        end
    end
endmodule


// Receive one complete Qt protocol frame and hold it until frame_accept.
module gx5_uart_frame_rx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    input  wire        frame_accept,
    input  wire [12:0] payload_address,
    output wire [7:0]  payload_data,
    output reg  [127:0] payload_prefix,
    output reg         frame_valid,
    output reg  [7:0]  frame_type,
    output reg  [15:0] frame_sequence,
    output reg  [12:0] frame_length
);
    localparam [3:0] FR_SYNC0=4'd0, FR_SYNC1=4'd1,
                     FR_HEADER=4'd2, FR_PAYLOAD=4'd3,
                     FR_CRC_LO=4'd4, FR_CRC_HI=4'd5,
                     FR_HOLD=4'd6;
    reg [3:0] state;
    reg [2:0] header_index;
    reg [12:0] payload_index;
    reg [7:0] version;
    reg [7:0] received_crc_low;
    reg [15:0] crc_state;
    (* ram_style = "distributed" *) reg [7:0] payload_memory [0:4099];
    assign payload_data = payload_memory[payload_address];

    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer bit_number;
        reg [15:0] value;
        begin
            value = crc_in ^ {data_in, 8'h00};
            for (bit_number=0; bit_number<8; bit_number=bit_number+1)
                value = value[15] ? ((value << 1) ^ 16'h1021) :
                                    (value << 1);
            crc16_byte = value;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= FR_SYNC0;
            header_index   <= 3'd0;
            payload_index  <= 13'd0;
            version        <= 8'd0;
            received_crc_low <= 8'd0;
            crc_state      <= 16'hFFFF;
            payload_prefix <= 128'd0;
            frame_valid    <= 1'b0;
            frame_type     <= 8'd0;
            frame_sequence <= 16'd0;
            frame_length   <= 13'd0;
        end else begin
            if ((state == FR_HOLD) && frame_accept) begin
                frame_valid <= 1'b0;
                state       <= FR_SYNC0;
            end else if (byte_valid && (state != FR_HOLD)) begin
                case (state)
                    FR_SYNC0: begin
                        if (byte_data == 8'hA5)
                            state <= FR_SYNC1;
                    end
                    FR_SYNC1: begin
                        if (byte_data == 8'h5A) begin
                            state          <= FR_HEADER;
                            header_index   <= 3'd0;
                            crc_state      <= 16'hFFFF;
                            payload_prefix <= 128'd0;
                        end else if (byte_data != 8'hA5) begin
                            state <= FR_SYNC0;
                        end
                    end
                    FR_HEADER: begin
                        crc_state <= crc16_byte(crc_state, byte_data);
                        case (header_index)
                            3'd0: version <= byte_data;
                            3'd1: frame_type <= byte_data;
                            3'd2: frame_sequence[7:0] <= byte_data;
                            3'd3: frame_sequence[15:8] <= byte_data;
                            3'd4: frame_length[7:0] <= byte_data;
                            default: begin
                                frame_length[12:8] <= byte_data[4:0];
                                if ((byte_data[7:5] != 0) ||
                                    ({byte_data[4:0], frame_length[7:0]} >
                                     13'd4100)) begin
                                    state <= FR_SYNC0;
                                end else if ({byte_data[4:0],
                                              frame_length[7:0]} == 0) begin
                                    state <= FR_CRC_LO;
                                end else begin
                                    payload_index <= 13'd0;
                                    state <= FR_PAYLOAD;
                                end
                            end
                        endcase
                        if (header_index != 3'd5)
                            header_index <= header_index + 1'b1;
                    end
                    FR_PAYLOAD: begin
                        payload_memory[payload_index] <= byte_data;
                        if (payload_index < 13'd16)
                            payload_prefix[payload_index*8 +: 8] <= byte_data;
                        crc_state <= crc16_byte(crc_state, byte_data);
                        if (payload_index + 1'b1 == frame_length)
                            state <= FR_CRC_LO;
                        else
                            payload_index <= payload_index + 1'b1;
                    end
                    FR_CRC_LO: begin
                        received_crc_low <= byte_data;
                        state <= FR_CRC_HI;
                    end
                    default: begin
                        if ((version == 8'h01) &&
                            ({byte_data, received_crc_low} == crc_state)) begin
                            frame_valid <= 1'b1;
                            state       <= FR_HOLD;
                        end else begin
                            state <= FR_SYNC0;
                        end
                    end
                endcase
            end
        end
    end
endmodule


// Serialize short replies (ACK, STATUS and HELLO_REPLY) into protocol frames.
module gx5_uart_packet_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 921_600
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        send,
    input  wire [7:0]  packet_type,
    input  wire [3:0]  payload_length,
    input  wire [71:0] payload,
    output wire        ready,
    output wire        uart_tx
);
    localparam [3:0] PT_IDLE=4'd0, PT_SYNC0=4'd1, PT_SYNC1=4'd2,
                     PT_VERSION=4'd3, PT_TYPE=4'd4,
                     PT_SEQ_LO=4'd5, PT_SEQ_HI=4'd6,
                     PT_LEN_LO=4'd7, PT_LEN_HI=4'd8,
                     PT_PAYLOAD=4'd9, PT_CRC_LO=4'd10,
                     PT_CRC_HI=4'd11;
    reg [3:0] state;
    reg [7:0] type_latched;
    reg [3:0] length_latched;
    reg [71:0] payload_latched;
    reg [3:0] payload_index;
    reg [15:0] sequence_counter;
    reg [15:0] sequence_latched;
    reg [15:0] crc_state;
    reg byte_in_flight;
    reg uart_start;
    wire uart_busy;
    wire uart_done;
    wire [7:0] selected_payload_byte =
        payload_latched >> (payload_index * 8);
    wire [7:0] current_byte =
        (state == PT_SYNC0)   ? 8'hA5 :
        (state == PT_SYNC1)   ? 8'h5A :
        (state == PT_VERSION) ? 8'h01 :
        (state == PT_TYPE)    ? type_latched :
        (state == PT_SEQ_LO)  ? sequence_latched[7:0] :
        (state == PT_SEQ_HI)  ? sequence_latched[15:8] :
        (state == PT_LEN_LO)  ? {4'd0, length_latched} :
        (state == PT_LEN_HI)  ? 8'h00 :
        (state == PT_PAYLOAD) ? selected_payload_byte :
        (state == PT_CRC_LO)  ? crc_state[7:0] :
                                crc_state[15:8];
    assign ready = (state == PT_IDLE) && !byte_in_flight;

    gx5_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n), .start(uart_start),
        .data(current_byte), .tx(uart_tx), .busy(uart_busy),
        .done(uart_done)
    );

    function [15:0] crc16_byte_tx;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer bit_number;
        reg [15:0] value;
        begin
            value = crc_in ^ {data_in, 8'h00};
            for (bit_number=0; bit_number<8; bit_number=bit_number+1)
                value = value[15] ? ((value << 1) ^ 16'h1021) :
                                    (value << 1);
            crc16_byte_tx = value;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= PT_IDLE;
            type_latched     <= 8'd0;
            length_latched   <= 4'd0;
            payload_latched  <= 72'd0;
            payload_index    <= 4'd0;
            sequence_counter <= 16'd1;
            sequence_latched <= 16'd0;
            crc_state        <= 16'hFFFF;
            byte_in_flight   <= 1'b0;
            uart_start       <= 1'b0;
        end else begin
            uart_start <= 1'b0;
            if (state == PT_IDLE) begin
                byte_in_flight <= 1'b0;
                if (send) begin
                    type_latched     <= packet_type;
                    length_latched   <= payload_length;
                    payload_latched  <= payload;
                    payload_index    <= 4'd0;
                    sequence_latched <= sequence_counter;
                    sequence_counter <= sequence_counter + 1'b1;
                    crc_state        <= 16'hFFFF;
                    state            <= PT_SYNC0;
                end
            end else if (!byte_in_flight && !uart_busy) begin
                uart_start     <= 1'b1;
                byte_in_flight<= 1'b1;
            end else if (byte_in_flight && uart_done) begin
                byte_in_flight <= 1'b0;
                case (state)
                    PT_SYNC0: state <= PT_SYNC1;
                    PT_SYNC1: state <= PT_VERSION;
                    PT_VERSION: begin
                        crc_state <= crc16_byte_tx(crc_state, 8'h01);
                        state <= PT_TYPE;
                    end
                    PT_TYPE: begin
                        crc_state <= crc16_byte_tx(crc_state, type_latched);
                        state <= PT_SEQ_LO;
                    end
                    PT_SEQ_LO: begin
                        crc_state <= crc16_byte_tx(crc_state,
                                                   sequence_latched[7:0]);
                        state <= PT_SEQ_HI;
                    end
                    PT_SEQ_HI: begin
                        crc_state <= crc16_byte_tx(crc_state,
                                                   sequence_latched[15:8]);
                        state <= PT_LEN_LO;
                    end
                    PT_LEN_LO: begin
                        crc_state <= crc16_byte_tx(crc_state,
                                                   {4'd0, length_latched});
                        state <= PT_LEN_HI;
                    end
                    PT_LEN_HI: begin
                        crc_state <= crc16_byte_tx(crc_state, 8'h00);
                        state <= (length_latched == 0) ? PT_CRC_LO :
                                                       PT_PAYLOAD;
                    end
                    PT_PAYLOAD: begin
                        crc_state <= crc16_byte_tx(crc_state,
                                                   selected_payload_byte);
                        if (payload_index + 1'b1 == length_latched)
                            state <= PT_CRC_LO;
                        else
                            payload_index <= payload_index + 1'b1;
                    end
                    PT_CRC_LO: state <= PT_CRC_HI;
                    default: state <= PT_IDLE;
                endcase
            end
        end
    end
endmodule

// --------------------------------------------------------------------------
// Qt protocol endpoint and sequential FAT32 slot writer.
// USRxx.GXM must already exist (normally 96 MiB, created once by Qt).
// The controller never allocates clusters or changes FAT/directory entries;
// it follows the existing chain and verifies every written sector by readback.
// --------------------------------------------------------------------------
module gx5_uart_sd_controller #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 921_600
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        uart_rx,
    output wire        uart_tx,

    output reg         cmd_play,
    output reg         cmd_pause,
    output reg         cmd_previous,
    output reg         cmd_next,
    output reg         cmd_source_valid,
    output reg         cmd_source_qspi,
    output reg         cmd_track_valid,
    output reg  [3:0]  cmd_track,
    output reg         cmd_reload,

    input  wire        status_source_qspi,
    input  wire [3:0]  status_track,
    input  wire        status_playing,
    input  wire        status_paused,
    input  wire [31:0] status_play_ms,
    input  wire [7:0]  status_error,
    input  wire [7:0]  status_fifo_percent,
    input  wire        allow_upload,

    output reg         upload_active,
    output reg  [3:0]  upload_slot,
    output reg         slot_io_active,
    output reg  [4:0]  upload_stage,
    output reg  [7:0]  upload_error,

    input  wire        sd_init_ok,
    input  wire [7:0]  sd_error_code,
    input  wire        slot_mount_done,
    input  wire        slot_file_found,
    input  wire [7:0]  slot_fat_error,
    input  wire [31:0] slot_file_size,
    input  wire [31:0] slot_start_cluster,
    input  wire [31:0] slot_fat_start_lba,
    input  wire [31:0] slot_data_start_lba,
    input  wire [7:0]  slot_sectors_per_cluster,

    input  wire        block_ready,
    output reg         block_read_req,
    output reg  [31:0] block_read_lba,
    input  wire        block_data_valid,
    input  wire [8:0]  block_data_index,
    input  wire [7:0]  block_data_byte,
    input  wire        block_read_done,

    output reg         block_write_req,
    output reg  [31:0] block_write_lba,
    output reg         block_write_buffer_we,
    output reg  [8:0]  block_write_buffer_addr,
    output reg  [7:0]  block_write_buffer_data,
    input  wire        block_write_done
);
    localparam [4:0]
        UP_WAIT_FRAME        = 5'd0,
        UP_WAIT_SLOT         = 5'd1,
        UP_PREP_SECTOR       = 5'd2,
        UP_FILL_SECTOR       = 5'd3,
        UP_WRITE_REQ         = 5'd4,
        UP_WRITE_WAIT        = 5'd5,
        UP_VERIFY_REQ        = 5'd6,
        UP_VERIFY_WAIT       = 5'd7,
        UP_ADVANCE           = 5'd8,
        UP_FAT_REQ           = 5'd9,
        UP_FAT_WAIT          = 5'd10,
        UP_FAT_EVAL          = 5'd11,
        UP_CHUNK_ACK         = 5'd12,
        UP_COMMIT_FILL       = 5'd13,
        UP_COMMIT_WRITE_REQ  = 5'd14,
        UP_COMMIT_WRITE_WAIT = 5'd15,
        UP_COMMIT_VERIFY_REQ = 5'd16,
        UP_COMMIT_VERIFY_WAIT= 5'd17,
        UP_END_ACK           = 5'd18,
        UP_ERROR_ACK         = 5'd19;

    wire [7:0] rx_byte;
    wire       rx_byte_valid;
    gx5_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx),
        .data(rx_byte), .valid(rx_byte_valid)
    );

    reg         frame_accept;
    wire        frame_valid;
    wire [7:0]  frame_type;
    wire [15:0] frame_sequence;
    wire [12:0] frame_length;
    wire [127:0] frame_prefix;
    wire [7:0] frame_payload_data;
    wire [12:0] frame_payload_address;

    reg [4:0] state;
    reg [12:0] chunk_length;
    reg [12:0] sector_base_consumed;
    reg [8:0]  fill_index;
    reg        sector_verify_bad;
    wire [12:0] verify_payload_index =
        sector_base_consumed + {4'd0, block_data_index};
    assign frame_payload_address =
        (state == UP_FILL_SECTOR) ?
            (13'd4 + sector_base_consumed + {4'd0, fill_index}) :
        (state == UP_VERIFY_WAIT) ?
            (13'd4 + verify_payload_index) : 13'd0;

    gx5_uart_frame_rx u_frame_rx (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(rx_byte_valid), .byte_data(rx_byte),
        .frame_accept(frame_accept),
        .payload_address(frame_payload_address),
        .payload_data(frame_payload_data),
        .payload_prefix(frame_prefix),
        .frame_valid(frame_valid), .frame_type(frame_type),
        .frame_sequence(frame_sequence), .frame_length(frame_length)
    );

    reg        reply_pending;
    reg [7:0]  reply_type;
    reg [3:0]  reply_length;
    reg [71:0] reply_payload;
    reg        packet_send;
    wire       packet_ready;
    gx5_uart_packet_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_packet_tx (
        .clk(clk), .rst_n(rst_n), .send(packet_send),
        .packet_type(reply_type), .payload_length(reply_length),
        .payload(reply_payload), .ready(packet_ready),
        .uart_tx(uart_tx)
    );

    reg [31:0] upload_size;
    reg [31:0] upload_crc_expected;
    reg [31:0] upload_crc_state;
    reg [31:0] expected_offset;
    reg [15:0] active_frame_sequence;
    reg [15:0] last_committed_sequence;
    reg [31:0] current_cluster;
    reg [7:0]  current_cluster_sector;
    reg        fat_return_to_ack;
    reg [8:0]  fat_entry_offset;
    reg [7:0]  fat_byte0;
    reg [7:0]  fat_byte1;
    reg [7:0]  fat_byte2;
    reg [7:0]  fat_byte3;
    wire [31:0] next_cluster =
        ({fat_byte3, fat_byte2, fat_byte1, fat_byte0} & 32'h0FFF_FFFF);
    wire [31:0] current_file_lba = slot_data_start_lba +
        ((current_cluster - 2) * slot_sectors_per_cluster) +
        current_cluster_sector;
    wire [31:0] first_file_lba = slot_data_start_lba +
        ((slot_start_cluster - 2) * slot_sectors_per_cluster);

    reg [7:0] header_cache [0:511];
    reg [8:0] commit_index;
    reg       commit_verify_bad;

    reg [15:0] failure_sequence;
    reg [7:0]  failure_result;
    reg [31:0] status_timer;
    reg        status_due;

    wire [31:0] prefix_u32_0 = {frame_prefix[31:24],
                                  frame_prefix[23:16],
                                  frame_prefix[15:8],
                                  frame_prefix[7:0]};
    wire [31:0] prefix_u32_1 = {frame_prefix[39:32],
                                  frame_prefix[31:24],
                                  frame_prefix[23:16],
                                  frame_prefix[15:8]};
    wire [31:0] prefix_u32_5 = {frame_prefix[71:64],
                                  frame_prefix[63:56],
                                  frame_prefix[55:48],
                                  frame_prefix[47:40]};
    wire [12:0] incoming_data_length = frame_length - 13'd4;
    wire [31:0] fill_absolute_offset = expected_offset +
        sector_base_consumed + {23'd0, fill_index};
    wire fill_has_payload =
        (sector_base_consumed + {4'd0, fill_index}) < chunk_length;
    wire [7:0] fill_original_byte = fill_has_payload ?
        frame_payload_data : 8'h00;
    wire [7:0] fill_sd_byte =
        (fill_absolute_offset < 32'd4) ? 8'h2D : fill_original_byte;
    wire [31:0] verify_absolute_offset = expected_offset +
        sector_base_consumed + {23'd0, block_data_index};
    wire verify_has_payload = verify_payload_index < chunk_length;
    wire [7:0] verify_expected_byte =
        (verify_absolute_offset < 32'd4) ? 8'h2D :
        (verify_has_payload ? frame_payload_data : 8'h00);

    function [31:0] upload_crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        integer crc_bit;
        reg [31:0] value;
        begin
            value = crc_in ^ data_in;
            for (crc_bit=0; crc_bit<8; crc_bit=crc_bit+1)
                value = value[0] ? ((value >> 1) ^ 32'hEDB8_8320) :
                                   (value >> 1);
            upload_crc32_byte = value;
        end
    endfunction

    task queue_ack;
        input [15:0] acknowledged_sequence;
        input [7:0] result_code;
        begin
            reply_type    <= 8'h80;
            reply_length  <= 4'd3;
            reply_payload <= {48'd0, result_code,
                              acknowledged_sequence[15:8],
                              acknowledged_sequence[7:0]};
            reply_pending <= 1'b1;
        end
    endtask

    task queue_status;
        begin
            reply_type   <= 8'h81;
            reply_length <= 4'd9;
            reply_payload <= {
                status_fifo_percent,
                status_error,
                status_play_ms[31:24],
                status_play_ms[23:16],
                status_play_ms[15:8],
                status_play_ms[7:0],
                (status_paused ? 8'd2 :
                 (status_playing ? 8'd1 : 8'd0)),
                {4'd0, status_track},
                {7'd0, status_source_qspi}
            };
            reply_pending <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                   <= UP_WAIT_FRAME;
            frame_accept            <= 1'b0;
            packet_send             <= 1'b0;
            reply_pending           <= 1'b0;
            reply_type              <= 8'd0;
            reply_length            <= 4'd0;
            reply_payload           <= 72'd0;
            cmd_play                <= 1'b0;
            cmd_pause               <= 1'b0;
            cmd_previous            <= 1'b0;
            cmd_next                <= 1'b0;
            cmd_source_valid        <= 1'b0;
            cmd_source_qspi         <= 1'b0;
            cmd_track_valid         <= 1'b0;
            cmd_track               <= 4'd0;
            cmd_reload              <= 1'b0;
            upload_active           <= 1'b0;
            upload_slot             <= 4'd0;
            slot_io_active          <= 1'b0;
            upload_stage            <= 5'd0;
            upload_error            <= 8'd0;
            block_read_req          <= 1'b0;
            block_read_lba          <= 32'd0;
            block_write_req         <= 1'b0;
            block_write_lba         <= 32'd0;
            block_write_buffer_we   <= 1'b0;
            block_write_buffer_addr <= 9'd0;
            block_write_buffer_data <= 8'd0;
            upload_size             <= 32'd0;
            upload_crc_expected     <= 32'd0;
            upload_crc_state        <= 32'hFFFF_FFFF;
            expected_offset         <= 32'd0;
            active_frame_sequence   <= 16'd0;
            last_committed_sequence <= 16'd0;
            chunk_length            <= 13'd0;
            sector_base_consumed    <= 13'd0;
            fill_index              <= 9'd0;
            sector_verify_bad       <= 1'b0;
            current_cluster         <= 32'd0;
            current_cluster_sector  <= 8'd0;
            fat_return_to_ack       <= 1'b0;
            fat_entry_offset        <= 9'd0;
            fat_byte0               <= 8'd0;
            fat_byte1               <= 8'd0;
            fat_byte2               <= 8'd0;
            fat_byte3               <= 8'd0;
            commit_index            <= 9'd0;
            commit_verify_bad       <= 1'b0;
            failure_sequence        <= 16'd0;
            failure_result          <= 8'd0;
            status_timer            <= 32'd0;
            status_due              <= 1'b0;
        end else begin
            frame_accept          <= 1'b0;
            packet_send           <= 1'b0;
            cmd_play              <= 1'b0;
            cmd_pause             <= 1'b0;
            cmd_previous          <= 1'b0;
            cmd_next              <= 1'b0;
            cmd_source_valid      <= 1'b0;
            cmd_track_valid       <= 1'b0;
            cmd_reload            <= 1'b0;
            block_read_req        <= 1'b0;
            block_write_req       <= 1'b0;
            block_write_buffer_we <= 1'b0;

            if (reply_pending && packet_ready) begin
                packet_send   <= 1'b1;
                reply_pending <= 1'b0;
            end

            if (status_timer == (CLK_HZ/5)-1) begin
                status_timer <= 32'd0;
                status_due   <= 1'b1;
            end else begin
                status_timer <= status_timer + 1'b1;
            end

            if (status_due && !upload_active && !frame_valid &&
                !reply_pending && (state == UP_WAIT_FRAME)) begin
                queue_status;
                status_due <= 1'b0;
            end

            case (state)
                UP_WAIT_FRAME: begin
                    upload_stage <= upload_active ? 5'd3 : 5'd0;
                    if (frame_valid && !reply_pending) begin
                        case (frame_type)
                            8'h01: begin
                                if ((frame_length == 13'd4) &&
                                    (frame_prefix[31:0] == 32'h5451_5847)) begin
                                    reply_type    <= 8'h83;
                                    reply_length  <= 4'd7;
                                    reply_payload <= {16'd0, "1", "A", "G",
                                                      "P", "F", "X", "G"};
                                    reply_pending <= 1'b1;
                                end
                                frame_accept <= 1'b1;
                            end
                            8'h02: begin
                                queue_status;
                                frame_accept <= 1'b1;
                                status_due <= 1'b0;
                            end
                            8'h10: begin
                                if (!upload_active)
                                    cmd_play <= 1'b1;
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            8'h11: begin
                                if (!upload_active)
                                    cmd_pause <= 1'b1;
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            8'h12: begin
                                if (!upload_active)
                                    cmd_previous <= 1'b1;
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            8'h13: begin
                                if (!upload_active)
                                    cmd_next <= 1'b1;
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            8'h14: begin
                                if (!upload_active && (frame_length == 13'd1) &&
                                    (frame_prefix[7:0] <= 8'd1)) begin
                                    cmd_source_valid <= 1'b1;
                                    cmd_source_qspi  <= frame_prefix[0];
                                end
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            8'h15: begin
                                if (!upload_active && (frame_length == 13'd1) &&
                                    (frame_prefix[7:0] <= 8'd14)) begin
                                    cmd_track_valid <= 1'b1;
                                    cmd_track       <= frame_prefix[3:0];
                                end
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            8'h16: begin
                                // Digital board volume is reserved; the
                                // command is consumed so future Qt builds stay
                                // protocol-compatible.
                                frame_accept <= 1'b1;
                            end
                            8'h20: begin
                                if (!upload_active && allow_upload &&
                                    (frame_length == 13'd9) &&
                                    (frame_prefix[7:0] <= 8'd9) &&
                                    (prefix_u32_1 >= 32'd65_536) &&
                                    (prefix_u32_1 <= 32'd100_663_296)) begin
                                    upload_active       <= 1'b1;
                                    upload_slot         <= frame_prefix[3:0];
                                    upload_size         <= prefix_u32_1;
                                    upload_crc_expected <= prefix_u32_5;
                                    upload_crc_state    <= 32'hFFFF_FFFF;
                                    expected_offset     <= 32'd0;
                                    active_frame_sequence <= frame_sequence;
                                    slot_io_active      <= 1'b0;
                                    upload_error        <= 8'd0;
                                    upload_stage        <= 5'd1;
                                    state               <= UP_WAIT_SLOT;
                                end else begin
                                    failure_sequence <= frame_sequence;
                                    failure_result   <= allow_upload ? 8'h01 :
                                                                      8'h07;
                                    state <= UP_ERROR_ACK;
                                end
                            end
                            8'h21: begin
                                if (upload_active && (frame_length > 13'd4)) begin
                                    if ((prefix_u32_0 == expected_offset) &&
                                        (prefix_u32_0 + incoming_data_length <=
                                         upload_size) &&
                                        ((prefix_u32_0 != 0) ||
                                         ((incoming_data_length >= 13'd512) &&
                                          (frame_prefix[63:32] ==
                                           32'h314D_5847)))) begin
                                        active_frame_sequence <= frame_sequence;
                                        chunk_length         <= incoming_data_length;
                                        sector_base_consumed <= 13'd0;
                                        state                <= UP_PREP_SECTOR;
                                    end else if ((prefix_u32_0 < expected_offset) &&
                                                 (prefix_u32_0 +
                                                  incoming_data_length ==
                                                  expected_offset)) begin
                                        // The preceding ACK was lost. The
                                        // sector has already been verified.
                                        queue_ack(frame_sequence, 8'h00);
                                        frame_accept <= 1'b1;
                                    end else begin
                                        failure_sequence <= frame_sequence;
                                        failure_result   <= 8'h04;
                                        state <= UP_ERROR_ACK;
                                    end
                                end else begin
                                    failure_sequence <= frame_sequence;
                                    failure_result   <= 8'h01;
                                    state <= UP_ERROR_ACK;
                                end
                            end
                            8'h22: begin
                                if (upload_active && (frame_length == 13'd9) &&
                                    (frame_prefix[3:0] == upload_slot) &&
                                    (prefix_u32_1 == upload_size) &&
                                    (prefix_u32_5 == upload_crc_expected) &&
                                    (expected_offset == upload_size) &&
                                    ((upload_crc_state ^ 32'hFFFF_FFFF) ==
                                     upload_crc_expected)) begin
                                    active_frame_sequence <= frame_sequence;
                                    commit_index <= 9'd0;
                                    upload_stage <= 5'd4;
                                    state <= UP_COMMIT_FILL;
                                end else begin
                                    failure_sequence <= frame_sequence;
                                    failure_result   <= 8'h06;
                                    state <= UP_ERROR_ACK;
                                end
                            end
                            8'h23: begin
                                if (!upload_active)
                                    cmd_reload <= 1'b1;
                                frame_accept <= 1'b1;
                                status_due <= 1'b1;
                            end
                            default: frame_accept <= 1'b1;
                        endcase
                    end
                end

                UP_WAIT_SLOT: begin
                    upload_stage <= 5'd2;
                    if ((sd_error_code != 0) ||
                        (slot_mount_done && (slot_fat_error != 0))) begin
                        failure_sequence <= active_frame_sequence;
                        failure_result   <= 8'h02;
                        state <= UP_ERROR_ACK;
                    end else if (sd_init_ok && slot_file_found &&
                                 !reply_pending) begin
                        if ((slot_start_cluster < 2) ||
                            (slot_sectors_per_cluster == 0) ||
                            (slot_file_size < upload_size)) begin
                            failure_sequence <= active_frame_sequence;
                            failure_result   <= (slot_file_size < upload_size) ?
                                                8'h03 : 8'h02;
                            state <= UP_ERROR_ACK;
                        end else begin
                            current_cluster        <= slot_start_cluster;
                            current_cluster_sector <= 8'd0;
                            slot_io_active         <= 1'b1;
                            queue_ack(active_frame_sequence, 8'h00);
                            frame_accept <= 1'b1;
                            upload_stage <= 5'd3;
                            state <= UP_WAIT_FRAME;
                        end
                    end
                end

                UP_PREP_SECTOR: begin
                    fill_index        <= 9'd0;
                    sector_verify_bad <= 1'b0;
                    state             <= UP_FILL_SECTOR;
                end

                UP_FILL_SECTOR: begin
                    block_write_buffer_we   <= 1'b1;
                    block_write_buffer_addr <= fill_index;
                    block_write_buffer_data <= fill_sd_byte;
                    if (fill_has_payload) begin
                        upload_crc_state <= upload_crc32_byte(
                            upload_crc_state, fill_original_byte);
                        if (fill_absolute_offset < 32'd512)
                            header_cache[fill_absolute_offset[8:0]] <=
                                fill_original_byte;
                    end
                    if (fill_index == 9'd511) begin
                        fill_index <= 9'd0;
                        state <= UP_WRITE_REQ;
                    end else begin
                        fill_index <= fill_index + 1'b1;
                    end
                end

                UP_WRITE_REQ: begin
                    if (block_ready) begin
                        block_write_lba <= current_file_lba;
                        block_write_req <= 1'b1;
                        state <= UP_WRITE_WAIT;
                    end
                end

                UP_WRITE_WAIT: begin
                    if (sd_error_code != 0) begin
                        failure_sequence <= active_frame_sequence;
                        failure_result   <= 8'h05;
                        state <= UP_ERROR_ACK;
                    end else if (block_write_done) begin
                        state <= UP_VERIFY_REQ;
                    end
                end

                UP_VERIFY_REQ: begin
                    if (block_ready) begin
                        block_read_lba <= current_file_lba;
                        block_read_req <= 1'b1;
                        sector_verify_bad <= 1'b0;
                        state <= UP_VERIFY_WAIT;
                    end
                end

                UP_VERIFY_WAIT: begin
                    if (block_data_valid &&
                        (block_data_byte != verify_expected_byte))
                        sector_verify_bad <= 1'b1;
                    if (block_read_done) begin
                        if (sector_verify_bad) begin
                            failure_sequence <= active_frame_sequence;
                            failure_result   <= 8'h05;
                            state <= UP_ERROR_ACK;
                        end else begin
                            state <= UP_ADVANCE;
                        end
                    end
                end

                UP_ADVANCE: begin
                    if (sector_base_consumed + 13'd512 >= chunk_length) begin
                        expected_offset <= expected_offset + chunk_length;
                        last_committed_sequence <= active_frame_sequence;
                        if (expected_offset + chunk_length >= upload_size) begin
                            state <= UP_CHUNK_ACK;
                        end else if (current_cluster_sector + 1'b1 <
                                     slot_sectors_per_cluster) begin
                            current_cluster_sector <=
                                current_cluster_sector + 1'b1;
                            state <= UP_CHUNK_ACK;
                        end else begin
                            fat_return_to_ack <= 1'b1;
                            state <= UP_FAT_REQ;
                        end
                    end else begin
                        sector_base_consumed <= sector_base_consumed + 13'd512;
                        if (current_cluster_sector + 1'b1 <
                            slot_sectors_per_cluster) begin
                            current_cluster_sector <=
                                current_cluster_sector + 1'b1;
                            state <= UP_PREP_SECTOR;
                        end else begin
                            fat_return_to_ack <= 1'b0;
                            state <= UP_FAT_REQ;
                        end
                    end
                end

                UP_FAT_REQ: begin
                    if (block_ready) begin
                        block_read_lba <= slot_fat_start_lba +
                                          (current_cluster >> 7);
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        fat_byte0 <= 8'd0;
                        fat_byte1 <= 8'd0;
                        fat_byte2 <= 8'd0;
                        fat_byte3 <= 8'd0;
                        block_read_req <= 1'b1;
                        state <= UP_FAT_WAIT;
                    end
                end

                UP_FAT_WAIT: begin
                    if (block_data_valid) begin
                        if (block_data_index == fat_entry_offset)
                            fat_byte0 <= block_data_byte;
                        else if (block_data_index == fat_entry_offset + 1'b1)
                            fat_byte1 <= block_data_byte;
                        else if (block_data_index == fat_entry_offset + 2'd2)
                            fat_byte2 <= block_data_byte;
                        else if (block_data_index == fat_entry_offset + 2'd3)
                            fat_byte3 <= block_data_byte;
                    end
                    if (block_read_done)
                        state <= UP_FAT_EVAL;
                end

                UP_FAT_EVAL: begin
                    if ((next_cluster < 2) ||
                        (next_cluster >= 32'h0FFF_FFF8)) begin
                        failure_sequence <= active_frame_sequence;
                        failure_result   <= 8'h05;
                        state <= UP_ERROR_ACK;
                    end else begin
                        current_cluster <= next_cluster;
                        current_cluster_sector <= 8'd0;
                        state <= fat_return_to_ack ? UP_CHUNK_ACK :
                                                     UP_PREP_SECTOR;
                    end
                end

                UP_CHUNK_ACK: begin
                    if (!reply_pending) begin
                        queue_ack(active_frame_sequence, 8'h00);
                        frame_accept <= 1'b1;
                        upload_stage <= 5'd3;
                        state <= UP_WAIT_FRAME;
                    end
                end

                UP_COMMIT_FILL: begin
                    block_write_buffer_we   <= 1'b1;
                    block_write_buffer_addr <= commit_index;
                    block_write_buffer_data <= header_cache[commit_index];
                    if (commit_index == 9'd511) begin
                        commit_index <= 9'd0;
                        state <= UP_COMMIT_WRITE_REQ;
                    end else begin
                        commit_index <= commit_index + 1'b1;
                    end
                end

                UP_COMMIT_WRITE_REQ: begin
                    if (block_ready) begin
                        block_write_lba <= first_file_lba;
                        block_write_req <= 1'b1;
                        state <= UP_COMMIT_WRITE_WAIT;
                    end
                end

                UP_COMMIT_WRITE_WAIT: begin
                    if (sd_error_code != 0) begin
                        failure_sequence <= active_frame_sequence;
                        failure_result   <= 8'h05;
                        state <= UP_ERROR_ACK;
                    end else if (block_write_done) begin
                        state <= UP_COMMIT_VERIFY_REQ;
                    end
                end

                UP_COMMIT_VERIFY_REQ: begin
                    if (block_ready) begin
                        block_read_lba <= first_file_lba;
                        block_read_req <= 1'b1;
                        commit_verify_bad <= 1'b0;
                        state <= UP_COMMIT_VERIFY_WAIT;
                    end
                end

                UP_COMMIT_VERIFY_WAIT: begin
                    if (block_data_valid &&
                        (block_data_byte != header_cache[block_data_index]))
                        commit_verify_bad <= 1'b1;
                    if (block_read_done) begin
                        if (commit_verify_bad) begin
                            failure_sequence <= active_frame_sequence;
                            failure_result   <= 8'h05;
                            state <= UP_ERROR_ACK;
                        end else begin
                            state <= UP_END_ACK;
                        end
                    end
                end

                UP_END_ACK: begin
                    if (!reply_pending) begin
                        queue_ack(active_frame_sequence, 8'h00);
                        frame_accept   <= 1'b1;
                        upload_active  <= 1'b0;
                        slot_io_active <= 1'b0;
                        upload_stage   <= 5'd0;
                        upload_error   <= 8'd0;
                        cmd_reload     <= 1'b1;
                        status_due     <= 1'b1;
                        state          <= UP_WAIT_FRAME;
                    end
                end

                default: begin // UP_ERROR_ACK
                    if (!reply_pending) begin
                        queue_ack(failure_sequence, failure_result);
                        frame_accept   <= 1'b1;
                        upload_active  <= 1'b0;
                        slot_io_active <= 1'b0;
                        upload_stage   <= 5'd0;
                        upload_error   <= failure_result;
                        status_due     <= 1'b1;
                        state          <= UP_WAIT_FRAME;
                    end
                end
            endcase
        end
    end
endmodule

// ============================================================================
// Qt-enabled production top.
//
// SD tracks 0..4 keep the proven legacy RAW path.  Tracks 5..14 read the
// runtime GXM1 packages USR00.GXM..USR09.GXM, including their LCD records.
// UART control and verified in-place SD upload use 921600 baud, 8N1.
// The independent user QSPI WDT excerpt and KEY3 copier remain available.
// ============================================================================
module top_sd_audio_lyrics_4bit_all_in_one (
    input  wire       sys_clk,
    input  wire       UART_RXD,
    output wire       UART_TXD,

    output wire       AUDIO_MCLK,
    output wire       AUDIO_BCLK,
    output wire       AUDIO_LRCK,
    output wire       AUDIO_DAC_DIN,
    input  wire       AUDIO_ADC_DOUT,
    output wire       AUDIO_CCLK,
    inout  wire       AUDIO_CDATA,

    output wire       FLASH_CS_N,
    output wire       FLASH_SCLK,
    output wire       FLASH_MOSI,
    input  wire       FLASH_MISO,
    output wire       FLASH_HOLD_N,

    output wire       SD_CS_N,
    output wire       SD_SCLK,
    output wire       SD_MOSI,
    input  wire       SD_MISO,
    input  wire       SD_CD_N,

    input  wire       KEY0_N,
    input  wire       KEY1_N,
    input  wire       KEY2_N,
    input  wire       KEY3_N,

    output wire [7:0] LCD_D,
    output wire       LCD_RS,
    output wire       LCD_RW,
    output wire       LCD_E,

    output wire       LED0,
    output wire       LED1
);
    // ---------------------------------------------------------------------
    // Declarations
    // ---------------------------------------------------------------------
    wire por_n;
    wire key_prev_press;
    wire key_next_press;
    wire key_source_press;
    reg  key3_meta;
    reg  key3_sync;
    reg  key3_armed;
    reg  key_copy_request;

    reg        source_qspi;
    reg [3:0]  track_index;
    reg        play_paused;
    reg [19:0] media_reset_count;
    reg        flash_copy_active;
    reg        flash_copy_ok;
    reg        flash_copy_failed;
    reg [7:0]  flash_copy_latched_error;
    wire       flash_copy_done;
    wire       flash_copy_error;
    wire [7:0] flash_copy_error_code;
    wire [3:0] flash_copy_stage;
    wire [31:0] flash_copy_bytes;

    wire uart_cmd_play;
    wire uart_cmd_pause;
    wire uart_cmd_previous;
    wire uart_cmd_next;
    wire uart_cmd_source_valid;
    wire uart_cmd_source_qspi;
    wire uart_cmd_track_valid;
    wire [3:0] uart_cmd_track;
    wire uart_cmd_reload;
    wire uart_upload_active;
    wire [3:0] uart_upload_slot;
    wire uart_slot_io_active;
    wire [4:0] uart_upload_stage;
    wire [7:0] uart_upload_error;

    wire media_cycle_rst_n;
    wire media_play_rst_n;
    wire sd_media_rst_n;
    wire qspi_media_rst_n;
    wire qspi_copy_rst_n;
    wire media_finished_sys;

    wire audio_mclk;
    wire audio_clock_locked;
    wire audio_rst_n;
    wire stream_async_rst_n;
    reg [2:0] stream_reset_sync;
    wire stream_audio_rst_n;
    wire codec_init_done;
    wire codec_init_ok;

    wire        sd_block_ready;
    wire        sd_read_busy;
    wire        sd_read_done;
    wire        sd_write_busy;
    wire        sd_write_done;
    wire        sd_data_valid;
    wire [8:0]  sd_data_index;
    wire [7:0]  sd_data_byte;
    wire        sd_init_done;
    wire        sd_init_ok;
    wire        sd_card_sdhc;
    wire [7:0]  sd_error;

    wire        media_block_read_req;
    wire [31:0] media_block_read_lba;
    wire        locator_block_read_req;
    wire [31:0] locator_block_read_lba;
    wire        uart_block_read_req;
    wire [31:0] uart_block_read_lba;
    wire        uart_block_write_req;
    wire [31:0] uart_block_write_lba;
    wire        uart_write_buffer_we;
    wire [8:0]  uart_write_buffer_addr;
    wire [7:0]  uart_write_buffer_data;
    wire        block_read_req_mux;
    wire [31:0] block_read_lba_mux;
    wire        block_write_req_mux;
    wire        write_buffer_we_mux;

    wire        sd_raw_byte_valid;
    wire [7:0]  sd_raw_byte;
    wire        fat_mount_done;
    wire        song_found;
    wire        file_streaming;
    wire        file_eof;
    wire [31:0] song_file_size;
    wire [31:0] song_bytes_sent;
    wire [7:0]  fat_error;
    wire        gxm_mode;
    wire        gxm_header_done;
    wire        gxm_header_ok;
    wire [127:0] gxm_title;
    wire        gxm_lyric_valid;
    wire [13:0] gxm_lyric_index;
    wire [7:0]  gxm_lyric_byte;
    wire [8:0]  gxm_lyric_count;
    wire        gxm_lyrics_done;
    wire        gxm_audio_crc_ok;
    wire [31:0] media_start_cluster;
    wire [31:0] media_fat_start_lba;
    wire [31:0] media_data_start_lba;
    wire [7:0]  media_sectors_per_cluster;

    wire        slot_mount_done;
    wire        slot_file_found;
    wire [7:0]  slot_fat_error;
    wire [31:0] slot_file_size;
    wire [31:0] slot_start_cluster;
    wire [31:0] slot_fat_start_lba;
    wire [31:0] slot_data_start_lba;
    wire [7:0]  slot_sectors_per_cluster;

    wire [12:0] pcm_fifo_level;
    wire        flash_copy_sector_allow;
    wire        sector_allow;

    wire        qspi_byte_valid;
    wire [7:0]  qspi_byte;
    wire        qspi_header_done;
    wire        qspi_header_ok;
    wire        qspi_eof;
    wire [31:0] qspi_bytes_sent;
    wire [7:0]  qspi_error;
    wire        qspi_byte_ready;
    wire        qspi_play_cs_n;
    wire        qspi_play_sclk;
    wire        qspi_play_mosi;
    wire        qspi_lyric_byte_valid;
    wire [7:0]  qspi_lyric_byte_index;
    wire [7:0]  qspi_lyric_byte;
    wire        qspi_lyric_load_done;
    wire        qspi_lyrics_ready;
    wire        qspi_copy_cs_n;
    wire        qspi_copy_sclk;
    wire        qspi_copy_mosi;

    wire       raw_byte_valid;
    wire [7:0] raw_byte;
    wire       media_eof;
    reg [1:0]  pcm_byte_phase;
    reg [7:0]  left_low;
    reg [7:0]  left_high;
    reg [7:0]  right_low;
    reg        pcm_fifo_write;
    reg [15:0] pcm_write_left;
    reg [15:0] pcm_write_right;
    reg        pcm_overflow;
    wire       pcm_fifo_full;
    wire [15:0] pcm_read_left;
    wire [15:0] pcm_read_right;
    wire        pcm_fifo_empty;
    wire        pcm_fifo_pop;

    reg playback_enable_sys;
    reg playback_enable_sync1;
    reg playback_enable_sync2;
    reg pause_sync1;
    reg pause_sync2;
    wire playback_run_audio;
    wire [15:0] adc_left;
    wire [15:0] adc_right;
    wire        adc_valid;
    wire        audio_frame_tick;
    wire [15:0] dac_left;
    wire [15:0] dac_right;
    wire [31:0] playback_ms;
    reg [31:0] playback_ms_gray;
    reg [31:0] status_gray_meta;
    reg [31:0] status_gray_sync;
    wire [31:0] status_play_ms;

    wire [127:0] sd_lyric_line1;
    wire [127:0] sd_lyric_line2;
    wire [127:0] gxm_lyric_line1;
    wire [127:0] gxm_lyric_line2;
    wire        gxm_lyrics_ready;
    wire [127:0] qspi_lyric_line1;
    wire [127:0] qspi_lyric_line2;
    wire [127:0] lyric_line1;
    wire [127:0] lyric_line2;
    reg fifo_empty_sync1;
    reg fifo_empty_sync2;

    reg [127:0] track_title;
    reg [127:0] track_find_line;
    reg [127:0] lcd_line1;
    reg [127:0] lcd_line2;
    wire [19:0] fifo_percent_product;
    wire [7:0] status_fifo_percent;
    wire [7:0] board_status_error;
    wire status_playing;
    wire status_paused;

    // ---------------------------------------------------------------------
    // Reset, physical keys and unified control state
    // ---------------------------------------------------------------------
    sly4_por_reset #(.POR_BITS(22)) u_qt_por (
        .clk(sys_clk),
        .rst_n(por_n)
    );

    sly4_button_press #(.CLK_HZ(100_000_000), .DEBOUNCE_MS(20))
    u_qt_key_prev (
        .clk(sys_clk), .rst_n(por_n), .button_n(KEY0_N),
        .press(key_prev_press)
    );
    sly4_button_press #(.CLK_HZ(100_000_000), .DEBOUNCE_MS(20))
    u_qt_key_next (
        .clk(sys_clk), .rst_n(por_n), .button_n(KEY1_N),
        .press(key_next_press)
    );
    sly4_button_press #(.CLK_HZ(100_000_000), .DEBOUNCE_MS(20))
    u_qt_key_source (
        .clk(sys_clk), .rst_n(por_n), .button_n(KEY2_N),
        .press(key_source_press)
    );

    // KEY3 is deliberately accepted as a synchronized edge without waiting
    // for the 20-ms debouncer; holding it can still start only one copy.
    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
            key3_meta        <= 1'b1;
            key3_sync        <= 1'b1;
            key3_armed       <= 1'b1;
            key_copy_request <= 1'b0;
        end else begin
            key3_meta        <= KEY3_N;
            key3_sync        <= key3_meta;
            key_copy_request <= 1'b0;
            if (key3_sync)
                key3_armed <= 1'b1;
            else if (key3_armed) begin
                key3_armed       <= 1'b0;
                key_copy_request <= 1'b1;
            end
        end
    end

    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
            source_qspi              <= 1'b0;
            track_index              <= 4'd0;
            play_paused              <= 1'b0;
            media_reset_count        <= 20'd0;
            flash_copy_active        <= 1'b0;
            flash_copy_ok            <= 1'b0;
            flash_copy_failed        <= 1'b0;
            flash_copy_latched_error <= 8'd0;
        end else begin
            if (media_reset_count != 0)
                media_reset_count <= media_reset_count - 1'b1;

            if (flash_copy_active) begin
                if (flash_copy_done) begin
                    flash_copy_active        <= 1'b0;
                    flash_copy_ok            <= 1'b1;
                    flash_copy_failed        <= 1'b0;
                    flash_copy_latched_error <= 8'd0;
                end else if (flash_copy_error) begin
                    flash_copy_active        <= 1'b0;
                    flash_copy_ok            <= 1'b0;
                    flash_copy_failed        <= 1'b1;
                    flash_copy_latched_error <= flash_copy_error_code;
                end
            end else if (uart_upload_active) begin
                // Upload owns the SD block device; media resets below keep
                // playback and the ordinary FAT reader quiescent.
                play_paused <= 1'b0;
            end else if (key_copy_request) begin
                source_qspi              <= 1'b0;
                play_paused              <= 1'b0;
                flash_copy_active        <= 1'b1;
                flash_copy_ok            <= 1'b0;
                flash_copy_failed        <= 1'b0;
                flash_copy_latched_error <= 8'd0;
                media_reset_count        <= 20'd1_000_000;
            end else if (uart_cmd_source_valid || key_source_press) begin
                source_qspi <= uart_cmd_source_valid ?
                               uart_cmd_source_qspi : !source_qspi;
                play_paused              <= 1'b0;
                flash_copy_ok            <= 1'b0;
                flash_copy_failed        <= 1'b0;
                flash_copy_latched_error <= 8'd0;
                media_reset_count        <= 20'd1_000_000;
            end else if (uart_cmd_track_valid) begin
                track_index              <= uart_cmd_track;
                play_paused              <= 1'b0;
                flash_copy_ok            <= 1'b0;
                flash_copy_failed        <= 1'b0;
                flash_copy_latched_error <= 8'd0;
                media_reset_count        <= 20'd1_000_000;
            end else if (!source_qspi &&
                         (uart_cmd_next || key_next_press)) begin
                track_index <= (track_index == 4'd14) ? 4'd0 :
                               track_index + 1'b1;
                play_paused              <= 1'b0;
                flash_copy_ok            <= 1'b0;
                flash_copy_failed        <= 1'b0;
                flash_copy_latched_error <= 8'd0;
                media_reset_count        <= 20'd1_000_000;
            end else if (!source_qspi &&
                         (uart_cmd_previous || key_prev_press)) begin
                track_index <= (track_index == 4'd0) ? 4'd14 :
                               track_index - 1'b1;
                play_paused              <= 1'b0;
                flash_copy_ok            <= 1'b0;
                flash_copy_failed        <= 1'b0;
                flash_copy_latched_error <= 8'd0;
                media_reset_count        <= 20'd1_000_000;
            end else if (uart_cmd_reload) begin
                play_paused              <= 1'b0;
                flash_copy_ok            <= 1'b0;
                flash_copy_failed        <= 1'b0;
                flash_copy_latched_error <= 8'd0;
                media_reset_count        <= 20'd1_000_000;
            end else if (uart_cmd_play) begin
                play_paused <= 1'b0;
                if (media_finished_sys)
                    media_reset_count <= 20'd1_000_000;
            end else if (uart_cmd_pause) begin
                play_paused <= 1'b1;
            end
        end
    end

    assign media_cycle_rst_n = por_n && (media_reset_count == 0);
    assign media_play_rst_n = media_cycle_rst_n &&
                              !flash_copy_active &&
                              !(flash_copy_ok || flash_copy_failed) &&
                              !uart_upload_active;
    assign sd_media_rst_n = media_cycle_rst_n && !source_qspi &&
                            !uart_upload_active &&
                            (flash_copy_active ||
                             !(flash_copy_ok || flash_copy_failed));
    assign qspi_media_rst_n = media_cycle_rst_n && source_qspi &&
                              !flash_copy_active &&
                              !(flash_copy_ok || flash_copy_failed) &&
                              !uart_upload_active;
    assign qspi_copy_rst_n = media_cycle_rst_n && flash_copy_active &&
                             !uart_upload_active;

    // ---------------------------------------------------------------------
    // Audio clock, codec and I2S
    // ---------------------------------------------------------------------
    sly4_audio_clock_gen u_qt_audio_clock (
        .clk_100m(sys_clk), .rst_n(por_n),
        .mclk_audio(audio_mclk), .locked(audio_clock_locked)
    );
    assign AUDIO_MCLK = audio_mclk;
    assign audio_rst_n = por_n && audio_clock_locked;
    assign stream_async_rst_n = audio_rst_n && media_play_rst_n;

    always @(posedge audio_mclk or negedge stream_async_rst_n) begin
        if (!stream_async_rst_n)
            stream_reset_sync <= 3'b000;
        else
            stream_reset_sync <= {stream_reset_sync[1:0], 1'b1};
    end
    assign stream_audio_rst_n = stream_reset_sync[2];

    sly4_es8388_init #(.CLK_HZ(100_000_000)) u_qt_codec (
        .clk(sys_clk), .rst_n(audio_rst_n),
        .codec_scl(AUDIO_CCLK), .codec_sda(AUDIO_CDATA),
        .init_done(codec_init_done), .init_ok(codec_init_ok)
    );

    // ---------------------------------------------------------------------
    // One persistent SD SPI device, shared by playback, locator and uploader
    // ---------------------------------------------------------------------
    assign block_read_req_mux = uart_upload_active ?
        (uart_slot_io_active ? uart_block_read_req :
                               locator_block_read_req) :
        media_block_read_req;
    assign block_read_lba_mux = uart_upload_active ?
        (uart_slot_io_active ? uart_block_read_lba :
                               locator_block_read_lba) :
        media_block_read_lba;
    assign block_write_req_mux = uart_upload_active &&
                                 uart_slot_io_active &&
                                 uart_block_write_req;
    assign write_buffer_we_mux = uart_upload_active &&
                                 uart_slot_io_active &&
                                 uart_write_buffer_we;

    sly4_sd_spi_block_reader #(
        .CLK_HZ(100_000_000),
        .INIT_SPI_HZ(400_000),
        .DATA_SPI_HZ(12_500_000)
    ) u_qt_sd (
        .clk(sys_clk), .rst_n(por_n),
        .sd_cs_n(SD_CS_N), .sd_sclk(SD_SCLK),
        .sd_mosi(SD_MOSI), .sd_miso(SD_MISO),
        .read_req(block_read_req_mux), .read_lba(block_read_lba_mux),
        .ready(sd_block_ready), .read_busy(sd_read_busy),
        .read_done(sd_read_done), .data_valid(sd_data_valid),
        .data_index(sd_data_index), .data_byte(sd_data_byte),
        .write_req(block_write_req_mux),
        .write_lba(uart_block_write_lba),
        .write_buffer_we(write_buffer_we_mux),
        .write_buffer_addr(uart_write_buffer_addr),
        .write_buffer_data(uart_write_buffer_data),
        .write_busy(sd_write_busy), .write_done(sd_write_done),
        .init_done(sd_init_done), .init_ok(sd_init_ok),
        .card_sdhc(sd_card_sdhc), .error_code(sd_error)
    );

    assign sector_allow = flash_copy_active ? flash_copy_sector_allow :
                                                (pcm_fifo_level <= 13'd3712);

    sly4_fat32_song_raw_reader u_qt_media_reader (
        .clk(sys_clk), .rst_n(sd_media_rst_n),
        .track_index(flash_copy_active ? 4'd0 : track_index),
        .sd_init_ok(sd_init_ok), .sd_error_code(sd_error),
        .block_ready(sd_block_ready),
        .block_read_req(media_block_read_req),
        .block_read_lba(media_block_read_lba),
        .block_data_valid(sd_data_valid),
        .block_data_index(sd_data_index),
        .block_data_byte(sd_data_byte),
        .block_read_done(sd_read_done),
        .sector_allow(sector_allow),
        .out_valid(sd_raw_byte_valid), .out_byte(sd_raw_byte),
        .mount_done(fat_mount_done), .file_found(song_found),
        .playing(file_streaming), .eof(file_eof),
        .file_size(song_file_size), .bytes_sent(song_bytes_sent),
        .error_code(fat_error),
        .gxm_mode(gxm_mode), .gxm_header_done(gxm_header_done),
        .gxm_header_ok(gxm_header_ok), .gxm_title(gxm_title),
        .gxm_lyric_valid(gxm_lyric_valid),
        .gxm_lyric_index(gxm_lyric_index),
        .gxm_lyric_byte(gxm_lyric_byte),
        .gxm_lyric_count(gxm_lyric_count),
        .gxm_lyrics_done(gxm_lyrics_done),
        .gxm_audio_crc_ok(gxm_audio_crc_ok),
        .selected_start_cluster(media_start_cluster),
        .fs_fat_start_lba(media_fat_start_lba),
        .fs_data_start_lba(media_data_start_lba),
        .fs_sectors_per_cluster(media_sectors_per_cluster)
    );

    // During BEGIN_UPLOAD this second reader only locates the preallocated
    // USRxx.GXM file and exposes its FAT geometry. sector_allow=0 guarantees
    // it never starts streaming the file body or competes with the writer.
    sly4_fat32_song_raw_reader u_qt_slot_locator (
        .clk(sys_clk), .rst_n(por_n && uart_upload_active),
        .track_index(4'd5 + uart_upload_slot),
        .sd_init_ok(sd_init_ok), .sd_error_code(sd_error),
        .block_ready(sd_block_ready),
        .block_read_req(locator_block_read_req),
        .block_read_lba(locator_block_read_lba),
        .block_data_valid(sd_data_valid),
        .block_data_index(sd_data_index),
        .block_data_byte(sd_data_byte),
        .block_read_done(sd_read_done),
        .sector_allow(1'b0),
        .out_valid(), .out_byte(),
        .mount_done(slot_mount_done), .file_found(slot_file_found),
        .playing(), .eof(), .file_size(slot_file_size),
        .bytes_sent(), .error_code(slot_fat_error),
        .gxm_mode(), .gxm_header_done(), .gxm_header_ok(),
        .gxm_title(), .gxm_lyric_valid(), .gxm_lyric_index(),
        .gxm_lyric_byte(), .gxm_lyric_count(), .gxm_lyrics_done(),
        .gxm_audio_crc_ok(),
        .selected_start_cluster(slot_start_cluster),
        .fs_fat_start_lba(slot_fat_start_lba),
        .fs_data_start_lba(slot_data_start_lba),
        .fs_sectors_per_cluster(slot_sectors_per_cluster)
    );

    // ---------------------------------------------------------------------
    // Independent 4-MiB QSPI excerpt and KEY3 SD-to-QSPI copier
    // ---------------------------------------------------------------------
    assign qspi_byte_ready = (pcm_fifo_level <= 13'd3712);
    sly4_qspi_pcm_streamer #(
        .CLK_HZ(100_000_000), .SPI_HZ(5_000_000),
        .BASE_ADDR(24'h010000), .DATA_BYTES(32'd1_764_000),
        .LYRIC_ADDR(24'h000100), .LYRIC_BYTES(16'd180)
    ) u_qt_qspi_player (
        .clk(sys_clk), .rst_n(qspi_media_rst_n),
        .enable(source_qspi && !uart_upload_active),
        .spi_cs_n(qspi_play_cs_n), .spi_sclk(qspi_play_sclk),
        .spi_mosi(qspi_play_mosi), .spi_miso(FLASH_MISO),
        .data(qspi_byte), .valid(qspi_byte_valid),
        .ready(qspi_byte_ready),
        .header_done(qspi_header_done), .header_ok(qspi_header_ok),
        .eof(qspi_eof), .bytes_sent(qspi_bytes_sent),
        .error_code(qspi_error),
        .lyric_byte_valid(qspi_lyric_byte_valid),
        .lyric_byte_index(qspi_lyric_byte_index),
        .lyric_byte(qspi_lyric_byte),
        .lyric_load_done(qspi_lyric_load_done)
    );

    sly4_sd_to_qspi_copier #(
        .CLK_HZ(100_000_000), .SPI_HZ(5_000_000),
        .BASE_ADDR(24'h010000), .DATA_BYTES(32'd1_764_000),
        .LYRIC_ADDR(24'h000100), .LAST_ERASE_ADDR(24'h1B0000)
    ) u_qt_qspi_copier (
        .clk(sys_clk), .rst_n(qspi_copy_rst_n),
        .enable(flash_copy_active),
        .sd_byte_valid(sd_raw_byte_valid), .sd_byte(sd_raw_byte),
        .sd_init_ok(sd_init_ok), .file_found(song_found),
        .file_size(song_file_size), .sd_error_code(sd_error),
        .fat_error_code(fat_error),
        .sector_allow(flash_copy_sector_allow),
        .spi_cs_n(qspi_copy_cs_n), .spi_sclk(qspi_copy_sclk),
        .spi_mosi(qspi_copy_mosi), .spi_miso(FLASH_MISO),
        .done(flash_copy_done), .error(flash_copy_error),
        .error_code(flash_copy_error_code), .stage(flash_copy_stage),
        .bytes_copied(flash_copy_bytes)
    );

    assign FLASH_CS_N = flash_copy_active ? qspi_copy_cs_n :
                                              qspi_play_cs_n;
    assign FLASH_SCLK = flash_copy_active ? qspi_copy_sclk :
                                              qspi_play_sclk;
    assign FLASH_MOSI = flash_copy_active ? qspi_copy_mosi :
                                              qspi_play_mosi;
    assign FLASH_HOLD_N = 1'b1;

    // ---------------------------------------------------------------------
    // Byte packing, asynchronous FIFO and sample-accurate pause/time
    // ---------------------------------------------------------------------
    assign raw_byte_valid = flash_copy_active ? 1'b0 :
                            (source_qspi ?
                             (qspi_byte_valid && qspi_byte_ready) :
                             sd_raw_byte_valid);
    assign raw_byte = source_qspi ? qspi_byte : sd_raw_byte;
    assign media_eof = source_qspi ? qspi_eof : file_eof;

    always @(posedge sys_clk or negedge media_play_rst_n) begin
        if (!media_play_rst_n) begin
            pcm_byte_phase  <= 2'd0;
            left_low        <= 8'd0;
            left_high       <= 8'd0;
            right_low       <= 8'd0;
            pcm_fifo_write  <= 1'b0;
            pcm_write_left  <= 16'd0;
            pcm_write_right <= 16'd0;
            pcm_overflow    <= 1'b0;
        end else begin
            pcm_fifo_write <= 1'b0;
            if (raw_byte_valid) begin
                case (pcm_byte_phase)
                    2'd0: begin left_low <= raw_byte; pcm_byte_phase <= 2'd1; end
                    2'd1: begin left_high <= raw_byte; pcm_byte_phase <= 2'd2; end
                    2'd2: begin right_low <= raw_byte; pcm_byte_phase <= 2'd3; end
                    default: begin
                        if (!pcm_fifo_full) begin
                            pcm_write_left  <= {left_high, left_low};
                            pcm_write_right <= {raw_byte, right_low};
                            pcm_fifo_write  <= 1'b1;
                        end else begin
                            pcm_overflow <= 1'b1;
                        end
                        pcm_byte_phase <= 2'd0;
                    end
                endcase
            end
        end
    end

    sly4_async_stereo_fifo_level #(.AW(12)) u_qt_pcm_fifo (
        .wr_clk(sys_clk), .wr_rst_n(media_play_rst_n), .wr_clear(1'b0),
        .wr_en(pcm_fifo_write), .wr_l(pcm_write_left),
        .wr_r(pcm_write_right), .wr_full(pcm_fifo_full),
        .wr_level(pcm_fifo_level),
        .rd_clk(audio_mclk), .rd_rst_n(stream_audio_rst_n),
        .rd_clear(1'b0), .rd_pop(pcm_fifo_pop),
        .rd_l(pcm_read_left), .rd_r(pcm_read_right),
        .rd_empty(pcm_fifo_empty)
    );

    always @(posedge sys_clk or negedge media_play_rst_n) begin
        if (!media_play_rst_n)
            playback_enable_sys <= 1'b0;
        else if (pcm_overflow ||
                 (source_qspi && (qspi_error != 0)) ||
                 (!source_qspi && ((sd_error != 0) || (fat_error != 0))))
            playback_enable_sys <= 1'b0;
        else if (!playback_enable_sys &&
                 (source_qspi ? qspi_lyrics_ready :
                  ((track_index < 4'd5) ||
                   (gxm_header_ok && gxm_lyrics_ready))) &&
                 ((pcm_fifo_level >= 13'd1024) ||
                  (media_eof && (pcm_fifo_level != 0))))
            playback_enable_sys <= 1'b1;
    end

    always @(posedge audio_mclk or negedge stream_audio_rst_n) begin
        if (!stream_audio_rst_n) begin
            playback_enable_sync1 <= 1'b0;
            playback_enable_sync2 <= 1'b0;
            pause_sync1           <= 1'b0;
            pause_sync2           <= 1'b0;
        end else begin
            playback_enable_sync1 <= playback_enable_sys;
            playback_enable_sync2 <= playback_enable_sync1;
            pause_sync1           <= play_paused;
            pause_sync2           <= pause_sync1;
        end
    end

    assign playback_run_audio = playback_enable_sync2 && !pause_sync2;
    assign dac_left = (playback_run_audio && !pcm_fifo_empty) ?
                      pcm_read_left : 16'd0;
    assign dac_right = (playback_run_audio && !pcm_fifo_empty) ?
                       pcm_read_right : 16'd0;
    assign pcm_fifo_pop = audio_frame_tick && playback_run_audio &&
                          !pcm_fifo_empty;

    sly4_i2s_audio_if u_qt_i2s (
        .mclk(audio_mclk), .rst_n(audio_rst_n),
        .tx_left(dac_left), .tx_right(dac_right),
        .adc_data(AUDIO_ADC_DOUT), .dac_data(AUDIO_DAC_DIN),
        .bclk(AUDIO_BCLK), .lrclk(AUDIO_LRCK),
        .rx_left(adc_left), .rx_right(adc_right),
        .rx_valid(adc_valid), .frame_tick(audio_frame_tick)
    );

    sly4_play_time_ms u_qt_play_time (
        .clk(audio_mclk), .rst_n(stream_audio_rst_n),
        .reset_time(!playback_enable_sync2),
        .sample_tick(audio_frame_tick),
        .advance(playback_run_audio && !pcm_fifo_empty),
        .ms(playback_ms)
    );

    always @(posedge audio_mclk or negedge stream_audio_rst_n) begin
        if (!stream_audio_rst_n)
            playback_ms_gray <= 32'd0;
        else
            playback_ms_gray <= (playback_ms >> 1) ^ playback_ms;
    end

    function [31:0] qt_gray_to_binary32;
        input [31:0] gray_value;
        integer bit_number;
        begin
            qt_gray_to_binary32[31] = gray_value[31];
            for (bit_number=30; bit_number>=0; bit_number=bit_number-1)
                qt_gray_to_binary32[bit_number] =
                    qt_gray_to_binary32[bit_number+1] ^ gray_value[bit_number];
        end
    endfunction
    assign status_play_ms = qt_gray_to_binary32(status_gray_sync);
    always @(posedge sys_clk or negedge media_play_rst_n) begin
        if (!media_play_rst_n) begin
            status_gray_meta <= 32'd0;
            status_gray_sync <= 32'd0;
        end else begin
            status_gray_meta <= playback_ms_gray;
            status_gray_sync <= status_gray_meta;
        end
    end

    // ---------------------------------------------------------------------
    // Embedded, GXM and QSPI lyric sources
    // ---------------------------------------------------------------------
    sly4_lyrics_display u_qt_legacy_lyrics (
        .clk(sys_clk), .rst_n(por_n),
        .active(playback_enable_sys && !source_qspi &&
                (track_index < 4'd5)),
        .track_index(track_index[2:0]), .qspi_mode(1'b0),
        .play_ms_gray_async(playback_ms_gray),
        .line1(sd_lyric_line1), .line2(sd_lyric_line2)
    );

    gx5_gxm_lyrics_display u_qt_gxm_lyrics (
        .clk(sys_clk), .rst_n(sd_media_rst_n),
        .active(playback_enable_sys && !source_qspi &&
                (track_index >= 4'd5)),
        .load_valid(gxm_lyric_valid), .load_index(gxm_lyric_index),
        .load_byte(gxm_lyric_byte), .load_count(gxm_lyric_count),
        .load_done(gxm_lyrics_done),
        .play_ms_gray_async(playback_ms_gray),
        .ready(gxm_lyrics_ready),
        .line1(gxm_lyric_line1), .line2(gxm_lyric_line2)
    );

    sly4_qspi_lyrics_display u_qt_qspi_lyrics (
        .clk(sys_clk), .rst_n(qspi_media_rst_n),
        .active(playback_enable_sys && source_qspi),
        .load_valid(qspi_lyric_byte_valid),
        .load_index(qspi_lyric_byte_index),
        .load_byte(qspi_lyric_byte),
        .load_done(qspi_lyric_load_done),
        .play_ms_gray_async(playback_ms_gray),
        .ready(qspi_lyrics_ready),
        .line1(qspi_lyric_line1), .line2(qspi_lyric_line2)
    );

    assign lyric_line1 = source_qspi ? qspi_lyric_line1 :
                         ((track_index >= 4'd5) ? gxm_lyric_line1 :
                                                 sd_lyric_line1);
    assign lyric_line2 = source_qspi ? qspi_lyric_line2 :
                         ((track_index >= 4'd5) ? gxm_lyric_line2 :
                                                 sd_lyric_line2);

    always @(posedge sys_clk or negedge media_play_rst_n) begin
        if (!media_play_rst_n) begin
            fifo_empty_sync1 <= 1'b1;
            fifo_empty_sync2 <= 1'b1;
        end else begin
            fifo_empty_sync1 <= pcm_fifo_empty;
            fifo_empty_sync2 <= fifo_empty_sync1;
        end
    end
    assign media_finished_sys = media_eof && fifo_empty_sync2;

    // ---------------------------------------------------------------------
    // LCD status and lyrics
    // ---------------------------------------------------------------------
    always @* begin
        case (track_index)
            4'd0: begin
                track_title = "WE DON'T TALK...";
                track_find_line = "FIND SONG.RAW   ";
            end
            4'd1: begin
                track_title = "BEAUTY AND BEAT ";
                track_find_line = "FIND BEAUTY.RAW ";
            end
            4'd2: begin
                track_title = "DIE FOR YOU     ";
                track_find_line = "FIND DIE4YOU.RAW";
            end
            4'd3: begin
                track_title = "PAYPHONE        ";
                track_find_line = "FIND PAYPHONE   ";
            end
            4'd4: begin
                track_title = "STARBOY         ";
                track_find_line = "FIND STARBOY.RAW";
            end
            4'd5: begin
                track_title = gxm_header_ok ? gxm_title : "USR00.GXM       ";
                track_find_line = "FIND USR00.GXM  ";
            end
            4'd6: begin
                track_title = gxm_header_ok ? gxm_title : "USR01.GXM       ";
                track_find_line = "FIND USR01.GXM  ";
            end
            4'd7: begin
                track_title = gxm_header_ok ? gxm_title : "USR02.GXM       ";
                track_find_line = "FIND USR02.GXM  ";
            end
            4'd8: begin
                track_title = gxm_header_ok ? gxm_title : "USR03.GXM       ";
                track_find_line = "FIND USR03.GXM  ";
            end
            4'd9: begin
                track_title = gxm_header_ok ? gxm_title : "USR04.GXM       ";
                track_find_line = "FIND USR04.GXM  ";
            end
            4'd10: begin
                track_title = gxm_header_ok ? gxm_title : "USR05.GXM       ";
                track_find_line = "FIND USR05.GXM  ";
            end
            4'd11: begin
                track_title = gxm_header_ok ? gxm_title : "USR06.GXM       ";
                track_find_line = "FIND USR06.GXM  ";
            end
            4'd12: begin
                track_title = gxm_header_ok ? gxm_title : "USR07.GXM       ";
                track_find_line = "FIND USR07.GXM  ";
            end
            4'd13: begin
                track_title = gxm_header_ok ? gxm_title : "USR08.GXM       ";
                track_find_line = "FIND USR08.GXM  ";
            end
            default: begin
                track_title = gxm_header_ok ? gxm_title : "USR09.GXM       ";
                track_find_line = "FIND USR09.GXM  ";
            end
        endcase
    end

    always @* begin
        lcd_line1 = source_qspi ? "QSPI WDT 10 SEC " : track_title;
        lcd_line2 = source_qspi ? "CHECKING FLASH  " :
                                  "SD INITIALIZING ";

        if (uart_upload_active) begin
            lcd_line1 = "QT SD UPLOAD    ";
            case (uart_upload_stage)
                5'd1: lcd_line2 = "WAIT FOR SD     ";
                5'd2: lcd_line2 = "LOCATE USER SLOT";
                5'd3: lcd_line2 = "WRITE + VERIFY  ";
                5'd4: lcd_line2 = "COMMIT HEADER   ";
                default: lcd_line2 = "WAIT FOR DATA   ";
            endcase
        end else if (flash_copy_active) begin
            lcd_line1 = "COPY SD TO QSPI ";
            if (!media_cycle_rst_n)
                lcd_line2 = "STARTING COPY...";
            else begin
                case (flash_copy_stage)
                    4'd1: lcd_line2 = "ERASING FLASH   ";
                    4'd2: lcd_line2 = sd_init_done ? "FIND SONG.RAW   " :
                                                    "SD INITIALIZING ";
                    4'd3, 4'd4: lcd_line2 = "COPYING AUDIO   ";
                    4'd5: lcd_line2 = "WRITING LYRICS  ";
                    4'd6: lcd_line2 = "WRITING HEADER  ";
                    default: lcd_line2 = "PREPARING...    ";
                endcase
            end
        end else if (flash_copy_ok) begin
            lcd_line1 = "QSPI COPY OK    ";
            lcd_line2 = "PRESS K2 TO PLAY";
        end else if (flash_copy_failed) begin
            lcd_line1 = "QSPI COPY ERROR ";
            case (flash_copy_latched_error)
                8'h01: lcd_line2 = "SD READ ERROR   ";
                8'h02: lcd_line2 = "FAT32 ERROR     ";
                8'h03: lcd_line2 = "SONG TOO SHORT  ";
                8'h04: lcd_line2 = "VERIFY FAILED   ";
                8'h05: lcd_line2 = "ERASE TIMEOUT   ";
                8'h06: lcd_line2 = "WRITE TIMEOUT   ";
                default: lcd_line2 = "FLASH FSM ERROR ";
            endcase
        end else if (!media_cycle_rst_n) begin
            lcd_line2 = "RESTARTING...   ";
        end else if (!codec_init_done) begin
            lcd_line2 = "CODEC INIT...   ";
        end else if (!codec_init_ok) begin
            lcd_line1 = "AUDIO ERROR     ";
            lcd_line2 = "CODEC I2C ERROR ";
        end else if (pcm_overflow) begin
            lcd_line1 = "AUDIO ERROR     ";
            lcd_line2 = "PCM FIFO FULL   ";
        end else if (source_qspi) begin
            if (qspi_header_done && !qspi_header_ok) begin
                lcd_line1 = "FLASH DATA ERROR";
                lcd_line2 = "PRESS K3 TO COPY";
            end else if (!qspi_header_done) begin
                lcd_line2 = "CHECKING FLASH  ";
            end else if (!qspi_lyrics_ready) begin
                lcd_line2 = "LOADING LYRICS  ";
            end else if (!playback_enable_sys) begin
                lcd_line2 = "BUFFERING QSPI  ";
            end else if (play_paused) begin
                lcd_line1 = lyric_line1;
                lcd_line2 = "*** PAUSED ***  ";
            end else if (qspi_eof && fifo_empty_sync2) begin
                lcd_line1 = "QSPI WDT 10 SEC ";
                lcd_line2 = "QSPI TEST DONE  ";
            end else begin
                lcd_line1 = lyric_line1;
                lcd_line2 = lyric_line2;
            end
        end else if (sd_error != 0) begin
            lcd_line1 = "SD READ ERROR   ";
            case (sd_error)
                8'h01: lcd_line2 = "CMD0 FAILED     ";
                8'h02: lcd_line2 = "CMD8 FAILED     ";
                8'h03: lcd_line2 = "ACMD41 TIMEOUT  ";
                8'h04: lcd_line2 = "CMD58 FAILED    ";
                8'h05: lcd_line2 = "CMD16 FAILED    ";
                8'h06: lcd_line2 = "CMD17 FAILED    ";
                8'h07: lcd_line2 = "READ TIMEOUT    ";
                8'h08: lcd_line2 = "CMD24 FAILED    ";
                8'h09: lcd_line2 = "WRITE REJECTED  ";
                default: lcd_line2 = "WRITE TIMEOUT   ";
            endcase
        end else if (!sd_init_done) begin
            lcd_line2 = "SD INITIALIZING ";
        end else if (fat_error != 0) begin
            lcd_line1 = (track_index >= 4'd5) ? "GXM DATA ERROR  " :
                                                "FAT32 ERROR     ";
            case (fat_error)
                8'h01: lcd_line2 = "NO FAT32 VOLUME ";
                8'h02: lcd_line2 = "BAD FAT32 BPB   ";
                8'h03: lcd_line2 = "TRACK FILE MISS ";
                8'h04: lcd_line2 = "BAD FILE ENTRY  ";
                8'h05: lcd_line2 = "FAT CHAIN ERROR ";
                8'h07: lcd_line2 = "BAD GXM HEADER  ";
                8'h08: lcd_line2 = "LYRIC CRC ERROR ";
                8'h09: lcd_line2 = "AUDIO CRC ERROR ";
                default: lcd_line2 = "SD SECTOR ERROR ";
            endcase
        end else if (!fat_mount_done) begin
            lcd_line2 = track_find_line;
        end else if ((track_index >= 4'd5) && !gxm_lyrics_ready) begin
            lcd_line2 = "LOADING GXM TEXT";
        end else if (!playback_enable_sys) begin
            lcd_line2 = "BUFFERING AUDIO ";
        end else if (play_paused) begin
            lcd_line1 = lyric_line1;
            lcd_line2 = "*** PAUSED ***  ";
        end else if (file_eof && fifo_empty_sync2) begin
            lcd_line1 = track_title;
            lcd_line2 = "PLAYBACK FINISH ";
        end else begin
            lcd_line1 = lyric_line1;
            lcd_line2 = lyric_line2;
        end
    end

    sly4_lcd1602_driver #(.CLK_HZ(100_000_000)) u_qt_lcd (
        .clk(sys_clk), .rst_n(por_n),
        .line1(lcd_line1), .line2(lcd_line2),
        .lcd_d(LCD_D), .lcd_rs(LCD_RS),
        .lcd_rw(LCD_RW), .lcd_e(LCD_E)
    );

    // ---------------------------------------------------------------------
    // Qt UART endpoint and board-status reporting
    // ---------------------------------------------------------------------
    assign fifo_percent_product = {7'd0, pcm_fifo_level} * 8'd100;
    assign status_fifo_percent = pcm_fifo_level[12] ? 8'd100 :
                                  fifo_percent_product[19:12];
    assign board_status_error = (uart_upload_error != 0) ?
                                 uart_upload_error :
                                flash_copy_failed ? 8'hE1 :
                                pcm_overflow ? 8'hE2 :
                                source_qspi ? qspi_error :
                                ((sd_error != 0) ? sd_error : fat_error);
    assign status_playing = playback_enable_sys && !play_paused &&
                            !fifo_empty_sync2 && !uart_upload_active;
    assign status_paused = playback_enable_sys && play_paused &&
                           !uart_upload_active;

    gx5_uart_sd_controller #(
        .CLK_HZ(100_000_000), .BAUD(921_600)
    ) u_qt_uart_controller (
        .clk(sys_clk), .rst_n(por_n),
        .uart_rx(UART_RXD), .uart_tx(UART_TXD),
        .cmd_play(uart_cmd_play), .cmd_pause(uart_cmd_pause),
        .cmd_previous(uart_cmd_previous), .cmd_next(uart_cmd_next),
        .cmd_source_valid(uart_cmd_source_valid),
        .cmd_source_qspi(uart_cmd_source_qspi),
        .cmd_track_valid(uart_cmd_track_valid),
        .cmd_track(uart_cmd_track), .cmd_reload(uart_cmd_reload),
        .status_source_qspi(source_qspi), .status_track(track_index),
        .status_playing(status_playing), .status_paused(status_paused),
        .status_play_ms(status_play_ms),
        .status_error(board_status_error),
        .status_fifo_percent(status_fifo_percent),
        .allow_upload(!flash_copy_active),
        .upload_active(uart_upload_active),
        .upload_slot(uart_upload_slot),
        .slot_io_active(uart_slot_io_active),
        .upload_stage(uart_upload_stage),
        .upload_error(uart_upload_error),
        .sd_init_ok(sd_init_ok), .sd_error_code(sd_error),
        .slot_mount_done(slot_mount_done),
        .slot_file_found(slot_file_found),
        .slot_fat_error(slot_fat_error),
        .slot_file_size(slot_file_size),
        .slot_start_cluster(slot_start_cluster),
        .slot_fat_start_lba(slot_fat_start_lba),
        .slot_data_start_lba(slot_data_start_lba),
        .slot_sectors_per_cluster(slot_sectors_per_cluster),
        .block_ready(sd_block_ready),
        .block_read_req(uart_block_read_req),
        .block_read_lba(uart_block_read_lba),
        .block_data_valid(sd_data_valid),
        .block_data_index(sd_data_index),
        .block_data_byte(sd_data_byte),
        .block_read_done(sd_read_done),
        .block_write_req(uart_block_write_req),
        .block_write_lba(uart_block_write_lba),
        .block_write_buffer_we(uart_write_buffer_we),
        .block_write_buffer_addr(uart_write_buffer_addr),
        .block_write_buffer_data(uart_write_buffer_data),
        .block_write_done(sd_write_done)
    );

    assign LED0 = uart_upload_active ? 1'b1 :
                  flash_copy_active ? 1'b1 :
                  (codec_init_ok &&
                   (source_qspi ? qspi_header_ok : sd_init_ok));
    assign LED1 = uart_upload_active ? uart_slot_io_active :
                  flash_copy_active ? 1'b0 :
                  (playback_run_audio && !pcm_fifo_empty);

    // Retain diagnostic paths without allowing optimization warnings to hide
    // a genuinely unconnected board pin.
    wire unused_qt_diagnostics = SD_CD_N ^ sd_card_sdhc ^ sd_read_busy ^
        sd_write_busy ^ file_streaming ^ song_found ^ song_bytes_sent[0] ^
        qspi_bytes_sent[0] ^ flash_copy_bytes[0] ^ gxm_mode ^
        gxm_header_done ^ gxm_audio_crc_ok ^ media_start_cluster[0] ^
        media_fat_start_lba[0] ^ media_data_start_lba[0] ^
        media_sectors_per_cluster[0] ^ adc_left[0] ^ adc_right[0] ^
        adc_valid ^ playback_ms[0];
endmodule

`default_nettype wire
