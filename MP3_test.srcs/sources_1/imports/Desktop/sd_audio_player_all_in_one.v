`timescale 1ns / 1ps
`default_nettype none

// GX-BIDT XC7A200T SD-card audio player -- self-contained Design Source.
// Add only this Verilog file as a Design Source and set
// top_sd_audio_player_all_in_one as the top module.
// SD root file: SONG.RAW (44.1 kHz, signed 16-bit LE stereo PCM).
// Revision 5: slow unsynchronized lyric-preview mode (2 seconds per page).


// SD-card full-song PCM player for GX-BIDT + XC7A200T + ES8388.
//
// SD root file: SONG.RAW
// Format: 44.1 kHz, signed 16-bit little-endian, stereo interleaved PCM.
// Byte order for every frame: L low, L high, R low, R high.
//
// QSPI Flash is deliberately held inactive in this build.
module top_sd_audio_player_all_in_one (
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

    output wire [7:0] LCD_D,
    output wire       LCD_RS,
    output wire       LCD_RW,
    output wire       LCD_E,

    output wire       LED0,
    output wire       LED1
);
    // Temporary inspection mode requested by the user.  Set to 0 later to
    // restore sample-time synchronization after the lyric text is confirmed.
    localparam integer LYRIC_PREVIEW_MODE = 1;

    wire por_n;
    sdall_por_reset #(.POR_BITS(22)) u_por (
        .clk(sys_clk),
        .rst_n(por_n)
    );

    // 11.2896 MHz = 256 * 44.1 kHz.
    wire audio_mclk;
    wire audio_clock_locked;
    sdall_audio_clock_gen u_audio_clock (
        .clk_100m(sys_clk),
        .rst_n(por_n),
        .mclk_audio(audio_mclk),
        .locked(audio_clock_locked)
    );
    wire audio_rst_n = por_n & audio_clock_locked;
    assign AUDIO_MCLK = audio_mclk;

    wire codec_init_done;
    wire codec_init_ok;
    sdall_es8388_init #(.CLK_HZ(100_000_000)) u_codec_init (
        .clk(sys_clk),
        .rst_n(audio_rst_n),
        .codec_scl(AUDIO_CCLK),
        .codec_sda(AUDIO_CDATA),
        .init_done(codec_init_done),
        .init_ok(codec_init_ok)
    );

    // ------------------------------------------------------------------
    // SD SPI block device
    // ------------------------------------------------------------------
    wire        sd_block_ready;
    wire        sd_read_busy;
    wire        sd_read_done;
    wire        sd_data_valid;
    wire [8:0]  sd_data_index;
    wire [7:0]  sd_data_byte;
    wire        sd_init_done;
    wire        sd_init_ok;
    wire        sd_card_sdhc;
    wire [7:0]  sd_error;
    wire        block_read_req;
    wire [31:0] block_read_lba;

    sdall_sd_spi_block_reader #(
        .CLK_HZ(100_000_000),
        .INIT_SPI_HZ(400_000),
        .DATA_SPI_HZ(12_500_000)
    ) u_sd (
        .clk(sys_clk),
        .rst_n(por_n),
        .sd_cs_n(SD_CS_N),
        .sd_sclk(SD_SCLK),
        .sd_mosi(SD_MOSI),
        .sd_miso(SD_MISO),
        .read_req(block_read_req),
        .read_lba(block_read_lba),
        .ready(sd_block_ready),
        .read_busy(sd_read_busy),
        .read_done(sd_read_done),
        .data_valid(sd_data_valid),
        .data_index(sd_data_index),
        .data_byte(sd_data_byte),
        .init_done(sd_init_done),
        .init_ok(sd_init_ok),
        .card_sdhc(sd_card_sdhc),
        .error_code(sd_error)
    );

    // ------------------------------------------------------------------
    // FAT32 root-directory search and SONG.RAW byte stream
    // ------------------------------------------------------------------
    wire        raw_byte_valid;
    wire [7:0]  raw_byte;
    wire        fat_mount_done;
    wire        song_found;
    wire        file_streaming;
    wire        file_eof;
    wire [31:0] song_file_size;
    wire [31:0] song_bytes_sent;
    wire [7:0]  fat_error;

    wire [12:0] pcm_fifo_level;
    // A sector contributes 128 stereo frames. Keep at least 384 slots free.
    wire sector_allow = (pcm_fifo_level <= 13'd3712);

    sdall_fat32_song_raw_reader u_fat32 (
        .clk(sys_clk),
        .rst_n(por_n),
        .sd_init_ok(sd_init_ok),
        .sd_error_code(sd_error),
        .block_ready(sd_block_ready),
        .block_read_req(block_read_req),
        .block_read_lba(block_read_lba),
        .block_data_valid(sd_data_valid),
        .block_data_index(sd_data_index),
        .block_data_byte(sd_data_byte),
        .block_read_done(sd_read_done),
        .sector_allow(sector_allow),
        .out_valid(raw_byte_valid),
        .out_byte(raw_byte),
        .mount_done(fat_mount_done),
        .file_found(song_found),
        .playing(file_streaming),
        .eof(file_eof),
        .file_size(song_file_size),
        .bytes_sent(song_bytes_sent),
        .error_code(fat_error)
    );

    // ------------------------------------------------------------------
    // Four little-endian bytes -> one stereo PCM frame
    // ------------------------------------------------------------------
    reg [1:0]  pcm_byte_phase;
    reg [7:0]  left_low;
    reg [7:0]  left_high;
    reg [7:0]  right_low;
    reg        pcm_fifo_write;
    reg [15:0] pcm_write_left;
    reg [15:0] pcm_write_right;
    reg        pcm_overflow;
    wire       pcm_fifo_full;

    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
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
                    2'd0: begin
                        left_low       <= raw_byte;
                        pcm_byte_phase <= 2'd1;
                    end
                    2'd1: begin
                        left_high      <= raw_byte;
                        pcm_byte_phase <= 2'd2;
                    end
                    2'd2: begin
                        right_low      <= raw_byte;
                        pcm_byte_phase <= 2'd3;
                    end
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

    // ------------------------------------------------------------------
    // Cross from the 100-MHz SD domain to the 11.2896-MHz audio domain.
    // ------------------------------------------------------------------
    wire [15:0] pcm_read_left;
    wire [15:0] pcm_read_right;
    wire        pcm_fifo_empty;
    wire        pcm_fifo_pop;

    sdall_async_stereo_fifo_level #(.AW(12)) u_pcm_fifo (
        .wr_clk(sys_clk),
        .wr_rst_n(por_n),
        .wr_clear(1'b0),
        .wr_en(pcm_fifo_write),
        .wr_l(pcm_write_left),
        .wr_r(pcm_write_right),
        .wr_full(pcm_fifo_full),
        .wr_level(pcm_fifo_level),
        .rd_clk(audio_mclk),
        .rd_rst_n(audio_rst_n),
        .rd_clear(1'b0),
        .rd_pop(pcm_fifo_pop),
        .rd_l(pcm_read_left),
        .rd_r(pcm_read_right),
        .rd_empty(pcm_fifo_empty)
    );

    // Start only after about 23 ms has been buffered. Very short test files
    // are also allowed to start once their complete contents are present.
    reg playback_enable_sys;
    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n)
            playback_enable_sys <= 1'b0;
        else if ((sd_error != 0) || (fat_error != 0) || pcm_overflow)
            playback_enable_sys <= 1'b0;
        else if (!playback_enable_sys &&
                 ((pcm_fifo_level >= 13'd1024) ||
                  (file_eof && (pcm_fifo_level != 0))))
            playback_enable_sys <= 1'b1;
    end

    reg playback_sync1;
    reg playback_sync2;
    always @(posedge audio_mclk or negedge audio_rst_n) begin
        if (!audio_rst_n) begin
            playback_sync1 <= 1'b0;
            playback_sync2 <= 1'b0;
        end else begin
            playback_sync1 <= playback_enable_sys;
            playback_sync2 <= playback_sync1;
        end
    end

    wire [15:0] adc_left;
    wire [15:0] adc_right;
    wire        adc_valid;
    wire        audio_frame_tick;
    wire [15:0] dac_left =
        (playback_sync2 && !pcm_fifo_empty) ? pcm_read_left : 16'd0;
    wire [15:0] dac_right =
        (playback_sync2 && !pcm_fifo_empty) ? pcm_read_right : 16'd0;

    assign pcm_fifo_pop = audio_frame_tick && playback_sync2 &&
                          !pcm_fifo_empty;

    sdall_i2s_audio_if u_i2s (
        .mclk(audio_mclk),
        .rst_n(audio_rst_n),
        .tx_left(dac_left),
        .tx_right(dac_right),
        .adc_data(AUDIO_ADC_DOUT),
        .dac_data(AUDIO_DAC_DIN),
        .bclk(AUDIO_BCLK),
        .lrclk(AUDIO_LRCK),
        .rx_left(adc_left),
        .rx_right(adc_right),
        .rx_valid(adc_valid),
        .frame_tick(audio_frame_tick)
    );

    // Sample-derived time base keeps the lyrics locked to samples actually
    // delivered to the codec, rather than to SD-card read/buffer time.
    wire [31:0] playback_ms;
    sdall_play_time_ms u_play_time (
        .clk(audio_mclk),
        .rst_n(audio_rst_n),
        .reset_time(!playback_sync2),
        .sample_tick(audio_frame_tick),
        .advance(playback_sync2 && !pcm_fifo_empty),
        .ms(playback_ms)
    );

    // Register the Gray counter in its source domain before crossing into the
    // 100-MHz LCD domain.  This preserves the one-bit-change Gray property.
    reg [31:0] playback_ms_gray;
    always @(posedge audio_mclk or negedge audio_rst_n) begin
        if (!audio_rst_n)
            playback_ms_gray <= 32'd0;
        else
            playback_ms_gray <= (playback_ms >> 1) ^ playback_ms;
    end
    wire [127:0] lyric_line2;
    sdall_lyrics_display #(
        .CLK_HZ(100_000_000),
        .PREVIEW_MODE(LYRIC_PREVIEW_MODE),
        .PREVIEW_PAGE_MS(2000)
    ) u_lyrics (
        .clk(sys_clk),
        .rst_n(por_n),
        .active(playback_enable_sys),
        .play_ms_gray_async(playback_ms_gray),
        .line2(lyric_line2)
    );

    // Synchronize the empty flag for the end-of-playback LCD message.
    reg fifo_empty_sync1;
    reg fifo_empty_sync2;
    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
            fifo_empty_sync1 <= 1'b1;
            fifo_empty_sync2 <= 1'b1;
        end else begin
            fifo_empty_sync1 <= pcm_fifo_empty;
            fifo_empty_sync2 <= fifo_empty_sync1;
        end
    end

    reg [127:0] lcd_line1;
    reg [127:0] lcd_line2;
    always @* begin
        lcd_line1 = "SD PCM PLAYER   ";
        lcd_line2 = "SD INITIALIZING ";

        if (sd_error != 0) begin
            lcd_line1 = "SD READ ERROR   ";
            case (sd_error)
                8'h01: lcd_line2 = "CMD0 FAILED     ";
                8'h02: lcd_line2 = "CMD8 FAILED     ";
                8'h03: lcd_line2 = "ACMD41 TIMEOUT  ";
                8'h04: lcd_line2 = "CMD58 FAILED    ";
                8'h05: lcd_line2 = "CMD16 FAILED    ";
                8'h06: lcd_line2 = "CMD17 FAILED    ";
                default: lcd_line2 = "DATA TIMEOUT    ";
            endcase
        end else if (!sd_init_done) begin
            lcd_line2 = "SD INITIALIZING ";
        end else if (!codec_init_done) begin
            lcd_line2 = "CODEC INIT...   ";
        end else if (!codec_init_ok) begin
            lcd_line1 = "AUDIO ERROR     ";
            lcd_line2 = "CODEC I2C ERROR ";
        end else if (fat_error != 0) begin
            lcd_line1 = "FAT32 ERROR     ";
            case (fat_error)
                8'h01: lcd_line2 = "NO FAT32 VOLUME ";
                8'h02: lcd_line2 = "BAD FAT32 BPB   ";
                8'h03: lcd_line2 = "SONG.RAW MISSING";
                8'h04: lcd_line2 = "BAD SONG ENTRY  ";
                8'h05: lcd_line2 = "FAT CHAIN ERROR ";
                default: lcd_line2 = "SD SECTOR ERROR ";
            endcase
        end else if (pcm_overflow) begin
            lcd_line1 = "AUDIO ERROR     ";
            lcd_line2 = "PCM FIFO FULL   ";
        end else if (!fat_mount_done) begin
            lcd_line2 = "FINDING SONG.RAW";
        end else if (!playback_enable_sys) begin
            lcd_line2 = "BUFFERING AUDIO ";
        end else if (file_eof && fifo_empty_sync2 &&
                     (LYRIC_PREVIEW_MODE == 0)) begin
            lcd_line1 = "WE DON'T TALK...";
            lcd_line2 = "PLAYBACK FINISH ";
        end else begin
            if (LYRIC_PREVIEW_MODE != 0)
                lcd_line1 = "LYRIC PREVIEW   ";
            else
                lcd_line1 = "WE DON'T TALK...";
            lcd_line2 = lyric_line2;
        end
    end

    sdall_lcd1602_driver #(.CLK_HZ(100_000_000)) u_lcd (
        .clk(sys_clk),
        .rst_n(por_n),
        .line1(lcd_line1),
        .line2(lcd_line2),
        .lcd_d(LCD_D),
        .lcd_rs(LCD_RS),
        .lcd_rw(LCD_RW),
        .lcd_e(LCD_E)
    );

    // QSPI Flash and UART remain electrically inactive in the SD build.
    assign FLASH_CS_N   = 1'b1;
    assign FLASH_SCLK   = 1'b0;
    assign FLASH_MOSI   = 1'b1;
    assign FLASH_HOLD_N = 1'b1;
    assign UART_TXD     = 1'b1;

    // LED0: SD and codec ready. LED1: samples are actively reaching I2S.
    assign LED0 = sd_init_ok && codec_init_ok;
    assign LED1 = playback_sync2 && !pcm_fifo_empty;

    // Retained top-level inputs are intentionally unused in this build.
    wire unused_inputs = UART_RXD ^ FLASH_MISO ^ SD_CD_N ^ sd_card_sdhc ^
                         sd_read_busy ^ file_streaming ^ song_found ^
                         song_file_size[0] ^ song_bytes_sent[0] ^
                         adc_left[0] ^ adc_right[0] ^ adc_valid ^ playback_ms[0];
endmodule


// SDHC/SDSC SPI block device.
// Initializes the card at 400 kHz, then accepts single-sector CMD17 requests
// at 12.5 MHz and returns exactly 512 byte-valid pulses per successful read.
module sdall_sd_spi_block_reader #(
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

    sdall_sd_spi_byte_master #(
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


// SPI mode-0 byte master with the two clock rates required by SD cards:
// <=400 kHz during card initialization and 12.5 MHz for sector streaming.
module sdall_sd_spi_byte_master #(
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


