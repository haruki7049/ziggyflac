const std = @import("std");
const flacontainer = @import("flacontainer");
const audio = flacontainer.audio;
const metadata = flacontainer.metadata;

/// How `encode` codes each subframe (RFC 9639 Section 9.2).
pub const SubframeMode = enum {
    /// Store every sample unencoded (Section 9.2.4). The simplest correct
    /// encoding: no residual coding, and no limit on sample values.
    verbatim,
    /// Use the FIXED predictor of order 0 (Section 9.2.5): the prediction is
    /// always 0, so the residual equals the samples, which are then Rice
    /// coded (Section 9.2.7). A block with a sample of -2^31 (reachable only
    /// at 32 bits per sample) is written as VERBATIM instead, because a
    /// residual may not take that value (Section 9.2.7.3).
    fixed0,
};

/// Which values `encode` puts into the STREAMINFO block (RFC 9639 Section 8.2).
pub const StreamInfoMode = enum {
    /// Fill in the minimum and maximum frame size, the total number of
    /// samples, and the MD5 signature of the unencoded audio.
    complete,
    /// Write 0 for the frame sizes and the total number of samples and an
    /// all-zero MD5 signature, which Section 8.2 defines as "not known".
    unknown,
};

/// Parameters of the stream `encode` writes.
pub const Options = struct {
    /// Sample rate in Hz. Must be in 1-1048575 (RFC 9639 Section 8.2).
    ///
    /// Only 8, 16, 22.05, 24, 32, 44.1, 48, 88.2, 96, 176.4, and 192 kHz have
    /// a dedicated frame header code (Section 9.1.2). Any other rate is
    /// written as a reference to STREAMINFO, which makes the stream fall
    /// outside the streamable subset (Section 7).
    sample_rate: u20,
    /// Bits per sample, 4-32 (RFC 9639 Section 8.2).
    ///
    /// Only 8, 12, 16, 20, 24, and 32 have a dedicated frame header code
    /// (Section 9.1.4). Any other depth is written as a reference to
    /// STREAMINFO, which makes the stream fall outside the streamable subset
    /// (Section 7).
    bits_per_sample: u6,
    /// The number of interchannel samples in every frame except the last,
    /// which holds the remainder and may be shorter. Must be in 16-65535
    /// (RFC 9639 Sections 4.1 and 8.2). Any value in that range is accepted.
    ///
    /// The streamable subset (Section 7) additionally requires at most 16384,
    /// and at most 4608 for sample rates up to 48000 Hz; a larger block size
    /// makes the stream fall outside it.
    block_size: u16 = 4096,
    /// How every subframe is coded.
    subframe_mode: SubframeMode,
    /// Which STREAMINFO values are filled in. There is deliberately no
    /// default: callers choose between `.complete` and `.unknown`.
    stream_info_mode: StreamInfoMode,
};

/// Errors returned by `encode`.
pub const EncodeError = std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    metadata.StreamInfo.WriteError ||
    audio.Frame.WriteError ||
    error{
        /// There are no channels, or more than 8 (RFC 9639 Section 8.2).
        InvalidChannelCount,
        /// `Options.bits_per_sample` is outside 4-32 (RFC 9639 Section 8.2).
        InvalidBitsPerSample,
        /// `Options.sample_rate` is 0, which is only allowed for non-audio
        /// (RFC 9639 Section 8.2).
        InvalidSampleRate,
        /// `Options.block_size` is below 16 (RFC 9639 Sections 4.1 and 8.2).
        InvalidBlockSize,
        /// The channels do not all hold the same number of samples.
        ChannelLengthMismatch,
        /// The channels hold no samples at all.
        EmptyStream,
        /// A sample does not fit `Options.bits_per_sample` as a signed integer.
        SampleOutOfRange,
        /// The stream has more samples than STREAMINFO's 36-bit total can
        /// count (RFC 9639 Section 8.2).
        TooManySamples,
        /// The stream has more frames than a frame number can count: a frame
        /// number is at most 31 bits (RFC 9639 Section 9.1.5).
        TooManyFrames,
        /// A frame is larger than STREAMINFO's 24-bit frame size can describe
        /// (RFC 9639 Section 8.2).
        FrameTooLarge,
    };

