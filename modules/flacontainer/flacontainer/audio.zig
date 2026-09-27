const std = @import("std");

/// The CRC-8 algorithm used to protect a frame header (RFC 9639 Section 9.1.7):
/// polynomial 0x07, no reflection, initial value 0, no output XOR.
pub const HeaderCrc = std.hash.crc.Crc8Smbus;

/// The CRC-16 algorithm used to protect a whole frame (RFC 9639 Section 9.3):
/// polynomial 0x8005, no reflection, initial value 0, no output XOR.
///
/// Verifying a frame footer requires the complete encoded frame (header,
/// subframes, and padding), which this container layer does not decode.
/// Callers that buffer the raw frame bytes can pass them to `FooterCrc.hash`.
pub const FooterCrc = std.hash.crc.Crc16Umts;

/// How a frame's block size relates to the value coded after the sync code
/// (RFC 9639 Section 9.1.2): whether the coded number is a frame number
/// (every frame has the same block size, except possibly the last) or a
/// sample number (frames may have varying block sizes).
pub const BlockingStrategy = enum(u1) {
    fixed = 0,
    variable = 1,
};

/// The channel assignment of a frame (RFC 9639 Section 9.1.4).
pub const ChannelAssignment = union(enum) {
    /// Each channel is coded independently. The value is the channel count (1-8).
    independent: u4,
    /// 2 channels: left/side stereo.
    left_side,
    /// 2 channels: right/side stereo.
    right_side,
    /// 2 channels: mid/side stereo.
    mid_side,

    fn decode(bits: u4) error{ReservedChannelAssignment}!ChannelAssignment {
        return switch (bits) {
            0...7 => .{ .independent = bits + 1 },
            8 => .left_side,
            9 => .right_side,
            10 => .mid_side,
            else => error.ReservedChannelAssignment,
        };
    }
};

