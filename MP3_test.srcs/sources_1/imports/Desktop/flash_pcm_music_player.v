`timescale 1ns / 1ps

// STEP-17 FIX:
// Program and play the 1-second stereo PCM excerpt.
//
// Fixes:
//   1) Every SPI command is terminated by a real CS rising edge.
//   2) A >=1-us CS-high gap is inserted between Flash transactions.
//   3) Marker changed to "WDT1", forcing one clean rewrite for the new song.
//   4) Recommended SPI clock is 5 MHz.
//
// PCM:
//   48 kHz, signed 16-bit stereo
//   48,000 frames x 4 bytes = 192,000 bytes
//
// Flash:
//   data   0x3C0000 .. 0x3EEDFF
//   marker 0x3EEE00 .. 0x3EEE03 ("WDT1")
//   erase  0x3C0000 .. 0x3EEFFF
module flash_pcm_music_player #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer SPI_HZ = 5_000_000,
    parameter [23:0] BASE_ADDR = 24'h3C0000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_req,

    output reg         spi_cs_n,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,

    output reg  [15:0] pcm_left,
    output reg  [15:0] pcm_right,
    output reg         ready,
    output reg         play_seen
);

    localparam integer START_WAIT_CYCLES = CLK_HZ / 1000;
    localparam integer CS_HIGH_CYCLES =
        (CLK_HZ / 1_000_000 < 2) ? 2 : (CLK_HZ / 1_000_000);

    localparam integer TOTAL_SAMPLES = 48_000;
    localparam integer PCM_BYTES     = 192_000;
    localparam integer TOTAL_PAGES   = 750;
    localparam integer ERASE_SECTORS = 47;

    localparam [23:0] MARKER_ADDR = BASE_ADDR + PCM_BYTES;
    localparam [31:0] MARKER_WORD = 32'h57445431; // "WDT1"

    // ---------------------------------------------------------------------
    // PCM ROM: one 32-bit stereo frame per line:
    // [31:16] left, [15:0] right
    // ---------------------------------------------------------------------
    (* rom_style = "block" *) reg [31:0] song_rom [0:TOTAL_SAMPLES-1];
    reg  [15:0] rom_addr;
    reg  [31:0] rom_q;

    initial begin
        $readmemh("song_pcm_1s.mem", song_rom);
    end

    always @(posedge clk) begin
        rom_q <= song_rom[rom_addr];
    end

    // ---------------------------------------------------------------------
    // Shared SPI mode-0 byte engine.
    // ---------------------------------------------------------------------
    reg        xfer_start;
    reg [7:0]  xfer_tx;
    wire [7:0] xfer_rx;
    wire       xfer_busy;
    wire       xfer_done;

    spi_byte_master #(
        .CLK_HZ(CLK_HZ),
        .SPI_HZ(SPI_HZ)
    ) u_spi_byte (
        .clk(clk),
        .rst_n(rst_n),
        .start(xfer_start),
        .tx_data(xfer_tx),
        .rx_data(xfer_rx),
        .busy(xfer_busy),
        .done(xfer_done),
        .sclk(spi_sclk),
        .mosi(spi_mosi),
        .miso(spi_miso)
    );

    // ---------------------------------------------------------------------
    // State machine.
    // ST_GAP is the important fix: CS remains HIGH for >= 1 us between
    // separate Flash commands.
    // ---------------------------------------------------------------------
    localparam [4:0]
        ST_BOOT        = 5'd0,
        ST_MARKER_READ = 5'd1,

        ST_ERASE_WREN  = 5'd2,
        ST_ERASE_CMD   = 5'd3,
        ST_ERASE_POLL  = 5'd4,

        ST_PROG_WREN   = 5'd5,
        ST_PROGRAM     = 5'd6,
        ST_PROG_POLL   = 5'd7,

        ST_MARK_WREN   = 5'd8,
        ST_MARK_PROG   = 5'd9,
        ST_MARK_POLL   = 5'd10,

        ST_READY       = 5'd11,
        ST_READ        = 5'd12,
        ST_GAP         = 5'd13;

    reg [4:0]  state;
    reg [4:0]  gap_next_state;

    reg [31:0] boot_cnt;
    reg [31:0] gap_cnt;

    reg        byte_pending;
    reg [8:0]  seq_idx;

    reg [5:0]  erase_sector_index;
    reg [23:0] erase_addr;

    reg [9:0]  page_index;
    reg [23:0] page_addr;
    reg [15:0] prog_sample_index;
    reg        rom_wait;

    reg [7:0]  status_reg;
    reg [31:0] marker_buf;

    reg [15:0] play_sample_index;
    reg [23:0] play_addr;
    reg [7:0]  read_l_hi;
    reg [7:0]  read_l_lo;
    reg [7:0]  read_r_hi;

    // ---------------------------------------------------------------------
    // Current byte to transmit.
    // ---------------------------------------------------------------------
    reg [7:0] next_tx_byte;

    always @(*) begin
        next_tx_byte = 8'hFF;

        case (state)
            ST_MARKER_READ: begin
                case (seq_idx)
                    9'd0: next_tx_byte = 8'h03;
                    9'd1: next_tx_byte = MARKER_ADDR[23:16];
                    9'd2: next_tx_byte = MARKER_ADDR[15:8];
                    9'd3: next_tx_byte = MARKER_ADDR[7:0];
                    default: next_tx_byte = 8'hFF;
                endcase
            end

            ST_ERASE_WREN,
            ST_PROG_WREN,
            ST_MARK_WREN:
                next_tx_byte = 8'h06;

            ST_ERASE_CMD: begin
                case (seq_idx)
                    9'd0: next_tx_byte = 8'h20;
                    9'd1: next_tx_byte = erase_addr[23:16];
                    9'd2: next_tx_byte = erase_addr[15:8];
                    default: next_tx_byte = erase_addr[7:0];
                endcase
            end

            ST_ERASE_POLL,
            ST_PROG_POLL,
            ST_MARK_POLL:
                next_tx_byte = (seq_idx == 9'd0) ? 8'h05 : 8'hFF;

            ST_PROGRAM: begin
                if (seq_idx == 9'd0)
                    next_tx_byte = 8'h02;
                else if (seq_idx == 9'd1)
                    next_tx_byte = page_addr[23:16];
                else if (seq_idx == 9'd2)
                    next_tx_byte = page_addr[15:8];
                else if (seq_idx == 9'd3)
                    next_tx_byte = page_addr[7:0];
                else begin
                    case (seq_idx[1:0])
                        2'd0: next_tx_byte = rom_q[31:24];
                        2'd1: next_tx_byte = rom_q[23:16];
                        2'd2: next_tx_byte = rom_q[15:8];
                        default: next_tx_byte = rom_q[7:0];
                    endcase
                end
            end

            ST_MARK_PROG: begin
                case (seq_idx)
                    9'd0: next_tx_byte = 8'h02;
                    9'd1: next_tx_byte = MARKER_ADDR[23:16];
                    9'd2: next_tx_byte = MARKER_ADDR[15:8];
                    9'd3: next_tx_byte = MARKER_ADDR[7:0];
                    9'd4: next_tx_byte = MARKER_WORD[31:24];
                    9'd5: next_tx_byte = MARKER_WORD[23:16];
                    9'd6: next_tx_byte = MARKER_WORD[15:8];
                    default: next_tx_byte = MARKER_WORD[7:0];
                endcase
            end

            ST_READ: begin
                case (seq_idx)
                    9'd0: next_tx_byte = 8'h03;
                    9'd1: next_tx_byte = play_addr[23:16];
                    9'd2: next_tx_byte = play_addr[15:8];
                    9'd3: next_tx_byte = play_addr[7:0];
                    default: next_tx_byte = 8'hFF;
                endcase
            end

            default:
                next_tx_byte = 8'hFF;
        endcase
    end

    wire command_state =
        (state == ST_MARKER_READ) ||
        (state == ST_ERASE_WREN)  ||
        (state == ST_ERASE_CMD)   ||
        (state == ST_ERASE_POLL)  ||
        (state == ST_PROG_WREN)   ||
        (state == ST_PROGRAM)     ||
        (state == ST_PROG_POLL)   ||
        (state == ST_MARK_WREN)   ||
        (state == ST_MARK_PROG)   ||
        (state == ST_MARK_POLL)   ||
        (state == ST_READ);

    wire stall_for_rom = (state == ST_PROGRAM) && rom_wait;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_BOOT;
            gap_next_state       <= ST_BOOT;

            boot_cnt             <= 32'd0;
            gap_cnt              <= 32'd0;

            byte_pending         <= 1'b0;
            seq_idx              <= 9'd0;

            erase_sector_index   <= 6'd0;
            erase_addr           <= BASE_ADDR;

            page_index           <= 10'd0;
            page_addr            <= BASE_ADDR;
            prog_sample_index    <= 16'd0;
            rom_addr             <= 16'd0;
            rom_wait             <= 1'b0;

            status_reg           <= 8'h00;
            marker_buf           <= 32'h00000000;

            play_sample_index    <= 16'd0;
            play_addr            <= BASE_ADDR;
            read_l_hi            <= 8'h00;
            read_l_lo            <= 8'h00;
            read_r_hi            <= 8'h00;

            xfer_start           <= 1'b0;
            xfer_tx              <= 8'hFF;
            spi_cs_n             <= 1'b1;

            pcm_left             <= 16'h0000;
            pcm_right            <= 16'h0000;
            ready                <= 1'b0;
            play_seen            <= 1'b0;
        end
        else begin
            xfer_start <= 1'b0;

            // Give inferred synchronous ROM one idle clk after address change.
            if (rom_wait)
                rom_wait <= 1'b0;

            // -------------------------------------------------------------
            // Generic byte launch.
            // CS is asserted before the byte engine sees start on the next
            // system clock, so setup time is generous.
            // -------------------------------------------------------------
            if (command_state &&
                !byte_pending &&
                !xfer_busy &&
                !stall_for_rom) begin

                spi_cs_n     <= 1'b0;
                xfer_tx      <= next_tx_byte;
                xfer_start   <= 1'b1;
                byte_pending <= 1'b1;
            end

            // -------------------------------------------------------------
            // Completed SPI byte.
            // -------------------------------------------------------------
            if (xfer_done && byte_pending) begin
                byte_pending <= 1'b0;

                case (state)
                    // -----------------------------------------------------
                    // Marker normal read: command/address + 4 data bytes.
                    // -----------------------------------------------------
                    ST_MARKER_READ: begin
                        if (seq_idx == 9'd4)
                            marker_buf[31:24] <= xfer_rx;
                        else if (seq_idx == 9'd5)
                            marker_buf[23:16] <= xfer_rx;
                        else if (seq_idx == 9'd6)
                            marker_buf[15:8] <= xfer_rx;
                        else if (seq_idx == 9'd7) begin
                            marker_buf[7:0] <= xfer_rx;
                            spi_cs_n        <= 1'b1;
                            seq_idx         <= 9'd0;

                            if ({marker_buf[31:8], xfer_rx} == MARKER_WORD) begin
                                ready             <= 1'b1;
                                play_sample_index <= 16'd0;
                                play_addr         <= BASE_ADDR;
                                state             <= ST_READY;
                            end
                            else begin
                                erase_sector_index <= 6'd0;
                                erase_addr         <= BASE_ADDR;

                                gap_cnt        <= 32'd0;
                                gap_next_state <= ST_ERASE_WREN;
                                state          <= ST_GAP;
                            end
                        end

                        if (seq_idx != 9'd7)
                            seq_idx <= seq_idx + 1'b1;
                    end

                    // -----------------------------------------------------
                    // WREN before sector erase.
                    // -----------------------------------------------------
                    ST_ERASE_WREN: begin
                        spi_cs_n      <= 1'b1;
                        seq_idx       <= 9'd0;
                        gap_cnt       <= 32'd0;
                        gap_next_state<= ST_ERASE_CMD;
                        state         <= ST_GAP;
                    end

                    // -----------------------------------------------------
                    // 20h + 24-bit address.
                    // -----------------------------------------------------
                    ST_ERASE_CMD: begin
                        if (seq_idx == 9'd3) begin
                            spi_cs_n       <= 1'b1;
                            seq_idx        <= 9'd0;
                            gap_cnt        <= 32'd0;
                            gap_next_state <= ST_ERASE_POLL;
                            state          <= ST_GAP;
                        end
                        else
                            seq_idx <= seq_idx + 1'b1;
                    end

                    // -----------------------------------------------------
                    // RDSR: 05h + one dummy/read byte.
                    // -----------------------------------------------------
                    ST_ERASE_POLL: begin
                        if (seq_idx == 9'd1) begin
                            status_reg <= xfer_rx;
                            spi_cs_n   <= 1'b1;
                            seq_idx    <= 9'd0;
                            gap_cnt    <= 32'd0;

                            if (xfer_rx[0]) begin
                                gap_next_state <= ST_ERASE_POLL;
                            end
                            else if (erase_sector_index == ERASE_SECTORS-1) begin
                                page_index        <= 10'd0;
                                page_addr         <= BASE_ADDR;
                                prog_sample_index <= 16'd0;
                                rom_addr          <= 16'd0;
                                rom_wait          <= 1'b1;
                                gap_next_state    <= ST_PROG_WREN;
                            end
                            else begin
                                erase_sector_index <= erase_sector_index + 1'b1;
                                erase_addr         <= erase_addr + 24'h001000;
                                gap_next_state     <= ST_ERASE_WREN;
                            end

                            state <= ST_GAP;
                        end
                        else
                            seq_idx <= 9'd1;
                    end

                    // -----------------------------------------------------
                    // WREN before every Page Program.
                    // -----------------------------------------------------
                    ST_PROG_WREN: begin
                        spi_cs_n       <= 1'b1;
                        seq_idx        <= 9'd0;
                        gap_cnt        <= 32'd0;
                        gap_next_state <= ST_PROGRAM;
                        state          <= ST_GAP;
                    end

                    // -----------------------------------------------------
                    // 02h + 24-bit address + exactly 256 payload bytes.
                    // CS RISES immediately after byte #256.
                    // -----------------------------------------------------
                    ST_PROGRAM: begin
                        if ((seq_idx >= 9'd4) && (seq_idx[1:0] == 2'd3)) begin
                            if (prog_sample_index < TOTAL_SAMPLES-1) begin
                                prog_sample_index <= prog_sample_index + 1'b1;
                                rom_addr          <= rom_addr + 1'b1;
                                rom_wait          <= 1'b1;
                            end
                        end

                        if (seq_idx == 9'd259) begin
                            spi_cs_n       <= 1'b1;
                            seq_idx        <= 9'd0;
                            gap_cnt        <= 32'd0;
                            gap_next_state <= ST_PROG_POLL;
                            state          <= ST_GAP;
                        end
                        else
                            seq_idx <= seq_idx + 1'b1;
                    end

                    // -----------------------------------------------------
                    // Poll Page Program WIP.
                    // -----------------------------------------------------
                    ST_PROG_POLL: begin
                        if (seq_idx == 9'd1) begin
                            status_reg <= xfer_rx;
                            spi_cs_n   <= 1'b1;
                            seq_idx    <= 9'd0;
                            gap_cnt    <= 32'd0;

                            if (xfer_rx[0]) begin
                                gap_next_state <= ST_PROG_POLL;
                            end
                            else if (page_index == TOTAL_PAGES-1) begin
                                gap_next_state <= ST_MARK_WREN;
                            end
                            else begin
                                page_index     <= page_index + 1'b1;
                                page_addr      <= page_addr + 24'h000100;
                                gap_next_state <= ST_PROG_WREN;
                            end

                            state <= ST_GAP;
                        end
                        else
                            seq_idx <= 9'd1;
                    end

                    // -----------------------------------------------------
                    // WREN + marker program.
                    // -----------------------------------------------------
                    ST_MARK_WREN: begin
                        spi_cs_n       <= 1'b1;
                        seq_idx        <= 9'd0;
                        gap_cnt        <= 32'd0;
                        gap_next_state <= ST_MARK_PROG;
                        state          <= ST_GAP;
                    end

                    ST_MARK_PROG: begin
                        if (seq_idx == 9'd7) begin
                            spi_cs_n       <= 1'b1;
                            seq_idx        <= 9'd0;
                            gap_cnt        <= 32'd0;
                            gap_next_state <= ST_MARK_POLL;
                            state          <= ST_GAP;
                        end
                        else
                            seq_idx <= seq_idx + 1'b1;
                    end

                    ST_MARK_POLL: begin
                        if (seq_idx == 9'd1) begin
                            status_reg <= xfer_rx;
                            spi_cs_n   <= 1'b1;
                            seq_idx    <= 9'd0;

                            if (xfer_rx[0]) begin
                                gap_cnt        <= 32'd0;
                                gap_next_state <= ST_MARK_POLL;
                                state          <= ST_GAP;
                            end
                            else begin
                                ready             <= 1'b1;
                                play_sample_index <= 16'd0;
                                play_addr         <= BASE_ADDR;
                                state             <= ST_READY;
                            end
                        end
                        else
                            seq_idx <= 9'd1;
                    end

                    // -----------------------------------------------------
                    // Playback: 03h + address + 4 PCM bytes.
                    // -----------------------------------------------------
                    ST_READ: begin
                        if (seq_idx == 9'd4)
                            read_l_hi <= xfer_rx;
                        else if (seq_idx == 9'd5)
                            read_l_lo <= xfer_rx;
                        else if (seq_idx == 9'd6)
                            read_r_hi <= xfer_rx;
                        else if (seq_idx == 9'd7) begin
                            pcm_left  <= {read_l_hi, read_l_lo};
                            pcm_right <= {read_r_hi, xfer_rx};
                            play_seen <= 1'b1;

                            spi_cs_n <= 1'b1;
                            seq_idx  <= 9'd0;

                            if (play_sample_index == TOTAL_SAMPLES-1) begin
                                play_sample_index <= 16'd0;
                                play_addr         <= BASE_ADDR;
                            end
                            else begin
                                play_sample_index <= play_sample_index + 1'b1;
                                play_addr         <= play_addr + 24'd4;
                            end

                            state <= ST_READY;
                        end

                        if (seq_idx != 9'd7)
                            seq_idx <= seq_idx + 1'b1;
                    end

                    default: begin
                    end
                endcase
            end

            // -------------------------------------------------------------
            // Non-command state behavior.
            // No second CS assignment exists for command states; this avoids
            // the old "set CS high, then overwrite it low" bug.
            // -------------------------------------------------------------
            case (state)
                ST_BOOT: begin
                    spi_cs_n  <= 1'b1;
                    ready     <= 1'b0;
                    play_seen <= 1'b0;

                    if (boot_cnt >= START_WAIT_CYCLES-1) begin
                        boot_cnt   <= 32'd0;
                        seq_idx    <= 9'd0;
                        marker_buf <= 32'h00000000;
                        state      <= ST_MARKER_READ;
                    end
                    else
                        boot_cnt <= boot_cnt + 1'b1;
                end

                ST_GAP: begin
                    spi_cs_n <= 1'b1;

                    if (gap_cnt >= CS_HIGH_CYCLES-1) begin
                        gap_cnt <= 32'd0;
                        state   <= gap_next_state;
                    end
                    else
                        gap_cnt <= gap_cnt + 1'b1;
                end

                ST_READY: begin
                    spi_cs_n <= 1'b1;

                    if (sample_req) begin
                        seq_idx   <= 9'd0;
                        read_l_hi <= 8'h00;
                        read_l_lo <= 8'h00;
                        read_r_hi <= 8'h00;
                        state     <= ST_READ;
                    end
                end

                default: begin
                    // Command states own CS only through the launch/end logic.
                end
            endcase
        end
    end

endmodule
