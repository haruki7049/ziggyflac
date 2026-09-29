const std = @import("std");
const flacontainer = @import("flacontainer");
const subframe = @import("./subframe.zig");
const channel = @import("./channel.zig");

/// A fully decoded FLAC stream: the format parameters from STREAMINFO, and
/// every channel's samples across the whole stream, in playback order.
///
/// This type is owned by `ziggyflac`; it deliberately does not match any
/// other project's PCM type (see the `ziggyflac: Decode a FLAC stream into
/// PCM samples` issue for why that integration is deferred).
pub const DecodedStream = struct {
    /// Sample rate in Hz, from STREAMINFO.
    sample_rate: u20,
    /// Number of audio channels, from STREAMINFO.
    channels: u4,
    /// Bits per sample, from STREAMINFO.
    bits_per_sample: u6,
    /// Planar PCM samples: `samples[channel]` holds every sample of that
    /// channel across the whole stream, in playback order. Owned by this
    /// `DecodedStream` and freed by `deinit`.
    samples: [][]i64,

    pub fn deinit(self: DecodedStream, allocator: std.mem.Allocator) void {
        for (self.samples) |channel_samples| allocator.free(channel_samples);
        allocator.free(self.samples);
    }
};

/// Errors returned by `decode`.
pub const DecodeError = subframe.DecodeError || channel.DecodeError || error{
    /// A frame's channel count, after undoing its channel decorrelation,
    /// did not match STREAMINFO's declared channel count.
    ChannelCountMismatch,
};

/// Decodes every frame of `stream` - subframe prediction, wasted bits, and
/// channel decorrelation (RFC 9639 Section 9.2) - and assembles the result
/// into a single `DecodedStream` spanning the whole stream.
pub fn decode(allocator: std.mem.Allocator, stream: flacontainer.Stream) DecodeError!DecodedStream {
    const channel_count = stream.stream_info.channels;

    const buffers = try allocator.alloc(std.ArrayList(i64), channel_count);
    for (buffers) |*buffer| buffer.* = .empty;
    errdefer {
        for (buffers) |*buffer| buffer.deinit(allocator);
        allocator.free(buffers);
    }

    for (stream.frames) |frame| {
        const subframe_samples = try allocator.alloc([]i64, frame.subframes.len);
        var subframes_filled: usize = 0;
        defer {
            for (subframe_samples[0..subframes_filled]) |samples| allocator.free(samples);
            allocator.free(subframe_samples);
        }
        for (frame.subframes) |sub| {
            subframe_samples[subframes_filled] = try subframe.decode(allocator, sub, frame.header.block_size);
            subframes_filled += 1;
        }

        const frame_channels = try channel.decode(allocator, frame.header.channel_assignment, subframe_samples);
        defer {
            for (frame_channels) |samples| allocator.free(samples);
            allocator.free(frame_channels);
        }
        if (frame_channels.len != channel_count) return error.ChannelCountMismatch;

        for (buffers, frame_channels) |*buffer, samples| try buffer.appendSlice(allocator, samples);
    }

    const samples = try allocator.alloc([]i64, channel_count);
    var filled: usize = 0;
    errdefer {
        for (samples[0..filled]) |buffer_samples| allocator.free(buffer_samples);
        allocator.free(samples);
    }
    for (buffers, 0..) |*buffer, i| {
        samples[i] = try buffer.toOwnedSlice(allocator);
        filled += 1;
    }
    allocator.free(buffers);

    return .{
        .sample_rate = stream.stream_info.sample_rate,
        .channels = channel_count,
        .bits_per_sample = stream.stream_info.bits_per_sample,
        .samples = samples,
    };
}

fn testStreamInfo(channels: u4, sample_rate: u20, bits_per_sample: u6) flacontainer.metadata.StreamInfo {
    return .{
        .min_block_size = 0,
        .max_block_size = 0,
        .min_frame_size = 0,
        .max_frame_size = 0,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits_per_sample = bits_per_sample,
        .total_samples = 0,
        .md5_signature = [_]u8{0} ** 16,
    };
}