/// A FLAC frame header (RFC 9639 Section 9.1).
pub const FrameHeader = struct {
    blocking_strategy: BlockingStrategy,
    /// Block size in inter-channel samples.
    block_size: u16,
    /// Sample rate in Hz, or `null` if it must be taken from STREAMINFO.
    sample_rate: ?u32,
    channel_assignment: ChannelAssignment,
    /// Bits per sample, or `null` if it must be taken from STREAMINFO.
    bits_per_sample: ?u6,
    /// The frame number (fixed-blocksize streams) or the starting sample
    /// number (variable-blocksize streams), per `blocking_strategy`.
    coded_number: u36,

    /// Errors returned by `read`.
    pub const ReadError = std.Io.Reader.Error || error{
        InvalidSyncCode,
        ReservedBit,
        ReservedBlockSize,
        ReservedSampleRate,
        ReservedChannelAssignment,
        ReservedSampleSize,
        InvalidCodedNumber,
        CrcMismatch,
    };

    /// A reader wrapper that records every byte it reads, so the bytes
    /// covered by the header CRC can be replayed into `HeaderCrc` afterwards.
    const Collector = struct {
        reader: *std.Io.Reader,
        // Max header size: 2 (sync/flags) + 2 (block size/sample rate codes)
        // + 7 (coded number) + 2 (extra block size) + 2 (extra sample rate) = 15 bytes.
        buffer: [15]u8 = undefined,
        len: usize = 0,

        fn takeByte(self: *Collector) std.Io.Reader.Error!u8 {
            const byte = try self.reader.takeByte();
            self.buffer[self.len] = byte;
            self.len += 1;
            return byte;
        }

        fn bytes(self: *const Collector) []const u8 {
            return self.buffer[0..self.len];
        }
    };

    /// Reads and validates a frame header from `reader`, including its CRC-8.
    pub fn read(reader: *std.Io.Reader) ReadError!FrameHeader {
        var collector = Collector{ .reader = reader };

        const sync_byte = try collector.takeByte();
        if (sync_byte != 0xff) return error.InvalidSyncCode;

        const flags_byte = try collector.takeByte();
        if (flags_byte & 0xfc != 0xf8) return error.InvalidSyncCode;
        if (flags_byte & 0b10 != 0) return error.ReservedBit;
        const blocking_strategy: BlockingStrategy = @enumFromInt(@as(u1, @intCast(flags_byte & 0b1)));

        const size_rate_byte = try collector.takeByte();
        const block_size_code: u4 = @intCast(size_rate_byte >> 4);
        const sample_rate_code: u4 = @intCast(size_rate_byte & 0x0f);

        const channel_sample_byte = try collector.takeByte();
        const channel_assignment_bits: u4 = @intCast(channel_sample_byte >> 4);
        const sample_size_code: u3 = @intCast((channel_sample_byte >> 1) & 0x07);
        if (channel_sample_byte & 0b1 != 0) return error.ReservedBit;

        const channel_assignment = try ChannelAssignment.decode(channel_assignment_bits);
        const bits_per_sample = try decodeSampleSize(sample_size_code);
        const coded_number = try readCodedNumber(&collector);

        const block_size = switch (block_size_code) {
            0 => return error.ReservedBlockSize,
            1 => @as(u16, 192),
            2...5 => @as(u16, 576) << @as(u3, @intCast(block_size_code - 2)),
            6 => @as(u16, try collector.takeByte()) + 1,
            7 => blk: {
                const high = try collector.takeByte();
                const low = try collector.takeByte();
                break :blk (@as(u16, high) << 8 | low) + 1;
            },
            8...15 => @as(u16, 256) << @as(u4, @intCast(block_size_code - 8)),
        };

        const sample_rate: ?u32 = switch (sample_rate_code) {
            0 => null,
            1 => 88_200,
            2 => 176_400,
            3 => 192_000,
            4 => 8_000,
            5 => 16_000,
            6 => 22_050,
            7 => 24_000,
            8 => 32_000,
            9 => 44_100,
            10 => 48_000,
            11 => 96_000,
            12 => @as(u32, try collector.takeByte()) * 1_000,
            13 => blk: {
                const high = try collector.takeByte();
                const low = try collector.takeByte();
                break :blk @as(u32, high) << 8 | low;
            },
            14 => blk: {
                const high = try collector.takeByte();
                const low = try collector.takeByte();
                break :blk (@as(u32, high) << 8 | low) * 10;
            },
            15 => return error.ReservedSampleRate,
        };

        const expected_crc = HeaderCrc.hash(collector.bytes());
        const actual_crc = try reader.takeByte();
        if (actual_crc != expected_crc) return error.CrcMismatch;

        return .{
            .blocking_strategy = blocking_strategy,
            .block_size = block_size,
            .sample_rate = sample_rate,
            .channel_assignment = channel_assignment,
            .bits_per_sample = bits_per_sample,
            .coded_number = coded_number,
        };
    }
};

fn decodeSampleSize(bits: u3) error{ReservedSampleSize}!?u6 {
    return switch (bits) {
        0 => null,
        1 => 8,
        2 => 12,
        3 => error.ReservedSampleSize,
        4 => 16,
        5 => 20,
        6 => 24,
        7 => 32,
    };
}

/// Reads the UTF-8-like variable-length coded number that follows a frame
/// header's fixed fields (RFC 9639 Section 9.1.5): 7 bits in 1 byte up to
/// 36 bits in 7 bytes.
fn readCodedNumber(collector: *FrameHeader.Collector) FrameHeader.ReadError!u36 {
    const first = try collector.takeByte();
    if (first & 0x80 == 0) return first;

    var continuation_bytes: u3 = undefined;
    var value: u36 = undefined;
    if (first & 0xe0 == 0xc0) {
        continuation_bytes = 1;
        value = first & 0x1f;
    } else if (first & 0xf0 == 0xe0) {
        continuation_bytes = 2;
        value = first & 0x0f;
    } else if (first & 0xf8 == 0xf0) {
        continuation_bytes = 3;
        value = first & 0x07;
    } else if (first & 0xfc == 0xf8) {
        continuation_bytes = 4;
        value = first & 0x03;
    } else if (first & 0xfe == 0xfc) {
        continuation_bytes = 5;
        value = first & 0x01;
    } else if (first == 0xfe) {
        continuation_bytes = 6;
        value = 0;
    } else {
        return error.InvalidCodedNumber;
    }

    var i: u3 = 0;
    while (i < continuation_bytes) : (i += 1) {
        const continuation = try collector.takeByte();
        if (continuation & 0xc0 != 0x80) return error.InvalidCodedNumber;
        value = (value << 6) | (continuation & 0x3f);
    }
    return value;
}

