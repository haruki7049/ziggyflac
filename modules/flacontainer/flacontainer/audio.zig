const std = @import("std");

/// The CRC-8 algorithm used to protect a frame header (RFC 9639 Section 9.1.8):
/// polynomial 0x07, no reflection, initial value 0, no output XOR.
pub const HeaderCrc = std.hash.crc.Crc8Smbus;

/// The CRC-16 algorithm used to protect a whole frame (RFC 9639 Section 9.3):
/// polynomial 0x8005, no reflection, initial value 0, no output XOR.
pub const FooterCrc = std.hash.crc.Crc16Umts;

/// Compares an already-computed CRC (from `HeaderCrc.hash` or
/// `FooterCrc.hash`) against the value read from the stream, returning
/// `error.CrcMismatch` on a mismatch.
///
/// Callers must compute `expected` before reading any more bytes through the
/// same `RecordingByteSource`: appending to it can reallocate its backing
/// buffer, which would invalidate a byte slice captured earlier but hashed
/// only later.
fn verifyCrc(expected: anytype, actual: @TypeOf(expected)) error{CrcMismatch}!void {
    if (actual != expected) return error.CrcMismatch;
}

/// How a frame's block size relates to the value coded after the sync code
/// (RFC 9639 Section 9.1): whether the coded number is a frame number
/// (every frame has the same block size, except possibly the last) or a
/// sample number (frames may have varying block sizes).
pub const BlockingStrategy = enum(u1) {
    /// Fixed block size: the coded number is a frame number (Section 9.1.5).
    fixed = 0,
    /// Variable block size: the coded number is the number of the first sample.
    variable = 1,
};

