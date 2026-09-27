const std = @import("std");

/// The metadata block type, stored in the low 7 bits of a metadata block
/// header's first byte (RFC 9639 Section 8.1).
pub const BlockHeader = enum(u7) {
    stream_info,
    padding,
    application,
    seek_table,
    vorbis_comment,
    cue_sheet,
    picture,
};

/// A metadata block header (RFC 9639 Section 8.1): a 1-byte last-block flag
/// and block type, followed by a 24-bit big-endian block length in bytes
/// (not including the header itself).
pub const Header = struct {
    is_last: bool,
    block_type: BlockHeader,
    length: u24,

    /// Errors returned by `read`.
    pub const ReadError = std.Io.Reader.Error || error{
        /// The block type in the header is not one of the values defined by `BlockHeader`.
        InvalidBlockType,
    };

    /// Reads a metadata block header from `reader`.
    pub fn read(reader: *std.Io.Reader) ReadError!Header {
        const first_byte = try reader.takeByte();
        const is_last = (first_byte & 0x80) != 0;
        const type_bits: u7 = @intCast(first_byte & 0x7f);
        const block_type = std.enums.fromInt(BlockHeader, type_bits) orelse return error.InvalidBlockType;
        const length = try reader.takeVarInt(u24, .big, 3);

        return .{
            .is_last = is_last,
            .block_type = block_type,
            .length = length,
        };
    }
};

/// The STREAMINFO metadata block (RFC 9639 Section 8.2): fixed-size stream
/// properties that must be present as the first metadata block in a FLAC
/// stream.
pub const StreamInfo = struct {
    /// Minimum block size (in samples) used in the stream.
    min_block_size: u16,
    /// Maximum block size (in samples) used in the stream.
    max_block_size: u16,
    /// Minimum frame size (in bytes) used in the stream, or 0 if unknown.
    min_frame_size: u24,
    /// Maximum frame size (in bytes) used in the stream, or 0 if unknown.
    max_frame_size: u24,
    /// Sample rate in Hz.
    sample_rate: u20,
    /// Number of audio channels (decoded from the spec's zero-based field).
    channels: u4,
    /// Bits per sample (decoded from the spec's zero-based field).
    bits_per_sample: u6,
    /// Total number of interchannel samples in the stream, or 0 if unknown.
    total_samples: u36,
    /// MD5 signature of the unencoded audio data.
    md5_signature: [16]u8,

    /// Errors returned by `read`.
    pub const ReadError = std.Io.Reader.Error;

    /// Reads a STREAMINFO block body from `reader`. The 34-byte body is
    /// assumed to immediately follow a `Header` with `block_type == .stream_info`.
    pub fn read(reader: *std.Io.Reader) ReadError!StreamInfo {
        const min_block_size = try reader.takeInt(u16, .big);
        const max_block_size = try reader.takeInt(u16, .big);
        const min_frame_size = try reader.takeInt(u24, .big);
        const max_frame_size = try reader.takeInt(u24, .big);

        // Sample rate (20 bits), channels - 1 (3 bits), bits per sample - 1
        // (5 bits), and total samples (36 bits) are packed into 64 bits with
        // no byte alignment between fields.
        const packed_bits = try reader.takeInt(u64, .big);
        const sample_rate: u20 = @truncate(packed_bits >> 44);
        const channels_minus_one: u3 = @truncate(packed_bits >> 41);
        const bits_per_sample_minus_one: u5 = @truncate(packed_bits >> 36);
        const total_samples: u36 = @truncate(packed_bits);

        const md5_signature = (try reader.takeArray(16)).*;

        return .{
            .min_block_size = min_block_size,
            .max_block_size = max_block_size,
            .min_frame_size = min_frame_size,
            .max_frame_size = max_frame_size,
            .sample_rate = sample_rate,
            .channels = @as(u4, channels_minus_one) + 1,
            .bits_per_sample = @as(u6, bits_per_sample_minus_one) + 1,
            .total_samples = total_samples,
            .md5_signature = md5_signature,
        };
    }
};

test "each BlockHeader has u7 value" {
    try std.testing.expectEqual(@intFromEnum(BlockHeader.stream_info), 0);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.padding), 1);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.application), 2);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.seek_table), 3);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.vorbis_comment), 4);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.cue_sheet), 5);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.picture), 6);
}

test "Header.read parses a non-last STREAMINFO header" {
    var reader: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0x00, 0x22 });
    const header = try Header.read(&reader);
    try std.testing.expectEqual(false, header.is_last);
    try std.testing.expectEqual(BlockHeader.stream_info, header.block_type);
    try std.testing.expectEqual(@as(u24, 0x22), header.length);
}

test "Header.read parses the last-block flag" {
    var reader: std.Io.Reader = .fixed(&.{ 0x84, 0x00, 0x00, 0x10 });
    const header = try Header.read(&reader);
    try std.testing.expectEqual(true, header.is_last);
    try std.testing.expectEqual(BlockHeader.vorbis_comment, header.block_type);
    try std.testing.expectEqual(@as(u24, 0x10), header.length);
}

test "Header.read rejects an unknown block type" {
    var reader: std.Io.Reader = .fixed(&.{ 0x7f, 0x00, 0x00, 0x00 });
    try std.testing.expectError(error.InvalidBlockType, Header.read(&reader));
}

test "Header.read rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed(&.{0x00});
    try std.testing.expectError(error.EndOfStream, Header.read(&reader));
}

test "StreamInfo.read parses a valid STREAMINFO body" {
    var reader: std.Io.Reader = .fixed(&.{
        0x10, 0x00, 0x10, 0x00,
        0x00, 0x03, 0xe8, 0x00,
        0x07, 0xd0, 0x0a, 0xc4,
        0x42, 0xf0, 0x00, 0x0f,
        0x42, 0x40, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0x0c, 0x0d,
        0x0e, 0x0f,
    });
    const stream_info = try StreamInfo.read(&reader);

    try std.testing.expectEqual(@as(u16, 4096), stream_info.min_block_size);
    try std.testing.expectEqual(@as(u16, 4096), stream_info.max_block_size);
    try std.testing.expectEqual(@as(u24, 1000), stream_info.min_frame_size);
    try std.testing.expectEqual(@as(u24, 2000), stream_info.max_frame_size);
    try std.testing.expectEqual(@as(u20, 44100), stream_info.sample_rate);
    try std.testing.expectEqual(@as(u4, 2), stream_info.channels);
    try std.testing.expectEqual(@as(u6, 16), stream_info.bits_per_sample);
    try std.testing.expectEqual(@as(u36, 1_000_000), stream_info.total_samples);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    }, &stream_info.md5_signature);
}

test "StreamInfo.read rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed(&([_]u8{0x00} ** 10));
    try std.testing.expectError(error.EndOfStream, StreamInfo.read(&reader));
}