/// Encodes planar PCM `samples` as a complete FLAC stream and writes it to
/// `writer`: the `fLaC` marker, a STREAMINFO block, and the audio frames
/// (RFC 9639 Section 6). The stream has a fixed block size (Section 4.1),
/// independent channel assignment (Section 9.1.3), no wasted bits
/// (Section 9.2.2), and no metadata block other than STREAMINFO. Compression
/// is not a goal: the output is merely a correct stream that decodes to
/// exactly `samples`.
///
/// `samples[channel]` holds every sample of that channel across the whole
/// stream, in playback order, the same layout as `DecodedStream.samples`.
/// Every channel must hold the same number of samples, at least one.
///
/// The whole stream is encoded in memory (owned by `allocator`, and freed
/// before returning) and only then written, because STREAMINFO precedes the
/// frames but depends on them. `writer` therefore only ever receives
/// sequential writes, and may be a file, a socket, or a buffer alike. On an
/// error, `writer` may or may not have received data.
pub fn encode(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    samples: []const []const i64,
    options: Options,
) EncodeError!void {
    try validate(samples, options);

    const total_samples = samples[0].len;
    const block_size: usize = options.block_size;
    const frame_count = (total_samples + block_size - 1) / block_size;
    if (frame_count - 1 > std.math.maxInt(u31)) return error.TooManyFrames;

    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);

    var min_frame_size: usize = std.math.maxInt(usize);
    var max_frame_size: usize = 0;
    var start: usize = 0;
    var frame_number: u36 = 0;
    while (start < total_samples) : ({
        start += block_size;
        frame_number += 1;
    }) {
        const length = @min(block_size, total_samples - start);
        const frame_start = frames.items.len;
        try encodeFrame(allocator, &frames, samples, start, length, frame_number, options);

        const frame_size = frames.items.len - frame_start;
        min_frame_size = @min(min_frame_size, frame_size);
        max_frame_size = @max(max_frame_size, frame_size);
    }

    var stream_info = metadata.StreamInfo{
        .min_block_size = options.block_size,
        .max_block_size = options.block_size,
        .min_frame_size = 0,
        .max_frame_size = 0,
        .sample_rate = options.sample_rate,
        .channels = @intCast(samples.len),
        .bits_per_sample = options.bits_per_sample,
        .total_samples = 0,
        .md5_signature = .{0} ** 16,
    };
    switch (options.stream_info_mode) {
        .complete => {
            stream_info.min_frame_size = std.math.cast(u24, min_frame_size) orelse return error.FrameTooLarge;
            stream_info.max_frame_size = std.math.cast(u24, max_frame_size) orelse return error.FrameTooLarge;
            stream_info.total_samples = @intCast(total_samples);
            stream_info.md5_signature = md5Signature(samples, options.bits_per_sample);
        },
        .unknown => {},
    }

    try flacontainer.writeMarker(writer);
    try (metadata.Header{
        .is_last = true,
        .block_type = .stream_info,
        .length = metadata.StreamInfo.body_length,
    }).write(writer);
    try stream_info.write(writer);
    try writer.writeAll(frames.items);
}

/// Checks everything `encode` relies on before any output is produced.
fn validate(samples: []const []const i64, options: Options) EncodeError!void {
    if (samples.len < 1 or samples.len > 8) return error.InvalidChannelCount;
    if (options.bits_per_sample < 4 or options.bits_per_sample > 32) return error.InvalidBitsPerSample;
    if (options.sample_rate == 0) return error.InvalidSampleRate;
    if (options.block_size < 16) return error.InvalidBlockSize;

    const length = samples[0].len;
    for (samples) |channel| {
        if (channel.len != length) return error.ChannelLengthMismatch;
    }
    if (length == 0) return error.EmptyStream;
    if (length > std.math.maxInt(u36)) return error.TooManySamples;

    const limit: i64 = @as(i64, 1) << @intCast(options.bits_per_sample - 1);
    for (samples) |channel| {
        for (channel) |sample| {
            if (sample < -limit or sample >= limit) return error.SampleOutOfRange;
        }
    }
}