/// The channel assignment of a frame (RFC 9639 Section 9.1.3).
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

    /// Encodes this assignment as the 4-bit channels code (RFC 9639 Section
    /// 9.1.3, Table 16): the inverse of `decode`.
    fn encode(self: ChannelAssignment) error{InvalidChannelCount}!u4 {
        return switch (self) {
            .independent => |count| if (count >= 1 and count <= 8) count - 1 else error.InvalidChannelCount,
            .left_side => 8,
            .right_side => 9,
            .mid_side => 10,
        };
    }

    /// The number of extra bits the subframe of `channel` is coded with: left/side,
    /// right/side and mid/side decorrelation store the side channel with one
    /// additional bit (RFC 9639 Section 9.2.3).
    fn extraBits(self: ChannelAssignment, channel: usize) u7 {
        return switch (self) {
            .left_side => if (channel == 1) 1 else 0,
            .right_side => if (channel == 0) 1 else 0,
            .mid_side => if (channel == 1) 1 else 0,
            .independent => 0,
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

    /// Frees the recorded bytes.
    pub fn deinit(self: *RecordingByteSource) void {
        self.recorded.deinit(self.allocator);
    }

    /// Errors returned by `takeByte`.
    pub const TakeByteError = std.Io.Reader.Error || std.mem.Allocator.Error;

    /// Reads one byte from the underlying reader and records it.
    pub fn takeByte(self: *RecordingByteSource) TakeByteError!u8 {
        const byte = try self.reader.takeByte();
        try self.recorded.append(self.allocator, byte);
        return byte;
    }
};

/// Reads individual bits, most-significant-bit first, from a `RecordingByteSource`.
pub const BitReader = struct {
    source: *RecordingByteSource,
    current_byte: u8 = 0,
    bits_remaining: u4 = 0,

    /// Errors returned by the reading methods.
    pub const Error = RecordingByteSource.TakeByteError;

    /// Reads one bit, fetching a new byte from `source` when the current one
    /// is used up.
    pub fn readBit(self: *BitReader) Error!u1 {
        if (self.bits_remaining == 0) {
            self.current_byte = try self.source.takeByte();
            self.bits_remaining = 8;
        }
        self.bits_remaining -= 1;
        return @intCast((self.current_byte >> @intCast(self.bits_remaining)) & 1);
    }

    /// Reads `n` bits (0-64) as an unsigned integer, consuming whole bytes at
    /// a time from `source` rather than one bit at a time.
    pub fn readBits(self: *BitReader, n: u7) Error!u64 {
        var value: u64 = 0;
        var remaining: u7 = n;
        while (remaining > 0) {
            if (self.bits_remaining == 0) {
                self.current_byte = try self.source.takeByte();
                self.bits_remaining = 8;
            }
            // Take the next `take` unconsumed bits: the top `take` bits of
            // the low `bits_remaining` bits of `current_byte`.
            const take: u4 = @intCast(@min(@as(u8, @intCast(remaining)), self.bits_remaining));
            const shift: u4 = self.bits_remaining - take;
            const mask: u8 = if (take == 8) 0xff else (@as(u8, 1) << @as(u3, @intCast(take))) - 1;
            const chunk: u8 = (self.current_byte >> @as(u3, @intCast(shift))) & mask;

            value = (value << take) | chunk;
            self.bits_remaining -= take;
            remaining -= take;
        }
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
    /// Skips whole runs of zero bits within a byte via `@clz` instead of
    /// checking one bit at a time.
    pub fn readUnary(self: *BitReader) Error!u32 {
        var count: u32 = 0;
        while (true) {
            if (self.bits_remaining == 0) {
                self.current_byte = try self.source.takeByte();
                self.bits_remaining = 8;
            }
            const window_width = self.bits_remaining;
            const mask: u8 = if (window_width == 8) 0xff else (@as(u8, 1) << @as(u3, @intCast(window_width))) - 1;
            const active = self.current_byte & mask;

            if (active == 0) {
                // No terminating 1 bit in the unconsumed part of this byte.
                count += window_width;
                self.bits_remaining = 0;
                continue;
            }

            const leading_in_byte = @clz(active);
            const zeros_in_window: u4 = leading_in_byte - (8 - window_width);
            count += zeros_in_window;
            self.bits_remaining -= zeros_in_window + 1; // also consume the terminating 1 bit
            return count;
        }
    }

    /// Discards any partially-read byte, aligning to the next byte boundary.
    pub fn alignToByte(self: *BitReader) void {
        self.bits_remaining = 0;
    }
};

/// Writes individual bits, most-significant-bit first, into a growable byte
/// buffer. This is the inverse of `BitReader`.
///
/// Whole bytes are appended to `bytes` as soon as they are complete. A
/// trailing partial byte is held back until `alignToByte` pads it with zero
/// bits (RFC 9639 Section 9.3), so callers must call `alignToByte` before
/// treating `bytes` as a finished byte sequence.
pub const BitWriter = struct {
    /// The buffer receiving completed bytes. Owned by the caller.
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    current_byte: u8 = 0,
    bits_filled: u4 = 0,

    /// Errors returned by the writing methods: only allocation can fail.
    pub const Error = std.mem.Allocator.Error;

    /// Writes one bit.
    pub fn writeBit(self: *BitWriter, bit: u1) Error!void {
        try self.writeBits(bit, 1);
    }

    /// Writes the low `n` bits (0-64) of `value`, most-significant bit first.
    /// Bits of `value` above the low `n` are ignored.
    pub fn writeBits(self: *BitWriter, value: u64, n: u7) Error!void {
        var remaining: u7 = n;
        while (remaining > 0) {
            const free: u4 = 8 - self.bits_filled;
            const take: u4 = @intCast(@min(remaining, free));
            // Take the next `take` bits below the ones already written.
            const shift: u6 = @intCast(remaining - take);
            const chunk: u16 = @intCast((value >> shift) & ((@as(u64, 1) << take) - 1));

            self.current_byte = @intCast((@as(u16, self.current_byte) << take) | chunk);
            self.bits_filled += take;
            remaining -= take;

            if (self.bits_filled == 8) {
                try self.bytes.append(self.allocator, self.current_byte);
                self.current_byte = 0;
                self.bits_filled = 0;
            }
        }
    }

    /// Writes the low `n` bits (1-64) of `value` as a two's-complement
    /// signed integer. `value` must be representable in `n` bits.
    pub fn writeSignedBits(self: *BitWriter, value: i64, n: u7) Error!void {
        try self.writeBits(@bitCast(value), n);
    }

    /// Writes a unary code: `count` 0 bits followed by a terminating 1 bit.
    pub fn writeUnary(self: *BitWriter, count: u64) Error!void {
        var zeros = count;
        while (zeros > 0) {
            const chunk: u7 = @intCast(@min(zeros, 64));
            try self.writeBits(0, chunk);
            zeros -= chunk;
        }
        try self.writeBit(1);
    }

    /// Pads any partially-written byte with zero bits up to the next byte
    /// boundary and appends it. Does nothing when already aligned.
    pub fn alignToByte(self: *BitWriter) Error!void {
        if (self.bits_filled == 0) return;
        try self.writeBits(0, 8 - @as(u7, self.bits_filled));
    }
};

/// The type of a subframe (RFC 9639 Section 9.2.1) and, where applicable, its
/// predictor order.
pub const SubframeType = union(enum) {
    /// CONSTANT: a single value repeated for the whole block (Section 9.2.3).
    constant,
    /// VERBATIM: every sample stored unencoded (Section 9.2.4).
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

    /// Encodes this type as the 6-bit subframe type code (RFC 9639 Section
    /// 9.2.1, Table 19): the inverse of `decode`.
    fn encode(self: SubframeType) error{InvalidPredictorOrder}!u6 {
        return switch (self) {
            .constant => 0,
            .verbatim => 1,
            .fixed => |order| if (order <= 4) 8 + @as(u6, order) else error.InvalidPredictorOrder,
            .lpc => |order| if (order >= 1 and order <= 32) 31 + order else error.InvalidPredictorOrder,
        };
    }
};

/// A subframe header (RFC 9639 Section 9.2.1).
pub const SubframeHeader = struct {
    subframe_type: SubframeType,
    /// Number of least-significant bits absent from every sample in this
    /// subframe (0 if none), per RFC 9639 Section 9.2.2.
    wasted_bits: u6,

    /// Errors returned by `read`.
    pub const ReadError = BitReader.Error || error{
        ReservedBit,
        ReservedSubframeType,
    };

    /// Reads a subframe header (RFC 9639 Section 9.2.1) from `bits`: the
    /// leading zero bit, the type code, and the wasted-bits flag followed, if
    /// set, by `wasted_bits - 1` in unary (Section 9.2.2).
    pub fn read(bits: *BitReader) ReadError!SubframeHeader {
        if (try bits.readBit() != 0) return error.ReservedBit;
        const subframe_type = try SubframeType.decode(@intCast(try bits.readBits(6)));
        var wasted_bits: u6 = 0;
        if (try bits.readBit() == 1) wasted_bits = @intCast(try bits.readUnary() + 1);
        return .{ .subframe_type = subframe_type, .wasted_bits = wasted_bits };
    }

    /// Errors returned by `write`.
    pub const WriteError = BitWriter.Error || error{
        /// A FIXED predictor order above 4, or an LPC order outside 1-32
        /// (RFC 9639 Section 9.2.1).
        InvalidPredictorOrder,
    };

    /// Writes this subframe header (RFC 9639 Section 9.2.1) to `bits`, the
    /// inverse of `read`: the leading zero bit, the type code, and the
    /// wasted-bits flag followed, if set, by `wasted_bits - 1` in unary
    /// (Section 9.2.2).
    pub fn write(self: SubframeHeader, bits: *BitWriter) WriteError!void {
        try bits.writeBit(0);
        try bits.writeBits(try self.subframe_type.encode(), 6);
        if (self.wasted_bits == 0) {
            try bits.writeBit(0);
        } else {
            try bits.writeBit(1);
            try bits.writeUnary(self.wasted_bits - 1);
        }
    }
};

/// The Rice-coded residual of a FIXED or LPC subframe (RFC 9639 Section 9.2.7).
pub const Residual = struct {
    /// Decoded residual values, owned by this `Residual` and freed by `deinit`.
    /// Not the final audio samples: the predictor has not been applied.
    values: []i32,
    /// The Rice parameter `write` codes `values` with. Only meaningful when
    /// building a `Residual` to write: `read` leaves it `null`, since a
    /// decoded residual may use a different parameter per partition.
    rice_parameter: ?u5 = null,

    /// Errors returned by `read`.
    pub const ReadError = BitReader.Error || std.mem.Allocator.Error || error{
        ReservedResidualCodingMethod,
    };

    /// Errors returned by `write`.
    pub const WriteError = BitWriter.Error || error{
        /// `rice_parameter` is `null` or above 30. The escape codes 0b1111
        /// (4-bit method) and 0b11111 (5-bit method) leave 14 and 30 as the
        /// largest usable parameters (RFC 9639 Section 9.2.7).
        InvalidRiceParameter,
        /// A value is outside the range every residual must fall in: the
        /// most negative 32-bit value, -2^31, and anything beyond it is
        /// forbidden (RFC 9639 Section 9.2.7.3).
        ResidualOutOfRange,
    };

    /// Writes this residual (RFC 9639 Section 9.2.7) to `bits` as a single
    /// Rice-coded partition (partition order 0), the inverse of `read` for
    /// that case. The 4-bit parameter coding method is used when
    /// `rice_parameter` is 14 or less, and the 5-bit method above that
    /// (Table 23). Escaped partitions are never written.
    ///
    /// On error, `bits` may hold a partial residual.
    pub fn write(self: Residual, bits: *BitWriter) WriteError!void {
        const parameter = self.rice_parameter orelse return error.InvalidRiceParameter;
        if (parameter > 30) return error.InvalidRiceParameter;

        const use_five_bit_parameter = parameter > 14;
        try bits.writeBits(@intFromBool(use_five_bit_parameter), 2);
        try bits.writeBits(0, 4); // partition order 0: one partition
        try bits.writeBits(parameter, if (use_five_bit_parameter) 5 else 4);

        for (self.values) |value| {
            const folded = try foldResidualValue(value);
            // Unary quotient, then the `parameter` low bits (Section 9.2.7.2).
            try bits.writeUnary(folded >> parameter);
            try bits.writeBits(folded, parameter);
        }
    }

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
            const escape_raw_bits: ?u7 = if (parameter == escape_parameter)
                @intCast(try bits.readBits(5))
            else
                null;
            const k: u7 = @intCast(parameter);

            var i: usize = 0;
            while (i < partition_samples) : (i += 1) {
                values[filled] = if (escape_raw_bits) |raw_bits|
                    try readEscapedValue(bits, raw_bits)
                else
                    try readRiceValue(bits, k);
                filled += 1;
            }
        }

        return .{ .values = values };
    }

    /// Frees `values`. `allocator` must be the one passed to `read`.
    pub fn deinit(self: Residual, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

/// Folds a signed residual value into the unsigned zigzag form that is Rice
/// coded (RFC 9639 Section 9.2.7.2): positive values are doubled, negative
/// values are multiplied by -2 and have 1 subtracted.
fn foldResidualValue(value: i32) error{ResidualOutOfRange}!u64 {
    if (value == std.math.minInt(i32)) return error.ResidualOutOfRange;
    const wide: i64 = value;
    return if (wide >= 0)
        @as(u64, @intCast(wide)) << 1
    else
        (@as(u64, @intCast(-wide)) << 1) - 1;
}

/// Reads one residual value stored as a raw `raw_bits`-wide signed integer
/// (the escape code for a partition whose Rice parameter equals the maximum
/// representable value, RFC 9639 Section 9.2.7).
fn readEscapedValue(bits: *BitReader, raw_bits: u7) BitReader.Error!i32 {
    return @intCast(try bits.readSignedBits(raw_bits));
}

/// Reads one Rice-coded residual value with parameter `k`: a unary quotient
/// followed by a `k`-bit remainder, folded into a signed integer
/// (RFC 9639 Section 9.2.7).
fn readRiceValue(bits: *BitReader, k: u7) BitReader.Error!i32 {
    const quotient = try bits.readUnary();
    const remainder = try bits.readBits(k);
    const folded = (@as(u64, quotient) << @intCast(k)) | remainder;
    return if (folded & 1 == 0)
        @intCast(folded >> 1)
    else
        @intCast(-@as(i64, @intCast((folded + 1) >> 1)));
}

/// A subframe body (RFC 9639 Section 9.2), decoded structurally: warmup
/// samples, LPC coefficients, and residual values are recovered as raw
/// integers, but the predictor is never applied, so these are not the final
/// audio samples. Reconstructing samples is the responsibility of the
/// higher-level `ziggyflac` module.
pub const SubframeBody = union(enum) {
    /// The one value of a CONSTANT subframe (RFC 9639 Section 9.2.3).
    constant: i64,
    /// Raw samples, owned by this body and freed by `deinit`.
    verbatim: []i64,
    /// A FIXED subframe (RFC 9639 Section 9.2.5): warmup samples and a residual.
    fixed: struct {
        /// Warmup samples, owned by this body and freed by `deinit`.
        warmup: []i64,
        /// The coded residual (RFC 9639 Section 9.2.7).
        residual: Residual,
    },
    /// An LPC subframe (RFC 9639 Section 9.2.6): warmup samples, quantized
    /// coefficients, and a residual.
    lpc: struct {
        /// Warmup samples, owned by this body and freed by `deinit`.
        warmup: []i64,
        /// Right shift applied to the prediction (RFC 9639 Section 9.2.6).
        qlp_shift: i6,
        /// QLP coefficients, owned by this body and freed by `deinit`.
        coefficients: []i64,
        /// The coded residual (RFC 9639 Section 9.2.7).
        residual: Residual,
    },

    /// Errors returned by `read`.
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

    /// Errors returned by `write`.
    pub const WriteError = BitWriter.Error || Residual.WriteError || error{
        /// The body kind has no writer yet: only VERBATIM and FIXED bodies
        /// can be written.
        UnsupportedSubframeType,
        /// The number of samples held by the body (warmup samples plus
        /// residual values for FIXED) differs from `block_size`.
        BlockSizeMismatch,
    };

    /// Writes this subframe body (RFC 9639 Sections 9.2.4 and 9.2.5) to
    /// `bits`, the inverse of `read`. `sample_width` is the width every
    /// verbatim or warmup sample is stored with (see `read`), and
    /// `block_size` the number of samples the body must account for. Only
    /// VERBATIM and FIXED bodies can be written; samples must fit
    /// `sample_width` bits, which is the caller's to guarantee. A FIXED
    /// body's residual is written with `Residual.write`.
    pub fn write(self: SubframeBody, bits: *BitWriter, sample_width: u7, block_size: u16) WriteError!void {
        switch (self) {
            .verbatim => |samples| {
                if (samples.len != block_size) return error.BlockSizeMismatch;
                for (samples) |sample| try bits.writeSignedBits(sample, sample_width);
            },
            .fixed => |fixed| {
                if (fixed.warmup.len + fixed.residual.values.len != block_size) return error.BlockSizeMismatch;
                for (fixed.warmup) |sample| try bits.writeSignedBits(sample, sample_width);
                try fixed.residual.write(bits);
            },
            .constant, .lpc => return error.UnsupportedSubframeType,
        }
    }

    /// Reads `order` warmup samples of a FIXED or LPC subframe (RFC 9639
    /// Sections 9.2.5 and 9.2.6), each `sample_width` bits wide and stored
    /// unencoded as described in Section 9.2.3.
    fn readWarmupSamples(bits: *BitReader, allocator: std.mem.Allocator, order: u6, sample_width: u7) ReadError![]i64 {
        const warmup = try allocator.alloc(i64, order);
        errdefer allocator.free(warmup);
        for (warmup) |*sample| sample.* = try bits.readSignedBits(sample_width);
        return warmup;
    }

    /// Frees whatever this body owns. `allocator` must be the one passed to `read`.
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
    /// The subframe header (RFC 9639 Section 9.2.1).
    header: SubframeHeader,
    /// The subframe body, which holds the samples or the predictor data.
    body: SubframeBody,

    /// Errors returned by `read`.
    pub const ReadError = SubframeHeader.ReadError || SubframeBody.ReadError;

    /// Reads a subframe (RFC 9639 Section 9.2) from `bits`: the header, then
    /// the body. `sample_width` is the bit depth of this channel in the frame,
    /// including the extra bit of a side channel (RFC 9639 Section 9.2.3) and
    /// before the subframe's wasted bits are removed. `block_size` is the
    /// number of samples in the frame. The returned subframe owns its body and
    /// must be freed with `deinit`.
    pub fn read(bits: *BitReader, allocator: std.mem.Allocator, sample_width: u7, block_size: u16) ReadError!Subframe {
        const header = try SubframeHeader.read(bits);
        const effective_width = sample_width - header.wasted_bits;
        const body = try SubframeBody.read(bits, allocator, header.subframe_type, effective_width, block_size);
        return .{ .header = header, .body = body };
    }

    /// Errors returned by `write`.
    pub const WriteError = SubframeHeader.WriteError || SubframeBody.WriteError || error{
        /// `header.subframe_type` does not describe `body`, or a FIXED
        /// body's warmup length differs from the predictor order.
        SubframeTypeMismatch,
        /// `header.wasted_bits` leaves no bits per sample (RFC 9639 Section 9.2.2).
        InvalidWastedBits,
    };

    /// Writes the subframe header followed by its body (RFC 9639 Section
    /// 9.2) to `bits`, the inverse of `read`. `sample_width` is the width of
    /// the subframe's samples before wasted bits are removed (see `read`).
    /// The body's samples must already have `header.wasted_bits` removed.
    pub fn write(self: Subframe, bits: *BitWriter, sample_width: u7, block_size: u16) WriteError!void {
        const matches = switch (self.body) {
            .constant => self.header.subframe_type == .constant,
            .verbatim => self.header.subframe_type == .verbatim,
            .fixed => |fixed| switch (self.header.subframe_type) {
                .fixed => |order| fixed.warmup.len == order,
                else => false,
            },
            .lpc => |lpc| switch (self.header.subframe_type) {
                .lpc => |order| lpc.warmup.len == order,
                else => false,
            },
        };
        if (!matches) return error.SubframeTypeMismatch;
        if (self.header.wasted_bits >= sample_width) return error.InvalidWastedBits;

        try self.header.write(bits);
        try self.body.write(bits, sample_width - self.header.wasted_bits, block_size);
    }

    /// Frees the body. `allocator` must be the one passed to `read`.
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
    pub const ReadError = RecordingByteSource.TakeByteError || error{
        InvalidSyncCode,
        ReservedBit,
        ReservedBlockSize,
        ReservedSampleRate,
        ReservedChannelAssignment,
        ReservedSampleSize,
        InvalidCodedNumber,
        CrcMismatch,
    };

    /// Reads and validates a frame header from `reader`, including its CRC-8.
    /// `allocator` backs a throwaway `RecordingByteSource` used only to
    /// gather the header's own bytes for the CRC-8 check.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!FrameHeader {
        var source = RecordingByteSource{ .reader = reader, .allocator = allocator };
        defer source.deinit();
        return readRecorded(&source);
    }

    /// Same as `read`, but reads through a shared `RecordingByteSource` so
    /// the header bytes also become part of a whole-frame CRC-16 (the header
    /// CRC-8 byte itself is included too, per RFC 9639 Section 9.3).
    pub fn readRecorded(source: *RecordingByteSource) ReadError!FrameHeader {
        const start = source.recorded.items.len;
        const header = try parseFields(source);
        // Compute the expected CRC now, before the next `takeByte` below can
        // reallocate `source.recorded` and invalidate a slice into it.
        const expected_crc = HeaderCrc.hash(source.recorded.items[start..]);
        const actual_crc = try source.takeByte();
        try verifyCrc(expected_crc, actual_crc);
        return header;
    }

    /// The frame sync code (RFC 9639 Section 9.1) spans the header's first
    /// byte and the top 6 bits of the second.
    const sync_byte_value: u8 = 0xff;
    const sync_bits_mask: u8 = 0xfc;
    const sync_bits_value: u8 = 0xf8;
    /// Reserved bit (must be 0) in the second header byte, just before the
    /// blocking-strategy bit.
    const reserved_flag_mask: u8 = 0b10;

    fn parseFields(source: *RecordingByteSource) ReadError!FrameHeader {
        const sync_byte = try source.takeByte();
        if (sync_byte != sync_byte_value) return error.InvalidSyncCode;

        const flags_byte = try source.takeByte();
        if (flags_byte & sync_bits_mask != sync_bits_value) return error.InvalidSyncCode;
        if (flags_byte & reserved_flag_mask != 0) return error.ReservedBit;
        const blocking_strategy: BlockingStrategy = @enumFromInt(@as(u1, @intCast(flags_byte & 0b1)));

        const size_rate_byte = try source.takeByte();
        const block_size_code: u4 = @intCast(size_rate_byte >> 4);
        const sample_rate_code: u4 = @intCast(size_rate_byte & 0x0f);

        const channel_sample_byte = try source.takeByte();
        const channel_assignment_bits: u4 = @intCast(channel_sample_byte >> 4);
        const sample_size_code: u3 = @intCast((channel_sample_byte >> 1) & 0x07);
        if (channel_sample_byte & 0b1 != 0) return error.ReservedBit;

        const channel_assignment = try ChannelAssignment.decode(channel_assignment_bits);
        const bits_per_sample = try decodeSampleSize(sample_size_code);
        const coded_number = try readCodedNumber(source);

        const block_size = switch (block_size_code) {
            0 => return error.ReservedBlockSize,
            1 => @as(u16, 192),
            2...5 => @as(u16, 576) << @as(u3, @intCast(block_size_code - 2)),
            6 => @as(u16, try source.takeByte()) + 1,
            7 => blk: {
                const high = try source.takeByte();
                const low = try source.takeByte();
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
            12 => @as(u32, try source.takeByte()) * 1_000,
            13 => blk: {
                const high = try source.takeByte();
                const low = try source.takeByte();
                break :blk @as(u32, high) << 8 | low;
            },
            14 => blk: {
                const high = try source.takeByte();
                const low = try source.takeByte();
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

    /// Decodes the header's 3-bit sample-size code into bits per sample, or
    /// `null` if it must be taken from STREAMINFO (RFC 9639 Section 9.1.4).
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

    /// Errors returned by `write`.
    pub const WriteError = BitWriter.Error || error{
        /// The block size is 0, which no block size code can express (RFC 9639
        /// Section 9.1.1).
        InvalidBlockSize,
        /// `sample_rate` has no dedicated sample rate code; pass `null` to
        /// refer to STREAMINFO instead (RFC 9639 Section 9.1.2). `write`
        /// never emits the uncommon sample rate codes.
        UnsupportedSampleRate,
        /// `bits_per_sample` has no dedicated bit depth code; pass `null` to
        /// refer to STREAMINFO instead (RFC 9639 Section 9.1.4).
        UnsupportedBitsPerSample,
        /// The channel count of an independent assignment is not in 1-8
        /// (RFC 9639 Section 9.1.3).
        InvalidChannelCount,
        /// `coded_number` does not fit the coded number encoding: 31 bits for
        /// a frame number (fixed blocking strategy) or 36 bits for a sample
        /// number (variable blocking strategy) (RFC 9639 Section 9.1.5).
        InvalidCodedNumber,
    };

    /// The 4-bit sample rate code (RFC 9639 Section 9.1.2, Table 15) of a
    /// sample rate that has a dedicated code, or `null` if it has none.
    pub fn sampleRateCode(sample_rate: u32) ?u4 {
        return switch (sample_rate) {
            88_200 => 1,
            176_400 => 2,
            192_000 => 3,
            8_000 => 4,
            16_000 => 5,
            22_050 => 6,
            24_000 => 7,
            32_000 => 8,
            44_100 => 9,
            48_000 => 10,
            96_000 => 11,
            else => null,
        };
    }

    /// The 3-bit bit depth code (RFC 9639 Section 9.1.4, Table 17) of a bit
    /// depth that has a dedicated code, or `null` if it has none.
    pub fn bitsPerSampleCode(bits_per_sample: u6) ?u3 {
        return switch (bits_per_sample) {
            8 => 1,
            12 => 2,
            16 => 4,
            20 => 5,
            24 => 6,
            32 => 7,
            else => null,
        };
    }

    /// Appends this frame header (RFC 9639 Section 9.1), including its
    /// trailing CRC-8 (Section 9.1.8), to `out`, the inverse of `read`.
    ///
    /// A block size without a dedicated code is written as an uncommon block
    /// size: 8 bits for sizes up to 256 and 16 bits above. A `null`
    /// `sample_rate` or `bits_per_sample` is written as the code that refers
    /// to STREAMINFO. Block sizes of 1-15 are only valid in the last frame of
    /// a stream (Section 9.1.6); that rule is the caller's to uphold.
    ///
    /// `out` already containing bytes is fine: only the bytes appended by this
    /// call are covered by the CRC-8. On error, `out` may hold a partial header.
    pub fn write(self: FrameHeader, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) WriteError!void {
        const start = out.items.len;
        var bits = BitWriter{ .bytes = out, .allocator = allocator };

        if (self.block_size == 0) return error.InvalidBlockSize;
        const block_size_code: u4 = switch (self.block_size) {
            192 => 1,
            576 => 2,
            1152 => 3,
            2304 => 4,
            4608 => 5,
            256 => 8,
            512 => 9,
            1024 => 10,
            2048 => 11,
            4096 => 12,
            8192 => 13,
            16384 => 14,
            32768 => 15,
            else => if (self.block_size <= 256) 6 else 7,
        };

        const sample_rate_code: u4 = if (self.sample_rate) |rate|
            sampleRateCode(rate) orelse return error.UnsupportedSampleRate
        else
            0;
        const sample_size_code: u3 = if (self.bits_per_sample) |depth|
            bitsPerSampleCode(depth) orelse return error.UnsupportedBitsPerSample
        else
            0;

        // Frame sync code (15 bits), then the blocking strategy bit.
        try bits.writeBits(0b111111111111100, 15);
        try bits.writeBit(@intFromEnum(self.blocking_strategy));
        try bits.writeBits(block_size_code, 4);
        try bits.writeBits(sample_rate_code, 4);
        try bits.writeBits(try self.channel_assignment.encode(), 4);
        try bits.writeBits(sample_size_code, 3);
        try bits.writeBit(0); // reserved

        const coded_number_limit: u36 = switch (self.blocking_strategy) {
            .fixed => std.math.maxInt(u31),
            .variable => std.math.maxInt(u36),
        };
        if (self.coded_number > coded_number_limit) return error.InvalidCodedNumber;
        try writeCodedNumber(&bits, self.coded_number);

        switch (block_size_code) {
            6 => try bits.writeBits(self.block_size - 1, 8),
            7 => try bits.writeBits(self.block_size - 1, 16),
            else => {},
        }

        // The header is a whole number of bytes at this point, so the CRC-8
        // covers exactly the bytes appended since `start`.
        try bits.writeBits(HeaderCrc.hash(out.items[start..]), 8);
    }
};

/// Writes `value` as the UTF-8-like variable-length coded number of RFC 9639
/// Section 9.1.5 (Table 18): 7 bits in 1 byte up to 36 bits in 7 bytes.
fn writeCodedNumber(bits: *BitWriter, value: u36) BitWriter.Error!void {
    const byte_count: u6 = if (value < 1 << 7)
        1
    else if (value < 1 << 11)
        2
    else if (value < 1 << 16)
        3
    else if (value < 1 << 21)
        4
    else if (value < 1 << 26)
        5
    else if (value < 1 << 31)
        6
    else
        7;

    if (byte_count == 1) return bits.writeBits(value, 8);

    // The first byte holds `byte_count` leading 1 bits, a 0 bit, and the
    // most significant payload bits; each continuation byte holds 10 and 6
    // payload bits. The 7-byte form's first byte (0xfe) holds no payload.
    const continuation_bytes = byte_count - 1;
    const leading_ones: u8 = ~(@as(u8, 0xff) >> @intCast(byte_count));
    const first_payload: u8 = if (byte_count == 7) 0 else @intCast(value >> (6 * @as(u6, continuation_bytes)));
    try bits.writeBits(leading_ones | first_payload, 8);

    var i: u6 = continuation_bytes;
    while (i > 0) {
        i -= 1;
        try bits.writeBits(0x80 | ((value >> (6 * i)) & 0x3f), 8);
    }
}

/// Reads the UTF-8-like variable-length coded number that follows a frame
/// header's fixed fields (RFC 9639 Section 9.1.5): 7 bits in 1 byte up to
/// 36 bits in 7 bytes.
fn readCodedNumber(source: *RecordingByteSource) FrameHeader.ReadError!u36 {
    const first = try source.takeByte();
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
        const continuation = try source.takeByte();
        if (continuation & 0xc0 != 0x80) return error.InvalidCodedNumber;
        value = (value << 6) | (continuation & 0x3f);
    }
    return value;
}

/// A full FLAC frame (RFC 9639 Section 9): header, one subframe per channel,
/// byte-alignment padding, and a CRC-16 footer.
pub const Frame = struct {
    /// The frame header (RFC 9639 Section 9.1).
    header: FrameHeader,
    /// One subframe per physical channel, owned by this `Frame` and freed by `deinit`.
    subframes: []Subframe,

    /// Errors returned by `read`.
    pub const ReadError = FrameHeader.ReadError || Subframe.ReadError || std.mem.Allocator.Error;

    /// Reads a whole frame from `reader`, given the stream's bits per sample
    /// (from STREAMINFO), which is used when the frame header does not encode
    /// its own. Verifies both the header's CRC-8 and the frame's CRC-16
    /// footer. The returned frame owns its subframes and must be freed with
    /// `deinit`.
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

        // Reserve capacity for the rest of the frame up front, so the
        // per-byte appends below don't repeatedly grow `source.recorded`.
        // This is only a hint: an unusually large residual can still exceed
        // it, and `RecordingByteSource.takeByte` grows the buffer safely
        // (never `appendAssumeCapacity`) if that happens, since a malformed
        // or adversarial frame must never be treated as undefined behavior.
        const estimated_body_bytes = (@as(usize, header.block_size) * channel_count * (@as(usize, bits_per_sample) + 1) + 7) / 8;
        try source.recorded.ensureTotalCapacity(allocator, source.recorded.items.len + estimated_body_bytes);

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
            const extra_bit = header.channel_assignment.extraBits(channel);
            subframes[filled] = try Subframe.read(&bit_reader, allocator, bits_per_sample + extra_bit, header.block_size);
            filled += 1;
        }

        bit_reader.alignToByte();

        const expected_crc = FooterCrc.hash(source.recorded.items);
        const actual_crc = try reader.takeInt(u16, .big);
        try verifyCrc(expected_crc, actual_crc);

        return .{ .header = header, .subframes = subframes };
    }

    /// Errors returned by `write`.
    pub const WriteError = FrameHeader.WriteError || Subframe.WriteError || error{
        /// The number of subframes differs from the header's channel assignment.
        ChannelCountMismatch,
    };

    /// Appends this whole frame (RFC 9639 Section 9) to `out`, the inverse
    /// of `read`: the header with its CRC-8, one subframe per channel, zero
    /// padding up to a byte boundary, and the CRC-16 footer (Section 9.3).
    /// `stream_bits_per_sample` is used when the header carries no bit depth
    /// of its own. See `Subframe.write` for what the subframes must hold.
    ///
    /// `out` already containing bytes is fine: only the bytes appended by
    /// this call are covered by the CRC-16. On error, `out` may hold a
    /// partial frame.
    pub fn write(
        self: Frame,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        stream_bits_per_sample: u6,
    ) WriteError!void {
        if (self.subframes.len != self.header.channel_assignment.channelCount()) return error.ChannelCountMismatch;

        const start = out.items.len;
        try self.header.write(allocator, out);

        const bits_per_sample = self.header.bits_per_sample orelse stream_bits_per_sample;
        var bits = BitWriter{ .bytes = out, .allocator = allocator };
        for (self.subframes, 0..) |subframe, channel| {
            const extra_bit = self.header.channel_assignment.extraBits(channel);
            try subframe.write(&bits, bits_per_sample + extra_bit, self.header.block_size);
        }
        try bits.alignToByte();

        try bits.writeBits(FooterCrc.hash(out.items[start..]), 16);
    }

    /// Frees `subframes` and what each subframe owns. `allocator` must be the
    /// one that allocated them (the one passed to `read`).
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

    const header = try FrameHeader.read(&reader, std.testing.allocator);
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

    const header = try FrameHeader.read(&reader, std.testing.allocator);
    try std.testing.expectEqual(BlockingStrategy.variable, header.blocking_strategy);
    try std.testing.expectEqual(@as(u16, 4096), header.block_size);
    try std.testing.expectEqual(@as(?u32, 44_100), header.sample_rate);
    try std.testing.expectEqual(ChannelAssignment.left_side, header.channel_assignment);
    try std.testing.expectEqual(@as(?u6, null), header.bits_per_sample);
}

test "FrameHeader.read rejects an invalid sync code" {
    var reader: std.Io.Reader = .fixed(&.{ 0x00, 0xf8, 0x49, 0x14, 0x00, 0x00 });
    try std.testing.expectError(error.InvalidSyncCode, FrameHeader.read(&reader, std.testing.allocator));
}

test "FrameHeader.read rejects a reserved block size code" {
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x09, 0x14, 0x00 };
    const crc = HeaderCrc.hash(&header_bytes);
    var reader: std.Io.Reader = .fixed(&(header_bytes ++ [_]u8{crc}));
    try std.testing.expectError(error.ReservedBlockSize, FrameHeader.read(&reader, std.testing.allocator));
}

test "FrameHeader.read rejects a CRC mismatch" {
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x49, 0x14, 0x00 };
    var reader: std.Io.Reader = .fixed(&(header_bytes ++ [_]u8{0x00}));
    try std.testing.expectError(error.CrcMismatch, FrameHeader.read(&reader, std.testing.allocator));
}

