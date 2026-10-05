`timescale 1ns / 1ps
`default_nettype none

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
module fat32_song_raw_reader (
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

`default_nettype wire
