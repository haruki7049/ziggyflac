//! Interoperability tests: streams written by `ziggyflac.encoder.encode` are
//! decoded by the reference `flac` decoder, and the PCM it writes is compared
//! with the samples that were encoded.
//!
//! The encoder is otherwise only checked against this repository's own
//! decoder, so a stream that both misread in the same way would go unnoticed.
//! `flac` checks the frame CRCs and, when STREAMINFO carries one, the MD5
//! signature of the audio, so a stream it accepts is well formed.
//!
//! `flac` is only a test-time tool. If it is not on `PATH`, the tests are
//! skipped, unless the build option `-Dflac-interop=required` is given, in
//! which case they fail.
//!
//! The parameter space is covered in layers rather than as a full Cartesian
//! product, whose size would explode:
//!
//! - Layer A: every value of one axis at a time, the other axes at a baseline.
//! - Layer B: every bit depth x channel count x subframe mode x STREAMINFO mode.
//! - Layer C: every content kind x length kind, applied to every Layer A case.
//! - Layer D: a fixed-seed pseudo-random sample of further combinations.
const std = @import("std");
const ziggyflac = @import("ziggyflac");
const build_options = @import("build_options");

const encoder = ziggyflac.encoder;

/// What the samples of a test stream contain.
const Content = enum { silence, max, min, noise, ramp };

/// How long a test stream is, relative to its block size.
const Length = enum {
    /// Shorter than one block, so there is a single, short frame.
    shorter_than_block,
    /// Exactly two blocks.
    block_multiple,
    /// Two blocks and a shorter last frame.
    short_last_frame,
};

/// One encoder run to be checked against `flac`.
const Case = struct {
    channels: u4 = baseline.channels,
    bits_per_sample: u6 = baseline.bits_per_sample,
    block_size: u16 = baseline.block_size,
    sample_rate: u20 = baseline.sample_rate,
    subframe_mode: encoder.SubframeMode = .fixed0,
    stream_info_mode: encoder.StreamInfoMode = .complete,
    content: Content = .noise,
    length: Length = .short_last_frame,
    /// Seeds the pseudo-random content.
    seed: u64 = 1,

    /// The number of interchannel samples in the stream.
    fn sampleCount(case: Case) usize {
        const block_size: usize = case.block_size;
        return switch (case.length) {
            .shorter_than_block => @max(1, block_size / 2),
            .block_multiple => 2 * block_size,
            .short_last_frame => 2 * block_size + @max(1, block_size / 3),
        };
    }
};

/// The value of every axis that a Layer A case does not vary.
const baseline = struct {
    const channels: u4 = 2;
    const bits_per_sample: u6 = 16;
    const block_size: u16 = 576;
    const sample_rate: u20 = 44100;
};

/// Block sizes at the boundaries of every block size code, and both escape
/// codes (RFC 9639 Section 9.1.1).
const block_sizes = [_]u16{ 16, 192, 255, 256, 257, 576, 4096, 4608, 16384, 32768, 65535 };

/// Sample rates with a dedicated frame header code (RFC 9639 Section 9.1.2)...
const coded_sample_rates = [_]u20{ 8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000 };
/// ... and rates that are written as a reference to STREAMINFO.
const referenced_sample_rates = [_]u20{ 1, 11025, 12340, 1048575 };

const subframe_modes = [_]encoder.SubframeMode{ .verbatim, .fixed0 };
const stream_info_modes = [_]encoder.StreamInfoMode{ .complete, .unknown };

/// Prints the case that failed, so that a failure can be reproduced.
fn reportFailure(case: Case) void {
    std.debug.print("interop case failed: {any}\n", .{case});
}

/// Fails the test when `flac` is required but missing, and skips it when
/// `flac` is missing but not required.
fn requireFlac() !void {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "flac", "--version" },
    }) catch |err| switch (err) {
        error.FileNotFound => return missingFlac(),
        else => |e| return e,
    };
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.FlacVersionFailed;
}

fn missingFlac() error{ FlacNotFound, SkipZigTest } {
    if (build_options.flac_required) {
        std.debug.print("`flac` was not found on PATH, but -Dflac-interop=required was given\n", .{});
        return error.FlacNotFound;
    }
    return error.SkipZigTest;
}

/// The smallest value of a signed `bits_per_sample`-bit sample.
fn minSample(bits_per_sample: u6) i64 {
    return -(@as(i64, 1) << (bits_per_sample - 1));
}