/// Appends the frame holding `length` samples from index `start` of every
/// channel to `out`.
fn encodeFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    samples: []const []const i64,
    start: usize,
    length: usize,
    frame_number: u36,
    options: Options,
) EncodeError!void {
    const subframes = try allocator.alloc(audio.Subframe, samples.len);
    var built: usize = 0;
    defer {
        for (subframes[0..built]) |subframe| subframe.deinit(allocator);
        allocator.free(subframes);
    }
    for (samples) |channel| {
        subframes[built] = try buildSubframe(allocator, channel[start..][0..length], options.subframe_mode);
        built += 1;
    }

    const frame = audio.Frame{
        .header = .{
            .blocking_strategy = .fixed,
            .block_size = @intCast(length),
            // Rates and depths without a dedicated code refer to STREAMINFO.
            .sample_rate = if (audio.FrameHeader.sampleRateCode(options.sample_rate) != null) options.sample_rate else null,
            .channel_assignment = .{ .independent = @intCast(samples.len) },
            .bits_per_sample = if (audio.FrameHeader.bitsPerSampleCode(options.bits_per_sample) != null) options.bits_per_sample else null,
            .coded_number = frame_number,
        },
        .subframes = subframes,
    };
    try frame.write(allocator, out, options.bits_per_sample);
}

/// Builds the subframe for one channel's `block` of samples. The returned
/// subframe owns its memory, freed by `Subframe.deinit` with `allocator`.
fn buildSubframe(allocator: std.mem.Allocator, block: []const i64, mode: SubframeMode) EncodeError!audio.Subframe {
    if (mode == .fixed0 and fitsResidualRange(block)) {
        const values = try allocator.alloc(i32, block.len);
        errdefer allocator.free(values);
        for (values, block) |*value, sample| value.* = @intCast(sample);

        // FIXED order 0 has no warmup samples (Section 9.2.5).
        const warmup = try allocator.alloc(i64, 0);
        return .{
            .header = .{ .subframe_type = .{ .fixed = 0 }, .wasted_bits = 0 },
            .body = .{ .fixed = .{
                .warmup = warmup,
                .residual = .{ .values = values, .rice_parameter = riceParameter(values) },
            } },
        };
    }

    return .{
        .header = .{ .subframe_type = .verbatim, .wasted_bits = 0 },
        .body = .{ .verbatim = try allocator.dupe(i64, block) },
    };
}

/// Whether every sample of `block` is usable as a residual value as is:
/// a residual must fit a 32-bit signed integer, excluding its most negative
/// value (RFC 9639 Section 9.2.7.3).
fn fitsResidualRange(block: []const i64) bool {
    for (block) |sample| {
        if (sample <= std.math.minInt(i32) or sample > std.math.maxInt(i32)) return false;
    }
    return true;
}

/// The largest Rice parameter the 5-bit parameter coding method can carry
/// (RFC 9639 Section 9.2.7): 0b11111 is reserved as the escape code.
const max_rice_parameter = 30;

/// Chooses the Rice parameter (RFC 9639 Section 9.2.7.2) that makes the
/// Rice-coded `values` shortest, among 0 to 30. A value costs its folded
/// magnitude shifted right by the parameter (the unary part), plus 1 bit
/// for the unary terminator, plus the parameter itself (the remainder), so
/// the cost of every parameter is computed in a single pass. The smallest
/// parameter wins a tie. `values` must not contain -2^31.
pub fn riceParameter(values: []const i32) u5 {
    var costs = [_]u64{0} ** (max_rice_parameter + 1);
    for (values) |value| {
        const wide: i64 = value;
        const folded: u64 = if (wide >= 0)
            @as(u64, @intCast(wide)) << 1
        else
            (@as(u64, @intCast(-wide)) << 1) - 1;
        for (&costs, 0..) |*cost, parameter| {
            cost.* += (folded >> @intCast(parameter)) + 1 + parameter;
        }
    }

    var best: u5 = 0;
    for (costs, 0..) |cost, parameter| {
        if (cost < costs[best]) best = @intCast(parameter);
    }
    return best;
}