// Minimal read-only FAT32 file streamer for one root-directory 8.3 file:
//
//                         SONG.RAW
//
// Supported layouts:
//   * FAT32 volume beginning directly at LBA 0
//   * MBR-partitioned card with the FAT32 volume in partition entry 0
//   * Fragmented files and multi-cluster root directories (FAT chain followed)
//
// SONG.RAW must contain headerless, little-endian, interleaved stereo PCM:
// left-low, left-high, right-low, right-high, repeated for every sample.
module sdall_fat32_song_raw_reader (
    input  wire        clk,
    input  wire        rst_n,

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
    output reg  [7:0]  error_code
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
        FS_ERROR         = 8'd15;

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
    // fat_for_file=1 follows the SONG.RAW cluster chain.
    reg        fat_for_file;
    reg [8:0]  fat_entry_offset;
    reg [7:0]  fat_byte0;
    reg [7:0]  fat_byte1;
    reg [7:0]  fat_byte2;
    reg [7:0]  fat_byte3;
    wire [31:0] next_cluster =
        ({fat_byte3, fat_byte2, fat_byte1, fat_byte0} & 32'h0FFF_FFFF);

    reg [31:0] bytes_remaining;

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

    function [7:0] song_name_byte;
        input [4:0] position;
        begin
            case (position)
                5'd0:  song_name_byte = "S";
                5'd1:  song_name_byte = "O";
                5'd2:  song_name_byte = "N";
                5'd3:  song_name_byte = "G";
                5'd4:  song_name_byte = " ";
                5'd5:  song_name_byte = " ";
                5'd6:  song_name_byte = " ";
                5'd7:  song_name_byte = " ";
                5'd8:  song_name_byte = "R";
                5'd9:  song_name_byte = "A";
                default: song_name_byte = "W";
            endcase
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
        end else begin
            block_read_req <= 1'b0;
            out_valid      <= 1'b0;

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
                                        (block_data_byte == song_name_byte(0));
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
                                         song_name_byte(block_data_index[4:0]));
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
                                    cluster_sector  <= 8'd0;
                                    file_size       <= found_size;
                                    bytes_remaining <= found_size;
                                    bytes_sent      <= 32'd0;
                                    mount_done      <= 1'b1;
                                    file_found      <= 1'b1;
                                    playing         <= 1'b1;
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
                            out_valid       <= 1'b1;
                            out_byte        <= block_data_byte;
                            bytes_remaining <= bytes_remaining - 1'b1;
                            bytes_sent      <= bytes_sent + 1'b1;
                        end
                        if (block_read_done)
                            state <= FS_FILE_NEXT;
                    end

                    FS_FILE_NEXT: begin
                        if (bytes_remaining == 0) begin
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
module sdall_async_stereo_fifo_level #(
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
// Self-contained timed lyrics for We Don't Talk Anymore.
// The lyric bytes are initialized inside this source; no external .mem file
// is required.  A single synchronous ROM read port keeps BRAM inference safe.
// --------------------------------------------------------------------------
module sdall_lyrics_display #(
    parameter integer CLK_HZ          = 100_000_000,
    parameter integer PREVIEW_MODE    = 0,
    parameter integer PREVIEW_PAGE_MS = 2000
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         active,
    input  wire [31:0]  play_ms_gray_async,
    output reg  [127:0] line2
);
    localparam integer PAGE_COUNT = 177;
    localparam integer LAST_PAGE  = 176;
    localparam integer TEXT_BYTES = 2199;
    localparam integer PREVIEW_PAGE_CYCLES =
        (CLK_HZ / 1000) * PREVIEW_PAGE_MS;

    (* rom_style = "block" *) reg [7:0] text_rom [0:TEXT_BYTES-1];
    initial begin
        text_rom[0] = 8'h57; text_rom[1] = 8'h65; text_rom[2] = 8'h20; text_rom[3] = 8'h64; text_rom[4] = 8'h6F; text_rom[5] = 8'h6E; text_rom[6] = 8'h27; text_rom[7] = 8'h74;
        text_rom[8] = 8'h20; text_rom[9] = 8'h74; text_rom[10] = 8'h61; text_rom[11] = 8'h6C; text_rom[12] = 8'h6B; text_rom[13] = 8'h20; text_rom[14] = 8'h61; text_rom[15] = 8'h6E;
        text_rom[16] = 8'h79; text_rom[17] = 8'h6D; text_rom[18] = 8'h6F; text_rom[19] = 8'h72; text_rom[20] = 8'h65; text_rom[21] = 8'h2C; text_rom[22] = 8'h20; text_rom[23] = 8'h77;
        text_rom[24] = 8'h65; text_rom[25] = 8'h20; text_rom[26] = 8'h64; text_rom[27] = 8'h6F; text_rom[28] = 8'h6E; text_rom[29] = 8'h27; text_rom[30] = 8'h74; text_rom[31] = 8'h20;
        text_rom[32] = 8'h74; text_rom[33] = 8'h61; text_rom[34] = 8'h6C; text_rom[35] = 8'h6B; text_rom[36] = 8'h20; text_rom[37] = 8'h61; text_rom[38] = 8'h6E; text_rom[39] = 8'h79;
        text_rom[40] = 8'h6D; text_rom[41] = 8'h6F; text_rom[42] = 8'h72; text_rom[43] = 8'h65; text_rom[44] = 8'h57; text_rom[45] = 8'h65; text_rom[46] = 8'h20; text_rom[47] = 8'h64;
        text_rom[48] = 8'h6F; text_rom[49] = 8'h6E; text_rom[50] = 8'h27; text_rom[51] = 8'h74; text_rom[52] = 8'h20; text_rom[53] = 8'h74; text_rom[54] = 8'h61; text_rom[55] = 8'h6C;
        text_rom[56] = 8'h6B; text_rom[57] = 8'h20; text_rom[58] = 8'h61; text_rom[59] = 8'h6E; text_rom[60] = 8'h79; text_rom[61] = 8'h6D; text_rom[62] = 8'h6F; text_rom[63] = 8'h72;
        text_rom[64] = 8'h65; text_rom[65] = 8'h2C; text_rom[66] = 8'h20; text_rom[67] = 8'h6C; text_rom[68] = 8'h69; text_rom[69] = 8'h6B; text_rom[70] = 8'h65; text_rom[71] = 8'h20;
        text_rom[72] = 8'h77; text_rom[73] = 8'h65; text_rom[74] = 8'h20; text_rom[75] = 8'h75; text_rom[76] = 8'h73; text_rom[77] = 8'h65; text_rom[78] = 8'h64; text_rom[79] = 8'h20;
        text_rom[80] = 8'h74; text_rom[81] = 8'h6F; text_rom[82] = 8'h20; text_rom[83] = 8'h64; text_rom[84] = 8'h6F; text_rom[85] = 8'h57; text_rom[86] = 8'h65; text_rom[87] = 8'h20;
        text_rom[88] = 8'h64; text_rom[89] = 8'h6F; text_rom[90] = 8'h6E; text_rom[91] = 8'h27; text_rom[92] = 8'h74; text_rom[93] = 8'h20; text_rom[94] = 8'h6C; text_rom[95] = 8'h6F;
        text_rom[96] = 8'h76; text_rom[97] = 8'h65; text_rom[98] = 8'h20; text_rom[99] = 8'h61; text_rom[100] = 8'h6E; text_rom[101] = 8'h79; text_rom[102] = 8'h6D; text_rom[103] = 8'h6F;
        text_rom[104] = 8'h72; text_rom[105] = 8'h65; text_rom[106] = 8'h57; text_rom[107] = 8'h68; text_rom[108] = 8'h61; text_rom[109] = 8'h74; text_rom[110] = 8'h20; text_rom[111] = 8'h77;
        text_rom[112] = 8'h61; text_rom[113] = 8'h73; text_rom[114] = 8'h20; text_rom[115] = 8'h61; text_rom[116] = 8'h6C; text_rom[117] = 8'h6C; text_rom[118] = 8'h20; text_rom[119] = 8'h6F;
        text_rom[120] = 8'h66; text_rom[121] = 8'h20; text_rom[122] = 8'h69; text_rom[123] = 8'h74; text_rom[124] = 8'h20; text_rom[125] = 8'h66; text_rom[126] = 8'h6F; text_rom[127] = 8'h72;
        text_rom[128] = 8'h3F; text_rom[129] = 8'h4F; text_rom[130] = 8'h68; text_rom[131] = 8'h2C; text_rom[132] = 8'h20; text_rom[133] = 8'h77; text_rom[134] = 8'h65; text_rom[135] = 8'h20;
        text_rom[136] = 8'h64; text_rom[137] = 8'h6F; text_rom[138] = 8'h6E; text_rom[139] = 8'h27; text_rom[140] = 8'h74; text_rom[141] = 8'h20; text_rom[142] = 8'h74; text_rom[143] = 8'h61;
        text_rom[144] = 8'h6C; text_rom[145] = 8'h6B; text_rom[146] = 8'h20; text_rom[147] = 8'h61; text_rom[148] = 8'h6E; text_rom[149] = 8'h79; text_rom[150] = 8'h6D; text_rom[151] = 8'h6F;
        text_rom[152] = 8'h72; text_rom[153] = 8'h65; text_rom[154] = 8'h2C; text_rom[155] = 8'h20; text_rom[156] = 8'h6C; text_rom[157] = 8'h69; text_rom[158] = 8'h6B; text_rom[159] = 8'h65;
        text_rom[160] = 8'h20; text_rom[161] = 8'h77; text_rom[162] = 8'h65; text_rom[163] = 8'h20; text_rom[164] = 8'h75; text_rom[165] = 8'h73; text_rom[166] = 8'h65; text_rom[167] = 8'h64;
        text_rom[168] = 8'h20; text_rom[169] = 8'h74; text_rom[170] = 8'h6F; text_rom[171] = 8'h20; text_rom[172] = 8'h64; text_rom[173] = 8'h6F; text_rom[174] = 8'h49; text_rom[175] = 8'h20;
        text_rom[176] = 8'h6A; text_rom[177] = 8'h75; text_rom[178] = 8'h73; text_rom[179] = 8'h74; text_rom[180] = 8'h20; text_rom[181] = 8'h68; text_rom[182] = 8'h65; text_rom[183] = 8'h61;
        text_rom[184] = 8'h72; text_rom[185] = 8'h64; text_rom[186] = 8'h20; text_rom[187] = 8'h79; text_rom[188] = 8'h6F; text_rom[189] = 8'h75; text_rom[190] = 8'h20; text_rom[191] = 8'h66;
        text_rom[192] = 8'h6F; text_rom[193] = 8'h75; text_rom[194] = 8'h6E; text_rom[195] = 8'h64; text_rom[196] = 8'h20; text_rom[197] = 8'h74; text_rom[198] = 8'h68; text_rom[199] = 8'h65;
        text_rom[200] = 8'h20; text_rom[201] = 8'h6F; text_rom[202] = 8'h6E; text_rom[203] = 8'h65; text_rom[204] = 8'h20; text_rom[205] = 8'h79; text_rom[206] = 8'h6F; text_rom[207] = 8'h75;
        text_rom[208] = 8'h27; text_rom[209] = 8'h76; text_rom[210] = 8'h65; text_rom[211] = 8'h20; text_rom[212] = 8'h62; text_rom[213] = 8'h65; text_rom[214] = 8'h65; text_rom[215] = 8'h6E;
        text_rom[216] = 8'h20; text_rom[217] = 8'h6C; text_rom[218] = 8'h6F; text_rom[219] = 8'h6F; text_rom[220] = 8'h6B; text_rom[221] = 8'h69; text_rom[222] = 8'h6E; text_rom[223] = 8'h67;
        text_rom[224] = 8'h59; text_rom[225] = 8'h6F; text_rom[226] = 8'h75; text_rom[227] = 8'h27; text_rom[228] = 8'h76; text_rom[229] = 8'h65; text_rom[230] = 8'h20; text_rom[231] = 8'h62;
        text_rom[232] = 8'h65; text_rom[233] = 8'h65; text_rom[234] = 8'h6E; text_rom[235] = 8'h20; text_rom[236] = 8'h6C; text_rom[237] = 8'h6F; text_rom[238] = 8'h6F; text_rom[239] = 8'h6B;
        text_rom[240] = 8'h69; text_rom[241] = 8'h6E; text_rom[242] = 8'h67; text_rom[243] = 8'h20; text_rom[244] = 8'h66; text_rom[245] = 8'h6F; text_rom[246] = 8'h72; text_rom[247] = 8'h49;
        text_rom[248] = 8'h20; text_rom[249] = 8'h77; text_rom[250] = 8'h69; text_rom[251] = 8'h73; text_rom[252] = 8'h68; text_rom[253] = 8'h20; text_rom[254] = 8'h49; text_rom[255] = 8'h20;
        text_rom[256] = 8'h77; text_rom[257] = 8'h6F; text_rom[258] = 8'h75; text_rom[259] = 8'h6C; text_rom[260] = 8'h64; text_rom[261] = 8'h20; text_rom[262] = 8'h68; text_rom[263] = 8'h61;
        text_rom[264] = 8'h76; text_rom[265] = 8'h65; text_rom[266] = 8'h20; text_rom[267] = 8'h6B; text_rom[268] = 8'h6E; text_rom[269] = 8'h6F; text_rom[270] = 8'h77; text_rom[271] = 8'h6E;
        text_rom[272] = 8'h20; text_rom[273] = 8'h74; text_rom[274] = 8'h68; text_rom[275] = 8'h61; text_rom[276] = 8'h74; text_rom[277] = 8'h20; text_rom[278] = 8'h77; text_rom[279] = 8'h61;
        text_rom[280] = 8'h73; text_rom[281] = 8'h6E; text_rom[282] = 8'h27; text_rom[283] = 8'h74; text_rom[284] = 8'h20; text_rom[285] = 8'h6D; text_rom[286] = 8'h65; text_rom[287] = 8'h43;
        text_rom[288] = 8'h61; text_rom[289] = 8'h75; text_rom[290] = 8'h73; text_rom[291] = 8'h65; text_rom[292] = 8'h20; text_rom[293] = 8'h65; text_rom[294] = 8'h76; text_rom[295] = 8'h65;
        text_rom[296] = 8'h6E; text_rom[297] = 8'h20; text_rom[298] = 8'h61; text_rom[299] = 8'h66; text_rom[300] = 8'h74; text_rom[301] = 8'h65; text_rom[302] = 8'h72; text_rom[303] = 8'h20;
        text_rom[304] = 8'h61; text_rom[305] = 8'h6C; text_rom[306] = 8'h6C; text_rom[307] = 8'h20; text_rom[308] = 8'h74; text_rom[309] = 8'h68; text_rom[310] = 8'h69; text_rom[311] = 8'h73;
        text_rom[312] = 8'h20; text_rom[313] = 8'h74; text_rom[314] = 8'h69; text_rom[315] = 8'h6D; text_rom[316] = 8'h65; text_rom[317] = 8'h20; text_rom[318] = 8'h49; text_rom[319] = 8'h20;
        text_rom[320] = 8'h73; text_rom[321] = 8'h74; text_rom[322] = 8'h69; text_rom[323] = 8'h6C; text_rom[324] = 8'h6C; text_rom[325] = 8'h20; text_rom[326] = 8'h77; text_rom[327] = 8'h6F;
        text_rom[328] = 8'h6E; text_rom[329] = 8'h64; text_rom[330] = 8'h65; text_rom[331] = 8'h72; text_rom[332] = 8'h57; text_rom[333] = 8'h68; text_rom[334] = 8'h79; text_rom[335] = 8'h20;
        text_rom[336] = 8'h49; text_rom[337] = 8'h20; text_rom[338] = 8'h63; text_rom[339] = 8'h61; text_rom[340] = 8'h6E; text_rom[341] = 8'h27; text_rom[342] = 8'h74; text_rom[343] = 8'h20;
        text_rom[344] = 8'h6D; text_rom[345] = 8'h6F; text_rom[346] = 8'h76; text_rom[347] = 8'h65; text_rom[348] = 8'h20; text_rom[349] = 8'h6F; text_rom[350] = 8'h6E; text_rom[351] = 8'h4A;
        text_rom[352] = 8'h75; text_rom[353] = 8'h73; text_rom[354] = 8'h74; text_rom[355] = 8'h20; text_rom[356] = 8'h74; text_rom[357] = 8'h68; text_rom[358] = 8'h65; text_rom[359] = 8'h20;
        text_rom[360] = 8'h77; text_rom[361] = 8'h61; text_rom[362] = 8'h79; text_rom[363] = 8'h20; text_rom[364] = 8'h79; text_rom[365] = 8'h6F; text_rom[366] = 8'h75; text_rom[367] = 8'h20;
        text_rom[368] = 8'h64; text_rom[369] = 8'h69; text_rom[370] = 8'h64; text_rom[371] = 8'h20; text_rom[372] = 8'h73; text_rom[373] = 8'h6F; text_rom[374] = 8'h20; text_rom[375] = 8'h65;
        text_rom[376] = 8'h61; text_rom[377] = 8'h73; text_rom[378] = 8'h69; text_rom[379] = 8'h6C; text_rom[380] = 8'h79; text_rom[381] = 8'h44; text_rom[382] = 8'h6F; text_rom[383] = 8'h6E;
        text_rom[384] = 8'h27; text_rom[385] = 8'h74; text_rom[386] = 8'h20; text_rom[387] = 8'h77; text_rom[388] = 8'h61; text_rom[389] = 8'h6E; text_rom[390] = 8'h6E; text_rom[391] = 8'h61;
        text_rom[392] = 8'h20; text_rom[393] = 8'h6B; text_rom[394] = 8'h6E; text_rom[395] = 8'h6F; text_rom[396] = 8'h77; text_rom[397] = 8'h77; text_rom[398] = 8'h68; text_rom[399] = 8'h61;
        text_rom[400] = 8'h74; text_rom[401] = 8'h20; text_rom[402] = 8'h6B; text_rom[403] = 8'h69; text_rom[404] = 8'h6E; text_rom[405] = 8'h64; text_rom[406] = 8'h20; text_rom[407] = 8'h6F;
        text_rom[408] = 8'h66; text_rom[409] = 8'h20; text_rom[410] = 8'h64; text_rom[411] = 8'h72; text_rom[412] = 8'h65; text_rom[413] = 8'h73; text_rom[414] = 8'h73; text_rom[415] = 8'h20;
        text_rom[416] = 8'h79; text_rom[417] = 8'h6F; text_rom[418] = 8'h75; text_rom[419] = 8'h27; text_rom[420] = 8'h72; text_rom[421] = 8'h65; text_rom[422] = 8'h20; text_rom[423] = 8'h77;
        text_rom[424] = 8'h65; text_rom[425] = 8'h61; text_rom[426] = 8'h72; text_rom[427] = 8'h69; text_rom[428] = 8'h6E; text_rom[429] = 8'h67; text_rom[430] = 8'h20; text_rom[431] = 8'h74;
        text_rom[432] = 8'h6F; text_rom[433] = 8'h6E; text_rom[434] = 8'h69; text_rom[435] = 8'h67; text_rom[436] = 8'h68; text_rom[437] = 8'h74; text_rom[438] = 8'h49; text_rom[439] = 8'h66;
        text_rom[440] = 8'h20; text_rom[441] = 8'h68; text_rom[442] = 8'h65; text_rom[443] = 8'h27; text_rom[444] = 8'h73; text_rom[445] = 8'h20; text_rom[446] = 8'h68; text_rom[447] = 8'h6F;
        text_rom[448] = 8'h6C; text_rom[449] = 8'h64; text_rom[450] = 8'h69; text_rom[451] = 8'h6E; text_rom[452] = 8'h67; text_rom[453] = 8'h20; text_rom[454] = 8'h6F; text_rom[455] = 8'h6E;
        text_rom[456] = 8'h74; text_rom[457] = 8'h6F; text_rom[458] = 8'h20; text_rom[459] = 8'h79; text_rom[460] = 8'h6F; text_rom[461] = 8'h75; text_rom[462] = 8'h20; text_rom[463] = 8'h73;
        text_rom[464] = 8'h6F; text_rom[465] = 8'h20; text_rom[466] = 8'h74; text_rom[467] = 8'h69; text_rom[468] = 8'h67; text_rom[469] = 8'h68; text_rom[470] = 8'h74; text_rom[471] = 8'h54;
        text_rom[472] = 8'h68; text_rom[473] = 8'h65; text_rom[474] = 8'h20; text_rom[475] = 8'h77; text_rom[476] = 8'h61; text_rom[477] = 8'h79; text_rom[478] = 8'h20; text_rom[479] = 8'h49;
        text_rom[480] = 8'h20; text_rom[481] = 8'h64; text_rom[482] = 8'h69; text_rom[483] = 8'h64; text_rom[484] = 8'h20; text_rom[485] = 8'h62; text_rom[486] = 8'h65; text_rom[487] = 8'h66;
        text_rom[488] = 8'h6F; text_rom[489] = 8'h72; text_rom[490] = 8'h65; text_rom[491] = 8'h49; text_rom[492] = 8'h20; text_rom[493] = 8'h6F; text_rom[494] = 8'h76; text_rom[495] = 8'h65;
        text_rom[496] = 8'h72; text_rom[497] = 8'h64; text_rom[498] = 8'h6F; text_rom[499] = 8'h73; text_rom[500] = 8'h65; text_rom[501] = 8'h64; text_rom[502] = 8'h53; text_rom[503] = 8'h68;
        text_rom[504] = 8'h6F; text_rom[505] = 8'h75; text_rom[506] = 8'h6C; text_rom[507] = 8'h64; text_rom[508] = 8'h27; text_rom[509] = 8'h76; text_rom[510] = 8'h65; text_rom[511] = 8'h20;
        text_rom[512] = 8'h6B; text_rom[513] = 8'h6E; text_rom[514] = 8'h6F; text_rom[515] = 8'h77; text_rom[516] = 8'h6E; text_rom[517] = 8'h20; text_rom[518] = 8'h79; text_rom[519] = 8'h6F;
        text_rom[520] = 8'h75; text_rom[521] = 8'h72; text_rom[522] = 8'h20; text_rom[523] = 8'h6C; text_rom[524] = 8'h6F; text_rom[525] = 8'h76; text_rom[526] = 8'h65; text_rom[527] = 8'h20;
        text_rom[528] = 8'h77; text_rom[529] = 8'h61; text_rom[530] = 8'h73; text_rom[531] = 8'h20; text_rom[532] = 8'h61; text_rom[533] = 8'h20; text_rom[534] = 8'h67; text_rom[535] = 8'h61;
        text_rom[536] = 8'h6D; text_rom[537] = 8'h65; text_rom[538] = 8'h4E; text_rom[539] = 8'h6F; text_rom[540] = 8'h77; text_rom[541] = 8'h20; text_rom[542] = 8'h49; text_rom[543] = 8'h20;
        text_rom[544] = 8'h63; text_rom[545] = 8'h61; text_rom[546] = 8'h6E; text_rom[547] = 8'h27; text_rom[548] = 8'h74; text_rom[549] = 8'h20; text_rom[550] = 8'h67; text_rom[551] = 8'h65;
        text_rom[552] = 8'h74; text_rom[553] = 8'h20; text_rom[554] = 8'h79; text_rom[555] = 8'h6F; text_rom[556] = 8'h75; text_rom[557] = 8'h20; text_rom[558] = 8'h6F; text_rom[559] = 8'h75;
        text_rom[560] = 8'h74; text_rom[561] = 8'h20; text_rom[562] = 8'h6F; text_rom[563] = 8'h66; text_rom[564] = 8'h20; text_rom[565] = 8'h6D; text_rom[566] = 8'h79; text_rom[567] = 8'h20;
        text_rom[568] = 8'h62; text_rom[569] = 8'h72; text_rom[570] = 8'h61; text_rom[571] = 8'h69; text_rom[572] = 8'h6E; text_rom[573] = 8'h4F; text_rom[574] = 8'h68; text_rom[575] = 8'h2C;
        text_rom[576] = 8'h20; text_rom[577] = 8'h69; text_rom[578] = 8'h74; text_rom[579] = 8'h27; text_rom[580] = 8'h73; text_rom[581] = 8'h20; text_rom[582] = 8'h73; text_rom[583] = 8'h75;
        text_rom[584] = 8'h63; text_rom[585] = 8'h68; text_rom[586] = 8'h20; text_rom[587] = 8'h61; text_rom[588] = 8'h20; text_rom[589] = 8'h73; text_rom[590] = 8'h68; text_rom[591] = 8'h61;
        text_rom[592] = 8'h6D; text_rom[593] = 8'h65; text_rom[594] = 8'h57; text_rom[595] = 8'h65; text_rom[596] = 8'h20; text_rom[597] = 8'h64; text_rom[598] = 8'h6F; text_rom[599] = 8'h6E;
        text_rom[600] = 8'h27; text_rom[601] = 8'h74; text_rom[602] = 8'h20; text_rom[603] = 8'h74; text_rom[604] = 8'h61; text_rom[605] = 8'h6C; text_rom[606] = 8'h6B; text_rom[607] = 8'h20;
        text_rom[608] = 8'h61; text_rom[609] = 8'h6E; text_rom[610] = 8'h79; text_rom[611] = 8'h6D; text_rom[612] = 8'h6F; text_rom[613] = 8'h72; text_rom[614] = 8'h65; text_rom[615] = 8'h2C;
        text_rom[616] = 8'h20; text_rom[617] = 8'h77; text_rom[618] = 8'h65; text_rom[619] = 8'h20; text_rom[620] = 8'h64; text_rom[621] = 8'h6F; text_rom[622] = 8'h6E; text_rom[623] = 8'h27;
        text_rom[624] = 8'h74; text_rom[625] = 8'h20; text_rom[626] = 8'h74; text_rom[627] = 8'h61; text_rom[628] = 8'h6C; text_rom[629] = 8'h6B; text_rom[630] = 8'h20; text_rom[631] = 8'h61;
        text_rom[632] = 8'h6E; text_rom[633] = 8'h79; text_rom[634] = 8'h6D; text_rom[635] = 8'h6F; text_rom[636] = 8'h72; text_rom[637] = 8'h65; text_rom[638] = 8'h57; text_rom[639] = 8'h65;
        text_rom[640] = 8'h20; text_rom[641] = 8'h64; text_rom[642] = 8'h6F; text_rom[643] = 8'h6E; text_rom[644] = 8'h27; text_rom[645] = 8'h74; text_rom[646] = 8'h20; text_rom[647] = 8'h74;
        text_rom[648] = 8'h61; text_rom[649] = 8'h6C; text_rom[650] = 8'h6B; text_rom[651] = 8'h20; text_rom[652] = 8'h61; text_rom[653] = 8'h6E; text_rom[654] = 8'h79; text_rom[655] = 8'h6D;
        text_rom[656] = 8'h6F; text_rom[657] = 8'h72; text_rom[658] = 8'h65; text_rom[659] = 8'h2C; text_rom[660] = 8'h20; text_rom[661] = 8'h6C; text_rom[662] = 8'h69; text_rom[663] = 8'h6B;
        text_rom[664] = 8'h65; text_rom[665] = 8'h20; text_rom[666] = 8'h77; text_rom[667] = 8'h65; text_rom[668] = 8'h20; text_rom[669] = 8'h75; text_rom[670] = 8'h73; text_rom[671] = 8'h65;
        text_rom[672] = 8'h64; text_rom[673] = 8'h20; text_rom[674] = 8'h74; text_rom[675] = 8'h6F; text_rom[676] = 8'h20; text_rom[677] = 8'h64; text_rom[678] = 8'h6F; text_rom[679] = 8'h57;
        text_rom[680] = 8'h65; text_rom[681] = 8'h20; text_rom[682] = 8'h64; text_rom[683] = 8'h6F; text_rom[684] = 8'h6E; text_rom[685] = 8'h27; text_rom[686] = 8'h74; text_rom[687] = 8'h20;
        text_rom[688] = 8'h6C; text_rom[689] = 8'h6F; text_rom[690] = 8'h76; text_rom[691] = 8'h65; text_rom[692] = 8'h20; text_rom[693] = 8'h61; text_rom[694] = 8'h6E; text_rom[695] = 8'h79;
        text_rom[696] = 8'h6D; text_rom[697] = 8'h6F; text_rom[698] = 8'h72; text_rom[699] = 8'h65; text_rom[700] = 8'h57; text_rom[701] = 8'h68; text_rom[702] = 8'h61; text_rom[703] = 8'h74;
        text_rom[704] = 8'h20; text_rom[705] = 8'h77; text_rom[706] = 8'h61; text_rom[707] = 8'h73; text_rom[708] = 8'h20; text_rom[709] = 8'h61; text_rom[710] = 8'h6C; text_rom[711] = 8'h6C;
        text_rom[712] = 8'h20; text_rom[713] = 8'h6F; text_rom[714] = 8'h66; text_rom[715] = 8'h20; text_rom[716] = 8'h69; text_rom[717] = 8'h74; text_rom[718] = 8'h20; text_rom[719] = 8'h66;
        text_rom[720] = 8'h6F; text_rom[721] = 8'h72; text_rom[722] = 8'h3F; text_rom[723] = 8'h4F; text_rom[724] = 8'h68; text_rom[725] = 8'h2C; text_rom[726] = 8'h20; text_rom[727] = 8'h77;
        text_rom[728] = 8'h65; text_rom[729] = 8'h20; text_rom[730] = 8'h64; text_rom[731] = 8'h6F; text_rom[732] = 8'h6E; text_rom[733] = 8'h27; text_rom[734] = 8'h74; text_rom[735] = 8'h20;
        text_rom[736] = 8'h74; text_rom[737] = 8'h61; text_rom[738] = 8'h6C; text_rom[739] = 8'h6B; text_rom[740] = 8'h20; text_rom[741] = 8'h61; text_rom[742] = 8'h6E; text_rom[743] = 8'h79;
        text_rom[744] = 8'h6D; text_rom[745] = 8'h6F; text_rom[746] = 8'h72; text_rom[747] = 8'h65; text_rom[748] = 8'h2C; text_rom[749] = 8'h20; text_rom[750] = 8'h6C; text_rom[751] = 8'h69;
        text_rom[752] = 8'h6B; text_rom[753] = 8'h65; text_rom[754] = 8'h20; text_rom[755] = 8'h77; text_rom[756] = 8'h65; text_rom[757] = 8'h20; text_rom[758] = 8'h75; text_rom[759] = 8'h73;
        text_rom[760] = 8'h65; text_rom[761] = 8'h64; text_rom[762] = 8'h20; text_rom[763] = 8'h74; text_rom[764] = 8'h6F; text_rom[765] = 8'h20; text_rom[766] = 8'h64; text_rom[767] = 8'h6F;
        text_rom[768] = 8'h57; text_rom[769] = 8'h68; text_rom[770] = 8'h6F; text_rom[771] = 8'h20; text_rom[772] = 8'h6B; text_rom[773] = 8'h6E; text_rom[774] = 8'h6F; text_rom[775] = 8'h77;
        text_rom[776] = 8'h73; text_rom[777] = 8'h20; text_rom[778] = 8'h68; text_rom[779] = 8'h6F; text_rom[780] = 8'h77; text_rom[781] = 8'h20; text_rom[782] = 8'h74; text_rom[783] = 8'h6F;
        text_rom[784] = 8'h20; text_rom[785] = 8'h6C; text_rom[786] = 8'h6F; text_rom[787] = 8'h76; text_rom[788] = 8'h65; text_rom[789] = 8'h20; text_rom[790] = 8'h79; text_rom[791] = 8'h6F;
        text_rom[792] = 8'h75; text_rom[793] = 8'h20; text_rom[794] = 8'h6C; text_rom[795] = 8'h69; text_rom[796] = 8'h6B; text_rom[797] = 8'h65; text_rom[798] = 8'h20; text_rom[799] = 8'h6D;
        text_rom[800] = 8'h65; text_rom[801] = 8'h54; text_rom[802] = 8'h68; text_rom[803] = 8'h65; text_rom[804] = 8'h72; text_rom[805] = 8'h65; text_rom[806] = 8'h20; text_rom[807] = 8'h6D;
        text_rom[808] = 8'h75; text_rom[809] = 8'h73; text_rom[810] = 8'h74; text_rom[811] = 8'h20; text_rom[812] = 8'h62; text_rom[813] = 8'h65; text_rom[814] = 8'h20; text_rom[815] = 8'h61;
        text_rom[816] = 8'h20; text_rom[817] = 8'h67; text_rom[818] = 8'h6F; text_rom[819] = 8'h6F; text_rom[820] = 8'h64; text_rom[821] = 8'h20; text_rom[822] = 8'h72; text_rom[823] = 8'h65;
        text_rom[824] = 8'h61; text_rom[825] = 8'h73; text_rom[826] = 8'h6F; text_rom[827] = 8'h6E; text_rom[828] = 8'h20; text_rom[829] = 8'h74; text_rom[830] = 8'h68; text_rom[831] = 8'h61;
        text_rom[832] = 8'h74; text_rom[833] = 8'h20; text_rom[834] = 8'h79; text_rom[835] = 8'h6F; text_rom[836] = 8'h75; text_rom[837] = 8'h27; text_rom[838] = 8'h72; text_rom[839] = 8'h65;
        text_rom[840] = 8'h20; text_rom[841] = 8'h67; text_rom[842] = 8'h6F; text_rom[843] = 8'h6E; text_rom[844] = 8'h65; text_rom[845] = 8'h45; text_rom[846] = 8'h76; text_rom[847] = 8'h65;
        text_rom[848] = 8'h72; text_rom[849] = 8'h79; text_rom[850] = 8'h20; text_rom[851] = 8'h6E; text_rom[852] = 8'h6F; text_rom[853] = 8'h77; text_rom[854] = 8'h20; text_rom[855] = 8'h61;
        text_rom[856] = 8'h6E; text_rom[857] = 8'h64; text_rom[858] = 8'h20; text_rom[859] = 8'h74; text_rom[860] = 8'h68; text_rom[861] = 8'h65; text_rom[862] = 8'h6E; text_rom[863] = 8'h20;
        text_rom[864] = 8'h49; text_rom[865] = 8'h20; text_rom[866] = 8'h74; text_rom[867] = 8'h68; text_rom[868] = 8'h69; text_rom[869] = 8'h6E; text_rom[870] = 8'h6B; text_rom[871] = 8'h20;
        text_rom[872] = 8'h79; text_rom[873] = 8'h6F; text_rom[874] = 8'h75; text_rom[875] = 8'h4D; text_rom[876] = 8'h69; text_rom[877] = 8'h67; text_rom[878] = 8'h68; text_rom[879] = 8'h74;
        text_rom[880] = 8'h20; text_rom[881] = 8'h77; text_rom[882] = 8'h61; text_rom[883] = 8'h6E; text_rom[884] = 8'h74; text_rom[885] = 8'h20; text_rom[886] = 8'h6D; text_rom[887] = 8'h65;
        text_rom[888] = 8'h20; text_rom[889] = 8'h74; text_rom[890] = 8'h6F; text_rom[891] = 8'h20; text_rom[892] = 8'h63; text_rom[893] = 8'h6F; text_rom[894] = 8'h6D; text_rom[895] = 8'h65;
        text_rom[896] = 8'h20; text_rom[897] = 8'h73; text_rom[898] = 8'h68; text_rom[899] = 8'h6F; text_rom[900] = 8'h77; text_rom[901] = 8'h20; text_rom[902] = 8'h75; text_rom[903] = 8'h70;
        text_rom[904] = 8'h20; text_rom[905] = 8'h61; text_rom[906] = 8'h74; text_rom[907] = 8'h20; text_rom[908] = 8'h79; text_rom[909] = 8'h6F; text_rom[910] = 8'h75; text_rom[911] = 8'h72;
        text_rom[912] = 8'h20; text_rom[913] = 8'h64; text_rom[914] = 8'h6F; text_rom[915] = 8'h6F; text_rom[916] = 8'h72; text_rom[917] = 8'h42; text_rom[918] = 8'h75; text_rom[919] = 8'h74;
        text_rom[920] = 8'h20; text_rom[921] = 8'h49; text_rom[922] = 8'h27; text_rom[923] = 8'h6D; text_rom[924] = 8'h20; text_rom[925] = 8'h6A; text_rom[926] = 8'h75; text_rom[927] = 8'h73;
        text_rom[928] = 8'h74; text_rom[929] = 8'h20; text_rom[930] = 8'h74; text_rom[931] = 8'h6F; text_rom[932] = 8'h6F; text_rom[933] = 8'h20; text_rom[934] = 8'h61; text_rom[935] = 8'h66;
        text_rom[936] = 8'h72; text_rom[937] = 8'h61; text_rom[938] = 8'h69; text_rom[939] = 8'h64; text_rom[940] = 8'h20; text_rom[941] = 8'h74; text_rom[942] = 8'h68; text_rom[943] = 8'h61;
        text_rom[944] = 8'h74; text_rom[945] = 8'h20; text_rom[946] = 8'h49; text_rom[947] = 8'h27; text_rom[948] = 8'h6C; text_rom[949] = 8'h6C; text_rom[950] = 8'h20; text_rom[951] = 8'h62;
        text_rom[952] = 8'h65; text_rom[953] = 8'h20; text_rom[954] = 8'h77; text_rom[955] = 8'h72; text_rom[956] = 8'h6F; text_rom[957] = 8'h6E; text_rom[958] = 8'h67; text_rom[959] = 8'h44;
        text_rom[960] = 8'h6F; text_rom[961] = 8'h6E; text_rom[962] = 8'h27; text_rom[963] = 8'h74; text_rom[964] = 8'h20; text_rom[965] = 8'h77; text_rom[966] = 8'h61; text_rom[967] = 8'h6E;
        text_rom[968] = 8'h6E; text_rom[969] = 8'h61; text_rom[970] = 8'h20; text_rom[971] = 8'h6B; text_rom[972] = 8'h6E; text_rom[973] = 8'h6F; text_rom[974] = 8'h77; text_rom[975] = 8'h49;
        text_rom[976] = 8'h66; text_rom[977] = 8'h20; text_rom[978] = 8'h79; text_rom[979] = 8'h6F; text_rom[980] = 8'h75; text_rom[981] = 8'h27; text_rom[982] = 8'h72; text_rom[983] = 8'h65;
        text_rom[984] = 8'h20; text_rom[985] = 8'h6C; text_rom[986] = 8'h6F; text_rom[987] = 8'h6F; text_rom[988] = 8'h6B; text_rom[989] = 8'h69; text_rom[990] = 8'h6E; text_rom[991] = 8'h67;
        text_rom[992] = 8'h20; text_rom[993] = 8'h69; text_rom[994] = 8'h6E; text_rom[995] = 8'h74; text_rom[996] = 8'h6F; text_rom[997] = 8'h20; text_rom[998] = 8'h68; text_rom[999] = 8'h65;
        text_rom[1000] = 8'h72; text_rom[1001] = 8'h20; text_rom[1002] = 8'h65; text_rom[1003] = 8'h79; text_rom[1004] = 8'h65; text_rom[1005] = 8'h73; text_rom[1006] = 8'h49; text_rom[1007] = 8'h66;
        text_rom[1008] = 8'h20; text_rom[1009] = 8'h73; text_rom[1010] = 8'h68; text_rom[1011] = 8'h65; text_rom[1012] = 8'h27; text_rom[1013] = 8'h73; text_rom[1014] = 8'h20; text_rom[1015] = 8'h68;
        text_rom[1016] = 8'h6F; text_rom[1017] = 8'h6C; text_rom[1018] = 8'h64; text_rom[1019] = 8'h69; text_rom[1020] = 8'h6E; text_rom[1021] = 8'h67; text_rom[1022] = 8'h20; text_rom[1023] = 8'h6F;
        text_rom[1024] = 8'h6E; text_rom[1025] = 8'h74; text_rom[1026] = 8'h6F; text_rom[1027] = 8'h20; text_rom[1028] = 8'h79; text_rom[1029] = 8'h6F; text_rom[1030] = 8'h75; text_rom[1031] = 8'h20;
        text_rom[1032] = 8'h73; text_rom[1033] = 8'h6F; text_rom[1034] = 8'h20; text_rom[1035] = 8'h74; text_rom[1036] = 8'h69; text_rom[1037] = 8'h67; text_rom[1038] = 8'h68; text_rom[1039] = 8'h74;
        text_rom[1040] = 8'h20; text_rom[1041] = 8'h74; text_rom[1042] = 8'h68; text_rom[1043] = 8'h65; text_rom[1044] = 8'h20; text_rom[1045] = 8'h77; text_rom[1046] = 8'h61; text_rom[1047] = 8'h79;
        text_rom[1048] = 8'h20; text_rom[1049] = 8'h49; text_rom[1050] = 8'h20; text_rom[1051] = 8'h64; text_rom[1052] = 8'h69; text_rom[1053] = 8'h64; text_rom[1054] = 8'h20; text_rom[1055] = 8'h62;
        text_rom[1056] = 8'h65; text_rom[1057] = 8'h66; text_rom[1058] = 8'h6F; text_rom[1059] = 8'h72; text_rom[1060] = 8'h65; text_rom[1061] = 8'h49; text_rom[1062] = 8'h20; text_rom[1063] = 8'h6F;
        text_rom[1064] = 8'h76; text_rom[1065] = 8'h65; text_rom[1066] = 8'h72; text_rom[1067] = 8'h64; text_rom[1068] = 8'h6F; text_rom[1069] = 8'h73; text_rom[1070] = 8'h65; text_rom[1071] = 8'h64;
        text_rom[1072] = 8'h53; text_rom[1073] = 8'h68; text_rom[1074] = 8'h6F; text_rom[1075] = 8'h75; text_rom[1076] = 8'h6C; text_rom[1077] = 8'h64; text_rom[1078] = 8'h27; text_rom[1079] = 8'h76;
        text_rom[1080] = 8'h65; text_rom[1081] = 8'h20; text_rom[1082] = 8'h6B; text_rom[1083] = 8'h6E; text_rom[1084] = 8'h6F; text_rom[1085] = 8'h77; text_rom[1086] = 8'h6E; text_rom[1087] = 8'h20;
        text_rom[1088] = 8'h79; text_rom[1089] = 8'h6F; text_rom[1090] = 8'h75; text_rom[1091] = 8'h72; text_rom[1092] = 8'h20; text_rom[1093] = 8'h6C; text_rom[1094] = 8'h6F; text_rom[1095] = 8'h76;
        text_rom[1096] = 8'h65; text_rom[1097] = 8'h20; text_rom[1098] = 8'h77; text_rom[1099] = 8'h61; text_rom[1100] = 8'h73; text_rom[1101] = 8'h20; text_rom[1102] = 8'h61; text_rom[1103] = 8'h20;
        text_rom[1104] = 8'h67; text_rom[1105] = 8'h61; text_rom[1106] = 8'h6D; text_rom[1107] = 8'h65; text_rom[1108] = 8'h4E; text_rom[1109] = 8'h6F; text_rom[1110] = 8'h77; text_rom[1111] = 8'h20;
        text_rom[1112] = 8'h49; text_rom[1113] = 8'h20; text_rom[1114] = 8'h63; text_rom[1115] = 8'h61; text_rom[1116] = 8'h6E; text_rom[1117] = 8'h27; text_rom[1118] = 8'h74; text_rom[1119] = 8'h20;
        text_rom[1120] = 8'h67; text_rom[1121] = 8'h65; text_rom[1122] = 8'h74; text_rom[1123] = 8'h20; text_rom[1124] = 8'h79; text_rom[1125] = 8'h6F; text_rom[1126] = 8'h75; text_rom[1127] = 8'h20;
        text_rom[1128] = 8'h6F; text_rom[1129] = 8'h75; text_rom[1130] = 8'h74; text_rom[1131] = 8'h20; text_rom[1132] = 8'h6F; text_rom[1133] = 8'h66; text_rom[1134] = 8'h20; text_rom[1135] = 8'h6D;
        text_rom[1136] = 8'h79; text_rom[1137] = 8'h20; text_rom[1138] = 8'h62; text_rom[1139] = 8'h72; text_rom[1140] = 8'h61; text_rom[1141] = 8'h69; text_rom[1142] = 8'h6E; text_rom[1143] = 8'h4F;
        text_rom[1144] = 8'h68; text_rom[1145] = 8'h2C; text_rom[1146] = 8'h20; text_rom[1147] = 8'h69; text_rom[1148] = 8'h74; text_rom[1149] = 8'h27; text_rom[1150] = 8'h73; text_rom[1151] = 8'h20;
        text_rom[1152] = 8'h73; text_rom[1153] = 8'h75; text_rom[1154] = 8'h63; text_rom[1155] = 8'h68; text_rom[1156] = 8'h20; text_rom[1157] = 8'h61; text_rom[1158] = 8'h20; text_rom[1159] = 8'h73;
        text_rom[1160] = 8'h68; text_rom[1161] = 8'h61; text_rom[1162] = 8'h6D; text_rom[1163] = 8'h65; text_rom[1164] = 8'h54; text_rom[1165] = 8'h68; text_rom[1166] = 8'h61; text_rom[1167] = 8'h74;
        text_rom[1168] = 8'h20; text_rom[1169] = 8'h77; text_rom[1170] = 8'h65; text_rom[1171] = 8'h20; text_rom[1172] = 8'h64; text_rom[1173] = 8'h6F; text_rom[1174] = 8'h6E; text_rom[1175] = 8'h27;
        text_rom[1176] = 8'h74; text_rom[1177] = 8'h20; text_rom[1178] = 8'h74; text_rom[1179] = 8'h61; text_rom[1180] = 8'h6C; text_rom[1181] = 8'h6B; text_rom[1182] = 8'h20; text_rom[1183] = 8'h61;
        text_rom[1184] = 8'h6E; text_rom[1185] = 8'h79; text_rom[1186] = 8'h6D; text_rom[1187] = 8'h6F; text_rom[1188] = 8'h72; text_rom[1189] = 8'h65; text_rom[1190] = 8'h20; text_rom[1191] = 8'h28;
        text_rom[1192] = 8'h57; text_rom[1193] = 8'h65; text_rom[1194] = 8'h20; text_rom[1195] = 8'h64; text_rom[1196] = 8'h6F; text_rom[1197] = 8'h6E; text_rom[1198] = 8'h27; text_rom[1199] = 8'h74;
        text_rom[1200] = 8'h2C; text_rom[1201] = 8'h20; text_rom[1202] = 8'h77; text_rom[1203] = 8'h65; text_rom[1204] = 8'h20; text_rom[1205] = 8'h64; text_rom[1206] = 8'h6F; text_rom[1207] = 8'h6E;
        text_rom[1208] = 8'h27; text_rom[1209] = 8'h74; text_rom[1210] = 8'h29; text_rom[1211] = 8'h57; text_rom[1212] = 8'h65; text_rom[1213] = 8'h20; text_rom[1214] = 8'h64; text_rom[1215] = 8'h6F;
        text_rom[1216] = 8'h6E; text_rom[1217] = 8'h27; text_rom[1218] = 8'h74; text_rom[1219] = 8'h20; text_rom[1220] = 8'h74; text_rom[1221] = 8'h61; text_rom[1222] = 8'h6C; text_rom[1223] = 8'h6B;
        text_rom[1224] = 8'h20; text_rom[1225] = 8'h61; text_rom[1226] = 8'h6E; text_rom[1227] = 8'h79; text_rom[1228] = 8'h6D; text_rom[1229] = 8'h6F; text_rom[1230] = 8'h72; text_rom[1231] = 8'h65;
        text_rom[1232] = 8'h20; text_rom[1233] = 8'h28; text_rom[1234] = 8'h57; text_rom[1235] = 8'h65; text_rom[1236] = 8'h20; text_rom[1237] = 8'h64; text_rom[1238] = 8'h6F; text_rom[1239] = 8'h6E;
        text_rom[1240] = 8'h27; text_rom[1241] = 8'h74; text_rom[1242] = 8'h2C; text_rom[1243] = 8'h20; text_rom[1244] = 8'h77; text_rom[1245] = 8'h65; text_rom[1246] = 8'h20; text_rom[1247] = 8'h64;
        text_rom[1248] = 8'h6F; text_rom[1249] = 8'h6E; text_rom[1250] = 8'h27; text_rom[1251] = 8'h74; text_rom[1252] = 8'h29; text_rom[1253] = 8'h57; text_rom[1254] = 8'h65; text_rom[1255] = 8'h20;
        text_rom[1256] = 8'h64; text_rom[1257] = 8'h6F; text_rom[1258] = 8'h6E; text_rom[1259] = 8'h27; text_rom[1260] = 8'h74; text_rom[1261] = 8'h20; text_rom[1262] = 8'h74; text_rom[1263] = 8'h61;
        text_rom[1264] = 8'h6C; text_rom[1265] = 8'h6B; text_rom[1266] = 8'h20; text_rom[1267] = 8'h61; text_rom[1268] = 8'h6E; text_rom[1269] = 8'h79; text_rom[1270] = 8'h6D; text_rom[1271] = 8'h6F;
        text_rom[1272] = 8'h72; text_rom[1273] = 8'h65; text_rom[1274] = 8'h2C; text_rom[1275] = 8'h20; text_rom[1276] = 8'h6C; text_rom[1277] = 8'h69; text_rom[1278] = 8'h6B; text_rom[1279] = 8'h65;
        text_rom[1280] = 8'h20; text_rom[1281] = 8'h77; text_rom[1282] = 8'h65; text_rom[1283] = 8'h20; text_rom[1284] = 8'h75; text_rom[1285] = 8'h73; text_rom[1286] = 8'h65; text_rom[1287] = 8'h64;
        text_rom[1288] = 8'h20; text_rom[1289] = 8'h74; text_rom[1290] = 8'h6F; text_rom[1291] = 8'h20; text_rom[1292] = 8'h64; text_rom[1293] = 8'h6F; text_rom[1294] = 8'h57; text_rom[1295] = 8'h65;
        text_rom[1296] = 8'h20; text_rom[1297] = 8'h64; text_rom[1298] = 8'h6F; text_rom[1299] = 8'h6E; text_rom[1300] = 8'h27; text_rom[1301] = 8'h74; text_rom[1302] = 8'h20; text_rom[1303] = 8'h6C;
        text_rom[1304] = 8'h6F; text_rom[1305] = 8'h76; text_rom[1306] = 8'h65; text_rom[1307] = 8'h20; text_rom[1308] = 8'h61; text_rom[1309] = 8'h6E; text_rom[1310] = 8'h79; text_rom[1311] = 8'h6D;
        text_rom[1312] = 8'h6F; text_rom[1313] = 8'h72; text_rom[1314] = 8'h65; text_rom[1315] = 8'h20; text_rom[1316] = 8'h28; text_rom[1317] = 8'h57; text_rom[1318] = 8'h65; text_rom[1319] = 8'h20;
        text_rom[1320] = 8'h64; text_rom[1321] = 8'h6F; text_rom[1322] = 8'h6E; text_rom[1323] = 8'h27; text_rom[1324] = 8'h74; text_rom[1325] = 8'h2C; text_rom[1326] = 8'h20; text_rom[1327] = 8'h77;
        text_rom[1328] = 8'h65; text_rom[1329] = 8'h20; text_rom[1330] = 8'h64; text_rom[1331] = 8'h6F; text_rom[1332] = 8'h6E; text_rom[1333] = 8'h27; text_rom[1334] = 8'h74; text_rom[1335] = 8'h29;
        text_rom[1336] = 8'h57; text_rom[1337] = 8'h68; text_rom[1338] = 8'h61; text_rom[1339] = 8'h74; text_rom[1340] = 8'h20; text_rom[1341] = 8'h77; text_rom[1342] = 8'h61; text_rom[1343] = 8'h73;
        text_rom[1344] = 8'h20; text_rom[1345] = 8'h61; text_rom[1346] = 8'h6C; text_rom[1347] = 8'h6C; text_rom[1348] = 8'h20; text_rom[1349] = 8'h6F; text_rom[1350] = 8'h66; text_rom[1351] = 8'h20;
        text_rom[1352] = 8'h69; text_rom[1353] = 8'h74; text_rom[1354] = 8'h20; text_rom[1355] = 8'h66; text_rom[1356] = 8'h6F; text_rom[1357] = 8'h72; text_rom[1358] = 8'h3F; text_rom[1359] = 8'h20;
        text_rom[1360] = 8'h28; text_rom[1361] = 8'h57; text_rom[1362] = 8'h65; text_rom[1363] = 8'h20; text_rom[1364] = 8'h64; text_rom[1365] = 8'h6F; text_rom[1366] = 8'h6E; text_rom[1367] = 8'h27;
        text_rom[1368] = 8'h74; text_rom[1369] = 8'h2C; text_rom[1370] = 8'h20; text_rom[1371] = 8'h77; text_rom[1372] = 8'h65; text_rom[1373] = 8'h20; text_rom[1374] = 8'h64; text_rom[1375] = 8'h6F;
        text_rom[1376] = 8'h6E; text_rom[1377] = 8'h27; text_rom[1378] = 8'h74; text_rom[1379] = 8'h29; text_rom[1380] = 8'h4F; text_rom[1381] = 8'h68; text_rom[1382] = 8'h2C; text_rom[1383] = 8'h20;
        text_rom[1384] = 8'h77; text_rom[1385] = 8'h65; text_rom[1386] = 8'h20; text_rom[1387] = 8'h64; text_rom[1388] = 8'h6F; text_rom[1389] = 8'h6E; text_rom[1390] = 8'h27; text_rom[1391] = 8'h74;
        text_rom[1392] = 8'h20; text_rom[1393] = 8'h74; text_rom[1394] = 8'h61; text_rom[1395] = 8'h6C; text_rom[1396] = 8'h6B; text_rom[1397] = 8'h20; text_rom[1398] = 8'h61; text_rom[1399] = 8'h6E;
        text_rom[1400] = 8'h79; text_rom[1401] = 8'h6D; text_rom[1402] = 8'h6F; text_rom[1403] = 8'h72; text_rom[1404] = 8'h65; text_rom[1405] = 8'h2C; text_rom[1406] = 8'h20; text_rom[1407] = 8'h6C;
        text_rom[1408] = 8'h69; text_rom[1409] = 8'h6B; text_rom[1410] = 8'h65; text_rom[1411] = 8'h20; text_rom[1412] = 8'h77; text_rom[1413] = 8'h65; text_rom[1414] = 8'h20; text_rom[1415] = 8'h75;
        text_rom[1416] = 8'h73; text_rom[1417] = 8'h65; text_rom[1418] = 8'h64; text_rom[1419] = 8'h20; text_rom[1420] = 8'h74; text_rom[1421] = 8'h6F; text_rom[1422] = 8'h20; text_rom[1423] = 8'h64;
        text_rom[1424] = 8'h6F; text_rom[1425] = 8'h4C; text_rom[1426] = 8'h69; text_rom[1427] = 8'h6B; text_rom[1428] = 8'h65; text_rom[1429] = 8'h20; text_rom[1430] = 8'h77; text_rom[1431] = 8'h65;
        text_rom[1432] = 8'h20; text_rom[1433] = 8'h75; text_rom[1434] = 8'h73; text_rom[1435] = 8'h65; text_rom[1436] = 8'h64; text_rom[1437] = 8'h20; text_rom[1438] = 8'h74; text_rom[1439] = 8'h6F;
        text_rom[1440] = 8'h20; text_rom[1441] = 8'h64; text_rom[1442] = 8'h6F; text_rom[1443] = 8'h44; text_rom[1444] = 8'h6F; text_rom[1445] = 8'h6E; text_rom[1446] = 8'h27; text_rom[1447] = 8'h74;
        text_rom[1448] = 8'h20; text_rom[1449] = 8'h77; text_rom[1450] = 8'h61; text_rom[1451] = 8'h6E; text_rom[1452] = 8'h6E; text_rom[1453] = 8'h61; text_rom[1454] = 8'h20; text_rom[1455] = 8'h6B;
        text_rom[1456] = 8'h6E; text_rom[1457] = 8'h6F; text_rom[1458] = 8'h77; text_rom[1459] = 8'h6B; text_rom[1460] = 8'h69; text_rom[1461] = 8'h6E; text_rom[1462] = 8'h64; text_rom[1463] = 8'h20;
        text_rom[1464] = 8'h6F; text_rom[1465] = 8'h66; text_rom[1466] = 8'h20; text_rom[1467] = 8'h64; text_rom[1468] = 8'h72; text_rom[1469] = 8'h65; text_rom[1470] = 8'h73; text_rom[1471] = 8'h73;
        text_rom[1472] = 8'h20; text_rom[1473] = 8'h79; text_rom[1474] = 8'h6F; text_rom[1475] = 8'h75; text_rom[1476] = 8'h27; text_rom[1477] = 8'h72; text_rom[1478] = 8'h65; text_rom[1479] = 8'h20;
        text_rom[1480] = 8'h77; text_rom[1481] = 8'h65; text_rom[1482] = 8'h61; text_rom[1483] = 8'h72; text_rom[1484] = 8'h69; text_rom[1485] = 8'h6E; text_rom[1486] = 8'h67; text_rom[1487] = 8'h20;
        text_rom[1488] = 8'h74; text_rom[1489] = 8'h6F; text_rom[1490] = 8'h6E; text_rom[1491] = 8'h69; text_rom[1492] = 8'h67; text_rom[1493] = 8'h68; text_rom[1494] = 8'h74; text_rom[1495] = 8'h49;
        text_rom[1496] = 8'h66; text_rom[1497] = 8'h20; text_rom[1498] = 8'h68; text_rom[1499] = 8'h65; text_rom[1500] = 8'h27; text_rom[1501] = 8'h73; text_rom[1502] = 8'h20; text_rom[1503] = 8'h67;
        text_rom[1504] = 8'h69; text_rom[1505] = 8'h76; text_rom[1506] = 8'h69; text_rom[1507] = 8'h6E; text_rom[1508] = 8'h67; text_rom[1509] = 8'h20; text_rom[1510] = 8'h69; text_rom[1511] = 8'h74;
        text_rom[1512] = 8'h20; text_rom[1513] = 8'h74; text_rom[1514] = 8'h6F; text_rom[1515] = 8'h20; text_rom[1516] = 8'h79; text_rom[1517] = 8'h6F; text_rom[1518] = 8'h75; text_rom[1519] = 8'h20;
        text_rom[1520] = 8'h6A; text_rom[1521] = 8'h75; text_rom[1522] = 8'h73; text_rom[1523] = 8'h74; text_rom[1524] = 8'h20; text_rom[1525] = 8'h72; text_rom[1526] = 8'h69; text_rom[1527] = 8'h67;
        text_rom[1528] = 8'h68; text_rom[1529] = 8'h74; text_rom[1530] = 8'h54; text_rom[1531] = 8'h68; text_rom[1532] = 8'h65; text_rom[1533] = 8'h20; text_rom[1534] = 8'h77; text_rom[1535] = 8'h61;
        text_rom[1536] = 8'h79; text_rom[1537] = 8'h20; text_rom[1538] = 8'h49; text_rom[1539] = 8'h20; text_rom[1540] = 8'h64; text_rom[1541] = 8'h69; text_rom[1542] = 8'h64; text_rom[1543] = 8'h20;
        text_rom[1544] = 8'h62; text_rom[1545] = 8'h65; text_rom[1546] = 8'h66; text_rom[1547] = 8'h6F; text_rom[1548] = 8'h72; text_rom[1549] = 8'h65; text_rom[1550] = 8'h49; text_rom[1551] = 8'h20;
        text_rom[1552] = 8'h6F; text_rom[1553] = 8'h76; text_rom[1554] = 8'h65; text_rom[1555] = 8'h72; text_rom[1556] = 8'h64; text_rom[1557] = 8'h6F; text_rom[1558] = 8'h73; text_rom[1559] = 8'h65;
        text_rom[1560] = 8'h64; text_rom[1561] = 8'h53; text_rom[1562] = 8'h68; text_rom[1563] = 8'h6F; text_rom[1564] = 8'h75; text_rom[1565] = 8'h6C; text_rom[1566] = 8'h64; text_rom[1567] = 8'h27;
        text_rom[1568] = 8'h76; text_rom[1569] = 8'h65; text_rom[1570] = 8'h20; text_rom[1571] = 8'h6B; text_rom[1572] = 8'h6E; text_rom[1573] = 8'h6F; text_rom[1574] = 8'h77; text_rom[1575] = 8'h6E;
        text_rom[1576] = 8'h20; text_rom[1577] = 8'h79; text_rom[1578] = 8'h6F; text_rom[1579] = 8'h75; text_rom[1580] = 8'h72; text_rom[1581] = 8'h20; text_rom[1582] = 8'h6C; text_rom[1583] = 8'h6F;
        text_rom[1584] = 8'h76; text_rom[1585] = 8'h65; text_rom[1586] = 8'h20; text_rom[1587] = 8'h77; text_rom[1588] = 8'h61; text_rom[1589] = 8'h73; text_rom[1590] = 8'h20; text_rom[1591] = 8'h61;
        text_rom[1592] = 8'h20; text_rom[1593] = 8'h67; text_rom[1594] = 8'h61; text_rom[1595] = 8'h6D; text_rom[1596] = 8'h65; text_rom[1597] = 8'h4E; text_rom[1598] = 8'h6F; text_rom[1599] = 8'h77;
        text_rom[1600] = 8'h20; text_rom[1601] = 8'h49; text_rom[1602] = 8'h20; text_rom[1603] = 8'h63; text_rom[1604] = 8'h61; text_rom[1605] = 8'h6E; text_rom[1606] = 8'h27; text_rom[1607] = 8'h74;
        text_rom[1608] = 8'h20; text_rom[1609] = 8'h67; text_rom[1610] = 8'h65; text_rom[1611] = 8'h74; text_rom[1612] = 8'h20; text_rom[1613] = 8'h79; text_rom[1614] = 8'h6F; text_rom[1615] = 8'h75;
        text_rom[1616] = 8'h20; text_rom[1617] = 8'h6F; text_rom[1618] = 8'h75; text_rom[1619] = 8'h74; text_rom[1620] = 8'h20; text_rom[1621] = 8'h6F; text_rom[1622] = 8'h66; text_rom[1623] = 8'h20;
        text_rom[1624] = 8'h6D; text_rom[1625] = 8'h79; text_rom[1626] = 8'h20; text_rom[1627] = 8'h62; text_rom[1628] = 8'h72; text_rom[1629] = 8'h61; text_rom[1630] = 8'h69; text_rom[1631] = 8'h6E;
        text_rom[1632] = 8'h4F; text_rom[1633] = 8'h68; text_rom[1634] = 8'h2C; text_rom[1635] = 8'h20; text_rom[1636] = 8'h69; text_rom[1637] = 8'h74; text_rom[1638] = 8'h27; text_rom[1639] = 8'h73;
        text_rom[1640] = 8'h20; text_rom[1641] = 8'h73; text_rom[1642] = 8'h75; text_rom[1643] = 8'h63; text_rom[1644] = 8'h68; text_rom[1645] = 8'h20; text_rom[1646] = 8'h61; text_rom[1647] = 8'h20;
        text_rom[1648] = 8'h73; text_rom[1649] = 8'h68; text_rom[1650] = 8'h61; text_rom[1651] = 8'h6D; text_rom[1652] = 8'h65; text_rom[1653] = 8'h54; text_rom[1654] = 8'h68; text_rom[1655] = 8'h61;
        text_rom[1656] = 8'h74; text_rom[1657] = 8'h20; text_rom[1658] = 8'h77; text_rom[1659] = 8'h65; text_rom[1660] = 8'h20; text_rom[1661] = 8'h64; text_rom[1662] = 8'h6F; text_rom[1663] = 8'h6E;
        text_rom[1664] = 8'h27; text_rom[1665] = 8'h74; text_rom[1666] = 8'h20; text_rom[1667] = 8'h74; text_rom[1668] = 8'h61; text_rom[1669] = 8'h6C; text_rom[1670] = 8'h6B; text_rom[1671] = 8'h20;
        text_rom[1672] = 8'h61; text_rom[1673] = 8'h6E; text_rom[1674] = 8'h79; text_rom[1675] = 8'h6D; text_rom[1676] = 8'h6F; text_rom[1677] = 8'h72; text_rom[1678] = 8'h65; text_rom[1679] = 8'h20;
        text_rom[1680] = 8'h28; text_rom[1681] = 8'h57; text_rom[1682] = 8'h65; text_rom[1683] = 8'h20; text_rom[1684] = 8'h64; text_rom[1685] = 8'h6F; text_rom[1686] = 8'h6E; text_rom[1687] = 8'h27;
        text_rom[1688] = 8'h74; text_rom[1689] = 8'h2C; text_rom[1690] = 8'h20; text_rom[1691] = 8'h77; text_rom[1692] = 8'h65; text_rom[1693] = 8'h20; text_rom[1694] = 8'h64; text_rom[1695] = 8'h6F;
        text_rom[1696] = 8'h6E; text_rom[1697] = 8'h27; text_rom[1698] = 8'h74; text_rom[1699] = 8'h29; text_rom[1700] = 8'h57; text_rom[1701] = 8'h65; text_rom[1702] = 8'h20; text_rom[1703] = 8'h64;
        text_rom[1704] = 8'h6F; text_rom[1705] = 8'h6E; text_rom[1706] = 8'h27; text_rom[1707] = 8'h74; text_rom[1708] = 8'h20; text_rom[1709] = 8'h74; text_rom[1710] = 8'h61; text_rom[1711] = 8'h6C;
        text_rom[1712] = 8'h6B; text_rom[1713] = 8'h20; text_rom[1714] = 8'h61; text_rom[1715] = 8'h6E; text_rom[1716] = 8'h79; text_rom[1717] = 8'h6D; text_rom[1718] = 8'h6F; text_rom[1719] = 8'h72;
        text_rom[1720] = 8'h65; text_rom[1721] = 8'h20; text_rom[1722] = 8'h28; text_rom[1723] = 8'h57; text_rom[1724] = 8'h65; text_rom[1725] = 8'h20; text_rom[1726] = 8'h64; text_rom[1727] = 8'h6F;
        text_rom[1728] = 8'h6E; text_rom[1729] = 8'h27; text_rom[1730] = 8'h74; text_rom[1731] = 8'h2C; text_rom[1732] = 8'h20; text_rom[1733] = 8'h77; text_rom[1734] = 8'h65; text_rom[1735] = 8'h20;
        text_rom[1736] = 8'h64; text_rom[1737] = 8'h6F; text_rom[1738] = 8'h6E; text_rom[1739] = 8'h27; text_rom[1740] = 8'h74; text_rom[1741] = 8'h29; text_rom[1742] = 8'h57; text_rom[1743] = 8'h65;
        text_rom[1744] = 8'h20; text_rom[1745] = 8'h64; text_rom[1746] = 8'h6F; text_rom[1747] = 8'h6E; text_rom[1748] = 8'h27; text_rom[1749] = 8'h74; text_rom[1750] = 8'h20; text_rom[1751] = 8'h74;
        text_rom[1752] = 8'h61; text_rom[1753] = 8'h6C; text_rom[1754] = 8'h6B; text_rom[1755] = 8'h20; text_rom[1756] = 8'h61; text_rom[1757] = 8'h6E; text_rom[1758] = 8'h79; text_rom[1759] = 8'h6D;
        text_rom[1760] = 8'h6F; text_rom[1761] = 8'h72; text_rom[1762] = 8'h65; text_rom[1763] = 8'h2C; text_rom[1764] = 8'h20; text_rom[1765] = 8'h6C; text_rom[1766] = 8'h69; text_rom[1767] = 8'h6B;
        text_rom[1768] = 8'h65; text_rom[1769] = 8'h20; text_rom[1770] = 8'h77; text_rom[1771] = 8'h65; text_rom[1772] = 8'h20; text_rom[1773] = 8'h75; text_rom[1774] = 8'h73; text_rom[1775] = 8'h65;
        text_rom[1776] = 8'h64; text_rom[1777] = 8'h20; text_rom[1778] = 8'h74; text_rom[1779] = 8'h6F; text_rom[1780] = 8'h20; text_rom[1781] = 8'h64; text_rom[1782] = 8'h6F; text_rom[1783] = 8'h57;
        text_rom[1784] = 8'h65; text_rom[1785] = 8'h20; text_rom[1786] = 8'h64; text_rom[1787] = 8'h6F; text_rom[1788] = 8'h6E; text_rom[1789] = 8'h27; text_rom[1790] = 8'h74; text_rom[1791] = 8'h20;
        text_rom[1792] = 8'h6C; text_rom[1793] = 8'h6F; text_rom[1794] = 8'h76; text_rom[1795] = 8'h65; text_rom[1796] = 8'h20; text_rom[1797] = 8'h61; text_rom[1798] = 8'h6E; text_rom[1799] = 8'h79;
        text_rom[1800] = 8'h6D; text_rom[1801] = 8'h6F; text_rom[1802] = 8'h72; text_rom[1803] = 8'h65; text_rom[1804] = 8'h20; text_rom[1805] = 8'h28; text_rom[1806] = 8'h57; text_rom[1807] = 8'h65;
        text_rom[1808] = 8'h20; text_rom[1809] = 8'h64; text_rom[1810] = 8'h6F; text_rom[1811] = 8'h6E; text_rom[1812] = 8'h27; text_rom[1813] = 8'h74; text_rom[1814] = 8'h2C; text_rom[1815] = 8'h20;
        text_rom[1816] = 8'h77; text_rom[1817] = 8'h65; text_rom[1818] = 8'h20; text_rom[1819] = 8'h64; text_rom[1820] = 8'h6F; text_rom[1821] = 8'h6E; text_rom[1822] = 8'h27; text_rom[1823] = 8'h74;
        text_rom[1824] = 8'h29; text_rom[1825] = 8'h57; text_rom[1826] = 8'h68; text_rom[1827] = 8'h61; text_rom[1828] = 8'h74; text_rom[1829] = 8'h20; text_rom[1830] = 8'h77; text_rom[1831] = 8'h61;
        text_rom[1832] = 8'h73; text_rom[1833] = 8'h20; text_rom[1834] = 8'h61; text_rom[1835] = 8'h6C; text_rom[1836] = 8'h6C; text_rom[1837] = 8'h20; text_rom[1838] = 8'h6F; text_rom[1839] = 8'h66;
        text_rom[1840] = 8'h20; text_rom[1841] = 8'h69; text_rom[1842] = 8'h74; text_rom[1843] = 8'h20; text_rom[1844] = 8'h66; text_rom[1845] = 8'h6F; text_rom[1846] = 8'h72; text_rom[1847] = 8'h3F;
        text_rom[1848] = 8'h20; text_rom[1849] = 8'h28; text_rom[1850] = 8'h57; text_rom[1851] = 8'h65; text_rom[1852] = 8'h20; text_rom[1853] = 8'h64; text_rom[1854] = 8'h6F; text_rom[1855] = 8'h6E;
        text_rom[1856] = 8'h27; text_rom[1857] = 8'h74; text_rom[1858] = 8'h2C; text_rom[1859] = 8'h20; text_rom[1860] = 8'h77; text_rom[1861] = 8'h65; text_rom[1862] = 8'h20; text_rom[1863] = 8'h64;
        text_rom[1864] = 8'h6F; text_rom[1865] = 8'h6E; text_rom[1866] = 8'h27; text_rom[1867] = 8'h74; text_rom[1868] = 8'h29; text_rom[1869] = 8'h4F; text_rom[1870] = 8'h68; text_rom[1871] = 8'h2C;
        text_rom[1872] = 8'h20; text_rom[1873] = 8'h77; text_rom[1874] = 8'h65; text_rom[1875] = 8'h20; text_rom[1876] = 8'h64; text_rom[1877] = 8'h6F; text_rom[1878] = 8'h6E; text_rom[1879] = 8'h27;
        text_rom[1880] = 8'h74; text_rom[1881] = 8'h20; text_rom[1882] = 8'h74; text_rom[1883] = 8'h61; text_rom[1884] = 8'h6C; text_rom[1885] = 8'h6B; text_rom[1886] = 8'h20; text_rom[1887] = 8'h61;
        text_rom[1888] = 8'h6E; text_rom[1889] = 8'h79; text_rom[1890] = 8'h6D; text_rom[1891] = 8'h6F; text_rom[1892] = 8'h72; text_rom[1893] = 8'h65; text_rom[1894] = 8'h2C; text_rom[1895] = 8'h20;
        text_rom[1896] = 8'h6C; text_rom[1897] = 8'h69; text_rom[1898] = 8'h6B; text_rom[1899] = 8'h65; text_rom[1900] = 8'h20; text_rom[1901] = 8'h77; text_rom[1902] = 8'h65; text_rom[1903] = 8'h20;
        text_rom[1904] = 8'h75; text_rom[1905] = 8'h73; text_rom[1906] = 8'h65; text_rom[1907] = 8'h64; text_rom[1908] = 8'h20; text_rom[1909] = 8'h74; text_rom[1910] = 8'h6F; text_rom[1911] = 8'h20;
        text_rom[1912] = 8'h64; text_rom[1913] = 8'h6F; text_rom[1914] = 8'h57; text_rom[1915] = 8'h65; text_rom[1916] = 8'h20; text_rom[1917] = 8'h64; text_rom[1918] = 8'h6F; text_rom[1919] = 8'h6E;
        text_rom[1920] = 8'h27; text_rom[1921] = 8'h74; text_rom[1922] = 8'h20; text_rom[1923] = 8'h74; text_rom[1924] = 8'h61; text_rom[1925] = 8'h6C; text_rom[1926] = 8'h6B; text_rom[1927] = 8'h20;
        text_rom[1928] = 8'h61; text_rom[1929] = 8'h6E; text_rom[1930] = 8'h79; text_rom[1931] = 8'h6D; text_rom[1932] = 8'h6F; text_rom[1933] = 8'h72; text_rom[1934] = 8'h65; text_rom[1935] = 8'h57;
        text_rom[1936] = 8'h68; text_rom[1937] = 8'h61; text_rom[1938] = 8'h74; text_rom[1939] = 8'h20; text_rom[1940] = 8'h6B; text_rom[1941] = 8'h69; text_rom[1942] = 8'h6E; text_rom[1943] = 8'h64;
        text_rom[1944] = 8'h20; text_rom[1945] = 8'h6F; text_rom[1946] = 8'h66; text_rom[1947] = 8'h20; text_rom[1948] = 8'h64; text_rom[1949] = 8'h72; text_rom[1950] = 8'h65; text_rom[1951] = 8'h73;
        text_rom[1952] = 8'h73; text_rom[1953] = 8'h20; text_rom[1954] = 8'h79; text_rom[1955] = 8'h6F; text_rom[1956] = 8'h75; text_rom[1957] = 8'h27; text_rom[1958] = 8'h72; text_rom[1959] = 8'h65;
        text_rom[1960] = 8'h20; text_rom[1961] = 8'h77; text_rom[1962] = 8'h65; text_rom[1963] = 8'h61; text_rom[1964] = 8'h72; text_rom[1965] = 8'h69; text_rom[1966] = 8'h6E; text_rom[1967] = 8'h67;
        text_rom[1968] = 8'h20; text_rom[1969] = 8'h74; text_rom[1970] = 8'h6F; text_rom[1971] = 8'h6E; text_rom[1972] = 8'h69; text_rom[1973] = 8'h67; text_rom[1974] = 8'h68; text_rom[1975] = 8'h74;
        text_rom[1976] = 8'h20; text_rom[1977] = 8'h28; text_rom[1978] = 8'h4F; text_rom[1979] = 8'h68; text_rom[1980] = 8'h29; text_rom[1981] = 8'h49; text_rom[1982] = 8'h66; text_rom[1983] = 8'h20;
        text_rom[1984] = 8'h68; text_rom[1985] = 8'h65; text_rom[1986] = 8'h27; text_rom[1987] = 8'h73; text_rom[1988] = 8'h20; text_rom[1989] = 8'h68; text_rom[1990] = 8'h6F; text_rom[1991] = 8'h6C;
        text_rom[1992] = 8'h64; text_rom[1993] = 8'h69; text_rom[1994] = 8'h6E; text_rom[1995] = 8'h67; text_rom[1996] = 8'h20; text_rom[1997] = 8'h6F; text_rom[1998] = 8'h6E; text_rom[1999] = 8'h74;
        text_rom[2000] = 8'h6F; text_rom[2001] = 8'h20; text_rom[2002] = 8'h79; text_rom[2003] = 8'h6F; text_rom[2004] = 8'h75; text_rom[2005] = 8'h20; text_rom[2006] = 8'h73; text_rom[2007] = 8'h6F;
        text_rom[2008] = 8'h20; text_rom[2009] = 8'h74; text_rom[2010] = 8'h69; text_rom[2011] = 8'h67; text_rom[2012] = 8'h68; text_rom[2013] = 8'h74; text_rom[2014] = 8'h20; text_rom[2015] = 8'h28;
        text_rom[2016] = 8'h4F; text_rom[2017] = 8'h68; text_rom[2018] = 8'h29; text_rom[2019] = 8'h54; text_rom[2020] = 8'h68; text_rom[2021] = 8'h65; text_rom[2022] = 8'h20; text_rom[2023] = 8'h77;
        text_rom[2024] = 8'h61; text_rom[2025] = 8'h79; text_rom[2026] = 8'h20; text_rom[2027] = 8'h49; text_rom[2028] = 8'h20; text_rom[2029] = 8'h64; text_rom[2030] = 8'h69; text_rom[2031] = 8'h64;
        text_rom[2032] = 8'h20; text_rom[2033] = 8'h62; text_rom[2034] = 8'h65; text_rom[2035] = 8'h66; text_rom[2036] = 8'h6F; text_rom[2037] = 8'h72; text_rom[2038] = 8'h65; text_rom[2039] = 8'h57;
        text_rom[2040] = 8'h65; text_rom[2041] = 8'h20; text_rom[2042] = 8'h64; text_rom[2043] = 8'h6F; text_rom[2044] = 8'h6E; text_rom[2045] = 8'h27; text_rom[2046] = 8'h74; text_rom[2047] = 8'h20;
        text_rom[2048] = 8'h74; text_rom[2049] = 8'h61; text_rom[2050] = 8'h6C; text_rom[2051] = 8'h6B; text_rom[2052] = 8'h20; text_rom[2053] = 8'h61; text_rom[2054] = 8'h6E; text_rom[2055] = 8'h79;
        text_rom[2056] = 8'h6D; text_rom[2057] = 8'h6F; text_rom[2058] = 8'h72; text_rom[2059] = 8'h65; text_rom[2060] = 8'h20; text_rom[2061] = 8'h28; text_rom[2062] = 8'h49; text_rom[2063] = 8'h20;
        text_rom[2064] = 8'h6F; text_rom[2065] = 8'h76; text_rom[2066] = 8'h65; text_rom[2067] = 8'h72; text_rom[2068] = 8'h64; text_rom[2069] = 8'h6F; text_rom[2070] = 8'h73; text_rom[2071] = 8'h65;
        text_rom[2072] = 8'h64; text_rom[2073] = 8'h29; text_rom[2074] = 8'h53; text_rom[2075] = 8'h68; text_rom[2076] = 8'h6F; text_rom[2077] = 8'h75; text_rom[2078] = 8'h6C; text_rom[2079] = 8'h64;
        text_rom[2080] = 8'h27; text_rom[2081] = 8'h76; text_rom[2082] = 8'h65; text_rom[2083] = 8'h20; text_rom[2084] = 8'h6B; text_rom[2085] = 8'h6E; text_rom[2086] = 8'h6F; text_rom[2087] = 8'h77;
        text_rom[2088] = 8'h6E; text_rom[2089] = 8'h20; text_rom[2090] = 8'h79; text_rom[2091] = 8'h6F; text_rom[2092] = 8'h75; text_rom[2093] = 8'h72; text_rom[2094] = 8'h20; text_rom[2095] = 8'h6C;
        text_rom[2096] = 8'h6F; text_rom[2097] = 8'h76; text_rom[2098] = 8'h65; text_rom[2099] = 8'h20; text_rom[2100] = 8'h77; text_rom[2101] = 8'h61; text_rom[2102] = 8'h73; text_rom[2103] = 8'h20;
        text_rom[2104] = 8'h61; text_rom[2105] = 8'h20; text_rom[2106] = 8'h67; text_rom[2107] = 8'h61; text_rom[2108] = 8'h6D; text_rom[2109] = 8'h65; text_rom[2110] = 8'h20; text_rom[2111] = 8'h28;
        text_rom[2112] = 8'h4F; text_rom[2113] = 8'h68; text_rom[2114] = 8'h29; text_rom[2115] = 8'h4E; text_rom[2116] = 8'h6F; text_rom[2117] = 8'h77; text_rom[2118] = 8'h20; text_rom[2119] = 8'h49;
        text_rom[2120] = 8'h20; text_rom[2121] = 8'h63; text_rom[2122] = 8'h61; text_rom[2123] = 8'h6E; text_rom[2124] = 8'h27; text_rom[2125] = 8'h74; text_rom[2126] = 8'h20; text_rom[2127] = 8'h67;
        text_rom[2128] = 8'h65; text_rom[2129] = 8'h74; text_rom[2130] = 8'h20; text_rom[2131] = 8'h79; text_rom[2132] = 8'h6F; text_rom[2133] = 8'h75; text_rom[2134] = 8'h20; text_rom[2135] = 8'h6F;
        text_rom[2136] = 8'h75; text_rom[2137] = 8'h74; text_rom[2138] = 8'h20; text_rom[2139] = 8'h6F; text_rom[2140] = 8'h66; text_rom[2141] = 8'h20; text_rom[2142] = 8'h6D; text_rom[2143] = 8'h79;
        text_rom[2144] = 8'h20; text_rom[2145] = 8'h62; text_rom[2146] = 8'h72; text_rom[2147] = 8'h61; text_rom[2148] = 8'h69; text_rom[2149] = 8'h6E; text_rom[2150] = 8'h20; text_rom[2151] = 8'h28;
        text_rom[2152] = 8'h57; text_rom[2153] = 8'h6F; text_rom[2154] = 8'h61; text_rom[2155] = 8'h68; text_rom[2156] = 8'h29; text_rom[2157] = 8'h4F; text_rom[2158] = 8'h68; text_rom[2159] = 8'h2C;
        text_rom[2160] = 8'h20; text_rom[2161] = 8'h69; text_rom[2162] = 8'h74; text_rom[2163] = 8'h27; text_rom[2164] = 8'h73; text_rom[2165] = 8'h20; text_rom[2166] = 8'h73; text_rom[2167] = 8'h75;
        text_rom[2168] = 8'h63; text_rom[2169] = 8'h68; text_rom[2170] = 8'h20; text_rom[2171] = 8'h61; text_rom[2172] = 8'h20; text_rom[2173] = 8'h73; text_rom[2174] = 8'h68; text_rom[2175] = 8'h61;
        text_rom[2176] = 8'h6D; text_rom[2177] = 8'h65; text_rom[2178] = 8'h57; text_rom[2179] = 8'h65; text_rom[2180] = 8'h20; text_rom[2181] = 8'h64; text_rom[2182] = 8'h6F; text_rom[2183] = 8'h6E;
        text_rom[2184] = 8'h27; text_rom[2185] = 8'h74; text_rom[2186] = 8'h20; text_rom[2187] = 8'h74; text_rom[2188] = 8'h61; text_rom[2189] = 8'h6C; text_rom[2190] = 8'h6B; text_rom[2191] = 8'h20;
        text_rom[2192] = 8'h61; text_rom[2193] = 8'h6E; text_rom[2194] = 8'h79; text_rom[2195] = 8'h6D; text_rom[2196] = 8'h6F; text_rom[2197] = 8'h72; text_rom[2198] = 8'h65;
    end

    // Each event is a word-aligned LCD page of at most 16 characters.
    // Page times are distributed across the duration of the matching LRC line.
    function [31:0] page_start_ms;
        input [7:0] index;
        begin
            case (index)
                8'd0: page_start_ms = 32'd720;
                8'd1: page_start_ms = 32'd1895;
                8'd2: page_start_ms = 32'd3070;
                8'd3: page_start_ms = 32'd4245;
                8'd4: page_start_ms = 32'd5420;
                8'd5: page_start_ms = 32'd7050;
                8'd6: page_start_ms = 32'd8680;
                8'd7: page_start_ms = 32'd10310;
                8'd8: page_start_ms = 32'd11490;
                8'd9: page_start_ms = 32'd12670;
                8'd10: page_start_ms = 32'd13485;
                8'd11: page_start_ms = 32'd14300;
                8'd12: page_start_ms = 32'd15695;
                8'd13: page_start_ms = 32'd17090;
                8'd14: page_start_ms = 32'd18485;
                8'd15: page_start_ms = 32'd19880;
                8'd16: page_start_ms = 32'd20777;
                8'd17: page_start_ms = 32'd21675;
                8'd18: page_start_ms = 32'd22572;
                8'd19: page_start_ms = 32'd23470;
                8'd20: page_start_ms = 32'd24660;
                8'd21: page_start_ms = 32'd25850;
                8'd22: page_start_ms = 32'd27020;
                8'd23: page_start_ms = 32'd28190;
                8'd24: page_start_ms = 32'd29360;
                8'd25: page_start_ms = 32'd30606;
                8'd26: page_start_ms = 32'd31853;
                8'd27: page_start_ms = 32'd33100;
                8'd28: page_start_ms = 32'd34260;
                8'd29: page_start_ms = 32'd35420;
                8'd30: page_start_ms = 32'd37395;
                8'd31: page_start_ms = 32'd39370;
                8'd32: page_start_ms = 32'd41100;
                8'd33: page_start_ms = 32'd41863;
                8'd34: page_start_ms = 32'd42626;
                8'd35: page_start_ms = 32'd43390;
                8'd36: page_start_ms = 32'd44360;
                8'd37: page_start_ms = 32'd45330;
                8'd38: page_start_ms = 32'd46300;
                8'd39: page_start_ms = 32'd47645;
                8'd40: page_start_ms = 32'd48990;
                8'd41: page_start_ms = 32'd50470;
                8'd42: page_start_ms = 32'd51313;
                8'd43: page_start_ms = 32'd52156;
                8'd44: page_start_ms = 32'd53000;
                8'd45: page_start_ms = 32'd53850;
                8'd46: page_start_ms = 32'd54700;
                8'd47: page_start_ms = 32'd55550;
                8'd48: page_start_ms = 32'd56875;
                8'd49: page_start_ms = 32'd58200;
                8'd50: page_start_ms = 32'd59400;
                8'd51: page_start_ms = 32'd60600;
                8'd52: page_start_ms = 32'd61800;
                8'd53: page_start_ms = 32'd63000;
                8'd54: page_start_ms = 32'd64623;
                8'd55: page_start_ms = 32'd66246;
                8'd56: page_start_ms = 32'd67870;
                8'd57: page_start_ms = 32'd69045;
                8'd58: page_start_ms = 32'd70220;
                8'd59: page_start_ms = 32'd70980;
                8'd60: page_start_ms = 32'd71740;
                8'd61: page_start_ms = 32'd73940;
                8'd62: page_start_ms = 32'd76140;
                8'd63: page_start_ms = 32'd78340;
                8'd64: page_start_ms = 32'd80540;
                8'd65: page_start_ms = 32'd81925;
                8'd66: page_start_ms = 32'd83310;
                8'd67: page_start_ms = 32'd84563;
                8'd68: page_start_ms = 32'd85816;
                8'd69: page_start_ms = 32'd87070;
                8'd70: page_start_ms = 32'd88105;
                8'd71: page_start_ms = 32'd89140;
                8'd72: page_start_ms = 32'd90393;
                8'd73: page_start_ms = 32'd91646;
                8'd74: page_start_ms = 32'd92900;
                8'd75: page_start_ms = 32'd94233;
                8'd76: page_start_ms = 32'd95566;
                8'd77: page_start_ms = 32'd96900;
                8'd78: page_start_ms = 32'd98530;
                8'd79: page_start_ms = 32'd99313;
                8'd80: page_start_ms = 32'd100096;
                8'd81: page_start_ms = 32'd100880;
                8'd82: page_start_ms = 32'd102282;
                8'd83: page_start_ms = 32'd103685;
                8'd84: page_start_ms = 32'd105087;
                8'd85: page_start_ms = 32'd106490;
                8'd86: page_start_ms = 32'd108070;
                8'd87: page_start_ms = 32'd108893;
                8'd88: page_start_ms = 32'd109716;
                8'd89: page_start_ms = 32'd110540;
                8'd90: page_start_ms = 32'd111423;
                8'd91: page_start_ms = 32'd112306;
                8'd92: page_start_ms = 32'd113190;
                8'd93: page_start_ms = 32'd114425;
                8'd94: page_start_ms = 32'd115660;
                8'd95: page_start_ms = 32'd116516;
                8'd96: page_start_ms = 32'd117373;
                8'd97: page_start_ms = 32'd118230;
                8'd98: page_start_ms = 32'd119033;
                8'd99: page_start_ms = 32'd119836;
                8'd100: page_start_ms = 32'd120640;
                8'd101: page_start_ms = 32'd122246;
                8'd102: page_start_ms = 32'd123853;
                8'd103: page_start_ms = 32'd125460;
                8'd104: page_start_ms = 32'd126223;
                8'd105: page_start_ms = 32'd126986;
                8'd106: page_start_ms = 32'd127750;
                8'd107: page_start_ms = 32'd128333;
                8'd108: page_start_ms = 32'd128916;
                8'd109: page_start_ms = 32'd129500;
                8'd110: page_start_ms = 32'd133065;
                8'd111: page_start_ms = 32'd136630;
                8'd112: page_start_ms = 32'd140195;
                8'd113: page_start_ms = 32'd143760;
                8'd114: page_start_ms = 32'd149130;
                8'd115: page_start_ms = 32'd154500;
                8'd116: page_start_ms = 32'd156130;
                8'd117: page_start_ms = 32'd156960;
                8'd118: page_start_ms = 32'd157790;
                8'd119: page_start_ms = 32'd158620;
                8'd120: page_start_ms = 32'd159446;
                8'd121: page_start_ms = 32'd160273;
                8'd122: page_start_ms = 32'd161100;
                8'd123: page_start_ms = 32'd162605;
                8'd124: page_start_ms = 32'd164110;
                8'd125: page_start_ms = 32'd165640;
                8'd126: page_start_ms = 32'd166453;
                8'd127: page_start_ms = 32'd167266;
                8'd128: page_start_ms = 32'd168080;
                8'd129: page_start_ms = 32'd168956;
                8'd130: page_start_ms = 32'd169833;
                8'd131: page_start_ms = 32'd170710;
                8'd132: page_start_ms = 32'd172020;
                8'd133: page_start_ms = 32'd173330;
                8'd134: page_start_ms = 32'd174180;
                8'd135: page_start_ms = 32'd175030;
                8'd136: page_start_ms = 32'd175880;
                8'd137: page_start_ms = 32'd176653;
                8'd138: page_start_ms = 32'd177426;
                8'd139: page_start_ms = 32'd178200;
                8'd140: page_start_ms = 32'd179833;
                8'd141: page_start_ms = 32'd181466;
                8'd142: page_start_ms = 32'd183100;
                8'd143: page_start_ms = 32'd183853;
                8'd144: page_start_ms = 32'd184606;
                8'd145: page_start_ms = 32'd185360;
                8'd146: page_start_ms = 32'd185906;
                8'd147: page_start_ms = 32'd186453;
                8'd148: page_start_ms = 32'd187000;
                8'd149: page_start_ms = 32'd188412;
                8'd150: page_start_ms = 32'd189825;
                8'd151: page_start_ms = 32'd191237;
                8'd152: page_start_ms = 32'd192650;
                8'd153: page_start_ms = 32'd193490;
                8'd154: page_start_ms = 32'd194330;
                8'd155: page_start_ms = 32'd194997;
                8'd156: page_start_ms = 32'd195665;
                8'd157: page_start_ms = 32'd196332;
                8'd158: page_start_ms = 32'd197000;
                8'd159: page_start_ms = 32'd197846;
                8'd160: page_start_ms = 32'd198693;
                8'd161: page_start_ms = 32'd199540;
                8'd162: page_start_ms = 32'd200885;
                8'd163: page_start_ms = 32'd202230;
                8'd164: page_start_ms = 32'd202846;
                8'd165: page_start_ms = 32'd203463;
                8'd166: page_start_ms = 32'd204080;
                8'd167: page_start_ms = 32'd204926;
                8'd168: page_start_ms = 32'd205773;
                8'd169: page_start_ms = 32'd206620;
                8'd170: page_start_ms = 32'd207486;
                8'd171: page_start_ms = 32'd208353;
                8'd172: page_start_ms = 32'd209220;
                8'd173: page_start_ms = 32'd210550;
                8'd174: page_start_ms = 32'd211880;
                8'd175: page_start_ms = 32'd213880;
                8'd176: page_start_ms = 32'd215880;
                default: page_start_ms = 32'hFFFF_FFFF;
            endcase
        end
    endfunction

    function [11:0] page_base;
        input [7:0] index;
        begin
            case (index)
                8'd0: page_base = 12'd0;
                8'd1: page_base = 12'd14;
                8'd2: page_base = 12'd26;
                8'd3: page_base = 12'd37;
                8'd4: page_base = 12'd44;
                8'd5: page_base = 12'd58;
                8'd6: page_base = 12'd75;
                8'd7: page_base = 12'd85;
                8'd8: page_base = 12'd99;
                8'd9: page_base = 12'd106;
                8'd10: page_base = 12'd122;
                8'd11: page_base = 12'd129;
                8'd12: page_base = 12'd142;
                8'd13: page_base = 12'd156;
                8'd14: page_base = 12'd172;
                8'd15: page_base = 12'd174;
                8'd16: page_base = 12'd191;
                8'd17: page_base = 12'd205;
                8'd18: page_base = 12'd217;
                8'd19: page_base = 12'd224;
                8'd20: page_base = 12'd236;
                8'd21: page_base = 12'd247;
                8'd22: page_base = 12'd262;
                8'd23: page_base = 12'd278;
                8'd24: page_base = 12'd287;
                8'd25: page_base = 12'd304;
                8'd26: page_base = 12'd320;
                8'd27: page_base = 12'd332;
                8'd28: page_base = 12'd349;
                8'd29: page_base = 12'd351;
                8'd30: page_base = 12'd368;
                8'd31: page_base = 12'd381;
                8'd32: page_base = 12'd397;
                8'd33: page_base = 12'd410;
                8'd34: page_base = 12'd423;
                8'd35: page_base = 12'd438;
                8'd36: page_base = 12'd454;
                8'd37: page_base = 12'd466;
                8'd38: page_base = 12'd471;
                8'd39: page_base = 12'd485;
                8'd40: page_base = 12'd491;
                8'd41: page_base = 12'd502;
                8'd42: page_base = 12'd518;
                8'd43: page_base = 12'd534;
                8'd44: page_base = 12'd538;
                8'd45: page_base = 12'd554;
                8'd46: page_base = 12'd568;
                8'd47: page_base = 12'd573;
                8'd48: page_base = 12'd589;
                8'd49: page_base = 12'd594;
                8'd50: page_base = 12'd608;
                8'd51: page_base = 12'd620;
                8'd52: page_base = 12'd631;
                8'd53: page_base = 12'd638;
                8'd54: page_base = 12'd652;
                8'd55: page_base = 12'd669;
                8'd56: page_base = 12'd679;
                8'd57: page_base = 12'd693;
                8'd58: page_base = 12'd700;
                8'd59: page_base = 12'd716;
                8'd60: page_base = 12'd723;
                8'd61: page_base = 12'd736;
                8'd62: page_base = 12'd750;
                8'd63: page_base = 12'd766;
                8'd64: page_base = 12'd768;
                8'd65: page_base = 12'd785;
                8'd66: page_base = 12'd801;
                8'd67: page_base = 12'd817;
                8'd68: page_base = 12'd834;
                8'd69: page_base = 12'd845;
                8'd70: page_base = 12'd859;
                8'd71: page_base = 12'd875;
                8'd72: page_base = 12'd892;
                8'd73: page_base = 12'd908;
                8'd74: page_base = 12'd917;
                8'd75: page_base = 12'd934;
                8'd76: page_base = 12'd951;
                8'd77: page_base = 12'd959;
                8'd78: page_base = 12'd975;
                8'd79: page_base = 12'd985;
                8'd80: page_base = 12'd1002;
                8'd81: page_base = 12'd1006;
                8'd82: page_base = 12'd1023;
                8'd83: page_base = 12'd1035;
                8'd84: page_base = 12'd1051;
                8'd85: page_base = 12'd1061;
                8'd86: page_base = 12'd1072;
                8'd87: page_base = 12'd1088;
                8'd88: page_base = 12'd1104;
                8'd89: page_base = 12'd1108;
                8'd90: page_base = 12'd1124;
                8'd91: page_base = 12'd1138;
                8'd92: page_base = 12'd1143;
                8'd93: page_base = 12'd1159;
                8'd94: page_base = 12'd1164;
                8'd95: page_base = 12'd1178;
                8'd96: page_base = 12'd1195;
                8'd97: page_base = 12'd1211;
                8'd98: page_base = 12'd1225;
                8'd99: page_base = 12'd1237;
                8'd100: page_base = 12'd1253;
                8'd101: page_base = 12'd1267;
                8'd102: page_base = 12'd1284;
                8'd103: page_base = 12'd1294;
                8'd104: page_base = 12'd1308;
                8'd105: page_base = 12'd1320;
                8'd106: page_base = 12'd1336;
                8'd107: page_base = 12'd1352;
                8'd108: page_base = 12'd1364;
                8'd109: page_base = 12'd1380;
                8'd110: page_base = 12'd1393;
                8'd111: page_base = 12'd1407;
                8'd112: page_base = 12'd1423;
                8'd113: page_base = 12'd1425;
                8'd114: page_base = 12'd1441;
                8'd115: page_base = 12'd1443;
                8'd116: page_base = 12'd1459;
                8'd117: page_base = 12'd1473;
                8'd118: page_base = 12'd1488;
                8'd119: page_base = 12'd1495;
                8'd120: page_base = 12'd1510;
                8'd121: page_base = 12'd1525;
                8'd122: page_base = 12'd1530;
                8'd123: page_base = 12'd1544;
                8'd124: page_base = 12'd1550;
                8'd125: page_base = 12'd1561;
                8'd126: page_base = 12'd1577;
                8'd127: page_base = 12'd1593;
                8'd128: page_base = 12'd1597;
                8'd129: page_base = 12'd1613;
                8'd130: page_base = 12'd1627;
                8'd131: page_base = 12'd1632;
                8'd132: page_base = 12'd1648;
                8'd133: page_base = 12'd1653;
                8'd134: page_base = 12'd1667;
                8'd135: page_base = 12'd1684;
                8'd136: page_base = 12'd1700;
                8'd137: page_base = 12'd1714;
                8'd138: page_base = 12'd1726;
                8'd139: page_base = 12'd1742;
                8'd140: page_base = 12'd1756;
                8'd141: page_base = 12'd1773;
                8'd142: page_base = 12'd1783;
                8'd143: page_base = 12'd1797;
                8'd144: page_base = 12'd1809;
                8'd145: page_base = 12'd1825;
                8'd146: page_base = 12'd1841;
                8'd147: page_base = 12'd1853;
                8'd148: page_base = 12'd1869;
                8'd149: page_base = 12'd1882;
                8'd150: page_base = 12'd1896;
                8'd151: page_base = 12'd1912;
                8'd152: page_base = 12'd1914;
                8'd153: page_base = 12'd1928;
                8'd154: page_base = 12'd1935;
                8'd155: page_base = 12'd1948;
                8'd156: page_base = 12'd1961;
                8'd157: page_base = 12'd1977;
                8'd158: page_base = 12'd1981;
                8'd159: page_base = 12'd1997;
                8'd160: page_base = 12'd2009;
                8'd161: page_base = 12'd2019;
                8'd162: page_base = 12'd2033;
                8'd163: page_base = 12'd2039;
                8'd164: page_base = 12'd2053;
                8'd165: page_base = 12'd2064;
                8'd166: page_base = 12'd2074;
                8'd167: page_base = 12'd2090;
                8'd168: page_base = 12'd2106;
                8'd169: page_base = 12'd2115;
                8'd170: page_base = 12'd2131;
                8'd171: page_base = 12'd2145;
                8'd172: page_base = 12'd2157;
                8'd173: page_base = 12'd2173;
                8'd174: page_base = 12'd2178;
                8'd175: page_base = 12'd2192;
                8'd176: page_base = 12'd2199;
                default: page_base = 12'd0;
            endcase
        end
    endfunction

    function [4:0] page_length;
        input [7:0] index;
        begin
            case (index)
                8'd0: page_length = 5'd13;
                8'd1: page_length = 5'd11;
                8'd2: page_length = 5'd10;
                8'd3: page_length = 5'd7;
                8'd4: page_length = 5'd13;
                8'd5: page_length = 5'd16;
                8'd6: page_length = 5'd10;
                8'd7: page_length = 5'd13;
                8'd8: page_length = 5'd7;
                8'd9: page_length = 5'd15;
                8'd10: page_length = 5'd7;
                8'd11: page_length = 5'd12;
                8'd12: page_length = 5'd13;
                8'd13: page_length = 5'd15;
                8'd14: page_length = 5'd2;
                8'd15: page_length = 5'd16;
                8'd16: page_length = 5'd13;
                8'd17: page_length = 5'd11;
                8'd18: page_length = 5'd7;
                8'd19: page_length = 5'd11;
                8'd20: page_length = 5'd11;
                8'd21: page_length = 5'd14;
                8'd22: page_length = 5'd15;
                8'd23: page_length = 5'd9;
                8'd24: page_length = 5'd16;
                8'd25: page_length = 5'd15;
                8'd26: page_length = 5'd12;
                8'd27: page_length = 5'd16;
                8'd28: page_length = 5'd2;
                8'd29: page_length = 5'd16;
                8'd30: page_length = 5'd13;
                8'd31: page_length = 5'd16;
                8'd32: page_length = 5'd12;
                8'd33: page_length = 5'd12;
                8'd34: page_length = 5'd15;
                8'd35: page_length = 5'd15;
                8'd36: page_length = 5'd11;
                8'd37: page_length = 5'd5;
                8'd38: page_length = 5'd13;
                8'd39: page_length = 5'd6;
                8'd40: page_length = 5'd11;
                8'd41: page_length = 5'd15;
                8'd42: page_length = 5'd15;
                8'd43: page_length = 5'd4;
                8'd44: page_length = 5'd15;
                8'd45: page_length = 5'd13;
                8'd46: page_length = 5'd5;
                8'd47: page_length = 5'd15;
                8'd48: page_length = 5'd5;
                8'd49: page_length = 5'd13;
                8'd50: page_length = 5'd11;
                8'd51: page_length = 5'd10;
                8'd52: page_length = 5'd7;
                8'd53: page_length = 5'd13;
                8'd54: page_length = 5'd16;
                8'd55: page_length = 5'd10;
                8'd56: page_length = 5'd13;
                8'd57: page_length = 5'd7;
                8'd58: page_length = 5'd15;
                8'd59: page_length = 5'd7;
                8'd60: page_length = 5'd12;
                8'd61: page_length = 5'd13;
                8'd62: page_length = 5'd15;
                8'd63: page_length = 5'd2;
                8'd64: page_length = 5'd16;
                8'd65: page_length = 5'd16;
                8'd66: page_length = 5'd15;
                8'd67: page_length = 5'd16;
                8'd68: page_length = 5'd11;
                8'd69: page_length = 5'd13;
                8'd70: page_length = 5'd16;
                8'd71: page_length = 5'd16;
                8'd72: page_length = 5'd15;
                8'd73: page_length = 5'd9;
                8'd74: page_length = 5'd16;
                8'd75: page_length = 5'd16;
                8'd76: page_length = 5'd8;
                8'd77: page_length = 5'd16;
                8'd78: page_length = 5'd9;
                8'd79: page_length = 5'd16;
                8'd80: page_length = 5'd4;
                8'd81: page_length = 5'd16;
                8'd82: page_length = 5'd11;
                8'd83: page_length = 5'd15;
                8'd84: page_length = 5'd10;
                8'd85: page_length = 5'd11;
                8'd86: page_length = 5'd15;
                8'd87: page_length = 5'd15;
                8'd88: page_length = 5'd4;
                8'd89: page_length = 5'd15;
                8'd90: page_length = 5'd13;
                8'd91: page_length = 5'd5;
                8'd92: page_length = 5'd15;
                8'd93: page_length = 5'd5;
                8'd94: page_length = 5'd13;
                8'd95: page_length = 5'd16;
                8'd96: page_length = 5'd16;
                8'd97: page_length = 5'd13;
                8'd98: page_length = 5'd11;
                8'd99: page_length = 5'd16;
                8'd100: page_length = 5'd13;
                8'd101: page_length = 5'd16;
                8'd102: page_length = 5'd10;
                8'd103: page_length = 5'd13;
                8'd104: page_length = 5'd11;
                8'd105: page_length = 5'd16;
                8'd106: page_length = 5'd15;
                8'd107: page_length = 5'd11;
                8'd108: page_length = 5'd16;
                8'd109: page_length = 5'd12;
                8'd110: page_length = 5'd13;
                8'd111: page_length = 5'd15;
                8'd112: page_length = 5'd2;
                8'd113: page_length = 5'd15;
                8'd114: page_length = 5'd2;
                8'd115: page_length = 5'd16;
                8'd116: page_length = 5'd13;
                8'd117: page_length = 5'd14;
                8'd118: page_length = 5'd7;
                8'd119: page_length = 5'd14;
                8'd120: page_length = 5'd14;
                8'd121: page_length = 5'd5;
                8'd122: page_length = 5'd13;
                8'd123: page_length = 5'd6;
                8'd124: page_length = 5'd11;
                8'd125: page_length = 5'd15;
                8'd126: page_length = 5'd15;
                8'd127: page_length = 5'd4;
                8'd128: page_length = 5'd15;
                8'd129: page_length = 5'd13;
                8'd130: page_length = 5'd5;
                8'd131: page_length = 5'd15;
                8'd132: page_length = 5'd5;
                8'd133: page_length = 5'd13;
                8'd134: page_length = 5'd16;
                8'd135: page_length = 5'd16;
                8'd136: page_length = 5'd13;
                8'd137: page_length = 5'd11;
                8'd138: page_length = 5'd16;
                8'd139: page_length = 5'd13;
                8'd140: page_length = 5'd16;
                8'd141: page_length = 5'd10;
                8'd142: page_length = 5'd13;
                8'd143: page_length = 5'd11;
                8'd144: page_length = 5'd16;
                8'd145: page_length = 5'd15;
                8'd146: page_length = 5'd11;
                8'd147: page_length = 5'd16;
                8'd148: page_length = 5'd12;
                8'd149: page_length = 5'd13;
                8'd150: page_length = 5'd15;
                8'd151: page_length = 5'd2;
                8'd152: page_length = 5'd13;
                8'd153: page_length = 5'd7;
                8'd154: page_length = 5'd12;
                8'd155: page_length = 5'd12;
                8'd156: page_length = 5'd15;
                8'd157: page_length = 5'd4;
                8'd158: page_length = 5'd15;
                8'd159: page_length = 5'd11;
                8'd160: page_length = 5'd10;
                8'd161: page_length = 5'd13;
                8'd162: page_length = 5'd6;
                8'd163: page_length = 5'd13;
                8'd164: page_length = 5'd10;
                8'd165: page_length = 5'd10;
                8'd166: page_length = 5'd15;
                8'd167: page_length = 5'd15;
                8'd168: page_length = 5'd9;
                8'd169: page_length = 5'd15;
                8'd170: page_length = 5'd13;
                8'd171: page_length = 5'd12;
                8'd172: page_length = 5'd15;
                8'd173: page_length = 5'd5;
                8'd174: page_length = 5'd13;
                8'd175: page_length = 5'd7;
                8'd176: page_length = 5'd0;
                default: page_length = 5'd0;
            endcase
        end
    endfunction

    // playback_ms is produced in the audio clock domain.  Synchronizing its
    // Gray representation prevents multi-bit carry transitions at lyric edges.
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
    reg       page_valid;
    reg [31:0] preview_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page_index <= 8'd0;
            page_valid <= 1'b0;
            preview_count <= 32'd0;
        end else if (!active) begin
            page_index <= 8'd0;
            page_valid <= 1'b0;
            preview_count <= 32'd0;
        end else if (PREVIEW_MODE != 0) begin
            if (!page_valid) begin
                page_index <= 8'd0;
                page_valid <= 1'b1;
                preview_count <= 32'd0;
            end else if (preview_count >= PREVIEW_PAGE_CYCLES-1) begin
                preview_count <= 32'd0;
                if (page_index >= LAST_PAGE)
                    page_index <= 8'd0;
                else
                    page_index <= page_index + 1'b1;
            end else begin
                preview_count <= preview_count + 1'b1;
            end
        end else begin
            preview_count <= 32'd0;
            if (!page_valid) begin
                if (play_ms >= page_start_ms(8'd0)) begin
                    page_index <= 8'd0;
                    page_valid <= 1'b1;
                end
            end else if ((page_index < LAST_PAGE) &&
                         (play_ms >= page_start_ms(page_index + 1'b1))) begin
                page_index <= page_index + 1'b1;
            end
        end
    end

    wire [11:0] selected_base = page_base(page_index);
    wire [4:0]  selected_len  = page_length(page_index);

    // Build the 16-character LCD line using one ROM byte per two clocks.
    localparam [1:0] BUILD_LATCH   = 2'd0;
    localparam [1:0] BUILD_ISSUE   = 2'd1;
    localparam [1:0] BUILD_CAPTURE = 2'd2;
    reg [1:0]   build_state;
    reg [4:0]   build_pos;
    reg [11:0]  build_base;
    reg [4:0]   build_len;
    reg         build_valid;
    reg [7:0]   rom_q;
    reg [127:0] line_work;

    wire [6:0] build_text_pos = {2'b00, build_pos};
    wire build_char_in_range = build_valid &&
        (build_text_pos < {2'b00, build_len});
    wire [11:0] rom_read_address = build_base + build_text_pos;
    wire [7:0] captured_byte = build_char_in_range ? rom_q : 8'h20;

    // Reset-free synchronous read is the Vivado block-ROM inference pattern.
    always @(posedge clk) begin
        if ((build_state == BUILD_ISSUE) && build_char_in_range)
            rom_q <= text_rom[rom_read_address];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line2        <= "                ";
            line_work    <= "                ";
            build_state  <= BUILD_LATCH;
            build_pos    <= 5'd0;
            build_base   <= 12'd0;
            build_len    <= 5'd0;
            build_valid  <= 1'b0;
        end else if (!active) begin
            line2        <= "                ";
            line_work    <= "                ";
            build_state  <= BUILD_LATCH;
            build_pos    <= 5'd0;
            build_valid  <= 1'b0;
        end else begin
            case (build_state)
                BUILD_LATCH: begin
                    build_base   <= selected_base;
                    build_len    <= selected_len;
                    build_valid  <= page_valid && (selected_len != 0);
                    build_pos    <= 5'd0;
                    build_state  <= BUILD_ISSUE;
                end

                BUILD_ISSUE: begin
                    build_state <= BUILD_CAPTURE;
                end

                default: begin
                    line_work[127-build_pos*8 -: 8] <= captured_byte;
                    if (build_pos == 5'd15) begin
                        line2 <= {line_work[127:8], captured_byte};
                        build_state <= BUILD_LATCH;
                    end else begin
                        build_pos <= build_pos + 1'b1;
                        build_state <= BUILD_ISSUE;
                    end
                end
            endcase
        end
    end
endmodule

module sdall_por_reset #(
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
module sdall_audio_clock_gen(
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
module sdall_es8388_init #(
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

    sdall_i2c_master_write #(
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
module sdall_i2c_master_write #(
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
module sdall_i2s_audio_if(
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
module sdall_play_time_ms(
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

// HD44780-compatible LCD1602, 8-bit bus.
// Board-side level shifting is already present.
// RW is kept low; timing delays are used instead of busy-flag reads.
module sdall_lcd1602_driver #(
    parameter integer CLK_HZ = 100_000_000
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output reg  [7:0]   lcd_d,
    output reg          lcd_rs,
    output wire         lcd_rw,
    output reg          lcd_e
);
    assign lcd_rw = 1'b0;

    localparam integer TICK_DIV = CLK_HZ / 100_000; // 10 us
    reg [31:0] div_cnt;
    wire tick = (div_cnt == TICK_DIV-1);

    reg [15:0] delay_ticks;
    reg [2:0]  init_index;
    reg [5:0]  op_index;
    reg [1:0]  pulse_phase;
    reg        initialized;

    function [7:0] line_char;
        input [127:0] line;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  line_char=line[127:120];
                5'd1:  line_char=line[119:112];
                5'd2:  line_char=line[111:104];
                5'd3:  line_char=line[103:96];
                5'd4:  line_char=line[95:88];
                5'd5:  line_char=line[87:80];
                5'd6:  line_char=line[79:72];
                5'd7:  line_char=line[71:64];
                5'd8:  line_char=line[63:56];
                5'd9:  line_char=line[55:48];
                5'd10: line_char=line[47:40];
                5'd11: line_char=line[39:32];
                5'd12: line_char=line[31:24];
                5'd13: line_char=line[23:16];
                5'd14: line_char=line[15:8];
                default: line_char=line[7:0];
            endcase
        end
    endfunction

    function [7:0] init_cmd;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: init_cmd=8'h38; // 8-bit, 2-line
                3'd1: init_cmd=8'h0C; // display on
                3'd2: init_cmd=8'h06; // entry increment
                default: init_cmd=8'h01; // clear
            endcase
        end
    endfunction

    task load_operation;
        input [5:0] op;
        begin
            if (op == 0) begin
                lcd_rs <= 1'b0;
                lcd_d  <= 8'h80;
            end else if ((op >= 1) && (op <= 16)) begin
                lcd_rs <= 1'b1;
                lcd_d  <= line_char(line1, op-1);
            end else if (op == 17) begin
                lcd_rs <= 1'b0;
                lcd_d  <= 8'hC0;
            end else begin
                lcd_rs <= 1'b1;
                lcd_d  <= line_char(line2, op-18);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt      <= 32'd0;
            delay_ticks  <= 16'd2000; // 20 ms
            init_index   <= 3'd0;
            op_index     <= 6'd0;
            pulse_phase  <= 2'd0;
            initialized  <= 1'b0;
            lcd_d        <= 8'h00;
            lcd_rs       <= 1'b0;
            lcd_e        <= 1'b0;
        end else begin
            if (tick)
                div_cnt <= 32'd0;
            else
                div_cnt <= div_cnt + 1'b1;

            if (tick) begin
                if (delay_ticks != 0) begin
                    delay_ticks <= delay_ticks - 1'b1;
                    lcd_e <= 1'b0;
                end else if (!initialized) begin
                    case (pulse_phase)
                        2'd0: begin
                            lcd_rs <= 1'b0;
                            lcd_d  <= init_cmd(init_index);
                            lcd_e  <= 1'b0;
                            pulse_phase <= 2'd1;
                        end
                        2'd1: begin
                            lcd_e <= 1'b1;
                            pulse_phase <= 2'd2;
                        end
                        default: begin
                            lcd_e <= 1'b0;
                            pulse_phase <= 2'd0;
                            if (init_index == 3) begin
                                initialized <= 1'b1;
                                op_index <= 6'd0;
                                delay_ticks <= 16'd200; // clear needs >1.5ms
                            end else begin
                                init_index <= init_index + 1'b1;
                                delay_ticks <= 16'd5;
                            end
                        end
                    endcase
                end else begin
                    case (pulse_phase)
                        2'd0: begin
                            load_operation(op_index);
                            lcd_e <= 1'b0;
                            pulse_phase <= 2'd1;
                        end
                        2'd1: begin
                            lcd_e <= 1'b1;
                            pulse_phase <= 2'd2;
                        end
                        default: begin
                            lcd_e <= 1'b0;
                            pulse_phase <= 2'd0;
                            if (op_index == 6'd33) begin
                                op_index <= 6'd0;
                                delay_ticks <= 16'd1000; // refresh about every 10ms
                            end else begin
                                op_index <= op_index + 1'b1;
                                delay_ticks <= 16'd5;
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