/// The largest value of a signed `bits_per_sample`-bit sample.
fn maxSample(bits_per_sample: u6) i64 {
    return (@as(i64, 1) << (bits_per_sample - 1)) - 1;
}

/// Allocates planar samples (`samples[channel][index]`) for `case`. Free them
/// with `freeSamples`.
fn generateSamples(allocator: std.mem.Allocator, case: Case) ![][]i64 {
    const length = case.sampleCount();
    const min = minSample(case.bits_per_sample);
    const max = maxSample(case.bits_per_sample);
    const range: u64 = @as(u64, 1) << case.bits_per_sample;
    const step: u64 = @max(1, range / 1000);

    const channels = try allocator.alloc([]i64, case.channels);
    var built: usize = 0;
    errdefer {
        for (channels[0..built]) |channel| allocator.free(channel);
        allocator.free(channels);
    }
    var prng: std.Random.DefaultPrng = .init(case.seed);
    for (channels, 0..) |*channel, channel_index| {
        channel.* = try allocator.alloc(i64, length);
        built += 1;
        for (channel.*, 0..) |*sample, index| {
            sample.* = switch (case.content) {
                .silence => 0,
                .max => max,
                .min => min,
                .noise => prng.random().intRangeAtMost(i64, min, max),
                .ramp => min + @as(i64, @intCast((index * step + channel_index * 7) % range)),
            };
        }
    }
    return channels;
}

fn freeSamples(allocator: std.mem.Allocator, samples: [][]i64) void {
    for (samples) |channel| allocator.free(channel);
    allocator.free(samples);
}

/// Encodes `case`, has `flac` decode the stream, and compares the PCM it
/// writes with the samples that were encoded. `dir` holds the temporary files.
fn checkCase(dir: std.Io.Dir, case: Case) !void {
    errdefer reportFailure(case);
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const samples = try generateSamples(allocator, case);
    defer freeSamples(allocator, samples);

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try encoder.encode(allocator, &encoded.writer, @ptrCast(samples), .{
        .sample_rate = case.sample_rate,
        .bits_per_sample = case.bits_per_sample,
        .block_size = case.block_size,
        .subframe_mode = case.subframe_mode,
        .stream_info_mode = case.stream_info_mode,
    });
    try dir.writeFile(io, .{ .sub_path = "in.flac", .data = encoded.written() });

    // WAVE output is used because raw output only supports 8, 16, 24, and 32
    // bits per sample. WAVE has no such limit: a sample is stored in the
    // smallest whole number of bytes that holds it, shifted to the most
    // significant bits.
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "flac", "--decode", "--silent", "--force", "--output-name=out.wav", "in.flac" },
        .cwd = .{ .dir = dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("flac rejected the stream ({any}): {s}\n", .{ result.term, result.stderr });
        return error.FlacRejectedStream;
    }

    const wave = try dir.readFileAlloc(io, "out.wav", allocator, .unlimited);
    defer allocator.free(wave);
    const actual = try waveData(wave);
    const expected = try wavePcm(allocator, samples, case.bits_per_sample);
    defer allocator.free(expected);
    try std.testing.expectEqual(expected.len, actual.len);
    try std.testing.expect(std.mem.eql(u8, expected, actual));
}

/// The contents of the `data` chunk of a WAVE file.
fn waveData(wave: []const u8) ![]const u8 {
    if (wave.len < 12 or !std.mem.eql(u8, wave[0..4], "RIFF") or !std.mem.eql(u8, wave[8..12], "WAVE")) {
        return error.NotWave;
    }
    var position: usize = 12;
    while (position + 8 <= wave.len) {
        const size = std.mem.readInt(u32, wave[position + 4 ..][0..4], .little);
        const body = position + 8;
        if (std.mem.eql(u8, wave[position..][0..4], "data")) {
            if (body + size > wave.len) return error.TruncatedWave;
            return wave[body..][0..size];
        }
        // Chunks are padded to an even size.
        position = body + size + (size & 1);
    }
    return error.NoDataChunk;
}