/// The MD5 signature of the unencoded audio (RFC 9639 Section 8.2): the MD5
/// of every sample of every channel, interleaved sample by sample, each as a
/// signed little-endian integer sign-extended to a whole number of bytes.
fn md5Signature(samples: []const []const i64, bits_per_sample: u6) [16]u8 {
    var hasher = std.crypto.hash.Md5.init(.{});
    const bytes_per_sample: usize = (@as(usize, bits_per_sample) + 7) / 8;

    var buffer: [4096]u8 = undefined;
    var used: usize = 0;
    for (0..samples[0].len) |index| {
        for (samples) |channel| {
            if (used + bytes_per_sample > buffer.len) {
                hasher.update(buffer[0..used]);
                used = 0;
            }
            // `i64` is sign-extended, so its low bytes are the sample's
            // two's complement at any width.
            const bits: u64 = @bitCast(channel[index]);
            for (0..bytes_per_sample) |byte| {
                buffer[used] = @truncate(bits >> @intCast(8 * byte));
                used += 1;
            }
        }
    }
    hasher.update(buffer[0..used]);

    var signature: [16]u8 = undefined;
    hasher.final(&signature);
    return signature;
}

const stream_module = @import("./stream.zig");

/// Pseudo-random planar samples spanning the whole range of
/// `bits_per_sample`, with the minimum and the maximum placed first.
/// Owned by the caller; free with `freeSamples`.
fn generateSamples(allocator: std.mem.Allocator, channels: usize, length: usize, bits_per_sample: u6, seed: u64) ![][]i64 {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const limit: i64 = @as(i64, 1) << @intCast(bits_per_sample - 1);

    const samples = try allocator.alloc([]i64, channels);
    var built: usize = 0;
    errdefer {
        for (samples[0..built]) |channel| allocator.free(channel);
        allocator.free(samples);
    }
    for (samples) |*channel| {
        channel.* = try allocator.alloc(i64, length);
        built += 1;
        for (channel.*) |*sample| sample.* = random.intRangeAtMost(i64, -limit, limit - 1);
        if (length > 0) channel.*[0] = -limit;
        if (length > 1) channel.*[1] = limit - 1;
    }
    return samples;
}

fn freeSamples(allocator: std.mem.Allocator, samples: [][]i64) void {
    for (samples) |channel| allocator.free(channel);
    allocator.free(samples);
}

/// Encodes `samples` into a freshly allocated byte slice.
fn encodeToBytes(allocator: std.mem.Allocator, samples: []const []const i64, options: Options) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();
    try encode(allocator, &buffer.writer, samples, options);
    return buffer.toOwnedSlice();
}

/// Encodes `samples`, parses the result with this repository's own reader,
/// decodes it, and expects the original samples back unchanged.
fn expectRoundTrip(samples: []const []const i64, options: Options) !void {
    const allocator = std.testing.allocator;
    const bytes = try encodeToBytes(allocator, samples, options);
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const container_stream = try flacontainer.Stream.read(&reader, allocator);
    defer container_stream.deinit(allocator);
    const decoded = try stream_module.decode(allocator, container_stream);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(options.sample_rate, decoded.sample_rate);
    try std.testing.expectEqual(options.bits_per_sample, decoded.bits_per_sample);
    try std.testing.expectEqual(samples.len, decoded.samples.len);
    for (samples, decoded.samples) |expected, actual| {
        try std.testing.expectEqualSlices(i64, expected, actual);
    }
}

const both_modes = [_]SubframeMode{ .verbatim, .fixed0 };