test "FrameHeader.read rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed(&.{0xff});
    try std.testing.expectError(error.EndOfStream, FrameHeader.read(&reader, std.testing.allocator));
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

test "BitReader.readBits spans multiple byte boundaries" {
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0xff, 0x00, 0xff });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    // 24 bits: 0xff 0x00 0xff, read in one call spanning all three bytes.
    try std.testing.expectEqual(@as(u64, 0xff00ff), try bits.readBits(24));
}

test "BitReader.readBits reads an unaligned span across two bytes" {
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0b0000_0111, 0b1000_0000 });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    _ = try bits.readBits(5); // discard the first 5 bits (00000)
    // Remaining: 111 from byte 1, then 1 from byte 2 -> 0b1111.
    try std.testing.expectEqual(@as(u64, 0b1111), try bits.readBits(4));
}

test "BitReader.readUnary counts zero bits across a whole zero byte" {
    var source = RecordingByteSource{
        .reader = &blk: {
            var r: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0b0000_0001 });
            break :blk r;
        },
        .allocator = std.testing.allocator,
    };
    defer source.deinit();
    var bits = BitReader{ .source = &source };

    // 16 zero bits from the first two bytes, then 7 more before the 1 bit.
    try std.testing.expectEqual(@as(u32, 23), try bits.readUnary());
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