/// The PCM that `flac --decode` writes into the `data` chunk of a WAVE file
/// for `samples`: interleaved and little-endian, in the smallest whole number
/// of bytes that holds a sample, shifted to its most significant bits. A
/// one-byte sample is unsigned, the rest are signed. Free the result with
/// `allocator`.
fn wavePcm(allocator: std.mem.Allocator, samples: []const []const i64, bits_per_sample: u6) ![]u8 {
    const bytes_per_sample: usize = (@as(usize, bits_per_sample) + 7) / 8;
    const shift: u6 = @intCast(8 * bytes_per_sample - bits_per_sample);
    const length = samples[0].len;
    const pcm = try allocator.alloc(u8, length * samples.len * bytes_per_sample);
    var position: usize = 0;
    for (0..length) |index| {
        for (samples) |channel| {
            var value = channel[index] << shift;
            if (bytes_per_sample == 1) value += 128;
            const unsigned: u64 = @bitCast(value);
            for (0..bytes_per_sample) |byte| {
                pcm[position] = @truncate(unsigned >> @intCast(8 * byte));
                position += 1;
            }
        }
    }
    return pcm;
}

/// Every Layer A case: one axis varies over all its values, the others stay at
/// the baseline. Free the result with `allocator`.
fn layerA(allocator: std.mem.Allocator) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    errdefer cases.deinit(allocator);
    for (4..33) |bits_per_sample| {
        try cases.append(allocator, .{ .bits_per_sample = @intCast(bits_per_sample) });
    }
    for (1..9) |channels| {
        try cases.append(allocator, .{ .channels = @intCast(channels) });
    }
    for (block_sizes) |block_size| {
        try cases.append(allocator, .{ .block_size = block_size });
    }
    for (coded_sample_rates ++ referenced_sample_rates) |sample_rate| {
        try cases.append(allocator, .{ .sample_rate = sample_rate });
    }
    return cases.toOwnedSlice(allocator);
}

test "Layer A: every value of each axis, the others at a baseline" {
    try requireFlac();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = try layerA(std.testing.allocator);
    defer std.testing.allocator.free(cases);
    for (cases) |case| try checkCase(tmp.dir, case);
}

test "Layer B: every bit depth x channel count x subframe mode x STREAMINFO mode" {
    try requireFlac();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (4..33) |bits_per_sample| {
        for (1..9) |channels| {
            for (subframe_modes) |subframe_mode| {
                for (stream_info_modes) |stream_info_mode| {
                    try checkCase(tmp.dir, .{
                        .bits_per_sample = @intCast(bits_per_sample),
                        .channels = @intCast(channels),
                        .block_size = 256,
                        .subframe_mode = subframe_mode,
                        .stream_info_mode = stream_info_mode,
                        .seed = bits_per_sample * 16 + channels,
                    });
                }
            }
        }
    }
}

test "Layer C: every content and length, for every Layer A case" {
    try requireFlac();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = try layerA(std.testing.allocator);
    defer std.testing.allocator.free(cases);
    for (cases) |base| {
        for (std.enums.values(Content)) |content| {
            for (std.enums.values(Length)) |length| {
                var case = base;
                case.content = content;
                case.length = length;
                try checkCase(tmp.dir, case);
            }
        }
    }
}

/// How many pseudo-random combinations Layer D tries.
const layer_d_count = 300;
/// The seed of Layer D. It is fixed so that a failure is reproducible.
const layer_d_seed = 0x5eed_f1ac;

test "Layer D: a fixed-seed pseudo-random sample of further combinations" {
    try requireFlac();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var prng: std.Random.DefaultPrng = .init(layer_d_seed);
    const random = prng.random();
    for (0..layer_d_count) |_| {
        const block_size = if (random.boolean())
            random.intRangeAtMost(u16, 16, 4608)
        else
            random.intRangeAtMost(u16, 16, 65535);
        try checkCase(tmp.dir, .{
            .channels = random.intRangeAtMost(u4, 1, 8),
            .bits_per_sample = random.intRangeAtMost(u6, 4, 32),
            .block_size = block_size,
            .sample_rate = if (random.boolean())
                random.intRangeAtMost(u20, 1, std.math.maxInt(u20))
            else
                coded_sample_rates[random.uintLessThan(usize, coded_sample_rates.len)],
            .subframe_mode = random.enumValue(encoder.SubframeMode),
            .stream_info_mode = random.enumValue(encoder.StreamInfoMode),
            .content = random.enumValue(Content),
            .length = random.enumValue(Length),
            .seed = random.int(u64),
        });
    }
}