/// Builds a frame of CONSTANT subframes, one per channel, each repeating
/// `values[channel]` for `block_size` samples, for tests only.
fn testConstantFrame(
    allocator: std.mem.Allocator,
    channel_assignment: flacontainer.audio.ChannelAssignment,
    block_size: u16,
    values: []const i64,
) !flacontainer.audio.Frame {
    const subframes = try allocator.alloc(flacontainer.audio.Subframe, channel_assignment.channelCount());
    for (subframes, values) |*sub, value| {
        sub.* = .{
            .header = .{ .subframe_type = .constant, .wasted_bits = 0 },
            .body = .{ .constant = value },
        };
    }
    return .{
        .header = .{
            .blocking_strategy = .fixed,
            .block_size = block_size,
            .sample_rate = null,
            .channel_assignment = channel_assignment,
            .bits_per_sample = null,
            .coded_number = 0,
        },
        .subframes = subframes,
    };
}

/// Builds a frame of VERBATIM subframes, one per channel, from `raws`, for
/// tests only.
fn testVerbatimFrame(
    allocator: std.mem.Allocator,
    channel_assignment: flacontainer.audio.ChannelAssignment,
    raws: []const []const i64,
) !flacontainer.audio.Frame {
    const subframes = try allocator.alloc(flacontainer.audio.Subframe, channel_assignment.channelCount());
    for (subframes, raws) |*sub, raw| {
        sub.* = .{
            .header = .{ .subframe_type = .verbatim, .wasted_bits = 0 },
            .body = .{ .verbatim = try allocator.dupe(i64, raw) },
        };
    }
    return .{
        .header = .{
            .blocking_strategy = .fixed,
            .block_size = @intCast(raws[0].len),
            .sample_rate = null,
            .channel_assignment = channel_assignment,
            .bits_per_sample = null,
            .coded_number = 0,
        },
        .subframes = subframes,
    };
}

test "decode assembles per-channel samples across multiple frames" {
    const frames = [_]flacontainer.audio.Frame{
        try testConstantFrame(std.testing.allocator, .{ .independent = 2 }, 2, &.{ 1, 10 }),
        try testConstantFrame(std.testing.allocator, .{ .independent = 2 }, 2, &.{ 2, 20 }),
    };
    defer for (frames) |frame| frame.deinit(std.testing.allocator);

    const stream: flacontainer.Stream = .{
        .stream_info = testStreamInfo(2, 44_100, 16),
        .frames = @constCast(&frames),
    };

    const decoded = try decode(std.testing.allocator, stream);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u20, 44_100), decoded.sample_rate);
    try std.testing.expectEqual(@as(u4, 2), decoded.channels);
    try std.testing.expectEqual(@as(u6, 16), decoded.bits_per_sample);
    try std.testing.expectEqualSlices(i64, &.{ 1, 1, 2, 2 }, decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, &.{ 10, 10, 20, 20 }, decoded.samples[1]);
}

test "decode undoes a frame's channel decorrelation" {
    var left = [_]i64{ 10, 20 };
    var side = [_]i64{ 3, 5 };
    const frames = [_]flacontainer.audio.Frame{
        try testVerbatimFrame(std.testing.allocator, .left_side, &.{ &left, &side }),
    };
    defer for (frames) |frame| frame.deinit(std.testing.allocator);

    const stream: flacontainer.Stream = .{
        .stream_info = testStreamInfo(2, 8_000, 16),
        .frames = @constCast(&frames),
    };

    const decoded = try decode(std.testing.allocator, stream);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(i64, &.{ 10, 20 }, decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, &.{ 7, 15 }, decoded.samples[1]);
}

test "decode rejects a frame whose channel count differs from STREAMINFO" {
    const frames = [_]flacontainer.audio.Frame{
        try testConstantFrame(std.testing.allocator, .{ .independent = 1 }, 1, &.{5}),
    };
    defer for (frames) |frame| frame.deinit(std.testing.allocator);

    const stream: flacontainer.Stream = .{
        .stream_info = testStreamInfo(2, 8_000, 16),
        .frames = @constCast(&frames),
    };

    try std.testing.expectError(error.ChannelCountMismatch, decode(std.testing.allocator, stream));
}

