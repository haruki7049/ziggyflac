const std = @import("std");

/// The CRC-8 algorithm used to protect a frame header (RFC 9639 Section 9.1.7):
/// polynomial 0x07, no reflection, initial value 0, no output XOR.
pub const HeaderCrc = std.hash.crc.Crc8Smbus;

/// The CRC-16 algorithm used to protect a whole frame (RFC 9639 Section 9.3):
/// polynomial 0x8005, no reflection, initial value 0, no output XOR.
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

    /// The number of channels physically present in the frame (before any
    /// mid/side or left/right/side decorrelation is undone).
    pub fn channelCount(self: ChannelAssignment) u4 {
        return switch (self) {
            .independent => |count| count,
            .left_side, .right_side, .mid_side => 2,
        };
    }
};

/// A byte source that records every byte read from the underlying
/// `std.Io.Reader` into a growable buffer, so the exact raw bytes of a frame
/// can be replayed into a CRC afterwards.
pub const RecordingByteSource = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    recorded: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *RecordingByteSource) void {
        self.recorded.deinit(self.allocator);
    }

    pub fn takeByte(self: *RecordingByteSource) std.Io.Reader.Error!u8 {
        const byte = try self.reader.takeByte();
        // Growing this buffer can only fail on OOM; a FLAC frame is always a
        // small, bounded amount of data, so treat allocation failure as fatal
        // rather than threading Allocator.Error through every bit read.
        self.recorded.append(self.allocator, byte) catch @panic("OutOfMemory");
        return byte;
    }
};

/// Reads individual bits, most-significant-bit first, from a `RecordingByteSource`.
pub const BitReader = struct {
    source: *RecordingByteSource,
    current_byte: u8 = 0,
    bits_remaining: u4 = 0,

    pub const Error = std.Io.Reader.Error;

    pub fn readBit(self: *BitReader) Error!u1 {
        if (self.bits_remaining == 0) {
            self.current_byte = try self.source.takeByte();
            self.bits_remaining = 8;
        }
        self.bits_remaining -= 1;
        return @intCast((self.current_byte >> @intCast(self.bits_remaining)) & 1);
    }

    /// Reads `n` bits (0-64) as an unsigned integer.
    pub fn readBits(self: *BitReader, n: u7) Error!u64 {
        var value: u64 = 0;
        var i: u7 = 0;
        while (i < n) : (i += 1) value = (value << 1) | try self.readBit();
        return value;
    }

    /// Reads `n` bits (1-64) as a two's-complement signed integer.
    pub fn readSignedBits(self: *BitReader, n: u7) Error!i64 {
        const raw = try self.readBits(n);
        const shift: u6 = @intCast(64 - n);
        const widened: i64 = @bitCast(raw << shift);
        return widened >> shift;
    }

    /// Reads a unary code: the number of 0 bits before the terminating 1 bit.
    pub fn readUnary(self: *BitReader) Error!u32 {
        var count: u32 = 0;
        while (try self.readBit() == 0) count += 1;
        return count;
    }

    /// Discards any partially-read byte, aligning to the next byte boundary.
    pub fn alignToByte(self: *BitReader) void {
        self.bits_remaining = 0;
    }
};

/// The type of a subframe (RFC 9639 Section 9.2.1) and, where applicable, its
/// predictor order.
pub const SubframeType = union(enum) {
    constant,
    verbatim,
    /// Fixed predictor order (0-4).
    fixed: u3,
    /// LPC predictor order (1-32).
    lpc: u6,

    fn decode(bits: u6) error{ReservedSubframeType}!SubframeType {
        if (bits == 0) return .constant;
        if (bits == 1) return .verbatim;
        if (bits & 0b111000 == 0b001000) {
            const order: u3 = @intCast(bits & 0b000111);
            if (order > 4) return error.ReservedSubframeType;
            return .{ .fixed = order };
        }
        if (bits & 0b100000 != 0) {
            const order: u6 = @intCast((bits & 0b011111) + 1);
            return .{ .lpc = order };
        }
        return error.ReservedSubframeType;
    }
};