test "encode round-trips every bit depth at its extreme values, in both subframe modes" {
    // 4 and 9 have no dedicated frame header code; 8, 12, 16, 20, 24, and 32 do.
    for ([_]u6{ 4, 8, 9, 12, 16, 20, 24, 31, 32 }) |bits_per_sample| {
        for (both_modes) |mode| {
            const samples = try generateSamples(std.testing.allocator, 2, 150, bits_per_sample, bits_per_sample);
            defer freeSamples(std.testing.allocator, samples);
            try expectRoundTrip(@ptrCast(samples), .{
                .sample_rate = 44100,
                .bits_per_sample = bits_per_sample,
                .block_size = 64,
                .subframe_mode = mode,
                .stream_info_mode = .complete,
            });
        }
    }
}

test "encode round-trips every block size code and a last frame of any length" {
    // 192 is the dedicated code 0001, 576 and 4608 are in 0010-0101, 256 and
    // 4096 are in 1000-1111, 16, 100, and 255 use the 8-bit uncommon size,
    // and 300, 1000, and 65535 use the 16-bit one.
    const block_sizes = [_]u16{ 16, 100, 192, 255, 256, 300, 576, 1000, 4096, 4608, 65535 };
    // A last frame of 1-15 samples is below the minimum block size and is
    // only allowed because it is the last one (RFC 9639 Section 9.1.6).
    const remainders = [_]usize{ 1, 15, 16, 17 };
    for (block_sizes) |block_size| {
        for (remainders) |remainder| {
            for (both_modes) |mode| {
                const length = 2 * @as(usize, block_size) + remainder;
                const samples = try generateSamples(std.testing.allocator, 1, length, 8, block_size + remainder);
                defer freeSamples(std.testing.allocator, samples);
                try expectRoundTrip(@ptrCast(samples), .{
                    .sample_rate = 8000,
                    .bits_per_sample = 8,
                    .block_size = block_size,
                    .subframe_mode = mode,
                    .stream_info_mode = .complete,
                });
            }
        }
    }
}

test "encode round-trips a stream shorter than one block" {
    for ([_]usize{ 1, 5, 15, 16, 100 }) |length| {
        for (both_modes) |mode| {
            const samples = try generateSamples(std.testing.allocator, 2, length, 16, length);
            defer freeSamples(std.testing.allocator, samples);
            try expectRoundTrip(@ptrCast(samples), .{
                .sample_rate = 44100,
                .bits_per_sample = 16,
                .subframe_mode = mode,
                .stream_info_mode = .complete,
            });
        }
    }
}

test "encode round-trips one to eight channels" {
    var channels: usize = 1;
    while (channels <= 8) : (channels += 1) {
        for (both_modes) |mode| {
            const samples = try generateSamples(std.testing.allocator, channels, 100, 16, channels);
            defer freeSamples(std.testing.allocator, samples);
            try expectRoundTrip(@ptrCast(samples), .{
                .sample_rate = 48000,
                .bits_per_sample = 16,
                .block_size = 32,
                .subframe_mode = mode,
                .stream_info_mode = .complete,
            });
        }
    }
}

test "encode round-trips sample rates with and without a dedicated code" {
    const rates = [_]u20{ 8000, 11025, 12345, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 1, 1048575 };
    for (rates) |rate| {
        const samples = try generateSamples(std.testing.allocator, 1, 40, 16, rate);
        defer freeSamples(std.testing.allocator, samples);
        try expectRoundTrip(@ptrCast(samples), .{
            .sample_rate = rate,
            .bits_per_sample = 16,
            .block_size = 16,
            .subframe_mode = .fixed0,
            .stream_info_mode = .unknown,
        });
    }
}

test "encode refers to STREAMINFO only for rates and depths without a dedicated code" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { rate: u20, depth: u6 }{
        .{ .rate = 44100, .depth = 16 },
        .{ .rate = 12345, .depth = 16 },
        .{ .rate = 44100, .depth = 9 },
    };
    for (cases) |case| {
        const samples = try generateSamples(allocator, 1, 20, case.depth, 1);
        defer freeSamples(allocator, samples);
        const bytes = try encodeToBytes(allocator, @ptrCast(samples), .{
            .sample_rate = case.rate,
            .bits_per_sample = case.depth,
            .subframe_mode = .verbatim,
            .stream_info_mode = .complete,
        });
        defer allocator.free(bytes);
        var reader: std.Io.Reader = .fixed(bytes);
        const parsed = try flacontainer.Stream.read(&reader, allocator);
        defer parsed.deinit(allocator);

        const header = parsed.frames[0].header;
        try std.testing.expectEqual(audio.FrameHeader.sampleRateCode(case.rate) != null, header.sample_rate != null);
        try std.testing.expectEqual(audio.FrameHeader.bitsPerSampleCode(case.depth) != null, header.bits_per_sample != null);
    }
}