test "FrameHeader.read parses a fixed-blocksize header" {
    // sync(0xff) + flags(reserved=0, fixed=0) = 0xf8
    // block size code 0100 -> 576*2^2=2304, sample rate code 1001 -> 44100
    // channel assignment 0001 -> independent 2ch, sample size 100 -> 16 bits, reserved=0
    // coded number: frame 0 (1 byte, 0x00)
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x49, 0x18, 0x00 };
    const crc = HeaderCrc.hash(&header_bytes);
    var reader: std.Io.Reader = .fixed(&(header_bytes ++ [_]u8{crc}));

    const header = try FrameHeader.read(&reader);
    try std.testing.expectEqual(BlockingStrategy.fixed, header.blocking_strategy);
    try std.testing.expectEqual(@as(u16, 2304), header.block_size);
    try std.testing.expectEqual(@as(?u32, 44_100), header.sample_rate);
    try std.testing.expectEqual(ChannelAssignment{ .independent = 2 }, header.channel_assignment);
    try std.testing.expectEqual(@as(?u6, 16), header.bits_per_sample);
    try std.testing.expectEqual(@as(u36, 0), header.coded_number);
}

test "FrameHeader.read parses extra block size and sample rate bytes" {
    // block size code 0111 -> 16-bit extra, sample rate code 1101 -> 16-bit extra (Hz)
    // channel assignment 1000 -> left/side, sample size 000 -> from STREAMINFO
    const header_bytes = [_]u8{
        0xff, 0xf9, 0x7d, 0x80,
        0x00, // frame number 0
        0x0f, 0xff, // block size - 1 = 4095 -> 4096
        0xac, 0x44, // sample rate = 44100
    };
    const crc = HeaderCrc.hash(&header_bytes);
    var reader: std.Io.Reader = .fixed(&(header_bytes ++ [_]u8{crc}));

    const header = try FrameHeader.read(&reader);
    try std.testing.expectEqual(BlockingStrategy.variable, header.blocking_strategy);
    try std.testing.expectEqual(@as(u16, 4096), header.block_size);
    try std.testing.expectEqual(@as(?u32, 44_100), header.sample_rate);
    try std.testing.expectEqual(ChannelAssignment.left_side, header.channel_assignment);
    try std.testing.expectEqual(@as(?u6, null), header.bits_per_sample);
}

test "FrameHeader.read rejects an invalid sync code" {
    var reader: std.Io.Reader = .fixed(&.{ 0x00, 0xf8, 0x49, 0x14, 0x00, 0x00 });
    try std.testing.expectError(error.InvalidSyncCode, FrameHeader.read(&reader));
}

test "FrameHeader.read rejects a reserved block size code" {
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x09, 0x14, 0x00 };
    const crc = HeaderCrc.hash(&header_bytes);
    var reader: std.Io.Reader = .fixed(&(header_bytes ++ [_]u8{crc}));
    try std.testing.expectError(error.ReservedBlockSize, FrameHeader.read(&reader));
}

test "FrameHeader.read rejects a CRC mismatch" {
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x49, 0x14, 0x00 };
    var reader: std.Io.Reader = .fixed(&(header_bytes ++ [_]u8{0x00}));
    try std.testing.expectError(error.CrcMismatch, FrameHeader.read(&reader));
}

test "FrameHeader.read rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed(&.{0xff});
    try std.testing.expectError(error.EndOfStream, FrameHeader.read(&reader));
}
