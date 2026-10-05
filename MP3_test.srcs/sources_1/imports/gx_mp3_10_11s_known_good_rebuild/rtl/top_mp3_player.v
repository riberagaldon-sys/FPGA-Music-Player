`timescale 1ns / 1ps

module top_mp3_player #(
    // 0 = FPGA ROM 1-kHz tone
    // 1 = ES8388 LINE-IN digital loopback
    // 2 = 1-second REAL stereo PCM excerpt from uploaded MP3 -> Flash -> I2S (STEP-10)
    parameter integer AUDIO_DEMO_MODE = 2
)(
    input  wire sys_clk,

    // ES8388
    output wire AUDIO_MCLK,
    output wire AUDIO_BCLK,
    output wire AUDIO_LRCK,
    output wire AUDIO_DAC_DIN,
    input  wire AUDIO_ADC_DOUT,
    output wire AUDIO_CCLK,
    inout  wire AUDIO_CDATA,

    // Independent user SPI flash U26
    output wire FLASH_CS_N,
    output wire FLASH_SCLK,
    output wire FLASH_MOSI,
    input  wire FLASH_MISO,
    output wire FLASH_HOLD_N,

    // Core-board TF/SD card in SPI mode
    output wire SD_CS_N,
    output wire SD_SCLK,
    output wire SD_MOSI,
    input  wire SD_MISO,
    input  wire SD_CD_N,

    // LCD1602
    output wire [7:0] LCD_D,
    output wire LCD_RS,
    output wire LCD_RW,
    output wire LCD_E,

    // Diagnostics
    output wire LED0,
    output wire LED1
);
    wire rst_n;
    por_reset #(.POR_BITS(22)) u_por (
        .clk(sys_clk),
        .rst_n(rst_n)
    );

    // -------------------------------------------------------------------------
    // Audio clocks
    // -------------------------------------------------------------------------
    wire audio_mclk_int;
    wire audio_clk_locked;

    audio_clock_gen u_audio_clk (
        .clk_100m(sys_clk),
        .rst_n(rst_n),
        .mclk_12m288(audio_mclk_int),
        .locked(audio_clk_locked)
    );

    assign AUDIO_MCLK = audio_mclk_int;

    // -------------------------------------------------------------------------
    // ES8388 control
    // -------------------------------------------------------------------------
    wire codec_init_done;
    wire codec_init_ok;

    es8388_init u_codec_init (
        .clk(sys_clk),
        .rst_n(rst_n & audio_clk_locked),
        .codec_scl(AUDIO_CCLK),
        .codec_sda(AUDIO_CDATA),
        .init_done(codec_init_done),
        .init_ok(codec_init_ok)
    );

    // -------------------------------------------------------------------------
    // I2S full duplex
    // -------------------------------------------------------------------------
    wire [15:0] adc_left;
    wire [15:0] adc_right;
    wire adc_valid;
    wire sample_tick;
    
    // ---------------------------------------------------------------------
    // Non-intrusive ADC activity detector.
    // This logic only observes rx_left/rx_right; it does not touch the I2S
    // loopback path.  A level threshold + sample-to-sample change threshold
    // rejects codec DC offset / idle noise.  Activity is held for about 1 s
    // so LCD/LED do not flicker during short quiet gaps in music.
    // ---------------------------------------------------------------------
    localparam [16:0] ADC_LEVEL_THRESHOLD  = 17'd512;
    localparam [16:0] ADC_CHANGE_THRESHOLD = 17'd64;

    reg [15:0] adc_prev_left;
    reg [15:0] adc_prev_right;
    reg [9:0]  activity_window_count;
    reg [7:0]  activity_hit_count;
    reg [5:0]  quiet_window_count;
    reg        audio_active_mclk;

    wire [16:0] adc_left_mag  = adc_left[15]  ? ({1'b0, ~adc_left}  + 17'd1) : {1'b0, adc_left};
    wire [16:0] adc_right_mag = adc_right[15] ? ({1'b0, ~adc_right} + 17'd1) : {1'b0, adc_right};

    wire signed [16:0] adc_left_diff_s =
        $signed({adc_left[15], adc_left}) - $signed({adc_prev_left[15], adc_prev_left});
    wire signed [16:0] adc_right_diff_s =
        $signed({adc_right[15], adc_right}) - $signed({adc_prev_right[15], adc_prev_right});

    wire [16:0] adc_left_change =
        adc_left_diff_s[16] ? (~adc_left_diff_s + 17'd1) : adc_left_diff_s;
    wire [16:0] adc_right_change =
        adc_right_diff_s[16] ? (~adc_right_diff_s + 17'd1) : adc_right_diff_s;

    wire adc_sample_active =
        ((adc_left_mag  >= ADC_LEVEL_THRESHOLD) && (adc_left_change  >= ADC_CHANGE_THRESHOLD)) ||
        ((adc_right_mag >= ADC_LEVEL_THRESHOLD) && (adc_right_change >= ADC_CHANGE_THRESHOLD));

    always @(posedge audio_mclk_int or negedge rst_n) begin
        if (!rst_n) begin
            adc_prev_left         <= 16'h0000;
            adc_prev_right        <= 16'h0000;
            activity_window_count <= 10'd0;
            activity_hit_count    <= 8'd0;
            quiet_window_count    <= 6'd0;
            audio_active_mclk     <= 1'b0;
        end
        else if (adc_valid) begin
            adc_prev_left  <= adc_left;
            adc_prev_right <= adc_right;

            if (adc_sample_active && activity_hit_count != 8'hFF)
                activity_hit_count <= activity_hit_count + 1'b1;

            // 1024 audio frames per decision window (~21 ms at 48 kHz).
            if (activity_window_count == 10'd1023) begin
                activity_window_count <= 10'd0;
                activity_hit_count    <= 8'd0;

                // Need multiple real audio samples in the window, not one
                // random spike. Include the current frame in the decision.
                if ((activity_hit_count >= 8'd12) ||
                    (adc_sample_active && activity_hit_count >= 8'd11)) begin
                    audio_active_mclk  <= 1'b1;
                    quiet_window_count <= 6'd0;
                end
                else if (audio_active_mclk) begin
                    // 12 quiet windows ~= 0.25 s at 48 kHz.
                    if (quiet_window_count >= 6'd11) begin
                        audio_active_mclk  <= 1'b0;
                        quiet_window_count <= 6'd0;
                    end
                    else begin
                        quiet_window_count <= quiet_window_count + 1'b1;
                    end
                end
                else begin
                    quiet_window_count <= 6'd0;
                end
            end
            else begin
                activity_window_count <= activity_window_count + 1'b1;
            end
        end
    end

    // Synchronize the one-bit status into the 100-MHz LCD/LED clock domain.
    reg audio_active_meta;
    reg audio_active_sys;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_active_meta <= 1'b0;
            audio_active_sys  <= 1'b0;
        end
        else begin
            audio_active_meta <= audio_active_mclk;
            audio_active_sys  <= audio_active_meta;
        end
    end

    wire [15:0] tone_left;
    wire [15:0] tone_right;
    wire [15:0] flash_pcm_left;
    wire [15:0] flash_pcm_right;

    wire [15:0] tx_left  = (AUDIO_DEMO_MODE == 1) ? adc_left :
                           (AUDIO_DEMO_MODE == 2) ? flash_pcm_left :
                                                   tone_left;
    wire [15:0] tx_right = (AUDIO_DEMO_MODE == 1) ? adc_right :
                           (AUDIO_DEMO_MODE == 2) ? flash_pcm_right :
                                                   tone_right;

    tone_generator u_tone (
        .clk(audio_mclk_int),
        .rst_n(rst_n & audio_clk_locked & codec_init_done),
        .sample_tick(sample_tick),
        .pcm_left(tone_left),
        .pcm_right(tone_right)
    );

    i2s_audio_if u_i2s (
        .mclk(audio_mclk_int),
        .rst_n(rst_n & audio_clk_locked),
        .tx_left(tx_left),
        .tx_right(tx_right),
        .adc_data(AUDIO_ADC_DOUT),
        .dac_data(AUDIO_DAC_DIN),
        .bclk(AUDIO_BCLK),
        .lrclk(AUDIO_LRCK),
        .rx_left(adc_left),
        .rx_right(adc_right),
        .rx_valid(adc_valid),
        .frame_tick(sample_tick)
    );

    // -------------------------------------------------------------------------
    // STEP-10: Real MP3-derived stereo PCM playback from Flash.
    // sample_tick is generated in the 12.288-MHz audio domain.  It stays high
    // for one MCLK cycle (~81 ns), so a standard 2-FF synchronizer plus edge
    // detector safely converts it into one pulse in the 100-MHz SPI domain.
    // -------------------------------------------------------------------------
    reg sample_tick_meta;
    reg sample_tick_sys;
    reg sample_tick_sys_d;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_tick_meta  <= 1'b0;
            sample_tick_sys   <= 1'b0;
            sample_tick_sys_d <= 1'b0;
        end
        else begin
            sample_tick_meta  <= sample_tick;
            sample_tick_sys   <= sample_tick_meta;
            sample_tick_sys_d <= sample_tick_sys;
        end
    end

    wire flash_sample_req = sample_tick_sys & ~sample_tick_sys_d;
    wire flash_pcm_ready;
    wire flash_pcm_play_seen;

    flash_pcm_music_player #(
        .CLK_HZ(100_000_000),
        .SPI_HZ(5_000_000),
        .BASE_ADDR(24'h3C0000)
    ) u_flash_pcm_music (
        .clk(sys_clk),
        .rst_n(rst_n),
        .sample_req(flash_sample_req),
        .spi_cs_n(FLASH_CS_N),
        .spi_sclk(FLASH_SCLK),
        .spi_mosi(FLASH_MOSI),
        .spi_miso(FLASH_MISO),
        .pcm_left(flash_pcm_left),
        .pcm_right(flash_pcm_right),
        .ready(flash_pcm_ready),
        .play_seen(flash_pcm_play_seen)
    );

    // -------------------------------------------------------------------------
    // SD card first probe: CMD0 only in Stage-1
    // -------------------------------------------------------------------------
    wire sd_probe_done;
    wire sd_cmd0_ok;
    wire [7:0] sd_r1;

    sd_spi_probe u_sd_probe (
        .clk(sys_clk),
        .rst_n(rst_n),
        .card_detect_n(SD_CD_N),
        .sd_cs_n(SD_CS_N),
        .sd_sclk(SD_SCLK),
        .sd_mosi(SD_MOSI),
        .sd_miso(SD_MISO),
        .probe_done(sd_probe_done),
        .cmd0_ok(sd_cmd0_ok),
        .r1_value(sd_r1)
    );

    // -------------------------------------------------------------------------
    // LCD1602 first screen / scroll demonstration
    // -------------------------------------------------------------------------
    wire [127:0] lcd_line1;
    wire [127:0] lcd_line2;
    
    reg saw_miso_high;
    reg saw_miso_low;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            saw_miso_high <= 1'b0;
            saw_miso_low  <= 1'b0;
        end
        else if (!FLASH_CS_N) begin
            if (FLASH_MISO)
                saw_miso_high <= 1'b1;
            else
                saw_miso_low <= 1'b1;
        end
    end

    // STEP-17 fixed Page-Program diagnostic screen.
    assign lcd_line1 = !flash_pcm_ready     ? "FLASH SONG FIX  " :
                       !flash_pcm_play_seen ? "FLASH SONG READY" :
                                              "FLASH SONG PLAY ";

    assign lcd_line2 = !flash_pcm_ready     ? "REWRITE AUD2... " :
                       !flash_pcm_play_seen ? "WAIT AUDIO TICK " :
                                              "10-11S MP3 TEST ";

    lcd1602_driver u_lcd (
        .clk(sys_clk),
        .rst_n(rst_n),
        .line1(lcd_line1),
        .line2(lcd_line2),
        .lcd_d(LCD_D),
        .lcd_rs(LCD_RS),
        .lcd_rw(LCD_RW),
        .lcd_e(LCD_E)
    );

  // STEP-10 LEDs:
  // LED0 = real-song PCM is stored in Flash and the player is ready.
  // LED1 = ES8388 initialization/ACK status.
  assign LED0 = flash_pcm_ready;
  assign LED1 = codec_init_ok;
  assign FLASH_HOLD_N = 1'b1;

endmodule