test "BitWriter packs bits most-significant-bit first" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    try writer.writeBit(1);
    try writer.writeBits(0b01, 2);
    try writer.writeBits(0b10110, 5);
    try writer.writeBits(0xabc, 12);
    try writer.alignToByte();

    try std.testing.expectEqualSlices(u8, &.{ 0b1011_0110, 0xab, 0xc0 }, bytes.items);
}

test "BitWriter.alignToByte does nothing when already aligned" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    try writer.writeBits(0xff, 8);
    try writer.alignToByte();
    try std.testing.expectEqualSlices(u8, &.{0xff}, bytes.items);
}

test "BitWriter writes a unary code" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    try writer.writeUnary(0);
    try writer.writeUnary(3);
    try writer.writeUnary(70);
    try writer.alignToByte();

    // "1", "0001", then 70 zeros and a 1: 5 bits + 70 + 1 = 76 bits.
    var reader: std.Io.Reader = .fixed(bytes.items);
    var source = RecordingByteSource{ .reader = &reader, .allocator = std.testing.allocator };
    defer source.deinit();
    var bits = BitReader{ .source = &source };
    try std.testing.expectEqual(@as(u32, 0), try bits.readUnary());
    try std.testing.expectEqual(@as(u32, 3), try bits.readUnary());
    try std.testing.expectEqual(@as(u32, 70), try bits.readUnary());
}

