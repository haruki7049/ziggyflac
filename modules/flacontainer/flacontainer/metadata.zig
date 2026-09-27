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
        if (type_bits >= @typeInfo(BlockHeader).@"enum".fields.len) return error.InvalidBlockType;
        const block_type: BlockHeader = @enumFromInt(type_bits);
        const length = try reader.takeVarInt(u24, .big, 3);

        return .{
            .is_last = is_last,
            .block_type = block_type,
            .length = length,
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