test "encode numbers frames from 0 and gives only the last one a shorter block" {
    const allocator = std.testing.allocator;
    const samples = try generateSamples(allocator, 1, 3 * 32 + 5, 16, 7);
    defer freeSamples(allocator, samples);
    const bytes = try encodeToBytes(allocator, @ptrCast(samples), .{
        .sample_rate = 44100,
        .bits_per_sample = 16,
        .block_size = 32,
        .subframe_mode = .verbatim,
        .stream_info_mode = .complete,
    });
    defer allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try flacontainer.Stream.read(&reader, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), parsed.frames.len);
    for (parsed.frames, 0..) |frame, index| {
        try std.testing.expectEqual(audio.BlockingStrategy.fixed, frame.header.blocking_strategy);
        try std.testing.expectEqual(@as(u36, @intCast(index)), frame.header.coded_number);
        try std.testing.expectEqual(@as(u16, if (index < 3) 32 else 5), frame.header.block_size);
        try std.testing.expectEqual(audio.ChannelAssignment{ .independent = 1 }, frame.header.channel_assignment);
    }
}

test "encode in complete mode writes the true STREAMINFO values" {
    const allocator = std.testing.allocator;
    // 8-bit mono VERBATIM frames: 2 full frames of 20 samples and a last
    // one of 7, so the frame sizes are known exactly from the byte count.
    const samples = try generateSamples(allocator, 1, 47, 8, 3);
    defer freeSamples(allocator, samples);
    const bytes = try encodeToBytes(allocator, @ptrCast(samples), .{
        .sample_rate = 22050,
        .bits_per_sample = 8,
        .block_size = 20,
        .subframe_mode = .verbatim,
        .stream_info_mode = .complete,
    });
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try flacontainer.Stream.read(&reader, allocator);
    defer parsed.deinit(allocator);
    const info = parsed.stream_info;

    try std.testing.expectEqual(@as(u16, 20), info.min_block_size);
    try std.testing.expectEqual(@as(u16, 20), info.max_block_size);
    try std.testing.expectEqual(@as(u20, 22050), info.sample_rate);
    try std.testing.expectEqual(@as(u4, 1), info.channels);
    try std.testing.expectEqual(@as(u6, 8), info.bits_per_sample);
    try std.testing.expectEqual(@as(u36, 47), info.total_samples);

    // marker (4) + metadata header (4) + STREAMINFO (34), then the frames.
    const frame_bytes = bytes.len - 42;
    try std.testing.expect(info.min_frame_size < info.max_frame_size);
    try std.testing.expectEqual(frame_bytes, 2 * @as(usize, info.max_frame_size) + info.min_frame_size);
    try std.testing.expect(!std.mem.allEqual(u8, &info.md5_signature, 0));
}

test "encode in unknown mode writes 0 for what Section 8.2 allows to be unknown" {
    const allocator = std.testing.allocator;
    const samples = try generateSamples(allocator, 2, 47, 16, 3);
    defer freeSamples(allocator, samples);
    const bytes = try encodeToBytes(allocator, @ptrCast(samples), .{
        .sample_rate = 44100,
        .bits_per_sample = 16,
        .block_size = 20,
        .subframe_mode = .fixed0,
        .stream_info_mode = .unknown,
    });
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try flacontainer.Stream.read(&reader, allocator);
    defer parsed.deinit(allocator);
    const info = parsed.stream_info;

    // The block sizes are always known, and may not be 0 (Section 8.2).
    try std.testing.expectEqual(@as(u16, 20), info.min_block_size);
    try std.testing.expectEqual(@as(u16, 20), info.max_block_size);
    try std.testing.expectEqual(@as(u24, 0), info.min_frame_size);
    try std.testing.expectEqual(@as(u24, 0), info.max_frame_size);
    try std.testing.expectEqual(@as(u36, 0), info.total_samples);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), &info.md5_signature);
}