test "BitWriter round-trips unsigned and signed values through BitReader" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    try writer.writeBits(5, 3);
    try writer.writeBits(std.math.maxInt(u64), 64);
    try writer.writeSignedBits(-1, 1);
    try writer.writeSignedBits(-123456, 20);
    try writer.writeSignedBits(std.math.minInt(i64), 64);
    try writer.writeBits(0, 0);
    try writer.alignToByte();

    var reader: std.Io.Reader = .fixed(bytes.items);
    var source = RecordingByteSource{ .reader = &reader, .allocator = std.testing.allocator };
    defer source.deinit();
    var bits = BitReader{ .source = &source };
    try std.testing.expectEqual(@as(u64, 5), try bits.readBits(3));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try bits.readBits(64));
    try std.testing.expectEqual(@as(i64, -1), try bits.readSignedBits(1));
    try std.testing.expectEqual(@as(i64, -123456), try bits.readSignedBits(20));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), try bits.readSignedBits(64));
}

test "FrameHeader.write matches a hand-assembled fixed-blocksize header" {
    // Same layout as the `FrameHeader.read` test: sync + fixed (0xff 0xf8),
    // block size code 0100 (2304) and sample rate code 1001 (44100),
    // independent 2ch (0001) and 16 bits (100), reserved 0, frame number 0.
    const header_bytes = [_]u8{ 0xff, 0xf8, 0x49, 0x18, 0x00 };
    const expected = header_bytes ++ [_]u8{HeaderCrc.hash(&header_bytes)};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try (FrameHeader{
        .blocking_strategy = .fixed,
        .block_size = 2304,
        .sample_rate = 44100,
        .channel_assignment = .{ .independent = 2 },
        .bits_per_sample = 16,
        .coded_number = 0,
    }).write(std.testing.allocator, &out);
    try std.testing.expectEqualSlices(u8, &expected, out.items);
}