test "decode calls channel.decode per frame, not once for the whole stream" {
    // Frame 0 is independent; frame 1 is left_side. If decode assumed a
    // single stream-wide channel assignment (e.g. read from the first frame
    // only), it would misinterpret frame 1's samples.
    const frames = [_]flacontainer.audio.Frame{
        try testConstantFrame(std.testing.allocator, .{ .independent = 2 }, 2, &.{ 5, -5 }),
        try testVerbatimFrame(std.testing.allocator, .left_side, &.{ &.{ 10, 20 }, &.{ 3, 5 } }),
    };
    defer for (frames) |frame| frame.deinit(std.testing.allocator);

    const stream: flacontainer.Stream = .{
        .stream_info = testStreamInfo(2, 8_000, 16),
        .frames = @constCast(&frames),
    };

    const decoded = try decode(std.testing.allocator, stream);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(i64, &.{ 5, 5, 10, 20 }, decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, &.{ -5, -5, 7, 15 }, decoded.samples[1]);
}

/// Reads `bytes` as interleaved little-endian `SampleType`-wide PCM and
/// splits it into `channel_count` planar `i64` sample arrays, for comparing
/// against `DecodedStream.samples` in tests. Owned by the caller and freed
/// the same way as `DecodedStream.samples`.
fn readReferencePcm(comptime SampleType: type, allocator: std.mem.Allocator, bytes: []const u8, channel_count: usize) ![][]i64 {
    const bytes_per_sample = @divExact(@typeInfo(SampleType).int.bits, 8);
    const sample_count = bytes.len / (channel_count * bytes_per_sample);

    const channels = try allocator.alloc([]i64, channel_count);
    var filled: usize = 0;
    errdefer {
        for (channels[0..filled]) |samples| allocator.free(samples);
        allocator.free(channels);
    }
    for (channels) |*samples| {
        samples.* = try allocator.alloc(i64, sample_count);
        filled += 1;
    }

    for (0..sample_count) |i| {
        for (channels, 0..) |samples, ch| {
            const offset = (i * channel_count + ch) * bytes_per_sample;
            samples[i] = std.mem.readInt(SampleType, bytes[offset..][0..bytes_per_sample], .little);
        }
    }
    return channels;
}