test "encode computes the same MD5 signature as libFLAC for real files" {
    // The reference signatures come from files written by libFLAC, so this
    // checks the byte layout of Section 8.2 independently of this encoder.
    const fixtures = [_][]const u8{
        @embedFile("../testdata/tiny.flac"),
        @embedFile("../testdata/bitdepth8.flac"),
        @embedFile("../testdata/bitdepth24.flac"),
        @embedFile("../testdata/bitdepth32.flac"),
        @embedFile("../testdata/stereo.flac"),
        @embedFile("../testdata/channels8.flac"),
        @embedFile("../testdata/clipping.flac"),
        @embedFile("../testdata/midside.flac"),
    };
    const allocator = std.testing.allocator;
    for (fixtures) |flac_bytes| {
        var reader: std.Io.Reader = .fixed(flac_bytes);
        const original = try flacontainer.Stream.read(&reader, allocator);
        defer original.deinit(allocator);
        const decoded = try stream_module.decode(allocator, original);
        defer decoded.deinit(allocator);
        try std.testing.expect(!std.mem.allEqual(u8, &original.stream_info.md5_signature, 0));

        const bytes = try encodeToBytes(allocator, @ptrCast(decoded.samples), .{
            .sample_rate = decoded.sample_rate,
            .bits_per_sample = decoded.bits_per_sample,
            .subframe_mode = .fixed0,
            .stream_info_mode = .complete,
        });
        defer allocator.free(bytes);
        var reencoded_reader: std.Io.Reader = .fixed(bytes);
        const reencoded = try flacontainer.Stream.read(&reencoded_reader, allocator);
        defer reencoded.deinit(allocator);

        try std.testing.expectEqualSlices(u8, &original.stream_info.md5_signature, &reencoded.stream_info.md5_signature);
        try std.testing.expectEqual(original.stream_info.total_samples, reencoded.stream_info.total_samples);
    }
}

test "encode round-trips real files decoded from libFLAC output, in both modes" {
    const fixtures = [_][]const u8{
        @embedFile("../testdata/tiny.flac"),
        @embedFile("../testdata/stereo.flac"),
        @embedFile("../testdata/bitdepth24.flac"),
        @embedFile("../testdata/bitdepth32.flac"),
        @embedFile("../testdata/multichannel.flac"),
        @embedFile("../testdata/lpcorder6.flac"),
        @embedFile("../testdata/silence.flac"),
    };
    const allocator = std.testing.allocator;
    for (fixtures) |flac_bytes| {
        var reader: std.Io.Reader = .fixed(flac_bytes);
        const original = try flacontainer.Stream.read(&reader, allocator);
        defer original.deinit(allocator);
        const decoded = try stream_module.decode(allocator, original);
        defer decoded.deinit(allocator);

        for (both_modes) |mode| {
            try expectRoundTrip(@ptrCast(decoded.samples), .{
                .sample_rate = decoded.sample_rate,
                .bits_per_sample = decoded.bits_per_sample,
                .block_size = 16,
                .subframe_mode = mode,
                .stream_info_mode = .complete,
            });
        }
    }
}

test "encode in fixed0 mode falls back to VERBATIM for a block with a sample of -2^31" {
    const allocator = std.testing.allocator;
    var channel = [_]i64{0} ** 32;
    channel[3] = std.math.minInt(i32); // first block only
    channel[20] = std.math.maxInt(i32); // second block: still a valid residual
    const samples = [_][]const i64{&channel};
    const bytes = try encodeToBytes(allocator, &samples, .{
        .sample_rate = 44100,
        .bits_per_sample = 32,
        .block_size = 16,
        .subframe_mode = .fixed0,
        .stream_info_mode = .complete,
    });
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    const parsed = try flacontainer.Stream.read(&reader, allocator);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.frames.len);
    try std.testing.expectEqual(audio.SubframeType.verbatim, parsed.frames[0].subframes[0].header.subframe_type);
    try std.testing.expectEqual(audio.SubframeType{ .fixed = 0 }, parsed.frames[1].subframes[0].header.subframe_type);

    try expectRoundTrip(&samples, .{
        .sample_rate = 44100,
        .bits_per_sample = 32,
        .block_size = 16,
        .subframe_mode = .fixed0,
        .stream_info_mode = .complete,
    });
}