test "FrameHeader.write emits uncommon block sizes and STREAMINFO references" {
    // Block size 100 -> code 0110 + 8-bit (100 - 1) after the coded number;
    // no dedicated sample rate or bit depth -> codes 0000 and 000;
    // 3 channels -> 0010; frame number 200 -> two coded-number bytes.
    const short = [_]u8{ 0xff, 0xf8, 0x60, 0x20, 0xc3, 0x88, 99 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try (FrameHeader{
        .blocking_strategy = .fixed,
        .block_size = 100,
        .sample_rate = null,
        .channel_assignment = .{ .independent = 3 },
        .bits_per_sample = null,
        .coded_number = 200,
    }).write(std.testing.allocator, &out);
    try std.testing.expectEqualSlices(u8, &(short ++ [_]u8{HeaderCrc.hash(&short)}), out.items);

    // Block size 1000 -> code 0111 + 16-bit (1000 - 1 = 0x03e7); 12 bits -> 010;
    // 8 channels -> 0111; sample rate 96000 -> 1011.
    const long = [_]u8{ 0xff, 0xf8, 0x7b, 0x74, 0x00, 0x03, 0xe7 };
    out.clearRetainingCapacity();
    try (FrameHeader{
        .blocking_strategy = .fixed,
        .block_size = 1000,
        .sample_rate = 96000,
        .channel_assignment = .{ .independent = 8 },
        .bits_per_sample = 12,
        .coded_number = 0,
    }).write(std.testing.allocator, &out);
    try std.testing.expectEqualSlices(u8, &(long ++ [_]u8{HeaderCrc.hash(&long)}), out.items);
}

test "FrameHeader.write round-trips every block size code through read" {
    const block_sizes = [_]u16{ 1, 15, 16, 100, 192, 255, 256, 257, 576, 1000, 1152, 2304, 4608, 4096, 8192, 16384, 32768, 65535 };
    for (block_sizes) |block_size| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const header = FrameHeader{
            .blocking_strategy = .fixed,
            .block_size = block_size,
            .sample_rate = 44100,
            .channel_assignment = .{ .independent = 1 },
            .bits_per_sample = 16,
            .coded_number = 3,
        };
        try header.write(std.testing.allocator, &out);

        var reader: std.Io.Reader = .fixed(out.items);
        const parsed = try FrameHeader.read(&reader, std.testing.allocator);
        try std.testing.expectEqual(header, parsed);
    }
}