/// A subframe header (RFC 9639 Section 9.2.1).
pub const SubframeHeader = struct {
    subframe_type: SubframeType,
    /// Number of least-significant bits absent from every sample in this
    /// subframe (0 if none), per RFC 9639 Section 9.2.5.
    wasted_bits: u6,

    pub const ReadError = BitReader.Error || error{
        ReservedBit,
        ReservedSubframeType,
    };

    pub fn read(bits: *BitReader) ReadError!SubframeHeader {
        if (try bits.readBit() != 0) return error.ReservedBit;
        const subframe_type = try SubframeType.decode(@intCast(try bits.readBits(6)));
        var wasted_bits: u6 = 0;
        if (try bits.readBit() == 1) wasted_bits = @intCast(try bits.readUnary() + 1);
        return .{ .subframe_type = subframe_type, .wasted_bits = wasted_bits };
    }
};

/// The Rice-coded residual of a FIXED or LPC subframe (RFC 9639 Section 9.2.7).
pub const Residual = struct {
    /// Decoded residual values, owned by this `Residual` and freed by `deinit`.
    /// Not the final audio samples: the predictor has not been applied.
    values: []i32,

    pub const ReadError = BitReader.Error || std.mem.Allocator.Error || error{
        ReservedResidualCodingMethod,
    };

    /// Reads the residual for `sample_count` values (`block_size - predictor_order`).
    pub fn read(
        bits: *BitReader,
        allocator: std.mem.Allocator,
        block_size: u16,
        predictor_order: u6,
        sample_count: usize,
    ) ReadError!Residual {
        const coding_method = try bits.readBits(2);
        const parameter_bits: u7 = switch (coding_method) {
            0 => 4,
            1 => 5,
            else => return error.ReservedResidualCodingMethod,
        };
        const escape_parameter: u64 = (@as(u64, 1) << @intCast(parameter_bits)) - 1;

        const partition_order: u5 = @intCast(try bits.readBits(4));
        const partition_count = @as(usize, 1) << partition_order;

        const values = try allocator.alloc(i32, sample_count);
        errdefer allocator.free(values);

        var filled: usize = 0;
        const shift: u4 = @intCast(partition_order);
        var partition: usize = 0;
        while (partition < partition_count) : (partition += 1) {
            const partition_samples: u16 = if (partition == 0)
                (block_size >> shift) - predictor_order
            else
                block_size >> shift;

            const parameter = try bits.readBits(parameter_bits);
            if (parameter == escape_parameter) {
                const raw_bits: u7 = @intCast(try bits.readBits(5));
                var i: usize = 0;
                while (i < partition_samples) : (i += 1) {
                    values[filled] = @intCast(try bits.readSignedBits(raw_bits));
                    filled += 1;
                }
            } else {
                const k: u7 = @intCast(parameter);
                var i: usize = 0;
                while (i < partition_samples) : (i += 1) {
                    const quotient = try bits.readUnary();
                    const remainder = try bits.readBits(k);
                    const folded = (@as(u64, quotient) << @intCast(k)) | remainder;
                    const value: i32 = if (folded & 1 == 0)
                        @intCast(folded >> 1)
                    else
                        @intCast(-@as(i64, @intCast((folded + 1) >> 1)));
                    values[filled] = value;
                    filled += 1;
                }
            }
        }

        return .{ .values = values };
    }

    pub fn deinit(self: Residual, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

/// A subframe body (RFC 9639 Section 9.2), decoded structurally: warmup
/// samples, LPC coefficients, and residual values are recovered as raw
/// integers, but the predictor is never applied, so these are not the final
/// audio samples. Reconstructing samples is the responsibility of the
/// higher-level `ziggyflac` module.
pub const SubframeBody = union(enum) {
    constant: i64,
    /// Raw samples, owned by this body and freed by `deinit`.
    verbatim: []i64,
    fixed: struct {
        /// Warmup samples, owned by this body and freed by `deinit`.
        warmup: []i64,
        residual: Residual,
    },
    lpc: struct {
        /// Warmup samples, owned by this body and freed by `deinit`.
        warmup: []i64,
        qlp_shift: i6,
        /// QLP coefficients, owned by this body and freed by `deinit`.
        coefficients: []i64,
        residual: Residual,
    },

    pub const ReadError = BitReader.Error || std.mem.Allocator.Error || Residual.ReadError;

    /// Reads a subframe body of the given `subframe_type` for a channel with
    /// the given `sample_width` (its bits-per-sample, already adjusted for
    /// side-channel decorrelation and reduced by any wasted bits) over
    /// `block_size` samples.
    pub fn read(
        bits: *BitReader,
        allocator: std.mem.Allocator,
        subframe_type: SubframeType,
        sample_width: u7,
        block_size: u16,
    ) ReadError!SubframeBody {
        return switch (subframe_type) {
            .constant => .{ .constant = try bits.readSignedBits(sample_width) },
            .verbatim => blk: {
                const samples = try allocator.alloc(i64, block_size);
                errdefer allocator.free(samples);
                for (samples) |*sample| sample.* = try bits.readSignedBits(sample_width);
                break :blk .{ .verbatim = samples };
            },
            .fixed => |order| blk: {
                const warmup = try readWarmupSamples(bits, allocator, order, sample_width);
                errdefer allocator.free(warmup);

                const residual = try Residual.read(bits, allocator, block_size, order, block_size - order);
                break :blk .{ .fixed = .{ .warmup = warmup, .residual = residual } };
            },
            .lpc => |order| blk: {
                const warmup = try readWarmupSamples(bits, allocator, order, sample_width);
                errdefer allocator.free(warmup);

                const qlp_precision: u5 = @intCast(try bits.readBits(4) + 1);
                const qlp_shift: i6 = @intCast(try bits.readSignedBits(5));

                const coefficients = try allocator.alloc(i64, order);
                errdefer allocator.free(coefficients);
                for (coefficients) |*coefficient| coefficient.* = try bits.readSignedBits(qlp_precision);

                const residual = try Residual.read(bits, allocator, block_size, order, block_size - order);
                break :blk .{ .lpc = .{
                    .warmup = warmup,
                    .qlp_shift = qlp_shift,
                    .coefficients = coefficients,
                    .residual = residual,
                } };
            },
        };
    }

    /// Reads `order` warmup samples (RFC 9639 Section 9.2.3/9.2.4), each
    /// `sample_width` bits wide.
    fn readWarmupSamples(bits: *BitReader, allocator: std.mem.Allocator, order: u6, sample_width: u7) ReadError![]i64 {
        const warmup = try allocator.alloc(i64, order);
        errdefer allocator.free(warmup);
        for (warmup) |*sample| sample.* = try bits.readSignedBits(sample_width);
        return warmup;
    }

    pub fn deinit(self: SubframeBody, allocator: std.mem.Allocator) void {
        switch (self) {
            .constant => {},
            .verbatim => |samples| allocator.free(samples),
            .fixed => |fixed| {
                allocator.free(fixed.warmup);
                fixed.residual.deinit(allocator);
            },
            .lpc => |lpc| {
                allocator.free(lpc.warmup);
                allocator.free(lpc.coefficients);
                lpc.residual.deinit(allocator);
            },
        }
    }
};

/// A full subframe: header plus body (RFC 9639 Section 9.2).
pub const Subframe = struct {
    header: SubframeHeader,
    body: SubframeBody,

    pub const ReadError = SubframeHeader.ReadError || SubframeBody.ReadError;

    pub fn read(bits: *BitReader, allocator: std.mem.Allocator, sample_width: u7, block_size: u16) ReadError!Subframe {
        const header = try SubframeHeader.read(bits);
        const effective_width = sample_width - header.wasted_bits;
        const body = try SubframeBody.read(bits, allocator, header.subframe_type, effective_width, block_size);
        return .{ .header = header, .body = body };
    }

    pub fn deinit(self: Subframe, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
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
        return readFromCollector(&collector, reader);
    }

    /// Same as `read`, but reads through a `RecordingByteSource` so the
    /// header bytes also become part of the whole-frame CRC-16.
    pub fn readRecorded(source: *RecordingByteSource) ReadError!FrameHeader {
        var collector = Collector{ .reader = source.reader };
        // Route every byte through `source` too, so it ends up recorded.
        // `Collector` already buffers its own copy for the header CRC-8; we
        // additionally mirror each byte into `source.recorded` here.
        return readFromCollectorRecording(&collector, source);
    }

    fn readFromCollector(collector: *Collector, reader: *std.Io.Reader) ReadError!FrameHeader {
        const header = try parseFields(collector);
        const expected_crc = HeaderCrc.hash(collector.bytes());
        const actual_crc = try reader.takeByte();
        if (actual_crc != expected_crc) return error.CrcMismatch;
        return header;
    }

    fn readFromCollectorRecording(collector: *Collector, source: *RecordingByteSource) ReadError!FrameHeader {
        const header = try parseFields(collector);
        for (collector.bytes()) |byte| {
            source.recorded.append(source.allocator, byte) catch @panic("OutOfMemory");
        }
        const expected_crc = HeaderCrc.hash(collector.bytes());
        const actual_crc = try source.takeByte();
        if (actual_crc != expected_crc) return error.CrcMismatch;
        return header;
    }

    fn parseFields(collector: *Collector) ReadError!FrameHeader {
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
        const coded_number = try readCodedNumber(collector);

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

/// A full FLAC frame (RFC 9639 Section 9): header, one subframe per channel,
/// byte-alignment padding, and a CRC-16 footer.
pub const Frame = struct {
    header: FrameHeader,
    /// One subframe per physical channel, owned by this `Frame` and freed by `deinit`.
    subframes: []Subframe,

    pub const ReadError = FrameHeader.ReadError || Subframe.ReadError || std.mem.Allocator.Error;

    /// Reads a whole frame from `reader`, given the stream's default sample
    /// rate and bits-per-sample (from STREAMINFO, used when the frame header
    /// does not encode its own). Verifies both the header's CRC-8 and the
    /// frame's CRC-16 footer.
    pub fn read(
        reader: *std.Io.Reader,
        allocator: std.mem.Allocator,
        stream_bits_per_sample: u6,
    ) ReadError!Frame {
        var source = RecordingByteSource{ .reader = reader, .allocator = allocator };
        defer source.deinit();

        const header = try FrameHeader.readRecorded(&source);
        const bits_per_sample = header.bits_per_sample orelse stream_bits_per_sample;
        const channel_count = header.channel_assignment.channelCount();

        const subframes = try allocator.alloc(Subframe, channel_count);
        var filled: usize = 0;
        errdefer {
            for (subframes[0..filled]) |subframe| subframe.deinit(allocator);
            allocator.free(subframes);
        }

        var bit_reader = BitReader{ .source = &source };
        var channel: usize = 0;
        while (channel < channel_count) : (channel += 1) {
            // Left/side and mid/side decorrelation store one channel with an
            // extra bit of width (RFC 9639 Section 9.2).
            const extra_bit: u7 = switch (header.channel_assignment) {
                .left_side => if (channel == 1) 1 else 0,
                .right_side => if (channel == 0) 1 else 0,
                .mid_side => if (channel == 1) 1 else 0,
                .independent => 0,
            };
            subframes[filled] = try Subframe.read(&bit_reader, allocator, bits_per_sample + extra_bit, header.block_size);
            filled += 1;
        }

        bit_reader.alignToByte();

        const expected_crc = FooterCrc.hash(source.recorded.items);
        const actual_crc = try reader.takeInt(u16, .big);
        if (actual_crc != expected_crc) return error.CrcMismatch;

        return .{ .header = header, .subframes = subframes };
    }

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        for (self.subframes) |subframe| subframe.deinit(allocator);
        allocator.free(self.subframes);
    }
};

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

test "BitReader reads bits, signed values, and unary codes MSB-first" {
    // 0b1011_0100, 0b1000_0000
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0b1011_0100, 0b1000_0000 });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    try std.testing.expectEqual(@as(u1, 1), try bits.readBit());
    try std.testing.expectEqual(@as(u64, 0b011), try bits.readBits(3));
    // Remaining in this byte: 0100 -> next is readSignedBits(4) of 0b0100 = 4.
    try std.testing.expectEqual(@as(i64, 4), try bits.readSignedBits(4));
    // Next byte is 0b1000_0000: unary code counts 0 zero bits (leading 1).
    try std.testing.expectEqual(@as(u32, 0), try bits.readUnary());
}

test "Subframe.read parses a CONSTANT subframe" {
    // header: 0 (pad) 000000 (constant) 0 (no wasted bits) = 0b00000000
    // value: 8-bit sample width, value 5 -> 0b00000101
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0b0000_0000, 0b0000_0101 });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    const subframe = try Subframe.read(&bits, std.testing.allocator, 8, 4);
    defer subframe.deinit(std.testing.allocator);

    try std.testing.expectEqual(SubframeType.constant, subframe.header.subframe_type);
    try std.testing.expectEqual(@as(i64, 5), subframe.body.constant);
}