test "decode reconstructs a real mono FLAC file's PCM samples" {
    // 100 samples, 8 kHz, mono, 16-bit sine wave, from reference libFLAC
    // 1.5.0 (same fixture as flacontainer's "tiny.flac" test); tiny.pcm is
    // its reference PCM output, decoded independently via sox.
    const flac_bytes = @embedFile("../testdata/tiny.flac");
    const pcm_bytes = @embedFile("../testdata/tiny.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a real FLAC file spanning multiple frames, including FIXED, VERBATIM, and wasted bits" {
    // The exact same 100-sample sine wave as "tiny.flac", but encoded with a
    // 32-sample blocksize so it spans 4 frames instead of 1: three 32-sample
    // FIXED-order-4 frames and a final 4-sample VERBATIM frame with
    // wasted_bits=1 (confirmed by inspecting the parsed frames directly).
    // Byte-identical to tiny.flac's own PCM when decoded independently via
    // sox, so tiny.pcm doubles as its reference here too.
    const flac_bytes = @embedFile("../testdata/multiframe.flac");
    const pcm_bytes = @embedFile("../testdata/tiny.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expect(container_stream.frames.len > 1);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a real FLAC file's silence via a real CONSTANT subframe" {
    // 50 samples of digital silence, 8 kHz, mono, 16-bit, from reference
    // libFLAC 1.5.0 (same fixture as flacontainer's "silence.flac" test).
    // The reference is trivially all zeros, so no separate PCM fixture is
    // needed.
    const flac_bytes = @embedFile("../testdata/silence.flac");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(flacontainer.audio.SubframeType.constant, container_stream.frames[0].subframes[0].header.subframe_type);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = [_]i64{0} ** 50;
    try std.testing.expectEqualSlices(i64, &expected, decoded.samples[0]);
}

test "decode reconstructs a real FLAC file using left_side channel assignment" {
    // 50 samples, 8 kHz, 2 channels, 16-bit: a mono tone duplicated into both
    // channels, encoded by SoX 14.4.2. Identical channels reliably make SoX's
    // FLAC writer pick left_side (confirmed by inspecting the parsed frame
    // directly) - previously, the only real-encoder stereo fixture
    // (stereo.flac) happened to use independent channel assignment, so
    // left_side/right_side were only exercised by channel.zig's synthetic
    // unit tests.
    const flac_bytes = @embedFile("../testdata/leftside.flac");
    const pcm_bytes = @embedFile("../testdata/leftside.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(flacontainer.audio.ChannelAssignment.left_side, container_stream.frames[0].header.channel_assignment);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 2);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, expected[1], decoded.samples[1]);
}

test "decode reconstructs a real FLAC file using right_side channel assignment" {
    // 50 samples, 8 kHz, 2 channels, 16-bit: the same tone on both channels,
    // one inverted in phase, encoded by SoX 14.4.2. Inverted-phase channels
    // reliably make SoX's FLAC writer pick right_side (confirmed by
    // inspecting the parsed frame directly).
    const flac_bytes = @embedFile("../testdata/rightside.flac");
    const pcm_bytes = @embedFile("../testdata/rightside.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(flacontainer.audio.ChannelAssignment.right_side, container_stream.frames[0].header.channel_assignment);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 2);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, expected[1], decoded.samples[1]);
}

test "decode reconstructs a real FLAC file using mid_side channel assignment" {
    // 400 samples, 8 kHz, 2 channels, 16-bit: two tones (300 Hz, 700 Hz) each
    // mixed into both channels at a roughly 2:1 ratio (so neither channel is
    // simply a scaled or phase-shifted copy of the other, unlike the
    // left_side/right_side fixtures above), encoded by the reference `flac`
    // 1.5.0 encoder at --best. SoX's FLAC writer never picked mid_side for
    // any stereo signal shape tried; the reference encoder did, but only
    // once enough samples (400) were present for its per-frame bit-cost
    // estimate to favor it over left_side/right_side/independent - shorter
    // (50-sample) versions of the same signal picked one of those instead.
    // Channel assignment confirmed by inspecting the parsed frame directly.
    const flac_bytes = @embedFile("../testdata/midside.flac");
    const pcm_bytes = @embedFile("../testdata/midside.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(flacontainer.audio.ChannelAssignment.mid_side, container_stream.frames[0].header.channel_assignment);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 2);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, expected[1], decoded.samples[1]);
}

test "decode reconstructs a real stereo FLAC file's PCM samples, undoing channel decorrelation" {
    // 100 samples, 8 kHz, 2 channels, 16-bit, two different sine tones, from
    // reference libFLAC 1.5.0 (same fixture as flacontainer's "stereo.flac"
    // test); stereo.pcm is its reference PCM output, decoded independently
    // via sox.
    const flac_bytes = @embedFile("../testdata/stereo.flac");
    const pcm_bytes = @embedFile("../testdata/stereo.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 2);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
    try std.testing.expectEqualSlices(i64, expected[1], decoded.samples[1]);
}

test "decode reconstructs an 8-bit FLAC file's PCM samples" {
    // 50 samples, 8 kHz, mono, 8-bit sine wave, encoded by SoX 14.4.2 (a
    // different encoder than the other fixtures, and libFLAC's smallest
    // supported bit depth).
    const flac_bytes = @embedFile("../testdata/bitdepth8.flac");
    const pcm_bytes = @embedFile("../testdata/bitdepth8.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i8, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqual(@as(u6, 8), decoded.bits_per_sample);
    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a 24-bit FLAC file's PCM samples" {
    // 50 samples, 8 kHz, mono, 24-bit sine wave, encoded by SoX 14.4.2.
    const flac_bytes = @embedFile("../testdata/bitdepth24.flac");
    const pcm_bytes = @embedFile("../testdata/bitdepth24.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i24, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqual(@as(u6, 24), decoded.bits_per_sample);
    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a 32-bit FLAC file's PCM samples" {
    // 50 samples, 8 kHz, mono, 32-bit sine wave. SoX cannot write FLAC above
    // 24-bit, so this was generated as raw signed 32-bit little-endian PCM
    // and encoded with the reference libFLAC 1.5.0 encoder's
    // `--force-raw-format` (run ad hoc via `nix run nixpkgs#flac --`, not
    // added as a project dependency). Verified independently by decoding
    // back to raw PCM with sox, confirmed byte-identical to the original
    // generated samples.
    //
    // 12-bit and 20-bit (the other bits-per-sample values RFC 9639 Section
    // 9.1.3's frame-header code can express directly) are not covered here:
    // neither SoX nor the reference flac encoder's raw-PCM import accepts
    // any bit depth other than 8/16/24/32 (byte-aligned containers only), so
    // producing them would require hand-crafting a bitstream with a
    // test-only bit-writer that doesn't exist yet in this repo - judged not
    // worth building for this one case.
    const flac_bytes = @embedFile("../testdata/bitdepth32.flac");
    const pcm_bytes = @embedFile("../testdata/bitdepth32.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i32, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqual(@as(u6, 32), decoded.bits_per_sample);
    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a FLAC file with a block size requiring the 16-bit escape code" {
    // 1000 samples, 8 kHz, mono, 16-bit, encoded as a single 1000-sample
    // frame via the reference flac 1.5.0 encoder's `--blocksize=1000` (run ad
    // hoc via `nix run nixpkgs#flac --`, not added as a project dependency).
    // RFC 9639 Section 9.1.2's block-size code has direct entries only for
    // specific sizes (192; 576-4608 by doubling; 256-32768 by doubling) plus
    // an 8-bit escape (up to 256) and a 16-bit escape; 1000 matches none of
    // the direct codes and exceeds the 8-bit escape's range, so flacontainer
    // must have used the 16-bit escape to parse this frame's header at all -
    // confirmed by inspecting the parsed frame's block_size directly before
    // committing the fixture. `multiframe.flac` (see #74) already exercises
    // the 8-bit escape (a 32-sample blocksize).
    const flac_bytes = @embedFile("../testdata/largeblocksize.flac");
    const pcm_bytes = @embedFile("../testdata/largeblocksize.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 1000), container_stream.frames[0].header.block_size);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a 4-channel independent FLAC file's PCM samples" {
    // 50 samples, 8 kHz, 4 independent channels (each a different sine
    // tone), encoded by SoX 14.4.2. Independent channel assignment was
    // previously only exercised with 1-2 channels.
    const flac_bytes = @embedFile("../testdata/multichannel.flac");
    const pcm_bytes = @embedFile("../testdata/multichannel.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 4);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqual(@as(u4, 4), decoded.channels);
    for (expected, decoded.samples) |expected_channel, actual_channel| {
        try std.testing.expectEqualSlices(i64, expected_channel, actual_channel);
    }
}

test "decode reconstructs an 8-channel independent FLAC file's PCM samples" {
    // 50 samples, 8 kHz, 8 independent channels (each a different sine
    // tone), encoded by SoX 14.4.2. 8 is the format's maximum channel count
    // (ChannelAssignment.independent's count is a u4); channel.decode's
    // independent branch has no channel-count-specific logic, so this
    // exercises only the upper boundary beyond the 4-channel case above.
    const flac_bytes = @embedFile("../testdata/channels8.flac");
    const pcm_bytes = @embedFile("../testdata/channels8.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 8);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqual(@as(u4, 8), decoded.channels);
    for (expected, decoded.samples) |expected_channel, actual_channel| {
        try std.testing.expectEqualSlices(i64, expected_channel, actual_channel);
    }
}

test "decode reconstructs a 44.1 kHz FLAC file's PCM samples" {
    // 200 samples, 44.1 kHz, mono, 16-bit sine wave, encoded by SoX 14.4.2.
    // Every other fixture uses 8 kHz; this exercises a different STREAMINFO
    // sample rate.
    const flac_bytes = @embedFile("../testdata/samplerate44100.flac");
    const pcm_bytes = @embedFile("../testdata/samplerate44100.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqual(@as(u20, 44_100), decoded.sample_rate);
    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a real FLAC file with samples clipped to the exact 16-bit boundaries" {
    // 50 samples, 8 kHz, mono, 16-bit: a sine wave heavily overdriven (+20 dB)
    // so it repeatedly hard-clips to exactly i16's minimum (-32768) and
    // maximum (32767), encoded by SoX 14.4.2. Every other sine-wave fixture's
    // samples rarely land on the exact integer boundary; this catches any
    // off-by-one or overflow bug specific to those extremes.
    const flac_bytes = @embedFile("../testdata/clipping.flac");
    const pcm_bytes = @embedFile("../testdata/clipping.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expect(std.mem.indexOfScalar(i64, expected[0], std.math.minInt(i16)) != null);
    try std.testing.expect(std.mem.indexOfScalar(i64, expected[0], std.math.maxInt(i16)) != null);
    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a real FLAC file exercising FIXED orders 0 through 3" {
    // 200 samples, 8 kHz, mono, 16-bit, four 50-sample frames each chosen to
    // make a specific FIXED order optimal: white noise (order 0), a sawtooth
    // (order 1), a 100 Hz sine (order 2), and a 300 Hz sine (order 3),
    // encoded with the reference flac 1.5.0 encoder's `-l 0` (LPC disabled,
    // so only FIXED predictors are considered; run ad hoc via
    // `nix run nixpkgs#flac --`, not added as a project dependency). Every
    // other real-encoder fixture that happens to use FIXED (multiframe.flac,
    // #74) uses order 4; orders 0-3 were previously only exercised by
    // subframe.zig's synthetic unit tests. Orders confirmed by inspecting
    // each parsed frame's subframe type directly before committing the
    // fixture.
    const flac_bytes = @embedFile("../testdata/fixedorders.flac");
    const pcm_bytes = @embedFile("../testdata/fixedorders.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), container_stream.frames.len);
    for (container_stream.frames, 0..) |frame, order| {
        try std.testing.expectEqual(
            flacontainer.audio.SubframeType{ .fixed = @intCast(order) },
            frame.subframes[0].header.subframe_type,
        );
    }

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a real FLAC file using a non-default LPC order" {
    // 50 samples, 8 kHz, mono, 16-bit, 440 Hz sine, encoded with the
    // reference flac 1.5.0 encoder's `-l 2 -e` (max LPC order 2, exhaustive
    // model search). Every other real-encoder fixture that uses LPC
    // (tiny.flac, stereo.flac, seektable.flac) happens to use order 4; order
    // 2 was previously only exercised by subframe.zig's synthetic unit
    // tests. Order confirmed by inspecting the parsed frame directly.
    const flac_bytes = @embedFile("../testdata/lpcorder2.flac");
    const pcm_bytes = @embedFile("../testdata/lpcorder2.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        flacontainer.audio.SubframeType{ .lpc = 2 },
        container_stream.frames[0].subframes[0].header.subframe_type,
    );

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}

test "decode reconstructs a real FLAC file using a higher non-default LPC order" {
    // 100 samples, 8 kHz, mono, 16-bit, four summed sine tones (300, 700,
    // 1100, 1900 Hz), encoded with the reference flac 1.5.0 encoder's
    // `-l 6 -e` (max LPC order 6, exhaustive model search). The richer
    // multi-tone content makes a higher order actually pay off, unlike a
    // pure sine. Order confirmed by inspecting the parsed frame directly.
    const flac_bytes = @embedFile("../testdata/lpcorder6.flac");
    const pcm_bytes = @embedFile("../testdata/lpcorder6.pcm");

    var reader: std.Io.Reader = .fixed(flac_bytes);
    const container_stream = try flacontainer.Stream.read(&reader, std.testing.allocator);
    defer container_stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        flacontainer.audio.SubframeType{ .lpc = 6 },
        container_stream.frames[0].subframes[0].header.subframe_type,
    );

    const decoded = try decode(std.testing.allocator, container_stream);
    defer decoded.deinit(std.testing.allocator);

    const expected = try readReferencePcm(i16, std.testing.allocator, pcm_bytes, 1);
    defer {
        for (expected) |samples| std.testing.allocator.free(samples);
        std.testing.allocator.free(expected);
    }

    try std.testing.expectEqualSlices(i64, expected[0], decoded.samples[0]);
}