test "FrameHeader.write round-trips every dedicated sample rate and bit depth" {
    const rates = [_]u32{ 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000 };
    const depths = [_]u6{ 8, 12, 16, 20, 24, 32 };
    for (rates) |rate| for (depths) |depth| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const header = FrameHeader{
            .blocking_strategy = .fixed,
            .block_size = 4096,
            .sample_rate = rate,
            .channel_assignment = .{ .independent = 2 },
            .bits_per_sample = depth,
            .coded_number = 0,
        };
        try header.write(std.testing.allocator, &out);
        var reader: std.Io.Reader = .fixed(out.items);
        try std.testing.expectEqual(header, try FrameHeader.read(&reader, std.testing.allocator));
    };
}

test "FrameHeader.write round-trips coded numbers of every length" {
    const numbers = [_]u36{ 0, 127, 128, 2047, 2048, 65535, 65536, 0x1fffff, 0x200000, 0x3ffffff, 0x4000000, 0x7fffffff, 0x80000000, 0xfffffffff };
    for (numbers) |number| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        const header = FrameHeader{
            .blocking_strategy = .variable,
            .block_size = 4096,
            .sample_rate = 44100,
            .channel_assignment = .mid_side,
            .bits_per_sample = 16,
            .coded_number = number,
        };
        try header.write(std.testing.allocator, &out);
        var reader: std.Io.Reader = .fixed(out.items);
        try std.testing.expectEqual(header, try FrameHeader.read(&reader, std.testing.allocator));
    }
}

test "FrameHeader.write rejects values the header cannot express" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const base = FrameHeader{
        .blocking_strategy = .fixed,
        .block_size = 4096,
        .sample_rate = 44100,
        .channel_assignment = .{ .independent = 2 },
        .bits_per_sample = 16,
        .coded_number = 0,
    };

    var header = base;
    header.block_size = 0;
    try std.testing.expectError(error.InvalidBlockSize, header.write(std.testing.allocator, &out));
    header = base;
    header.sample_rate = 12345;
    try std.testing.expectError(error.UnsupportedSampleRate, header.write(std.testing.allocator, &out));
    header = base;
    header.bits_per_sample = 9;
    try std.testing.expectError(error.UnsupportedBitsPerSample, header.write(std.testing.allocator, &out));
    header = base;
    header.channel_assignment = .{ .independent = 9 };
    try std.testing.expectError(error.InvalidChannelCount, header.write(std.testing.allocator, &out));
    header = base;
    header.coded_number = 0x80000000; // 32 bits: too big for a frame number
    try std.testing.expectError(error.InvalidCodedNumber, header.write(std.testing.allocator, &out));
    header.blocking_strategy = .variable; // but fine as a sample number
    try header.write(std.testing.allocator, &out);
}

test "SubframeHeader.write matches hand-assembled bytes and round-trips" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    // 0 | 000001 (VERBATIM) | 0 (no wasted bits)
    try (SubframeHeader{ .subframe_type = .verbatim, .wasted_bits = 0 }).write(&writer);
    // 0 | 001000 (FIXED order 0) | 1 + unary(2) = 001 (3 wasted bits)
    try (SubframeHeader{ .subframe_type = .{ .fixed = 0 }, .wasted_bits = 3 }).write(&writer);
    try writer.alignToByte();
    try std.testing.expectEqualSlices(u8, &.{ 0b0000_0010, 0b0001_0001, 0b0010_0000 }, bytes.items);

    var reader: std.Io.Reader = .fixed(bytes.items);
    var source = RecordingByteSource{ .reader = &reader, .allocator = std.testing.allocator };
    defer source.deinit();
    var bits = BitReader{ .source = &source };
    const first = try SubframeHeader.read(&bits);
    try std.testing.expectEqual(SubframeType.verbatim, first.subframe_type);
    const second = try SubframeHeader.read(&bits);
    try std.testing.expectEqual(SubframeType{ .fixed = 0 }, second.subframe_type);
    try std.testing.expectEqual(@as(u6, 3), second.wasted_bits);
}

