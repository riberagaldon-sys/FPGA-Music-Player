`timescale 1ns / 1ps
`default_nettype none

// GX-BIDT XC7A200T hybrid audio player:
//   * five full songs from FAT32 SD card
//   * one 10-second PCM excerpt from the independent 4-MiB user QSPI Flash
//   * synchronized 4-bit LCD1602 lyrics for both sources
// Self-contained Design Source: add only this Verilog file and set
// top_sd_audio_lyrics_4bit_all_in_one as the top module.
// SD root files: SONG.RAW, BEAUTY.RAW, DIE4YOU.RAW, PAYPHONE.RAW,
// and STARBOY.RAW (44.1 kHz, signed 16-bit LE stereo PCM).
// KEY0: previous SD song.  KEY1: next SD song.
// KEY2: toggle SD/QSPI mode.
// KEY3: copy the first 10.000 seconds of SONG.RAW plus its timed lyrics
//       from SD/FPGA into QSPI, with readback verification.
// All four core-board keys are active low.  No PC-side loader is required.
// Lyrics are embedded; no .mem or .lrc Design Source is required.


// Hybrid SD-card/QSPI PCM player for GX-BIDT + XC7A200T + ES8388.
//
// SD root files are selected with core-board KEY0/KEY1.  QSPI stores a
// 256-byte header at 0x000000, five timed lyric records at 0x000100, and
// 1,764,000 audio bytes at 0x010000. The QSPI player reads both audio and
// lyric bytes back from Flash. Total address span is safely below 4 MiB.
// Format: 44.1 kHz, signed 16-bit little-endian, stereo interleaved PCM.
// Byte order for every frame: L low, L high, R low, R high.
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
    wire por_n;
    sly4_por_reset #(.POR_BITS(22)) u_por (
        .clk(sys_clk),
        .rst_n(por_n)
    );

    // KEY0/KEY1 are pulled up to 1.5 V on the core board and go low when
    // pressed. KEY0/KEY1 select SD tracks, KEY2 toggles SD/QSPI, and KEY3
    // makes the FPGA copy SONG.RAW's first 10 seconds from SD into QSPI.
    wire key_prev_press;
    wire key_next_press;
    wire key_source_press;
    sly4_button_press #(
        .CLK_HZ(100_000_000),
        .DEBOUNCE_MS(20)
    ) u_key_prev (
        .clk(sys_clk),
        .rst_n(por_n),
        .button_n(KEY0_N),
        .press(key_prev_press)
    );
    sly4_button_press #(
        .CLK_HZ(100_000_000),
        .DEBOUNCE_MS(20)
    ) u_key_next (
        .clk(sys_clk),
        .rst_n(por_n),
        .button_n(KEY1_N),
        .press(key_next_press)
    );
    sly4_button_press #(
        .CLK_HZ(100_000_000),
        .DEBOUNCE_MS(20)
    ) u_key_source (
        .clk(sys_clk),
        .rst_n(por_n),
        .button_n(KEY2_N),
        .press(key_source_press)
    );

    // KEY3 uses a synchronized level/armed detector instead of requiring a
    // 20-ms pulse. Even a short press is accepted, while holding the key can
    // start only one copy operation. This also makes the LCD response direct.
    reg key3_meta;
    reg key3_sync;
    reg key3_armed;
    reg key_copy_request;
    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
            key3_meta       <= 1'b1;
            key3_sync       <= 1'b1;
            key3_armed      <= 1'b1;
            key_copy_request <= 1'b0;
        end else begin
            key3_meta        <= KEY3_N;
            key3_sync        <= key3_meta;
            key_copy_request <= 1'b0;
            if (key3_sync) begin
                key3_armed <= 1'b1;
            end else if (key3_armed) begin
                key3_armed       <= 1'b0;
                key_copy_request <= 1'b1;
            end
        end
    end

    reg        source_qspi;
    reg [2:0]  track_index;
    reg [19:0] media_reset_count;
    reg        flash_copy_active;
    reg        flash_copy_ok;
    reg        flash_copy_failed;
    reg [7:0]  flash_copy_latched_error;
    wire       flash_copy_done;
    wire       flash_copy_error;
    wire [7:0] flash_copy_error_code;
    always @(posedge sys_clk or negedge por_n) begin
        if (!por_n) begin
            source_qspi      <= 1'b0;
            track_index       <= 3'd0;
            media_reset_count <= 20'd0;
            flash_copy_active <= 1'b0;
            flash_copy_ok     <= 1'b0;
            flash_copy_failed <= 1'b0;
            flash_copy_latched_error <= 8'h00;
        end else if (flash_copy_active) begin
            // Ignore all keys until the autonomous copy/verify operation
            // finishes. The copier holds done/error until this reset path.
            if (flash_copy_done) begin
                flash_copy_active <= 1'b0;
                flash_copy_ok     <= 1'b1;
                flash_copy_failed <= 1'b0;
                flash_copy_latched_error <= 8'h00;
            end else if (flash_copy_error) begin
                flash_copy_active <= 1'b0;
                flash_copy_ok     <= 1'b0;
                flash_copy_failed <= 1'b1;
                flash_copy_latched_error <= flash_copy_error_code;
            end else if (media_reset_count != 0) begin
                media_reset_count <= media_reset_count - 1'b1;
            end
        end else if (key_copy_request) begin
            source_qspi       <= 1'b0;
            flash_copy_active <= 1'b1;
            flash_copy_ok     <= 1'b0;
            flash_copy_failed <= 1'b0;
            flash_copy_latched_error <= 8'h00;
            media_reset_count <= 20'd1_000_000;
        end else if (key_source_press) begin
            source_qspi      <= !source_qspi;
            flash_copy_ok     <= 1'b0;
            flash_copy_failed <= 1'b0;
            flash_copy_latched_error <= 8'h00;
            media_reset_count <= 20'd1_000_000;
        end else if (!source_qspi && key_next_press) begin
            track_index <= (track_index == 3'd4) ? 3'd0 :
                           track_index + 3'd1;
            flash_copy_ok     <= 1'b0;
            flash_copy_failed <= 1'b0;
            flash_copy_latched_error <= 8'h00;
            media_reset_count <= 20'd1_000_000;
        end else if (!source_qspi && key_prev_press) begin
            track_index <= (track_index == 3'd0) ? 3'd4 :
                           track_index - 3'd1;
            flash_copy_ok     <= 1'b0;
            flash_copy_failed <= 1'b0;
            flash_copy_latched_error <= 8'h00;
            media_reset_count <= 20'd1_000_000;
        end else if (media_reset_count != 0) begin
            media_reset_count <= media_reset_count - 1'b1;
        end
    end

    wire media_cycle_rst_n = por_n && (media_reset_count == 0);
    wire flash_copy_result = flash_copy_ok || flash_copy_failed;
    wire media_play_rst_n = media_cycle_rst_n &&
                            !flash_copy_active && !flash_copy_result;
    wire sd_media_rst_n = media_cycle_rst_n && !source_qspi &&
                          (flash_copy_active || !flash_copy_result);
    wire qspi_media_rst_n = media_cycle_rst_n && source_qspi &&
                            !flash_copy_active && !flash_copy_result;
    wire qspi_copy_rst_n = media_cycle_rst_n && flash_copy_active;

    // 11.2896 MHz = 256 * 44.1 kHz.
    wire audio_mclk;
    wire audio_clock_locked;
    sly4_audio_clock_gen u_audio_clock (
        .clk_100m(sys_clk),
        .rst_n(por_n),
        .mclk_audio(audio_mclk),
        .locked(audio_clock_locked)
    );
    wire audio_rst_n = por_n & audio_clock_locked;
    assign AUDIO_MCLK = audio_mclk;

    // Asynchronous assertion, synchronous release in the audio clock domain.
    wire stream_async_rst_n = audio_rst_n & media_play_rst_n;
    reg [2:0] stream_reset_sync;
    always @(posedge audio_mclk or negedge stream_async_rst_n) begin
        if (!stream_async_rst_n)
            stream_reset_sync <= 3'b000;
        else
            stream_reset_sync <= {stream_reset_sync[1:0], 1'b1};
    end
    wire stream_audio_rst_n = stream_reset_sync[2];

    wire codec_init_done;
    wire codec_init_ok;
    sly4_es8388_init #(.CLK_HZ(100_000_000)) u_codec_init (
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

    sly4_sd_spi_block_reader #(
        .CLK_HZ(100_000_000),
        .INIT_SPI_HZ(400_000),
        .DATA_SPI_HZ(12_500_000)
    ) u_sd (
        .clk(sys_clk),
        .rst_n(sd_media_rst_n),
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
    // FAT32 root-directory search and selected-track byte stream
    // ------------------------------------------------------------------
    wire        sd_raw_byte_valid;
    wire [7:0]  sd_raw_byte;
    wire        fat_mount_done;
    wire        song_found;
    wire        file_streaming;
    wire        file_eof;
    wire [31:0] song_file_size;
    wire [31:0] song_bytes_sent;
    wire [7:0]  fat_error;

    wire [12:0] pcm_fifo_level;
    // A sector contributes 128 stereo frames. Keep at least 384 slots free.
    wire flash_copy_sector_allow;
    wire sector_allow = flash_copy_active ? flash_copy_sector_allow :
                                               (pcm_fifo_level <= 13'd3712);

    sly4_fat32_song_raw_reader u_fat32 (
        .clk(sys_clk),
        .rst_n(sd_media_rst_n),
        .track_index(flash_copy_active ? 3'd0 : track_index),
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
        .out_valid(sd_raw_byte_valid),
        .out_byte(sd_raw_byte),
        .mount_done(fat_mount_done),
        .file_found(song_found),
        .playing(file_streaming),
        .eof(file_eof),
        .file_size(song_file_size),
        .bytes_sent(song_bytes_sent),
        .error_code(fat_error)
    );

    // ------------------------------------------------------------------
    // Independent 4-MiB user QSPI Flash PCM stream
    // ------------------------------------------------------------------
    // Layout produced autonomously by KEY3 from SD-card SONG.RAW:
    //   0x000000..0x0000FF : GXRP metadata header
    //   0x000100..0x0001B3 : five 36-byte timed LCD lyric records
    //   0x010000..0x1BEA9F : 10.000 s, 44.1-kHz, 16-bit stereo PCM
    // The highest used address is well below the GD25Q32 limit 0x3FFFFF.
    wire        qspi_byte_valid;
    wire [7:0]  qspi_byte;
    wire        qspi_header_done;
    wire        qspi_header_ok;
    wire        qspi_eof;
    wire [31:0] qspi_bytes_sent;
    wire [7:0]  qspi_error;
    wire        qspi_byte_ready = (pcm_fifo_level <= 13'd3712);
    wire        qspi_play_cs_n;
    wire        qspi_play_sclk;
    wire        qspi_play_mosi;
    wire        qspi_lyric_byte_valid;
    wire [7:0]  qspi_lyric_byte_index;
    wire [7:0]  qspi_lyric_byte;
    wire        qspi_lyric_load_done;
    wire        qspi_lyrics_ready;

    sly4_qspi_pcm_streamer #(
        .CLK_HZ(100_000_000),
        .SPI_HZ(5_000_000),
        .BASE_ADDR(24'h010000),
        .DATA_BYTES(32'd1_764_000),
        .LYRIC_ADDR(24'h000100),
        .LYRIC_BYTES(16'd180)
    ) u_qspi_pcm (
        .clk(sys_clk),
        .rst_n(qspi_media_rst_n),
        .enable(source_qspi),
        .spi_cs_n(qspi_play_cs_n),
        .spi_sclk(qspi_play_sclk),
        .spi_mosi(qspi_play_mosi),
        .spi_miso(FLASH_MISO),
        .data(qspi_byte),
        .valid(qspi_byte_valid),
        .ready(qspi_byte_ready),
        .header_done(qspi_header_done),
        .header_ok(qspi_header_ok),
        .eof(qspi_eof),
        .bytes_sent(qspi_bytes_sent),
        .error_code(qspi_error),
        .lyric_byte_valid(qspi_lyric_byte_valid),
        .lyric_byte_index(qspi_lyric_byte_index),
        .lyric_byte(qspi_lyric_byte),
        .lyric_load_done(qspi_lyric_load_done)
    );

    // KEY3 path: the FPGA erases the required QSPI blocks, streams the first
    // 1,764,000 bytes of SONG.RAW from FAT32 SD, programs/verifies every
    // 256-byte page, and writes the GXRP validity header only after all audio
    // bytes pass readback. Thus an interrupted copy remains invalid.
    wire       qspi_copy_cs_n;
    wire       qspi_copy_sclk;
    wire       qspi_copy_mosi;
    wire [3:0] flash_copy_stage;
    wire [31:0] flash_copy_bytes;
    sly4_sd_to_qspi_copier #(
        .CLK_HZ(100_000_000),
        .SPI_HZ(5_000_000),
        .BASE_ADDR(24'h010000),
        .DATA_BYTES(32'd1_764_000),
        .LYRIC_ADDR(24'h000100),
        .LAST_ERASE_ADDR(24'h1B0000)
    ) u_sd_to_qspi (
        .clk(sys_clk),
        .rst_n(qspi_copy_rst_n),
        .enable(flash_copy_active),
        .sd_byte_valid(sd_raw_byte_valid),
        .sd_byte(sd_raw_byte),
        .sd_init_ok(sd_init_ok),
        .file_found(song_found),
        .file_size(song_file_size),
        .sd_error_code(sd_error),
        .fat_error_code(fat_error),
        .sector_allow(flash_copy_sector_allow),
        .spi_cs_n(qspi_copy_cs_n),
        .spi_sclk(qspi_copy_sclk),
        .spi_mosi(qspi_copy_mosi),
        .spi_miso(FLASH_MISO),
        .done(flash_copy_done),
        .error(flash_copy_error),
        .error_code(flash_copy_error_code),
        .stage(flash_copy_stage),
        .bytes_copied(flash_copy_bytes)
    );

    // Only one internal Flash master can reach the physical pins at a time.
    assign FLASH_CS_N   = flash_copy_active ? qspi_copy_cs_n :
                                               qspi_play_cs_n;
    assign FLASH_SCLK   = flash_copy_active ? qspi_copy_sclk :
                                               qspi_play_sclk;
    assign FLASH_MOSI   = flash_copy_active ? qspi_copy_mosi :
                                               qspi_play_mosi;
    assign FLASH_HOLD_N = 1'b1;

    // Select exactly one byte stream.  The QSPI valid level is gated by its
    // ready signal so a paused byte can never be consumed more than once.
    wire       raw_byte_valid = flash_copy_active ? 1'b0 :
                                (source_qspi ?
                                 (qspi_byte_valid && qspi_byte_ready) :
                                 sd_raw_byte_valid);
    wire [7:0] raw_byte = source_qspi ? qspi_byte : sd_raw_byte;
    wire       media_eof = source_qspi ? qspi_eof : file_eof;

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

    sly4_async_stereo_fifo_level #(.AW(12)) u_pcm_fifo (
        .wr_clk(sys_clk),
        .wr_rst_n(media_play_rst_n),
        .wr_clear(1'b0),
        .wr_en(pcm_fifo_write),
        .wr_l(pcm_write_left),
        .wr_r(pcm_write_right),
        .wr_full(pcm_fifo_full),
        .wr_level(pcm_fifo_level),
        .rd_clk(audio_mclk),
        .rd_rst_n(stream_audio_rst_n),
        .rd_clear(1'b0),
        .rd_pop(pcm_fifo_pop),
        .rd_l(pcm_read_left),
        .rd_r(pcm_read_right),
        .rd_empty(pcm_fifo_empty)
    );

    // Start only after about 23 ms has been buffered. Very short test files
    // are also allowed to start once their complete contents are present.
    reg playback_enable_sys;
    always @(posedge sys_clk or negedge media_play_rst_n) begin
        if (!media_play_rst_n)
            playback_enable_sys <= 1'b0;
        else if (pcm_overflow ||
                 (source_qspi && (qspi_error != 0)) ||
                 (!source_qspi && ((sd_error != 0) || (fat_error != 0))))
            playback_enable_sys <= 1'b0;
        else if (!playback_enable_sys &&
                 (!source_qspi || qspi_lyrics_ready) &&
                 ((pcm_fifo_level >= 13'd1024) ||
                  (media_eof && (pcm_fifo_level != 0))))
            playback_enable_sys <= 1'b1;
    end

    reg playback_sync1;
    reg playback_sync2;
    always @(posedge audio_mclk or negedge stream_audio_rst_n) begin
        if (!stream_audio_rst_n) begin
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

    sly4_i2s_audio_if u_i2s (
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
    sly4_play_time_ms u_play_time (
        .clk(audio_mclk),
        .rst_n(stream_audio_rst_n),
        .reset_time(!playback_sync2),
        .sample_tick(audio_frame_tick),
        .advance(playback_sync2 && !pcm_fifo_empty),
        .ms(playback_ms)
    );

    // Register the Gray counter in its source domain before crossing into the
    // 100-MHz LCD domain.  This preserves the one-bit-change Gray property.
    reg [31:0] playback_ms_gray;
    always @(posedge audio_mclk or negedge stream_audio_rst_n) begin
        if (!stream_audio_rst_n)
            playback_ms_gray <= 32'd0;
        else
            playback_ms_gray <= (playback_ms >> 1) ^ playback_ms;
    end
    wire [127:0] sd_lyric_line1;
    wire [127:0] sd_lyric_line2;
    sly4_lyrics_display u_lyrics (
        .clk(sys_clk),
        .rst_n(por_n),
        .active(playback_enable_sys && !source_qspi),
        .track_index(track_index),
        .qspi_mode(1'b0),
        .play_ms_gray_async(playback_ms_gray),
        .line1(sd_lyric_line1),
        .line2(sd_lyric_line2)
    );

    // In QSPI mode these lines are reconstructed only from the 180 lyric
    // bytes just read from QSPI. They are not taken from the SD lyric table.
    wire [127:0] qspi_lyric_line1;
    wire [127:0] qspi_lyric_line2;
    sly4_qspi_lyrics_display u_qspi_lyrics (
        .clk(sys_clk),
        .rst_n(qspi_media_rst_n),
        .active(playback_enable_sys && source_qspi),
        .load_valid(qspi_lyric_byte_valid),
        .load_index(qspi_lyric_byte_index),
        .load_byte(qspi_lyric_byte),
        .load_done(qspi_lyric_load_done),
        .play_ms_gray_async(playback_ms_gray),
        .ready(qspi_lyrics_ready),
        .line1(qspi_lyric_line1),
        .line2(qspi_lyric_line2)
    );
    wire [127:0] lyric_line1 = source_qspi ? qspi_lyric_line1 :
                                               sd_lyric_line1;
    wire [127:0] lyric_line2 = source_qspi ? qspi_lyric_line2 :
                                               sd_lyric_line2;

    // Synchronize the empty flag for the end-of-playback LCD message.
    reg fifo_empty_sync1;
    reg fifo_empty_sync2;
    always @(posedge sys_clk or negedge media_play_rst_n) begin
        if (!media_play_rst_n) begin
            fifo_empty_sync1 <= 1'b1;
            fifo_empty_sync2 <= 1'b1;
        end else begin
            fifo_empty_sync1 <= pcm_fifo_empty;
            fifo_empty_sync2 <= fifo_empty_sync1;
        end
    end

    reg [127:0] track_title;
    reg [127:0] track_find_line;
    always @* begin
        case (track_index)
            3'd0: begin
                track_title     = "WE DON'T TALK...";
                track_find_line = "FIND SONG.RAW   ";
            end
            3'd1: begin
                track_title     = "BEAUTY AND BEAT ";
                track_find_line = "FIND BEAUTY.RAW ";
            end
            3'd2: begin
                track_title     = "DIE FOR YOU     ";
                track_find_line = "FIND DIE4YOU.RAW";
            end
            3'd3: begin
                track_title     = "PAYPHONE        ";
                track_find_line = "FIND PAYPHONE   ";
            end
            default: begin
                track_title     = "STARBOY         ";
                track_find_line = "FIND STARBOY.RAW";
            end
        endcase
    end

    reg [127:0] lcd_line1;
    reg [127:0] lcd_line2;
    always @* begin
        lcd_line1 = source_qspi ? "QSPI WDT 10 SEC " : track_title;
        lcd_line2 = source_qspi ? "CHECKING FLASH  " :
                                  "SD INITIALIZING ";

        if (flash_copy_active) begin
            lcd_line1 = "COPY SD TO QSPI ";
            if (!media_cycle_rst_n) begin
                lcd_line2 = "STARTING COPY...";
            end else begin
                case (flash_copy_stage)
                    4'd1: lcd_line2 = "ERASING FLASH   ";
                    4'd2: begin
                        if (!sd_init_done)
                            lcd_line2 = "SD INITIALIZING ";
                        else
                            lcd_line2 = "FIND SONG.RAW   ";
                    end
                    // Program/readback alternates once per page. Keep one
                    // stable message so LCD characters never look scrambled.
                    4'd3: lcd_line2 = "COPYING AUDIO   ";
                    4'd4: lcd_line2 = "COPYING AUDIO   ";
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
            end else if (qspi_eof && fifo_empty_sync2) begin
                lcd_line1 = "QSPI WDT 10 SEC ";
                lcd_line2 = "QSPI TEST DONE  ";
            end else begin
                lcd_line1 = lyric_line1;
                lcd_line2 = lyric_line2;
            end
        end else begin
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
            end else if (fat_error != 0) begin
                lcd_line1 = "FAT32 ERROR     ";
                case (fat_error)
                    8'h01: lcd_line2 = "NO FAT32 VOLUME ";
                    8'h02: lcd_line2 = "BAD FAT32 BPB   ";
                    8'h03: lcd_line2 = "TRACK FILE MISS ";
                    8'h04: lcd_line2 = "BAD SONG ENTRY  ";
                    8'h05: lcd_line2 = "FAT CHAIN ERROR ";
                    default: lcd_line2 = "SD SECTOR ERROR ";
                endcase
            end else if (!fat_mount_done) begin
                lcd_line2 = track_find_line;
            end else if (!playback_enable_sys) begin
                lcd_line2 = "BUFFERING AUDIO ";
            end else if (file_eof && fifo_empty_sync2) begin
                lcd_line1 = track_title;
                lcd_line2 = "PLAYBACK FINISH ";
            end else begin
                lcd_line1 = lyric_line1;
                lcd_line2 = lyric_line2;
            end
        end
    end

    sly4_lcd1602_driver #(.CLK_HZ(100_000_000)) u_lcd (
        .clk(sys_clk),
        .rst_n(por_n),
        .line1(lcd_line1),
        .line2(lcd_line2),
        .lcd_d(LCD_D),
        .lcd_rs(LCD_RS),
        .lcd_rw(LCD_RW),
        .lcd_e(LCD_E)
    );

    // The player does not accept UART commands; leave TX idle high.
    assign UART_TXD     = 1'b1;

    // During KEY3 copying LED0 stays on and LED1 stays off. Otherwise the
    // LEDs retain their player diagnostics.
    assign LED0 = flash_copy_active ? 1'b1 :
                  (codec_init_ok &&
                   (source_qspi ? qspi_header_ok : sd_init_ok));
    assign LED1 = flash_copy_active ? 1'b0 :
                  (playback_sync2 && !pcm_fifo_empty);

    // Retained diagnostic inputs/status bits are intentionally unused.
    wire unused_inputs = UART_RXD ^ SD_CD_N ^ sd_card_sdhc ^
                         sd_read_busy ^ file_streaming ^ song_found ^
                         song_file_size[0] ^ song_bytes_sent[0] ^
                         qspi_bytes_sent[0] ^
                         flash_copy_bytes[0] ^
                         adc_left[0] ^ adc_right[0] ^ adc_valid ^ playback_ms[0];
endmodule


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
// Initializes the card at 400 kHz, then accepts single-sector CMD17 requests
// at 12.5 MHz and returns exactly 512 byte-valid pulses per successful read.
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


// Minimal read-only FAT32 file streamer for one selected root-directory
// 8.3 file: SONG.RAW, BEAUTY.RAW, DIE4YOU.RAW, PAYPHONE.RAW or STARBOY.RAW.
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
    input  wire [2:0]  track_index,

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
        input [2:0] track;
        input [4:0] position;
        begin
            if (position == 5'd8)
                target_name_byte = "R";
            else if (position == 5'd9)
                target_name_byte = "A";
            else if (position == 5'd10)
                target_name_byte = "W";
            else begin
                target_name_byte = " ";
                case (track)
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
// verified timing. Beauty And A Beat uses a duration-scaled time axis for
// the supplied accelerated audio; Payphone is gently scaled to fit its MP3.
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
                        8'd1: page_start_ms = 32'd5494;
                        8'd2: page_start_ms = 32'd8424;
                        8'd3: page_start_ms = 32'd11354;
                        8'd4: page_start_ms = 32'd11797;
                        8'd5: page_start_ms = 32'd14621;
                        8'd6: page_start_ms = 32'd17446;
                        8'd7: page_start_ms = 32'd20492;
                        8'd8: page_start_ms = 32'd23539;
                        8'd9: page_start_ms = 32'd25034;
                        8'd10: page_start_ms = 32'd26530;
                        8'd11: page_start_ms = 32'd27991;
                        8'd12: page_start_ms = 32'd29452;
                        8'd13: page_start_ms = 32'd30870;
                        8'd14: page_start_ms = 32'd32289;
                        8'd15: page_start_ms = 32'd33260;
                        8'd16: page_start_ms = 32'd34232;
                        8'd17: page_start_ms = 32'd35265;
                        8'd18: page_start_ms = 32'd38521;
                        8'd19: page_start_ms = 32'd41777;
                        8'd20: page_start_ms = 32'd46401;
                        8'd21: page_start_ms = 32'd49933;
                        8'd22: page_start_ms = 32'd53465;
                        8'd23: page_start_ms = 32'd57988;
                        8'd24: page_start_ms = 32'd59612;
                        8'd25: page_start_ms = 32'd70017;
                        8'd26: page_start_ms = 32'd72877;
                        8'd27: page_start_ms = 32'd75737;
                        8'd28: page_start_ms = 32'd78845;
                        8'd29: page_start_ms = 32'd81954;
                        8'd30: page_start_ms = 32'd83387;
                        8'd31: page_start_ms = 32'd84821;
                        8'd32: page_start_ms = 32'd86262;
                        8'd33: page_start_ms = 32'd87704;
                        8'd34: page_start_ms = 32'd89130;
                        8'd35: page_start_ms = 32'd90556;
                        8'd36: page_start_ms = 32'd91733;
                        8'd37: page_start_ms = 32'd92911;
                        8'd38: page_start_ms = 32'd93346;
                        8'd39: page_start_ms = 32'd96707;
                        8'd40: page_start_ms = 32'd100068;
                        8'd41: page_start_ms = 32'd104506;
                        8'd42: page_start_ms = 32'd108131;
                        8'd43: page_start_ms = 32'd111756;
                        8'd44: page_start_ms = 32'd115416;
                        8'd45: page_start_ms = 32'd116675;
                        8'd46: page_start_ms = 32'd118159;
                        8'd47: page_start_ms = 32'd119644;
                        8'd48: page_start_ms = 32'd121116;
                        8'd49: page_start_ms = 32'd122589;
                        8'd50: page_start_ms = 32'd123987;
                        8'd51: page_start_ms = 32'd125386;
                        8'd52: page_start_ms = 32'd126373;
                        8'd53: page_start_ms = 32'd127360;
                        8'd54: page_start_ms = 32'd128347;
                        8'd55: page_start_ms = 32'd130251;
                        8'd56: page_start_ms = 32'd130779;
                        8'd57: page_start_ms = 32'd131307;
                        8'd58: page_start_ms = 32'd131836;
                        8'd59: page_start_ms = 32'd132248;
                        8'd60: page_start_ms = 32'd132660;
                        8'd61: page_start_ms = 32'd133072;
                        8'd62: page_start_ms = 32'd134059;
                        8'd63: page_start_ms = 32'd134486;
                        8'd64: page_start_ms = 32'd136580;
                        8'd65: page_start_ms = 32'd138675;
                        8'd66: page_start_ms = 32'd139755;
                        8'd67: page_start_ms = 32'd143271;
                        8'd68: page_start_ms = 32'd146788;
                        8'd69: page_start_ms = 32'd151210;
                        8'd70: page_start_ms = 32'd154811;
                        8'd71: page_start_ms = 32'd158413;
                        8'd72: page_start_ms = 32'd162967;
                        8'd73: page_start_ms = 32'd163760;
                        default: page_start_ms = 32'd163760;
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
                        line1 = "Young Money,    ";
                        line2 = "Nicki Minaj,    ";
                    end
                    8'd2: begin
                        line1 = "Justin          ";
                        line2 = "                ";
                    end
                    8'd3: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd4: begin
                        line1 = "Show you off,   ";
                        line2 = "tonight I wanna ";
                    end
                    8'd5: begin
                        line1 = "show you off    ";
                        line2 = "                ";
                    end
                    8'd6: begin
                        line1 = "What you got, a ";
                        line2 = "billion could've";
                    end
                    8'd7: begin
                        line1 = "never bought    ";
                        line2 = "                ";
                    end
                    8'd8: begin
                        line1 = "We gonna party  ";
                        line2 = "like it's 3012  ";
                    end
                    8'd9: begin
                        line1 = "tonight         ";
                        line2 = "                ";
                    end
                    8'd10: begin
                        line1 = "I wanna show you";
                        line2 = "all the finer   ";
                    end
                    8'd11: begin
                        line1 = "things in life  ";
                        line2 = "                ";
                    end
                    8'd12: begin
                        line1 = "So just forget  ";
                        line2 = "about the world,";
                    end
                    8'd13: begin
                        line1 = "we're young     ";
                        line2 = "tonight         ";
                    end
                    8'd14: begin
                        line1 = "I'm coming for  ";
                        line2 = "ya, i'm coming  ";
                    end
                    8'd15: begin
                        line1 = "for ya          ";
                        line2 = "                ";
                    end
                    8'd16: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd17: begin
                        line1 = "Cause all I need";
                        line2 = "is a beauty and ";
                    end
                    8'd18: begin
                        line1 = "a beat          ";
                        line2 = "                ";
                    end
                    8'd19: begin
                        line1 = "Who can make my ";
                        line2 = "life complete   ";
                    end
                    8'd20: begin
                        line1 = "It's all by you,";
                        line2 = "when the music  ";
                    end
                    8'd21: begin
                        line1 = "makes you move  ";
                        line2 = "                ";
                    end
                    8'd22: begin
                        line1 = "Baby do it like ";
                        line2 = "you do          ";
                    end
                    8'd23: begin
                        line1 = "Cause...        ";
                        line2 = "                ";
                    end
                    8'd24: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd25: begin
                        line1 = "Body rock, girl,";
                        line2 = "I can feel your ";
                    end
                    8'd26: begin
                        line1 = "body rock       ";
                        line2 = "                ";
                    end
                    8'd27: begin
                        line1 = "Take a bow, you ";
                        line2 = "on the hottest  ";
                    end
                    8'd28: begin
                        line1 = "ticket now      ";
                        line2 = "                ";
                    end
                    8'd29: begin
                        line1 = "We gonna party  ";
                        line2 = "like it's 3012  ";
                    end
                    8'd30: begin
                        line1 = "tonight         ";
                        line2 = "                ";
                    end
                    8'd31: begin
                        line1 = "I wanna show you";
                        line2 = "all the finer   ";
                    end
                    8'd32: begin
                        line1 = "things in life  ";
                        line2 = "                ";
                    end
                    8'd33: begin
                        line1 = "So just forget  ";
                        line2 = "about the world,";
                    end
                    8'd34: begin
                        line1 = "be young tonight";
                        line2 = "                ";
                    end
                    8'd35: begin
                        line1 = "I'm coming for  ";
                        line2 = "ya, i'm coming  ";
                    end
                    8'd36: begin
                        line1 = "for ya          ";
                        line2 = "                ";
                    end
                    8'd37: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd38: begin
                        line1 = "Cause all I need";
                        line2 = "is a beauty and ";
                    end
                    8'd39: begin
                        line1 = "a beat          ";
                        line2 = "                ";
                    end
                    8'd40: begin
                        line1 = "Who can make my ";
                        line2 = "life complete   ";
                    end
                    8'd41: begin
                        line1 = "It's all by you,";
                        line2 = "when the music  ";
                    end
                    8'd42: begin
                        line1 = "makes you move  ";
                        line2 = "                ";
                    end
                    8'd43: begin
                        line1 = "Baby do it like ";
                        line2 = "you do          ";
                    end
                    8'd44: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd45: begin
                        line1 = "In tongue, in   ";
                        line2 = "lung, b-tches   ";
                    end
                    8'd46: begin
                        line1 = "couldn't get on ";
                        line2 = "my ink crank    ";
                    end
                    8'd47: begin
                        line1 = "World tour, is  ";
                        line2 = "mine, ten       ";
                    end
                    8'd48: begin
                        line1 = "million letters,";
                        line2 = "no big sign     ";
                    end
                    8'd49: begin
                        line1 = "Justin bieber,  ";
                        line2 = "you know i'mma  ";
                    end
                    8'd50: begin
                        line1 = "hit 'em with the";
                        line2 = "ether           ";
                    end
                    8'd51: begin
                        line1 = "Guns out,       ";
                        line2 = "weiner, but I   ";
                    end
                    8'd52: begin
                        line1 = "gotta keep my   ";
                        line2 = "eye out for     ";
                    end
                    8'd53: begin
                        line1 = "Selena          ";
                        line2 = "                ";
                    end
                    8'd54: begin
                        line1 = "Beauty, beauty  ";
                        line2 = "and the beast   ";
                    end
                    8'd55: begin
                        line1 = "Beauty from the ";
                        line2 = "east, beauty    ";
                    end
                    8'd56: begin
                        line1 = "from the        ";
                        line2 = "precious of the ";
                    end
                    8'd57: begin
                        line1 = "priest          ";
                        line2 = "                ";
                    end
                    8'd58: begin
                        line1 = "Beast, beauty   ";
                        line2 = "from the        ";
                    end
                    8'd59: begin
                        line1 = "streets, we     ";
                        line2 = "don't get       ";
                    end
                    8'd60: begin
                        line1 = "deceased        ";
                        line2 = "                ";
                    end
                    8'd61: begin
                        line1 = "Everytime beauty";
                        line2 = "want a beats    ";
                    end
                    8'd62: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd63: begin
                        line1 = "Body rock, I    ";
                        line2 = "wanna feel your ";
                    end
                    8'd64: begin
                        line1 = "body rock       ";
                        line2 = "                ";
                    end
                    8'd65: begin
                        line1 = "                ";
                        line2 = "                ";
                    end
                    8'd66: begin
                        line1 = "Cause all I need";
                        line2 = "is a beauty and ";
                    end
                    8'd67: begin
                        line1 = "a beat          ";
                        line2 = "                ";
                    end
                    8'd68: begin
                        line1 = "Who can make my ";
                        line2 = "life complete   ";
                    end
                    8'd69: begin
                        line1 = "It's all by you,";
                        line2 = "when the music  ";
                    end
                    8'd70: begin
                        line1 = "makes you move  ";
                        line2 = "                ";
                    end
                    8'd71: begin
                        line1 = "Baby do it like ";
                        line2 = "you do          ";
                    end
                    8'd72: begin
                        line1 = "Cause...        ";
                        line2 = "                ";
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

`default_nettype wire