test "encode rejects invalid input before writing anything" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const ok = [_]i64{ 1, 2, 3 };
    const base = Options{
        .sample_rate = 44100,
        .bits_per_sample = 16,
        .subframe_mode = .verbatim,
        .stream_info_mode = .unknown,
    };
    const one_channel = [_][]const i64{&ok};

    try std.testing.expectError(error.InvalidChannelCount, encode(allocator, &writer, &.{}, base));
    const nine = [_][]const i64{&ok} ** 9;
    try std.testing.expectError(error.InvalidChannelCount, encode(allocator, &writer, &nine, base));

    var options = base;
    options.bits_per_sample = 3;
    try std.testing.expectError(error.InvalidBitsPerSample, encode(allocator, &writer, &one_channel, options));
    options.bits_per_sample = 33;
    try std.testing.expectError(error.InvalidBitsPerSample, encode(allocator, &writer, &one_channel, options));
    options = base;
    options.sample_rate = 0;
    try std.testing.expectError(error.InvalidSampleRate, encode(allocator, &writer, &one_channel, options));
    options = base;
    options.block_size = 15;
    try std.testing.expectError(error.InvalidBlockSize, encode(allocator, &writer, &one_channel, options));

    const short = [_]i64{1};
    const uneven = [_][]const i64{ &ok, &short };
    try std.testing.expectError(error.ChannelLengthMismatch, encode(allocator, &writer, &uneven, base));
    const empty = [_][]const i64{&.{}};
    try std.testing.expectError(error.EmptyStream, encode(allocator, &writer, &empty, base));

    const too_big = [_]i64{32768};
    const too_small = [_]i64{-32769};
    try std.testing.expectError(error.SampleOutOfRange, encode(allocator, &writer, &[_][]const i64{&too_big}, base));
    try std.testing.expectError(error.SampleOutOfRange, encode(allocator, &writer, &[_][]const i64{&too_small}, base));

    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "riceParameter picks the parameter with the shortest code" {
    // All zeros fold to 0: parameter 0 costs 1 bit each.
    try std.testing.expectEqual(@as(u5, 0), riceParameter(&([_]i32{0} ** 16)));
    try std.testing.expectEqual(@as(u5, 0), riceParameter(&.{}));

    // Brute force: no other parameter may beat the chosen one.
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for ([_]i32{ 1, 5, 100, 5000, 1 << 20, 1 << 30 }) |magnitude| {
        var values: [64]i32 = undefined;
        for (&values) |*value| value.* = random.intRangeAtMost(i32, -magnitude, magnitude);
        const chosen = riceParameter(&values);
        for (0..max_rice_parameter + 1) |parameter| {
            try std.testing.expect(riceCost(&values, chosen) <= riceCost(&values, @intCast(parameter)));
        }
    }

    // The extremes of the allowed residual range stay in the 5-bit method.
    const extremes = [_]i32{ std.math.maxInt(i32), -std.math.maxInt(i32) };
    try std.testing.expect(riceParameter(&extremes) <= max_rice_parameter);
}

/// The length in bits of `values` Rice-coded with `parameter`.
fn riceCost(values: []const i32, parameter: u5) u64 {
    var cost: u64 = 0;
    for (values) |value| {
        const wide: i64 = value;
        const folded: u64 = if (wide >= 0) @as(u64, @intCast(wide)) << 1 else (@as(u64, @intCast(-wide)) << 1) - 1;
        cost += (folded >> parameter) + 1 + parameter;
    }
    return cost;
}