test "SubframeHeader.write rejects predictor orders outside the format" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };
    try std.testing.expectError(error.InvalidPredictorOrder, (SubframeHeader{ .subframe_type = .{ .fixed = 5 }, .wasted_bits = 0 }).write(&writer));
    try std.testing.expectError(error.InvalidPredictorOrder, (SubframeHeader{ .subframe_type = .{ .lpc = 0 }, .wasted_bits = 0 }).write(&writer));
    try std.testing.expectError(error.InvalidPredictorOrder, (SubframeHeader{ .subframe_type = .{ .lpc = 33 }, .wasted_bits = 0 }).write(&writer));
}

test "Residual.write codes folded values with a Rice parameter, matching hand-assembled bits" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    // Values 0, -1, 2, 19 fold to 0, 1, 4, 38. With parameter 3:
    // 0 -> 1 000, 1 -> 1 001, 4 -> 1 100, 38 -> 00001 110 (RFC 9639 Section 9.2.7.2).
    var values = [_]i32{ 0, -1, 2, 19 };
    try (Residual{ .values = &values, .rice_parameter = 3 }).write(&writer);
    try writer.alignToByte();

    // Method 00, partition order 0000, parameter 0011, then the code words:
    // 00 0000 0011 | 1000 1001 1100 00001110 -> padded.
    try std.testing.expectEqualSlices(u8, &.{ 0b0000_0000, 0b1110_0010, 0b0111_0000, 0b0011_1000 }, bytes.items);
}

test "Residual.write round-trips through Residual.read for both parameter widths" {
    // Extreme values only go with large parameters: a small parameter would
    // turn them into a unary code billions of bits long.
    const small = [_]i32{ 0, 1, -1, 1000, -1000, 7 };
    const extreme = [_]i32{ 0, std.math.maxInt(i32), -std.math.maxInt(i32), 7 };
    const cases = [_]struct { parameter: u5, values: []const i32 }{
        .{ .parameter = 0, .values = &small },
        .{ .parameter = 1, .values = &small },
        .{ .parameter = 7, .values = &small },
        .{ .parameter = 14, .values = &small },
        .{ .parameter = 15, .values = &small },
        .{ .parameter = 22, .values = &extreme },
        .{ .parameter = 30, .values = &extreme },
    };
    for (cases) |case| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };
        const owned = try std.testing.allocator.dupe(i32, case.values);
        defer std.testing.allocator.free(owned);
        try (Residual{ .values = owned, .rice_parameter = case.parameter }).write(&writer);
        try writer.alignToByte();

        var reader: std.Io.Reader = .fixed(bytes.items);
        var source = RecordingByteSource{ .reader = &reader, .allocator = std.testing.allocator };
        defer source.deinit();
        var bits = BitReader{ .source = &source };
        const count: u16 = @intCast(case.values.len);
        const parsed = try Residual.read(&bits, std.testing.allocator, count, 0, count);
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(i32, case.values, parsed.values);
    }
}

test "Residual.write rejects a missing or oversized parameter and out-of-range values" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = BitWriter{ .bytes = &bytes, .allocator = std.testing.allocator };

    var values = [_]i32{1};
    try std.testing.expectError(error.InvalidRiceParameter, (Residual{ .values = &values }).write(&writer));
    try std.testing.expectError(error.InvalidRiceParameter, (Residual{ .values = &values, .rice_parameter = 31 }).write(&writer));
    values[0] = std.math.minInt(i32);
    try std.testing.expectError(error.ResidualOutOfRange, (Residual{ .values = &values, .rice_parameter = 3 }).write(&writer));
}

test "Frame.write produces a frame Frame.read parses, with both CRCs" {
    const allocator = std.testing.allocator;
    const header = FrameHeader{
        .blocking_strategy = .fixed,
        .block_size = 4,
        .sample_rate = null,
        .channel_assignment = .{ .independent = 2 },
        .bits_per_sample = null,
        .coded_number = 0,
    };

    var verbatim_samples = [_]i64{ 1, -2, 3, -4 };
    var residual_values = [_]i32{ 5, -6, 7, -8 };
    const subframes = [_]Subframe{
        .{
            .header = .{ .subframe_type = .verbatim, .wasted_bits = 0 },
            .body = .{ .verbatim = &verbatim_samples },
        },
        .{
            .header = .{ .subframe_type = .{ .fixed = 0 }, .wasted_bits = 0 },
            .body = .{ .fixed = .{
                .warmup = &.{},
                .residual = .{ .values = &residual_values, .rice_parameter = 2 },
            } },
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, 0x55); // pre-existing bytes must not affect the CRCs
    try (Frame{ .header = header, .subframes = @constCast(&subframes) }).write(allocator, &out, 8);

    var reader: std.Io.Reader = .fixed(out.items[1..]);
    const frame = try Frame.read(&reader, allocator, 8);
    defer frame.deinit(allocator);
    try std.testing.expectEqualSlices(i64, &verbatim_samples, frame.subframes[0].body.verbatim);
    try std.testing.expectEqualSlices(i32, &residual_values, frame.subframes[1].body.fixed.residual.values);
}

test "Frame.write rejects mismatched subframes" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var samples = [_]i64{ 1, 2, 3, 4 };
    const verbatim = Subframe{
        .header = .{ .subframe_type = .verbatim, .wasted_bits = 0 },
        .body = .{ .verbatim = &samples },
    };
    const header = FrameHeader{
        .blocking_strategy = .fixed,
        .block_size = 4,
        .sample_rate = null,
        .channel_assignment = .{ .independent = 2 },
        .bits_per_sample = null,
        .coded_number = 0,
    };

    var one = [_]Subframe{verbatim};
    try std.testing.expectError(error.ChannelCountMismatch, (Frame{ .header = header, .subframes = &one }).write(allocator, &out, 8));

    var mismatched = verbatim;
    mismatched.header.subframe_type = .{ .fixed = 1 };
    var scratch = BitWriter{ .bytes = &out, .allocator = allocator };
    try std.testing.expectError(error.SubframeTypeMismatch, mismatched.write(&scratch, 8, 4));

    var wasted = verbatim;
    wasted.header.wasted_bits = 8;
    var bits = BitWriter{ .bytes = &out, .allocator = allocator };
    try std.testing.expectError(error.InvalidWastedBits, wasted.write(&bits, 8, 4));
    try std.testing.expectError(error.BlockSizeMismatch, verbatim.write(&bits, 8, 5));
}
