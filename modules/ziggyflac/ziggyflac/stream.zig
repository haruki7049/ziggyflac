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