test "Subframe.read parses a VERBATIM subframe" {
    // header: 0 000001 (verbatim) 0 = 0b00000010
    // 2 samples, 8-bit width: 0x7f, 0x80 (-128)
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0b0000_0010, 0x7f, 0x80 });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    const subframe = try Subframe.read(&bits, std.testing.allocator, 8, 2);
    defer subframe.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(i64, &.{ 127, -128 }, subframe.body.verbatim);
}

test "Subframe.read applies wasted bits to the effective sample width" {
    // byte1: 0(pad) 000000(constant) 1(has wasted bits) = 0x01
    // byte2: 1(unary stop, wasted_bits=0+1=1) then 7-bit value 0101000=40 = 0xa8
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0b0000_0001, 0b1010_1000 });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    const subframe = try Subframe.read(&bits, std.testing.allocator, 8, 4);
    defer subframe.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u6, 1), subframe.header.wasted_bits);
    // 7-bit effective width reads 0b0101000 = 40.
    try std.testing.expectEqual(@as(i64, 40), subframe.body.constant);
}

test "Frame.read parses a small fixed-order frame and verifies both CRCs" {
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x19, 0x18, 0x00 }; // fixed, 192 samples, 44100Hz, 2ch, 16bit
    const header_crc = HeaderCrc.hash(&header_bytes);

    // Two SUBFRAME_CONSTANT subframes (one per independent channel), value 0.
    // Each: 0b00000000 (header) followed by 16 zero bits (constant value 0).
    const subframe_bytes = [_]u8{ 0x00, 0x00, 0x00 } ++ [_]u8{ 0x00, 0x00, 0x00 };

    const frame_body = header_bytes ++ [_]u8{header_crc} ++ subframe_bytes;
    var body_with_crc: [frame_body.len + 2]u8 = undefined;
    @memcpy(body_with_crc[0..frame_body.len], &frame_body);
    const footer_crc = FooterCrc.hash(&frame_body);
    std.mem.writeInt(u16, body_with_crc[frame_body.len..][0..2], footer_crc, .big);

    var reader: std.Io.Reader = .fixed(&body_with_crc);
    const frame = try Frame.read(&reader, std.testing.allocator, 16);
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.subframes.len);
    try std.testing.expectEqual(@as(i64, 0), frame.subframes[0].body.constant);
    try std.testing.expectEqual(@as(i64, 0), frame.subframes[1].body.constant);
}
